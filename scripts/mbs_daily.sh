#!/bin/bash
# mbs_daily.sh — run the /obsidian-daily morning report at most once per day.
#
# Triggered by launchd three ways (see scripts/com.mbs.daily.plist):
#   1. StartCalendarInterval at 06:00 local — runs on time if the Mac is awake.
#   2. Wake from sleep — launchd coalesces the missed 06:00 fire and runs it
#      when you open the lid. (Native launchd behavior; not cron.)
#   3. RunAtLoad at login — covers the case where the Mac was fully powered off
#      at 06:00, so the report runs shortly after you log back in.
#
# A per-day stamp file makes every trigger idempotent: the report runs only if
# today's run has not already succeeded. That stamp IS the "check whether it has
# run yet, and if not run it now" logic. The stamp is written only on success, so
# a failed run will retry on the next trigger rather than being skipped for the day.

set -uo pipefail

VAULT="/Users/cpreston/Vaults/storage_mbs"
STATE_DIR="$HOME/.mbs_automation"
STAMP="$STATE_DIR/last_daily_run"
LOG="$STATE_DIR/mbs_daily.log"

mkdir -p "$STATE_DIR"

TODAY="$(date +%Y-%m-%d)"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Already ran successfully today? Stop.
if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$TODAY" ]; then
  echo "$(ts) — already ran for $TODAY, skipping." >> "$LOG"
  exit 0
fi

# launchd starts jobs with a minimal PATH; prepend the common install locations
# for the `claude` binary before resolving it.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  echo "$(ts) — ERROR: 'claude' not found on PATH. Edit PATH in this script. Aborting." >> "$LOG"
  exit 1
fi

echo "$(ts) — starting /obsidian-daily for $TODAY (claude: $CLAUDE_BIN)" >> "$LOG"

cd "$VAULT" || { echo "$(ts) — ERROR: cannot cd to $VAULT" >> "$LOG"; exit 1; }

# Pre-flight: guarantee today's tasks file exists on this Mac's local disk
# BEFORE invoking Claude. Why: the Journals plugin's `tasks.autoCreate` is now
# intentionally disabled (to prevent phone-Mac sync races — phone Journals would
# otherwise create an empty competing version while Mac Obsidian is closed).
# Mac is now solely responsible for tasks-file creation; pre-flight here means
# the file exists even if the Claude call later fails (API overload, network,
# whatever) and the user always has somewhere to write. See SETUP.md.
TODAYS_TASKS="$VAULT/daily_notes/tasks/tasks_${TODAY}.md"
if [ ! -f "$TODAYS_TASKS" ]; then
  mkdir -p "$(dirname "$TODAYS_TASKS")"
  cat > "$TODAYS_TASKS" <<EOF
---
journal: tasks
journal-date: ${TODAY}
---

EOF
  echo "$(ts) — pre-flight: created minimal $TODAYS_TASKS" >> "$LOG"
fi

# Headless run. NOTE: custom slash commands (/obsidian-daily) do NOT expand in
# `claude -p` non-interactive mode — they only work in an interactive session. So
# instead of invoking the slash command, we point Claude at the command file and
# tell it to execute those instructions. The command file is symlinked from the
# repo, so this always runs the current logic (single source of truth).
#
# --dangerously-skip-permissions allows the unattended write without a prompt
# (skipDangerousModePermissionPrompt:true in ~/.claude/settings.json suppresses the
# mode warning). The command is hardened to use the filesystem, not the Obsidian
# MCP, so it does not require Obsidian to be running.
PROMPT="Read the file $HOME/.claude/commands/obsidian-daily.md and carry out its instructions exactly, using the mbs_automation skill, against the vault at $VAULT. This is the unattended scheduled morning run: append or refresh the bounded ## Vault Agent section in today's tasks note via the filesystem, and do not touch P's own sections."
if "$CLAUDE_BIN" -p "$PROMPT" --dangerously-skip-permissions >> "$LOG" 2>&1; then
  echo "$TODAY" > "$STAMP"
  echo "$(ts) — completed successfully; stamped $TODAY" >> "$LOG"
else
  rc=$?
  echo "$(ts) — ERROR: /obsidian-daily exited $rc; will retry on next trigger" >> "$LOG"
  exit "$rc"
fi
