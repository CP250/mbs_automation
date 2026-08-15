#!/bin/bash
# mbs_weekly.sh - run the weekly agent at most once per ISO week.
#
# Pairs with mbs_daily.sh. Triggered by launchd (see com.mbs.weekly.plist):
#   1. StartCalendarInterval Monday 07:00 local.
#   2. Wake from sleep - launchd coalesces the missed fire and runs on wake.
#   3. RunAtLoad at login - covers a powered-off Mac.
#
# A per-WEEK stamp file (ISO year-week, e.g. 2026-W21) makes every trigger
# idempotent: the weekly run happens at most once per week and only if this
# week's run hasn't already succeeded. Stamp is written only on success.
#
# What it runs: the /obsidian-health audit (REPORT-ONLY - no fixes applied
# unattended) followed by a weekly /obsidian-review. Slash commands don't expand
# in `claude -p`, so the wrapper points Claude at the command files.

set -uo pipefail

VAULT="/Users/cpreston/Vaults/storage_mbs"
STATE_DIR="$HOME/.mbs_automation"
STAMP="$STATE_DIR/last_weekly_run"
LOG="$STATE_DIR/mbs_weekly.log"

mkdir -p "$STATE_DIR"

THIS_WEEK="$(date +%G-W%V)"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$THIS_WEEK" ]; then
  echo "$(ts) - already ran for $THIS_WEEK, skipping." >> "$LOG"
  exit 0
fi

# Source auth-failure detection helpers.
# shellcheck source=./lib_auth.sh
source "$(dirname "$0")/lib_auth.sh"

# Pre-flight: skip cleanly if Claude Code needs re-auth.
if needs_reauth_skip "$LOG"; then
  exit 0
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  echo "$(ts) - ERROR: 'claude' not found on PATH. Edit PATH in this script. Aborting." >> "$LOG"
  exit 1
fi

echo "$(ts) - starting weekly run for $THIS_WEEK (claude: $CLAUDE_BIN)" >> "$LOG"

cd "$VAULT" || { echo "$(ts) - ERROR: cannot cd to $VAULT" >> "$LOG"; exit 1; }

PROMPT="This is the unattended weekly run for the mbs_automation vault at $VAULT, using the mbs_automation skill. Do two things in order: (1) Read $HOME/.claude/commands/obsidian-health.md and carry out the health audit, but REPORT ONLY - do NOT apply any fixes, do NOT move, archive, or delete anything; surface findings for P to act on. (2) Read $HOME/.claude/commands/obsidian-review.md and produce this week's weekly review note, incorporating the health findings under its open-items section. Write via the filesystem, not the Obsidian MCP."

run_claude_p "$PROMPT" "$LOG"
rc=$?
if [ "$rc" -eq 0 ]; then
  clear_reauth_sentinel
  echo "$THIS_WEEK" > "$STAMP"
  echo "$(ts) - completed successfully; stamped $THIS_WEEK" >> "$LOG"
elif [ "$rc" -eq 2 ]; then
  mark_reauth_needed "$LOG"
  echo "$(ts) - weekly run blocked on Claude Code auth; no stamp written. Next trigger after re-auth will retry." >> "$LOG"
  exit 2
else
  echo "$(ts) - ERROR: weekly run exited $rc; will retry on next trigger" >> "$LOG"
  exit "$rc"
fi
