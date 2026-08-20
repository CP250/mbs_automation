#!/bin/bash
# vault_backup.sh - encrypted offsite backup of the Obsidian vault.
#
# WHY THIS EXISTS (2026-08-09)
# ---------------------------
# The AWS migration made 2.81 TB of archive bulletproof and left the 189 MB
# index that explains it protected by nothing. Verified on 2026-08-09:
#   - the vault git repo has NO REMOTE, so the hourly MBS Multi Git
#     auto-commits are local history on one Mac, not a backup
#   - it is not in iCloud
#   - Time Machine has AutoBackup=0 and its destination fails to mount; the
#     last recorded backup was 2025-08-18, roughly twelve months earlier
#   - bulk_sync.sh never touched it; that job only reads ~/storage_mbs_assets/
# So a disk failure would have destroyed P's second brain while the archive it
# indexes survived. Raised as awsmig0, closed by this job.
#
# WHAT IT DOES
# ------------
# One-way `rclone copy` of the whole vault into the SENSITIVE crypt domain at
# sensitive:_vault/, client-side encrypted before anything leaves the Mac. It
# sits beside sensitive:_infra/, which already holds the Terraform state.
#
# TIER: sensitive, not bulk, and that is not a close call. The vault holds
# money/, health/, legal/, admin/ (identity, citizenships, tax), SOUL.md,
# CRITICAL_FACTS.md and admin/pn.md. It must never sit under the bulk key,
# which the long-lived automation EC2 instance is allowed to hold.
#
# COPY, NEVER SYNC. Additive only; a local deletion never propagates. This is
# the structural invariant from adr_2026-07-30_two_location_storage_model.md
# ("no --delete, ever") and it matters more here than anywhere else: the whole
# point is surviving a mistake or a dead disk, and the bucket's 365-day
# noncurrent version retention is the second net under it.
#
# WHAT IS EXCLUDED, and why each one is a deliberate decision:
#   trash/        the vault's disposal staging. P empties it himself; it is
#                 also opaque by hard rule. Backing up disposal defeats it.
#   .obsidian/    editor settings and workspace cache. It has its OWN git repo
#                 that commits and pushes to a real remote (see the vault
#                 CLAUDE.md, MBS Multi Git), so it is already backed up, and
#                 its cache churns constantly.
#   .DS_Store etc macOS noise.
# NOT excluded, on purpose:
#   .git/         26 MB, and it buys point-in-time recovery of every note back
#                 through the vault's whole history rather than just "latest".
#   admin/pn.md   opaque to Claude by hard rule, which means Claude never READS
#                 or surfaces it. A byte-level backup is not reading. Omitting
#                 P's most private note from his only backup would be a worse
#                 failure than including it. Flagged to P 2026-08-09; if he
#                 disagrees the fix is one --exclude line.
#   _corpora/, oura/raw/  bulk data excluded from the SEARCH surface, but still
#                 his data, and not stored anywhere else.
#
# SCHEDULE: four times a day (see scripts/launchd/com.mbs.vault-backup.plist),
# not once, because the vault changes all day and it is 189 MB of mostly-text
# that rclone transfers incrementally. Worst-case data loss is therefore about
# six hours rather than a day. Unlike mbs_daily.sh there is deliberately NO
# per-day "already ran, skip" stamp: re-running an incremental backup is
# harmless and more often is strictly better. The stamp is written for the
# watchdog to read, not to gate execution. A lock still prevents overlap.
#
# No claude, no LLM, no network service other than S3.

set -uo pipefail

VAULT="${MBS_VAULT_DIR:-/Users/cpreston/Vaults/storage_mbs}"
DEST="${MBS_VAULT_REMOTE:-sensitive:_vault}"
KEYCHAIN_ITEM="${MBS_RCLONE_KEYCHAIN_ITEM:-mbs-rclone-config}"

STATE_DIR="$HOME/.mbs_automation"
STAMP="$STATE_DIR/last_vault_backup_run"
LOG="$STATE_DIR/vault_backup.log"

mkdir -p "$STATE_DIR"

# Always Eastern, P's timezone (matches the other jobs).
TODAY="$(TZ=America/New_York date +%Y-%m-%d)"
ts() { TZ=America/New_York date '+%Y-%m-%d %H:%M:%S'; }

# Single-instance lock (mbs_daily.sh pattern). mkdir is atomic; a stale lock
# whose holder is gone is reclaimed rather than blocking forever.
LOCK_DIR="$STATE_DIR/vault_backup.lock"
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

if [ ! -d "$VAULT" ]; then
  echo "$(ts) - ERROR: vault not found at $VAULT" >> "$LOG"
  exit 1
fi

# launchd starts jobs with a minimal PATH.
export PATH="$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

RCLONE_BIN="$HOME/bin/rclone"
[ -x "$RCLONE_BIN" ] || RCLONE_BIN="$(command -v rclone || true)"
if [ -z "$RCLONE_BIN" ] || [ ! -x "$RCLONE_BIN" ]; then
  echo "$(ts) - ERROR: rclone not found" >> "$LOG"
  exit 1
fi

# The rclone config is encrypted and cannot prompt under launchd; the config
# password comes from the login Keychain. Never echoed.
PWCMD="security find-generic-password -w -s ${KEYCHAIN_ITEM}"
if ! $PWCMD >/dev/null 2>&1; then
  echo "$(ts) - ERROR: keychain item '${KEYCHAIN_ITEM}' unreadable; cannot unlock rclone config" >> "$LOG"
  exit 1
fi

if [ "${MBS_VAULT_BACKUP_LIVE:-1}" = "1" ]; then
  DRYFLAG=""; MODE="LIVE"
else
  DRYFLAG="--dry-run"; MODE="DRY-RUN"
fi

MANIFEST="$STATE_DIR/vault_backup_manifest_${TODAY}.log"
# Per-run scratch log. The daily manifest is APPENDED to across the four runs a
# day, so counting ': Copied' in it reports the day's cumulative total, not this
# run's (observed 2026-08-09: the second run of the day reported 11,936 when it
# had actually copied 62). Count from the scratch file, then append it.
RUNLOG="$(mktemp "${STATE_DIR}/.vault_backup_run.XXXXXX")"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null; rm -f "$RUNLOG" 2>/dev/null' EXIT INT TERM

echo "$(ts) - starting vault backup (mode=$MODE, ${VAULT} -> ${DEST})" >> "$LOG"

# --size-only for the same reason as bulk_sync.sh: crypt remotes expose no
# common hash. Note the consequence for notes specifically: an edit that leaves
# a file EXACTLY the same byte length is not detected. That is rarer in prose
# than in binaries but not impossible, so --max-age is NOT used and every run
# re-examines the whole tree, and .git (whose objects are immutable and
# uniquely named) captures the true history regardless.
"$RCLONE_BIN" copy "$VAULT" "$DEST" \
  $DRYFLAG \
  --password-command "$PWCMD" \
  --size-only \
  --exclude '/trash/**' \
  --exclude '/.obsidian/**' \
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

# grep -c exits 1 on zero matches; with `|| echo 0` that printed BOTH grep's "0"
# and echo's "0" into the log. The assignment already yields "0" on its own.
COPIED="$(grep -c ': Copied' "$RUNLOG" 2>/dev/null)"
[ -n "$COPIED" ] || COPIED=0

# --- post-copy destination size check (added 2026-08-20) --------------------
# Until today this script asked rclone whether it exited 0 and nothing else,
# then stamped. That stamp is the ONLY thing heartbeat check 17 reads, and
# check 17 calls itself "the highest-stakes check in this file" because it
# guards the only offsite copy of the vault. So the highest-stakes artifact in
# the estate was verified by an exit code and a timestamp: a copy that wrote
# nothing at all, or into an empty or wrong destination, stamps success and
# reads healthy for the next 30 hours.
#
# aws_repo_backup.sh has done this since it shipped on 2026-08-15 and its log
# has the numbers to prove the copy landed. This block is that block, minus the
# size ceiling: mbs_aws is a fixed-size IaC tree where growth means a broken
# exclusion, while the vault grows every day by design, so a ceiling here would
# only ever cry wolf. The floor and the shrink comparison live in heartbeat
# check 17b, which reads the line this writes.
#
# Warning rather than failure when the size cannot be read: the copy itself
# already succeeded, and a size check that quietly stopped working must not read
# as a size check that passed.
SIZE_OUT="$("$RCLONE_BIN" size "$DEST" --password-command "$PWCMD" --s3-no-check-bucket 2>/dev/null)"
# Prefer the EXACT count rclone prints in parentheses, and fall back to a bare
# integer only for older rclone builds that print no parenthesised form.
#
# WHY (found 2026-08-20, in production, by heartbeat check 17b): current rclone
# humanises this field, so a vault of 14,512 objects prints
#   Total objects: 14.512k (14512)
# and a sed anchored on the first run of digits captures "14". The vault backup
# logged "destination now holds 14 object(s), 166608032 bytes", which is 11.9 MB
# per object and obviously wrong the moment anyone divides. Nothing failed: the
# size read succeeded, the number was plausible, the log looked healthy. Same
# family as everything else this file guards against.
#
# aws_repo_backup.sh carried the identical sed and was never wrong only because
# its destination holds 217 objects and rclone prints counts under 1000 without
# a suffix. It would have silently started under-reporting at 1,000.
DEST_OBJECTS="$(printf '%s\n' "$SIZE_OUT" | sed -n 's/^Total objects:.*(\([0-9][0-9]*\)).*/\1/p' | head -1)"
if [ -z "$DEST_OBJECTS" ]; then
  DEST_OBJECTS="$(printf '%s\n' "$SIZE_OUT" | sed -n 's/^Total objects: *\([0-9][0-9]*\) *$/\1/p' | head -1)"
fi
DEST_BYTES="$(printf '%s\n' "$SIZE_OUT" | sed -n 's/.*(\([0-9][0-9]*\) Byte).*/\1/p' | head -1)"

if [ -z "$DEST_BYTES" ] || [ -z "$DEST_OBJECTS" ]; then
  echo "$(ts) - WARNING: could not read destination size from ${DEST}; copy succeeded, sanity check skipped" >> "$LOG"
else
  DEST_MB=$(( DEST_BYTES / 1048576 ))
  if [ "$MODE" = "LIVE" ] && [ "$DEST_OBJECTS" -eq 0 ]; then
    echo "$(ts) - FAILED: destination ${DEST} holds 0 objects after a LIVE copy; the vault has NO offsite copy. No stamp written. Manifest: $MANIFEST" >> "$LOG"
    exit 1
  fi
  echo "$(ts) - destination now holds ${DEST_OBJECTS} object(s), ${DEST_BYTES} bytes (${DEST_MB} MB)" >> "$LOG"
fi

# The stamp is what heartbeat check 17 trusts, so a DRY-RUN must never write
# it: a rehearsal that stamps looks like a real backup for the next 30 hours.
# Same guard as aws_repo_backup.sh, where this defect was caught 2026-08-15.
if [ "$MODE" = "LIVE" ]; then
  TZ=America/New_York date '+%Y-%m-%d %H:%M:%S' > "$STAMP"
  echo "$(ts) - OK (mode=$MODE): ${COPIED} file(s) uploaded; stamped. Manifest: $MANIFEST" >> "$LOG"
else
  echo "$(ts) - OK (mode=$MODE): ${COPIED} file(s) would upload; NO stamp written in dry-run. Manifest: $MANIFEST" >> "$LOG"
fi
exit 0
