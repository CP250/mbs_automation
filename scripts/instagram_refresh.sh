#!/bin/bash
# instagram_refresh.sh - once a day, re-run every archived Instagram account
# whose refresh cadence is due.
#
# The work lives in the media-tools plugin (~/dev/claude_mbs, skill
# instagram-download): ig_download.sh refresh-due reads every note in
# admin/mbs_system/applications/instagram_download/accounts/ in the vault, and
# for each one whose `refresh:` is not `off` and whose last successful contact
# is at least one cadence old, it fetches what is new into that account's
# asset-mirror folder. Setting a cadence is a frontmatter edit
# (ig_download.sh set-refresh <user> weekly), never a change to this file.
# With no account on a cadence this job does nothing and says so.
#
# Modeled on mbs_daily.sh (per-day stamp, PID lock with a day file, explicit
# PATH, log in ~/.mbs_automation named after the job, the shared terminal
# vocabulary "completed successfully; stamped" / "FAILED") with the body
# delegated to a script the way alcohol_stamp.sh does, plus the
# wait_for_network pre-flight from music_discovery.sh.
#
# Triggered by launchd (scripts/launchd/com.mbs.instagram-refresh.plist):
#   1. StartCalendarInterval 05:40 local, a slot nothing else uses (backups
#      end by 03:45, mbs_daily starts at 06:00).
#   2. Wake from sleep: launchd coalesces a missed 05:40 into one fire on wake.
#   3. RunAtLoad at login.
#
# DELIBERATELY NO RETRY LADDER. Every other network job here retries within
# the run. This one does not, because the failures that matter are Instagram
# refusing cprepo (expired session, challenge, 401 "Please wait a few
# minutes", 429), and retrying those inside the hour is how an account gets
# locked. A failed day writes FAILED and no stamp; the next trigger (tomorrow
# 05:40, or the next login) tries once more. Heartbeat check 26 reads the
# FAILED line, and check 31 reads instagram_refresh_state.tsv for any account
# whose last successful contact is older than its cadence plus two days.
#
# stdout and stderr of the body both go to $LOG, so a Python failure is
# written in this job's own vocabulary; only bash itself can reach
# instagram_refresh.err.log, which is what check 24 watches.

set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

STATE_DIR="$HOME/.mbs_automation"
STAMP="$STATE_DIR/last_instagram_refresh_run"
LOG="$STATE_DIR/instagram_refresh.log"
IG="${IG_DOWNLOAD_SH:-$HOME/dev/claude_mbs/plugins/media-tools/skills/instagram-download/scripts/ig_download.sh}"

mkdir -p "$STATE_DIR"

TODAY="$(date +%Y-%m-%d)"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$TODAY" ]; then
  echo "$(ts) - already ran for $TODAY, skipping." >> "$LOG"
  exit 0
fi

LOCK_DIR="$STATE_DIR/instagram_refresh.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  HOLDER_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -n "${HOLDER_PID:-}" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
    echo "$(ts) - another instance is running (PID $HOLDER_PID), exiting cleanly" >> "$LOG"
    exit 0
  fi
  echo "$(ts) - stale lock detected (holder PID was ${HOLDER_PID:-unknown}), claiming" >> "$LOG"
  rm -rf "$LOCK_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$(ts) - FAILED: could not claim lock after cleanup, aborting" >> "$LOG"
    exit 1
  fi
fi
echo $$ > "$LOCK_DIR/pid"
echo "$TODAY" > "$LOCK_DIR/day"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

if [ ! -f "$IG" ]; then
  echo "$(ts) - FAILED: $IG not found; is ~/dev/claude_mbs checked out? Not stamping $TODAY." >> "$LOG"
  exit 1
fi

wait_for_network() {
  local log="$1"
  local url="https://www.instagram.com/"
  local max_tries=12 i rc
  for i in $(seq 1 "$max_tries"); do
    curl -sS --max-time 5 -o /dev/null "$url" 2>/dev/null
    rc=$?
    case "$rc" in
      6|7|28|35)
        echo "$(ts) - network not ready (curl exit $rc); waiting 10s ($i/$max_tries)" >> "$log"
        sleep 10 ;;
      *)
        echo "$(ts) - network reachable (curl exit $rc after $i check(s))" >> "$log"
        return 0 ;;
    esac
  done
  echo "$(ts) - network still not ready after $max_tries checks; proceeding anyway" >> "$log"
  return 1
}

echo "$(ts) - starting instagram refresh-due for $TODAY ($IG)" >> "$LOG"
wait_for_network "$LOG"

/bin/bash "$IG" refresh-due >> "$LOG" 2>&1
RC=$?

if [ "$RC" -ne 0 ]; then
  echo "$(ts) - FAILED (rc=$RC); not stamping $TODAY, next trigger retries once. Per-account lines above; full run logs in each archive's _meta/logs/." >> "$LOG"
  exit "$RC"
fi

echo "$TODAY" > "$STAMP"
echo "$(ts) - completed successfully; stamped $TODAY" >> "$LOG"
exit 0
