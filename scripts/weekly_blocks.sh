#!/bin/bash
# weekly_blocks.sh - generate weekly time-block calendar events (C-lite).
#
# Pairs with weekly_blocks.py. Triggered by launchd (see com.mbs.weekly-blocks.plist):
#   1. StartCalendarInterval Sunday 17:00 local (planning the upcoming week).
#   2. Wake from sleep - launchd coalesces the missed fire and runs on wake.
#   3. RunAtLoad at login - covers a powered-off Mac.
#
# A per-PLAN-WEEK stamp file (ISO year-week, e.g. 2026-W26) makes every trigger
# idempotent: the script runs at most once per plan-week. Stamp is written only
# on success of BOTH phases (Python emit + Claude calendar-create). If only the
# Python succeeds and Claude fails, no stamp - next trigger retries.
#
# Note: "plan_week" = the ISO week the script is PLANNING for, not necessarily
# the ISO week the script RUNS in. When run on a Sunday, plan_week = next week.
# That matters here - Sunday's run plans 2026-W26, stamps 2026-W26, so Monday's
# RunAtLoad sees the stamp and skips correctly.
#
# Switched from the Morgen drop-zone approach to C-lite (direct Google Calendar
# event creation) on 2026-06-16. The previous approach wrote a markdown file
# that Morgen surfaced as all-day pins; P could not drag those pins to time
# slots. C-lite: Python writes events JSON, this wrapper calls `claude -p` to
# invoke mcp__google-calendar__create-event for each one. Real calendar events
# from minute one. The markdown is now an audit log, not a drop zone.

set -uo pipefail

VAULT="/Users/cpreston/Vaults/storage_mbs"
REPO="/Users/cpreston/dev/mbs_automation"
PY="$REPO/scripts/weekly_blocks.py"
STATE_DIR="$HOME/.mbs_automation"
LOG="$STATE_DIR/weekly_blocks.log"

mkdir -p "$STATE_DIR"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Source auth-failure detection helpers.
# shellcheck source=./lib_auth.sh
source "$(dirname "$0")/lib_auth.sh"

# Pre-flight: skip cleanly if Claude Code needs re-auth.
if needs_reauth_skip "$LOG"; then
  exit 0
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

PY_BIN="$(command -v python3 || true)"
if [ -z "$PY_BIN" ]; then
  echo "$(ts) - ERROR: python3 not found on PATH. Aborting." >> "$LOG"
  exit 1
fi

CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  echo "$(ts) - ERROR: claude not found on PATH. Aborting." >> "$LOG"
  exit 1
fi

# Compute plan_week the same way the Python does, so the stamp is consistent
# with what the Python actually generates. Sunday => next Monday; else => this
# week's Monday. Use Python rather than reimplementing the ISO-week math in bash.
PLAN_WEEK="$("$PY_BIN" - <<'EOF'
import datetime as dt
today = dt.date.today()
monday = today + dt.timedelta(days=1) if today.isoweekday() == 7 else today - dt.timedelta(days=today.isoweekday() - 1)
y, w, _ = monday.isocalendar()
print(f"{y}-W{w:02d}")
EOF
)"

STAMP="$STATE_DIR/last_weekly_blocks_run"
EVENTS_JSON="$STATE_DIR/weekly_blocks_${PLAN_WEEK}_events.json"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$PLAN_WEEK" ]; then
  echo "$(ts) - already generated for plan_week $PLAN_WEEK, skipping." >> "$LOG"
  exit 0
fi

echo "$(ts) - PHASE 1: running weekly_blocks.py for plan_week $PLAN_WEEK" >> "$LOG"

if ! "$PY_BIN" "$PY" --vault "$VAULT" --state-dir "$STATE_DIR" >> "$LOG" 2>&1; then
  rc=$?
  echo "$(ts) - ERROR: weekly_blocks.py exited $rc; aborting before Claude phase. Next trigger retries." >> "$LOG"
  exit "$rc"
fi

if [ ! -f "$EVENTS_JSON" ]; then
  echo "$(ts) - ERROR: events JSON not found at $EVENTS_JSON after Python phase; aborting." >> "$LOG"
  exit 1
fi

echo "$(ts) - PHASE 2: calling claude -p to create $(grep -c '"stable_id"' "$EVENTS_JSON") calendar events" >> "$LOG"

# Prompt: tell Claude to read the JSON and call mcp__google-calendar__create-event
# directly for each event. Verified 2026-06-15 that direct invocation works in
# `claude -p` headless mode (no ToolSearch step needed).
read -r -d '' PROMPT <<PROMPT_EOF
Read the JSON file at $EVENTS_JSON. It contains a list of weekly time-block events to create in Google Calendar for plan-week $PLAN_WEEK.

For EACH event in the "events" array, call mcp__google-calendar__create-event DIRECTLY (do NOT call ToolSearch, do NOT call any loading step, do NOT enumerate other tools - just invoke the tool by its full name). For each event use these parameters:

- calendarId: "primary"
- summary: the event's "summary" field
- description: the event's "description" field verbatim
- start: { dateTime: the event's "start" field, timeZone: the event's "timezone" field }
- end: { dateTime: the event's "end" field, timeZone: the event's "timezone" field }

After creating ALL events, report a single summary line in this exact format:
WEEKLY_BLOCKS_RESULT: created=<N_success> failed=<N_fail> plan_week=$PLAN_WEEK

If any event creation fails, also print the verbatim error for each failure, prefixed with "FAILURE:" so the wrapper can grep for it.

Do NOT write any vault files; this is calendar-create-only. Do not invoke any other MCP server or tool.
PROMPT_EOF

run_claude_p "$PROMPT" "$LOG"
rc=$?
if [ "$rc" -eq 0 ]; then
  clear_reauth_sentinel
  echo "$PLAN_WEEK" > "$STAMP"
  echo "$(ts) - completed successfully; stamped $PLAN_WEEK" >> "$LOG"
  /usr/bin/osascript -e "display notification \"weekly blocks placed for $PLAN_WEEK - drag in calendar\" with title \"mbs - weekly blocks\"" 2>/dev/null || true
elif [ "$rc" -eq 2 ]; then
  mark_reauth_needed "$LOG"
  echo "$(ts) - calendar-create phase blocked on Claude Code auth. No stamp written. Phase 1 already wrote the events JSON; next trigger after re-auth will retry Phase 2 only (Phase 1 is idempotent and will regenerate the same payloads). Calendar NOT modified by this run." >> "$LOG"
  exit 2
else
  echo "$(ts) - ERROR: claude calendar-create phase exited $rc; no stamp written. Calendar may be partially populated - check before next retry. Next trigger retries." >> "$LOG"
  exit "$rc"
fi
