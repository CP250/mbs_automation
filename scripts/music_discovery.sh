#!/bin/bash
# music_discovery.sh - weekly wrapper around ~/dev/mbs-music-discovery.
#
# Modeled on cars_weekly.sh (weekly stamp, retry ladder, STATE_DIR log, PATH
# export) plus mbs_daily.sh's wait_for_network pre-flight. Read both before
# changing this file.
#
# WHY THIS EXISTS (2026-08-30). Until today com.mbs.music-discovery ran
# `node index.js` directly from its plist, and it was the only scheduled job in
# the estate outside the CLAUDE.md contract that every recurring task is a
# scripts/<name>.sh modeled on mbs_daily.sh. Because it sat outside, it never
# inherited any of the hardening the rest of the estate got:
#
#   1. No network pre-flight. On Monday 2026-08-24 06:00 the fire landed before
#      DNS came back and both sources died on getaddrinfo ENOTFOUND. index.js
#      did the right thing (refused to overwrite the dispatch with nothing) and
#      exited 1. The identical failure had already happened on 2026-07-06, the
#      same morning mbs_daily.sh was hardened with wait_for_network. The fix was
#      applied to one job instead of to the class, and this job paid for it
#      seven weeks later.
#   2. No retry. A weekly StartCalendarInterval means the next trigger after a
#      failed Monday is the FOLLOWING Monday, so one transient DNS blip cost a
#      whole week of dispatches. This is the same shape that cost cars_weekly
#      and mbs_weekly a week on 2026-08-17.
#   3. No log in STATE_DIR. run.log lived in the repo, so heartbeat checks 24
#      (stderr sweep) and 26 (a job's own last word was FAILED) were
#      structurally blind to it. On 2026-08-24 this job's last line said
#      "Error: every source failed" in plain English and check 26, whose entire
#      purpose is to catch exactly that, could not see the file. The only thing
#      that noticed was check 8's 8-day mtime canary, one day later, and it
#      could only say the output was stale, not that the job had run and known it
#      had failed.
#
# The stamp is per ISO week (%G-W%V), which is Monday-start, so it is 1:1 with
# the Monday the dispatch is named for. Written only on success, so every extra
# trigger on the grid is a millisecond no-op once the week is done.
#
# SUCCESS IS THE FILE, NOT THE EXIT CODE. index.js sets exit 1 when a source
# degraded but the dispatch was still written, so this wrapper decides success
# by asking whether dispatch_<Monday>.md exists. A stamp written by a job that
# did no work is the estate's oldest failure family; see LEARNINGS_DIGEST
# 2026-08-20.

set -uo pipefail

VAULT="/Users/cpreston/Vaults/storage_mbs"
REPO="$HOME/dev/mbs-music-discovery"
STATE_DIR="$HOME/.mbs_automation"
STAMP="$STATE_DIR/last_music_discovery_run"
LOG="$STATE_DIR/music_discovery.log"
RUN_LOG="$REPO/run.log"
# ONE derivation of the output directory, passed to index.js with --out below
# so the path this wrapper polls for success and the path node writes to are
# the same string and cannot drift. index.js also carries its own default
# (cfg.vaultDir); two code paths deriving one artifact name is the contract
# that broke oura twice, see LEARNINGS_DIGEST 2026-08-15.
DISPATCH_DIR="$VAULT/culture/listen/project_music_discovery"

mkdir -p "$STATE_DIR"

THIS_WEEK="$(date +%G-W%V)"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

# The Monday this run is for, computed the same way index.js's mondayOf() does:
# local time, Monday-start. %u is 1 (Mon) through 7 (Sun).
DOW="$(date +%u)"
if [ "$DOW" = "1" ]; then
  # Monday: today. Handled separately because "date -v-0d" is the one
  # offset in the -v-Nd family this estate has never exercised, and the
  # normal fire is exactly this branch.
  WEEK_MONDAY="$(date +%Y-%m-%d)"
else
  WEEK_MONDAY="$(date -v-$(( DOW - 1 ))d +%Y-%m-%d 2>/dev/null)"
fi
if [ -z "$WEEK_MONDAY" ]; then
  echo "$(ts) - FAILED: could not compute this week's Monday (BSD 'date -v' unavailable); not stamping $THIS_WEEK." >> "$LOG"
  exit 1
fi
DISPATCH="$DISPATCH_DIR/dispatch_${WEEK_MONDAY}.md"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$THIS_WEEK" ]; then
  echo "$(ts) - already ran for $THIS_WEEK, skipping." >> "$LOG"
  exit 0
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

if [ ! -d "$REPO" ]; then
  echo "$(ts) - FAILED: repo missing at $REPO; not stamping $THIS_WEEK." >> "$LOG"
  exit 1
fi

NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  echo "$(ts) - FAILED: 'node' not found on PATH ($PATH); not stamping $THIS_WEEK." >> "$LOG"
  exit 1
fi

# Pre-flight network gate. Lifted from mbs_daily.sh's wait_for_network, pointed
# at the host that actually died on 2026-07-06 and 2026-08-24 rather than at the
# Anthropic API. Poll for up to ~2 min, then proceed regardless: the retry
# ladder below still covers a genuine outage, and on a healthy Monday the first
# probe returns immediately so this adds no delay.
wait_for_network() {
  local log="$1"
  local url="https://oauth2.googleapis.com/"
  local max_tries=12 i rc
  for i in $(seq 1 "$max_tries"); do
    curl -sS --max-time 5 -o /dev/null "$url" 2>/dev/null
    rc=$?
    # curl exit 0 = connected (an HTTP 401/404 still counts as reachable).
    # Exit 6 (DNS), 7 (connect refused), 28 (timeout), 35 (TLS) => not ready.
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

echo "$(ts) - starting music discovery for $THIS_WEEK (Monday $WEEK_MONDAY, node: $NODE_BIN)" >> "$LOG"
wait_for_network "$LOG"

# Retry ladder. Four attempts, 5/10/30-minute sleeps, so a transient outage of
# up to ~45 min is absorbed inside the run and the whole ladder is finished long
# before the 11:00 heartbeat.
MAX_ATTEMPTS=4
RETRY_DELAYS=(300 600 1800)

rc=1
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  echo "$(ts) - attempt $attempt/$MAX_ATTEMPTS" >> "$LOG"
  {
    echo ""
    echo "=== $(ts) music_discovery.sh attempt $attempt/$MAX_ATTEMPTS (week $THIS_WEEK) ==="
  } >> "$RUN_LOG"
  # --week and --out both passed explicitly. index.js can derive the week and
  # the directory itself, and letting it do so means two clocks and two path
  # derivations agreeing by luck: this wrapper reads the date ONCE at start,
  # node reads it again per attempt, and the 30-minute rung of the ladder can
  # carry an attempt across midnight into a different Monday. Caught in test
  # 2026-08-30, where the wrapper waited for a file node was never going to
  # write and burned all four attempts saying "produced no dispatch" while
  # node said "already exists" and exited 0. --week uses the trailing window,
  # which is what every live run has always done (see the windowFor comment
  # in index.js); --window=forward is the old wrong behaviour, never use it.
  ( cd "$REPO" && "$NODE_BIN" index.js --week="$WEEK_MONDAY" --out="$DISPATCH_DIR" ) >> "$RUN_LOG" 2>&1
  rc=$?

  if [ -f "$DISPATCH" ]; then
    echo "$THIS_WEEK" > "$STAMP"
    if [ "$rc" -eq 0 ]; then
      echo "$(ts) - completed successfully on attempt $attempt; dispatch_${WEEK_MONDAY}.md present; stamped $THIS_WEEK" >> "$LOG"
    else
      echo "$(ts) - completed successfully on attempt $attempt with a degraded source (node exit $rc); dispatch_${WEEK_MONDAY}.md present; stamped $THIS_WEEK. Heartbeat check 8c names the missing source." >> "$LOG"
    fi
    exit 0
  fi

  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    delay="${RETRY_DELAYS[$((attempt - 1))]}"
    echo "$(ts) - attempt $attempt produced no dispatch (node exit $rc); sleeping ${delay}s before retry $((attempt + 1))" >> "$LOG"
    sleep "$delay"
  fi
done

echo "$(ts) - FAILED all $MAX_ATTEMPTS attempts (final node exit $rc); dispatch_${WEEK_MONDAY}.md was not written and no stamp was taken. Read $RUN_LOG for the source errors. Backfill once the cause is fixed with: cd $REPO && node index.js --week=${WEEK_MONDAY}" >> "$LOG"
exit "$rc"
