#!/bin/bash
# bulk_sync.sh - one-way ENCRYPTED backup of ~/storage_mbs_assets/ to the
# mbs_aws S3 estate, via rclone crypt.
#
# REWRITTEN 2026-08-08. The previous version did `aws s3 sync` of the whole
# asset mirror to s3://cpreston-storage-reference/people/cp/ - the LEGACY
# account, in PLAINTEXT. That bucket is migrated and is being deleted, and
# plaintext was the entire problem this project exists to fix. The old version
# also carried LIVE=1 while its own header claimed dry-run, which is how 35
# files landed in the legacy bucket on 2026-08-04, after the migration, and
# had to be caught by phase 12 verify and swept up in a delta pass.
#
# WHAT IT DOES NOW
# ----------------
# Copies each top-level pillar of the asset mirror to the crypt remote that
# matches its tier, so everything is encrypted client-side before it leaves
# this Mac:
#
#   attachments create culture skills social sports  ->  bulk:<pillar>
#   admin health money                               ->  sensitive:<pillar>
#   trash                                            ->  never
#
# THE TIER SPLIT IS LOAD-BEARING, NOT COSMETIC. A single `rclone copy
# ~/storage_mbs_assets bulk:` would push admin/, health/ and money/ into the
# BULK crypt domain, whose password is the one the long-lived automation EC2
# instance is allowed to hold. That would silently undo the two-key split the
# whole estate is built around. The lists below mirror
# mbs_aws/scripts/classification-reference.tsv, which is how the migration
# tiered the same data. Keep them in agreement.
#
# An UNRECOGNISED top-level directory is NOT uploaded. Guessing a tier for
# unknown data risks putting sensitive material under the bulk key, which is
# worse than a gap. It is logged, and a marker file is written that
# mbs_heartbeat.sh check 16 turns into a visible finding, so the gap nags
# instead of hiding.
#
# COPY, NEVER SYNC. `rclone copy` is additive: it never deletes at the
# destination. This is structural, not a setting. P may delete local originals
# after upload (he asked about exactly that on 2026-08-07); with `sync` the
# next run would then delete those files from S3 and the backup would evaporate
# behind him. If pruning S3 is ever wanted it is a separate, deliberate,
# reviewed act - not a flag on this script.
#
# Triggered by launchd (scripts/launchd/com.mbs.bulk-sync.plist):
#   1. StartCalendarInterval 03:00 local.
#   2. RunAtLoad at login - covers a powered-off-overnight Mac.
# Per-day stamp (house pattern, TZ pinned to America/New_York) makes every
# trigger idempotent: at most one real run per day, stamped only on success.
# A single-instance lock (mbs_daily.sh pattern) stops a login trigger from
# starting a second copy while a long 03:00 run is still going.
#
# No claude, no LLM, no vault writes anywhere in this script.

set -uo pipefail

# ============================================================================
# LIVE FLAG
#
# LIVE=1 as of 2026-08-08, authorized by P ("build 14b now", to restore
# automated offsite copies after the pre-migration job was disabled on
# 2026-08-07). The condition adr_2026-07-30_two_location_storage_model.md set
# for going live - "bulk-sync stays in dry run until the S3 remap is complete
# and approved" - is met: phases 11 and 12 are done and both buckets verified
# PASS on 2026-08-07.
#
# Override for a no-write rehearsal:  MBS_BULK_SYNC_LIVE=0 ./bulk_sync.sh
# ============================================================================
LIVE="${MBS_BULK_SYNC_LIVE:-1}"

ASSETS_SRC="${MBS_ASSETS_DIR:-/Users/cpreston/storage_mbs_assets}"
KEYCHAIN_ITEM="${MBS_RCLONE_KEYCHAIN_ITEM:-mbs-rclone-config}"

STATE_DIR="$HOME/.mbs_automation"
STAMP="$STATE_DIR/last_bulk_sync_run"
LOG="$STATE_DIR/bulk_sync.log"
UNCLASSIFIED_MARKER="$STATE_DIR/bulk_sync_unclassified"

# Pillar -> tier. Mirrors mbs_aws/scripts/classification-reference.tsv.
BULK_PILLARS="attachments create culture skills social sports"
SENSITIVE_PILLARS="admin health money"
NEVER_PILLARS="trash"

mkdir -p "$STATE_DIR"

# Always Eastern - P's timezone (matches vault_index.sh / pointer_check.sh).
TODAY="$(TZ=America/New_York date +%Y-%m-%d)"
ts() { TZ=America/New_York date '+%Y-%m-%d %H:%M:%S'; }

# Already ran today? Stop.
if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$TODAY" ]; then
  echo "$(ts) - already ran for $TODAY, skipping." >> "$LOG"
  exit 0
fi

# Single-instance lock (mbs_daily.sh pattern). mkdir is atomic. A stale lock
# (holder PID no longer alive) is reclaimed rather than blocking forever.
LOCK_DIR="$STATE_DIR/bulk_sync.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  HOLDER_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -n "${HOLDER_PID:-}" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
    echo "$(ts) - another instance is running (PID $HOLDER_PID), exiting cleanly" >> "$LOG"
    exit 0
  fi
  echo "$(ts) - stale lock detected (holder PID was ${HOLDER_PID:-unknown}), claiming" >> "$LOG"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || {
    echo "$(ts) - ERROR: could not claim lock after cleanup, aborting" >> "$LOG"; exit 1; }
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

if [ ! -d "$ASSETS_SRC" ]; then
  echo "$(ts) - ERROR: asset source not found at $ASSETS_SRC" >> "$LOG"
  exit 1
fi

# launchd starts jobs with a minimal PATH.
export PATH="$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Prefer the official rclone.org binary at ~/bin/rclone. The Homebrew build is
# fine for copy (it only refuses to `mount`), but the mounts already depend on
# the official one, so pinning it here keeps one binary in play.
RCLONE_BIN="$HOME/bin/rclone"
[ -x "$RCLONE_BIN" ] || RCLONE_BIN="$(command -v rclone || true)"
if [ -z "$RCLONE_BIN" ] || [ ! -x "$RCLONE_BIN" ]; then
  echo "$(ts) - ERROR: rclone not found (looked at \$HOME/bin/rclone and PATH)" >> "$LOG"
  exit 1
fi

# The rclone config is encrypted; it cannot prompt under launchd. Read the
# config password from the login Keychain, exactly as the mount LaunchAgents
# do. Never echoes: rclone consumes the command's stdout directly.
PWCMD="security find-generic-password -w -s ${KEYCHAIN_ITEM}"
if ! $PWCMD >/dev/null 2>&1; then
  echo "$(ts) - ERROR: keychain item '${KEYCHAIN_ITEM}' unreadable; cannot unlock rclone config" >> "$LOG"
  exit 1
fi

if [ "$LIVE" = "1" ]; then
  DRYFLAG=""
  MODE="LIVE"
else
  DRYFLAG="--dry-run"
  MODE="DRY-RUN"
fi

MANIFEST="$STATE_DIR/bulk_sync_manifest_${TODAY}.log"
echo "$(ts) - starting bulk sync (mode=$MODE, rclone=$RCLONE_BIN)" >> "$LOG"

# Classify every top-level directory; refuse to guess.
UNCLASSIFIED=""
for path in "$ASSETS_SRC"/*/; do
  [ -d "$path" ] || continue
  name="$(basename "$path")"
  case " $BULK_PILLARS $SENSITIVE_PILLARS $NEVER_PILLARS " in
    *" $name "*) ;;
    *) UNCLASSIFIED="${UNCLASSIFIED}${name} " ;;
  esac
done

if [ -n "$UNCLASSIFIED" ]; then
  echo "$(ts) - WARNING: unclassified top-level dir(s), NOT backed up: ${UNCLASSIFIED}" >> "$LOG"
  printf '%s\n' "$UNCLASSIFIED" > "$UNCLASSIFIED_MARKER"
else
  rm -f "$UNCLASSIFIED_MARKER"
fi

# One rclone copy per pillar, into its tier's crypt remote.
copy_pillar() {
  local pillar="$1" remote="$2" src="${ASSETS_SRC}/$1"
  [ -d "$src" ] || { echo "$(ts) -   $pillar: not present locally, skipped" >> "$LOG"; return 0; }
  # --size-only is deliberate, not a shortcut. Three facts force it:
  #   1. crypt remotes expose no common hash (verify.sh hit the same wall:
  #      "No common hash found - not using a hash for checks"), so --checksum
  #      is not available.
  #   2. The pre-2026-08-08 backups were written by `aws s3 sync`, which does
  #      NOT preserve source mtimes; every object carries its upload time
  #      instead. The migration copied those stamps forward.
  #   3. So a default size+modtime comparison considers essentially every
  #      pre-existing file changed. Measured 2026-08-08: 7,226 files (~29 GB)
  #      would have been re-uploaded on the first run despite being byte-
  #      identical, at real cost and creating 90 days of pointless noncurrent
  #      versions.
  # Tradeoff, accepted: an in-place edit that leaves a file EXACTLY the same
  # size will not be detected. For a mirror of photos, scans, PDFs and audio
  # that is a negligible risk; for text that changes size, detection is normal.
  "$RCLONE_BIN" copy "$src" "${remote}:${pillar}" \
    $DRYFLAG \
    --password-command "$PWCMD" \
    --size-only \
    --exclude '.DS_Store' \
    --exclude '**/.DS_Store' \
    --exclude '.Spotlight-V100/**' \
    --exclude '.fseventsd/**' \
    --exclude '**/.Trashes/**' \
    --transfers 8 \
    --checkers 16 \
    --fast-list \
    --s3-no-check-bucket \
    --log-file "$MANIFEST" \
    --log-level INFO \
    --stats 5m \
    --stats-one-line
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "$(ts) -   $pillar -> ${remote}: ok" >> "$LOG"
  else
    echo "$(ts) -   $pillar -> ${remote}: FAILED rc=$rc" >> "$LOG"
  fi
  return "$rc"
}

FAILED=0
for pillar in $BULK_PILLARS; do
  copy_pillar "$pillar" "bulk" || FAILED=$((FAILED + 1))
done
for pillar in $SENSITIVE_PILLARS; do
  copy_pillar "$pillar" "sensitive" || FAILED=$((FAILED + 1))
done

if [ "$FAILED" -ne 0 ]; then
  echo "$(ts) - FAILED: $FAILED pillar(s) errored; no stamp written, will retry next trigger. Manifest: $MANIFEST" >> "$LOG"
  exit 1
fi

echo "$TODAY" > "$STAMP"
echo "$(ts) - OK (mode=$MODE): all pillars copied; stamped $TODAY. Manifest: $MANIFEST" >> "$LOG"
exit 0
