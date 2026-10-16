#!/bin/bash
# obsidian_keepalive.sh - relaunch Obsidian on garm when it is not running
# (com.mbs.obsidian-keepalive, added 2026-10-16).
#
# Modeled on deadman.sh (the other every-5-minutes garm job: StartInterval 300
# plus RunAtLoad, one decision per run, the next trigger is the retry, terminal
# lines in the estate vocabulary) and on mbs_daily.sh's conventions (STATE_DIR,
# ts(), log naming). Read both before changing this.
#
# WHY. garm's Obsidian is load-bearing and nothing watched it: it is the only
# path from garm to hoest and the phone (Obsidian Sync), it runs Journals (the
# health note just after midnight) and MBS Multi Git (the hourly vault commit
# that restored 99 ticked lines on 2026-10-15). If it quits, all three stop in
# silence. Heartbeat check 39 reports it once a day; this job fixes it within
# five minutes, and check 39b tells P that it had to.
#
# Each run:
#   - not garm (hostname -s, KEEPALIVE_HOST overrides): exit 0, no log.
#   - pause file ~/.mbs_automation/obsidian_keepalive.pause present: P's
#     maintenance switch. Log once per pause, do nothing. Check 39 part d reports a
#     pause older than 24 hours so a forgotten one cannot stand forever.
#   - Obsidian running (pgrep -x Obsidian): silent, except ONE
#     "completed successfully" line on the first healthy run after a FAILED,
#     because heartbeat check 26 reads this log's last terminal line.
#   - Obsidian not running: open -ga Obsidian (background, no focus), poll for
#     up to KEEPALIVE_WAIT_SECONDS, then log "relaunched Obsidian ...
#     completed successfully" or "FAILED: ...".
#
# Log: ~/.mbs_automation/obsidian_keepalive.log. Test hooks (env): STATE_DIR,
# KEEPALIVE_HOST, KEEPALIVE_WAIT_SECONDS; pgrep, open and hostname are shimmed
# on PATH by scripts/obsidian_keepalive_drill.sh.

set -uo pipefail

export PATH="${KEEPALIVE_PATH_PREFIX:+$KEEPALIVE_PATH_PREFIX:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

STATE_DIR="${STATE_DIR:-$HOME/.mbs_automation}"
LOG="$STATE_DIR/obsidian_keepalive.log"
PAUSE="$STATE_DIR/obsidian_keepalive.pause"
PAUSE_LOGGED="$STATE_DIR/obsidian_keepalive.pause_logged"
WAIT_SECONDS="${KEEPALIVE_WAIT_SECONDS:-60}"
HOST="${KEEPALIVE_HOST:-$(hostname -s)}"

[ "$HOST" = "garm" ] || exit 0

mkdir -p "$STATE_DIR"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) - $*" >> "$LOG"; }

running() { pgrep -x Obsidian >/dev/null 2>&1; }

if [ -f "$PAUSE" ]; then
  if [ ! -f "$PAUSE_LOGGED" ]; then
    log "paused: $PAUSE exists, not checking or relaunching Obsidian until it is removed"
    : > "$PAUSE_LOGGED"
  fi
  exit 0
fi
if [ -f "$PAUSE_LOGGED" ]; then
  rm -f "$PAUSE_LOGGED"
  log "resumed: pause file removed"
fi

if running; then
  LAST="$(grep -E 'completed successfully|FAILED' "$LOG" 2>/dev/null | tail -1)"
  case "$LAST" in
    *FAILED*) log "Obsidian is running again (pid $(pgrep -x Obsidian | head -1)); completed successfully" ;;
  esac
  exit 0
fi

log "Obsidian is not running; launching it (open -ga Obsidian)"
if ! open -ga Obsidian >> "$LOG" 2>&1; then
  log "FAILED: open -ga Obsidian returned non-zero; Obsidian is still not running"
  exit 1
fi
waited=0
while [ "$waited" -lt "$WAIT_SECONDS" ]; do
  running && break
  sleep 5
  waited=$((waited + 5))
done
if running; then
  log "relaunched Obsidian (pid $(pgrep -x Obsidian | head -1), up after ${waited}s); completed successfully"
  exit 0
fi
log "FAILED: launched Obsidian but no Obsidian process after ${WAIT_SECONDS}s"
exit 1
