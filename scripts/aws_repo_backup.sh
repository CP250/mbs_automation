#!/bin/bash
# aws_repo_backup.sh - encrypted offsite backup of the mbs_aws infrastructure repo.
#
# WHY THIS EXISTS (2026-08-15)
# ---------------------------
# HANDOFF.md section 10b, found 2026-08-14: ~/dev/mbs_aws had no offsite copy of
# any kind. Same shape as the vault gap found on 2026-08-09, one layer down.
# Verified at the time:
#   - `git remote -v` is EMPTY, so every commit lives on one disk
#   - bulk_sync.sh copies ~/storage_mbs_assets only; vault_backup.sh copies
#     ~/Vaults/storage_mbs only. Neither job has ever touched ~/dev
#   - Time Machine still has AutoBackup=0
# A partial manual fix on 2026-08-14 pushed the four terraform.tfstate files to
# sensitive:_infra/terraform/ by hand. That closed the worst of it and nothing
# refreshed it afterwards, so it went stale the moment anyone ran an apply. This
# job replaces that hand-work with a schedule.
#
# WHAT IT DOES
# ------------
# One-way `rclone copy` of the whole repo into the SENSITIVE crypt domain at
# sensitive:_infra/mbs_aws/, client-side encrypted before anything leaves the
# Mac. It lands beside sensitive:_vault/ (the Obsidian vault) under the same key.
#
# TIER: sensitive, and that is forced, not chosen. Terraform state files record
# resource attributes verbatim, which for this estate includes values that must
# never sit under the bulk key the long-lived automation EC2 instance is allowed
# to hold. HANDOFF.md's own note on the gap says the same thing about the
# alternative: a private git remote would work mechanically, but repo rule 2 is
# that nothing with a secret in it goes to a third party, so `sensitive:` is the
# destination and GitHub is not.
#
# COPY, NEVER SYNC. Additive only; a local deletion never propagates to S3.
# Structural invariant from adr_2026-07-30_two_location_storage_model.md ("no
# --delete, ever"), and the bucket's noncurrent version retention is the second
# net under it. If pruning S3 is ever wanted it is a separate, deliberate,
# reviewed act, not a flag on this script.
#
# WHAT IS EXCLUDED, and it is exactly one thing:
#   .terraform/**   2.6 GB of downloaded provider plugin binaries across the
#                   four stacks (measured 2026-08-15: 665M 00-org, 665M
#                   10-storage, 648M 20-iot, 648M 30-home). Pure cache:
#                   `terraform init` re-downloads all of it from the registry,
#                   and the exact versions are pinned by the .terraform.lock.hcl
#                   files, which ARE backed up. Excluding it takes the payload
#                   from 2.6 GB / 212 files down to 2.0 MB / 198 files, a 1,300x
#                   reduction that loses nothing recoverable.
#   Plus the usual macOS filesystem noise (.DS_Store and friends), same list as
#   the sibling jobs.
# NOT excluded, on purpose:
#   .git/           920 KB, and it buys point-in-time recovery of every file
#                   through the repo's whole history rather than just "latest".
#                   With no git remote this is the ONLY copy of that history.
#   *.tfstate, *.tfstate.backup   the entire reason the gap was urgent. State
#                   describes five live AWS accounts; losing it means orphaned
#                   resources and a manual reconciliation.
#   tfplan-*        saved binary plans from the 2026-08-11 approvals. Evidence.
#   _to_delete/     144 KB, and its name is a to-do, not a verdict. Backing up
#                   something P has not actually deleted yet costs nothing;
#                   deciding on his behalf that it is disposable does not.
#
# COMPARISON: rclone's DEFAULT size+modtime, deliberately NOT the --size-only
# that bulk_sync.sh and vault_backup.sh use. Their reason does not apply here.
# --size-only exists in those jobs because the pre-2026-08-08 backups were
# written by `aws s3 sync`, which does not preserve source mtimes, so every
# migrated object carries an upload time and a modtime comparison would re-upload
# the world. This destination is brand new and every object in it will be written
# by this script from a local file whose mtime rclone preserves, so modtime
# comparison is both correct and strictly better: it catches an edit that leaves
# a file exactly the same length, which for Terraform state and markdown is a
# real possibility rather than a theoretical one.
#
# SCHEDULE: daily 03:45 (see scripts/launchd/com.mbs.aws-repo-backup.plist),
# staying clear of com.mbs.bulk-sync at 03:00 and com.mbs.vault-backup at 03:15.
# Unlike bulk_sync.sh there is deliberately NO per-day "already ran, skip" stamp,
# for the same reason vault_backup.sh has none: the copy is incremental and
# idempotent, a re-run of an unchanged 2 MB tree is a handful of HEAD requests,
# and more often is strictly better. The stamp exists for the watchdog to read,
# not to gate execution. A lock still prevents overlap.
#
# WATCHDOG: mbs_heartbeat.sh check 18, age-based at 30 hours, self-arming on
# this job's plist being installed. The stamp is written in LIVE mode only (see
# the note at the bottom of this script), so a rehearsal can never make the
# watchdog report a backup that did not happen.
#
# No claude, no LLM, no vault writes, no network service other than S3.

set -uo pipefail

SRC="${MBS_AWS_REPO_DIR:-/Users/cpreston/dev/mbs_aws}"
DEST="${MBS_AWS_REPO_REMOTE:-sensitive:_infra/mbs_aws}"
KEYCHAIN_ITEM="${MBS_RCLONE_KEYCHAIN_ITEM:-mbs-rclone-config}"

# Sanity ceiling for the post-copy size check, in MB. The payload measured
# 2.0 MB on 2026-08-15 and this tree grows by kilobytes, so anything near this
# number means the .terraform exclusion stopped working and 2.6 GB of provider
# binaries are being pushed into the sensitive bucket. Raise it deliberately if
# the repo ever legitimately grows; do not remove it.
SANITY_MAX_MB="${MBS_AWS_REPO_BACKUP_MAX_MB:-100}"

STATE_DIR="$HOME/.mbs_automation"
STAMP="$STATE_DIR/last_aws_repo_backup_run"
LOG="$STATE_DIR/aws_repo_backup.log"

mkdir -p "$STATE_DIR"

# Always Eastern, P's timezone (matches every other job in this cluster).
TODAY="$(TZ=America/New_York date +%Y-%m-%d)"
ts() { TZ=America/New_York date '+%Y-%m-%d %H:%M:%S'; }

# Single-instance lock (mbs_daily.sh pattern). mkdir is atomic; a stale lock
# whose holder is gone is reclaimed rather than blocking forever.
LOCK_DIR="$STATE_DIR/aws_repo_backup.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  HOLDER_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -n "${HOLDER_PID:-}" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
    echo "$(ts) - another instance is running (PID $HOLDER_PID), exiting cleanly" >> "$LOG"
    exit 0
  fi
  echo "$(ts) - stale lock (holder PID ${HOLDER_PID:-unknown}), claiming" >> "$LOG"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || {
    echo "$(ts) - ERROR: could not claim lock, aborting" >> "$LOG"; exit 1; }
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

if [ ! -d "$SRC" ]; then
  echo "$(ts) - ERROR: repo not found at $SRC" >> "$LOG"
  exit 1
fi

# launchd starts jobs with a minimal PATH.
export PATH="$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# The official rclone.org binary, not Homebrew's. The S3 mounts already depend
# on this one; pinning it here keeps a single binary in play.
RCLONE_BIN="$HOME/bin/rclone"
[ -x "$RCLONE_BIN" ] || RCLONE_BIN="$(command -v rclone || true)"
if [ -z "$RCLONE_BIN" ] || [ ! -x "$RCLONE_BIN" ]; then
  echo "$(ts) - ERROR: rclone not found (looked at \$HOME/bin/rclone and PATH)" >> "$LOG"
  exit 1
fi

# The rclone config is encrypted and cannot prompt under launchd; the config
# password comes from the login Keychain. Never echoed: rclone consumes the
# command's stdout directly. Note this is required even for LOCAL paths, because
# rclone loads the encrypted config before it looks at the arguments.
PWCMD="security find-generic-password -w -s ${KEYCHAIN_ITEM}"
if ! $PWCMD >/dev/null 2>&1; then
  echo "$(ts) - ERROR: keychain item '${KEYCHAIN_ITEM}' unreadable; cannot unlock rclone config" >> "$LOG"
  exit 1
fi

# Override for a no-write rehearsal:  MBS_AWS_REPO_BACKUP_LIVE=0 ./aws_repo_backup.sh
if [ "${MBS_AWS_REPO_BACKUP_LIVE:-1}" = "1" ]; then
  DRYFLAG=""; MODE="LIVE"
else
  DRYFLAG="--dry-run"; MODE="DRY-RUN"
fi

MANIFEST="$STATE_DIR/aws_repo_backup_manifest_${TODAY}.log"
# Per-run scratch log, then appended to the daily manifest. Counting from the
# scratch file rather than the manifest is the fix vault_backup.sh needed on
# 2026-08-09: a manifest appended to across several runs a day reports the day's
# cumulative total, not this run's.
RUNLOG="$(mktemp "${STATE_DIR}/.aws_repo_backup_run.XXXXXX")"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null; rm -f "$RUNLOG" 2>/dev/null' EXIT INT TERM

echo "$(ts) - starting aws repo backup (mode=$MODE, ${SRC} -> ${DEST})" >> "$LOG"

"$RCLONE_BIN" copy "$SRC" "$DEST" \
  $DRYFLAG \
  --password-command "$PWCMD" \
  --exclude '.terraform/**' \
  --exclude '**/.terraform/**' \
  --exclude '.DS_Store' \
  --exclude '**/.DS_Store' \
  --exclude '.Spotlight-V100/**' \
  --exclude '.fseventsd/**' \
  --exclude '**/.Trashes/**' \
  --transfers 8 \
  --checkers 16 \
  --fast-list \
  --s3-no-check-bucket \
  --log-file "$RUNLOG" \
  --log-level INFO \
  --stats 5m \
  --stats-one-line
RC=$?

cat "$RUNLOG" >> "$MANIFEST" 2>/dev/null

if [ "$RC" -ne 0 ]; then
  echo "$(ts) - FAILED (rclone exit $RC); no stamp written, will retry next trigger. Manifest: $MANIFEST" >> "$LOG"
  exit "$RC"
fi

# Belt and braces on top of the exit code. rclone returns non-zero when a
# transfer errors, but a run that logged ERROR lines and still exited 0 is not a
# run this job should stamp as healthy, because the stamp is the only thing the
# watchdog reads.
ERRCOUNT="$(grep -c ' ERROR ' "$RUNLOG" 2>/dev/null)"
[ -n "$ERRCOUNT" ] || ERRCOUNT=0
if [ "$ERRCOUNT" -ne 0 ]; then
  echo "$(ts) - FAILED: rclone exited 0 but logged ${ERRCOUNT} ERROR line(s); no stamp written. Manifest: $MANIFEST" >> "$LOG"
  exit 1
fi

# grep -c exits 1 on zero matches; the assignment already yields "0" on its own,
# so no `|| echo 0` (which printed a doubled zero into vault_backup.sh's log).
COPIED="$(grep -c ': Copied' "$RUNLOG" 2>/dev/null)"
[ -n "$COPIED" ] || COPIED=0

# --- post-copy sanity check -------------------------------------------------
# Ask the destination what is actually there. Two distinct questions:
#   1. is anything there at all (a copy that silently wrote nothing)
#   2. is it the RIGHT ORDER OF MAGNITUDE (the .terraform exclusion still works)
# A dry run is exempt from the empty check, since by definition it wrote nothing.
SIZE_OUT="$("$RCLONE_BIN" size "$DEST" --password-command "$PWCMD" --s3-no-check-bucket 2>/dev/null)"
DEST_OBJECTS="$(printf '%s\n' "$SIZE_OUT" | sed -n 's/^Total objects: *\([0-9][0-9]*\).*/\1/p' | head -1)"
DEST_BYTES="$(printf '%s\n' "$SIZE_OUT" | sed -n 's/.*(\([0-9][0-9]*\) Byte).*/\1/p' | head -1)"

if [ -z "$DEST_BYTES" ] || [ -z "$DEST_OBJECTS" ]; then
  # The copy itself succeeded, so this is a warning and not a failure. Named
  # explicitly rather than swallowed, so a size check that quietly stopped
  # working does not read as a passing size check.
  echo "$(ts) - WARNING: could not read destination size from ${DEST}; copy succeeded, sanity check skipped" >> "$LOG"
else
  DEST_MB=$(( DEST_BYTES / 1048576 ))
  if [ "$MODE" = "LIVE" ] && [ "$DEST_OBJECTS" -eq 0 ]; then
    echo "$(ts) - FAILED: destination ${DEST} holds 0 objects after a LIVE copy; no stamp written" >> "$LOG"
    exit 1
  fi
  if [ "$DEST_MB" -gt "$SANITY_MAX_MB" ]; then
    echo "$(ts) - FAILED: destination ${DEST} is ${DEST_MB} MB, over the ${SANITY_MAX_MB} MB ceiling. The .terraform exclusion is very likely broken (that cache is 2.6 GB). Fix the excludes in this script; raise MBS_AWS_REPO_BACKUP_MAX_MB only if the repo genuinely grew. No stamp written. Manifest: $MANIFEST" >> "$LOG"
    exit 1
  fi
  echo "$(ts) - destination now holds ${DEST_OBJECTS} object(s), ${DEST_BYTES} bytes (${DEST_MB} MB, ceiling ${SANITY_MAX_MB} MB)" >> "$LOG"
fi

# The stamp is written in LIVE mode ONLY, and that is a deliberate departure
# from bulk_sync.sh and vault_backup.sh, which stamp on any successful run
# regardless of mode. Their behavior was right while bulk-sync was hardwired to
# a dry-run build phase, and it cost something later: on 2026-08-15 heartbeat
# check 7b had to be added precisely because a DRY-RUN that stamps success is
# indistinguishable, to the watchdog, from a real backup. This job is LIVE from
# its first run and has no dry-run phase to protect, so the hole is closed at
# the source instead of patched in the watchdog. The stamp means "an encrypted
# copy actually reached S3", and a rehearsal did not do that.
if [ "$MODE" != "LIVE" ]; then
  echo "$(ts) - OK (mode=$MODE): rehearsal complete, ${COPIED} file(s) uploaded; NO stamp written (a dry run is not a backup)" >> "$LOG"
  exit 0
fi

TZ=America/New_York date '+%Y-%m-%d %H:%M:%S' > "$STAMP"
echo "$(ts) - OK (mode=$MODE): ${COPIED} file(s) uploaded; stamped. Manifest: $MANIFEST" >> "$LOG"
exit 0
