#!/bin/bash
# tasks_rollover.sh - roll the daily tasks note over just after midnight
# (com.mbs.tasks-rollover, garm only, added 2026-10-16).
#
# Modeled on deadman.sh (the other every-5-minutes garm job: StartInterval 300
# plus RunAtLoad, one decision per run, the next trigger is the retry) and on
# mbs_daily.sh (STATE_DIR, ts(), the per-day stamp, the lock rules, and the
# note functions themselves, which both scripts now take from
# lib_tasks_note.sh). Read both before changing this.
#
# WHY. Since the 2026-10-08 cutover the daily notes are made on garm, where
# Obsidian never closes. P regularly works past midnight and that work counts
# for the new day (P, 2026-10-16), so the tasks note's rollover (create today's
# note, carry yesterday's open items forward, write the garden leave block)
# moves from 06:00 to just after midnight. The 06:00 report and every other
# briefing stay at 06:00; mbs_daily.sh does the rollover itself if this job has
# not. Brief: admin/mbs_system/design/brief_daily_note_garm_fixes.md (3.0).
#
# Each run:
#   - not garm (hostname -s, ROLLOVER_HOST overrides): exit 0, no log.
#   - touch ~/.mbs_automation/tasks_rollover_tick (heartbeat check 40 reads it).
#   - last_tasks_rollover already holds today: exit 0 silently.
#   - quiet guard: if the latest prior tasks note changed less than
#     ROLLOVER_QUIET_MINUTES ago (default 10), log "rollover: deferred ..." at
#     most once per 30 minutes and exit 0. P's edits on hoest or the phone reach
#     garm through Sync, so that file's mtime here follows his typing. From
#     ROLLOVER_FORCE_AFTER (default 09:00) the guard is skipped and the log says
#     forced. Both are environment-overridable from the plist.
#   - the note lock ($STATE_DIR/tasks_note.lock, shared with mbs_daily.sh) is
#     busy: exit 0, the next tick retries.
#   - otherwise: heal an Archiver-made note's frontmatter, create today's note
#     (neither writes open_tasks: that is the 06:00 snapshot), carry, rescue,
#     garden leave block, triage first-seen, stamp last_tasks_rollover, and log
#     "rollover: rolled tasks_D into tasks_T at HH:MM; completed successfully".
#     A failure logs "FAILED: ..." (check 26 reads it) and does not stamp.
#
# Log: ~/.mbs_automation/tasks_rollover.log. Drill:
# scripts/tasks_rollover_drill.sh (sandbox VAULT and STATE_DIR only).

set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

VAULT="${VAULT:-/Users/cpreston/Vaults/storage_mbs}"
STATE_DIR="${STATE_DIR:-$HOME/.mbs_automation}"
LOG="$STATE_DIR/tasks_rollover.log"
HOST="${ROLLOVER_HOST:-$(hostname -s)}"
export VAULT

[ "$HOST" = "garm" ] || exit 0

mkdir -p "$STATE_DIR"
touch "$STATE_DIR/tasks_rollover_tick"

# ROLLOVER_TODAY is a drill hook only (old-versus-new runs on dated real notes).
TODAY="${ROLLOVER_TODAY:-$(date +%Y-%m-%d)}"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Pin the sentinel paths to this STATE_DIR before sourcing, as the heartbeat
# does; lib_auth.sh supplies alert_tasks_note for the carry's WARNING line. This
# job never calls claude.
REAUTH_SENTINEL="$STATE_DIR/needs_reauth"
export REAUTH_SENTINEL
# shellcheck source=./lib_auth.sh
source "$(dirname "$0")/lib_auth.sh"
# shellcheck source=./lib_tasks_note.sh
source "$(dirname "$0")/lib_tasks_note.sh"

tasks_rollover_done "$TODAY" "$STATE_DIR" && exit 0

TASKS_DIR="$VAULT/daily_notes/tasks"
[ -d "$TASKS_DIR" ] || { echo "$(ts) - FAILED: $TASKS_DIR does not exist" >> "$LOG"; exit 1; }
PRIOR="$(tasks_prior_date "$TODAY" "$TASKS_DIR")"
if [ -n "$PRIOR" ]; then
  tasks_quiet_check "$TASKS_DIR/tasks_${PRIOR}.md" "$LOG" "$STATE_DIR" rollover || exit 0
fi

tasks_note_lock_acquire "$STATE_DIR" "$LOG" 0 || exit 0
trap 'tasks_note_lock_release' EXIT INT TERM

if SAID="$(tasks_rollover_steps "$TODAY" "$VAULT" "$STATE_DIR" "$LOG" tasks-rollover)"; then
  echo "$(ts) - rollover: ${SAID}; completed successfully" >> "$LOG"
  exit 0
fi
echo "$(ts) - FAILED: rollover of tasks_${PRIOR:-none} into tasks_${TODAY} stopped part way; not stamped, the next tick retries (read the lines above)" >> "$LOG"
exit 1
