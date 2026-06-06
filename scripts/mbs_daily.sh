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
# Idempotence + retry (2026-06-06 hardening):
# - A per-day stamp file ($STAMP) records the last successful day. Any trigger
#   on a stamped day exits immediately. The stamp is written only on success.
# - A directory lock ($LOCK_DIR) prevents two instances from running at once
#   (e.g. a launchd wake-trigger firing while a previous instance is still in
#   its retry-sleep). Stale locks (PID no longer alive) are cleaned up.
# - On Claude failure (transient API outage, network blip), the script retries
#   in-process with exponential backoff before giving up. Five attempts total,
#   sleeps of 5/10/30/60 min between attempts. Total elapsed up to ~1.75 hr.
#   macOS sleep pauses the sleep timer (CLOCK_MONOTONIC), so retries effectively
#   wait for "Mac awake" time rather than wall-clock time. This is the right
#   behavior — retrying while the network is asleep has no value.
# - If all in-script retries fail, the script exits non-zero with no stamp, so
#   the next launchd trigger (next wake event or tomorrow's 06:00) will retry.
#
# Why this matters: on 2026-06-05 a 06:00 FailedToOpenSocket killed that day's
# report because the script exited after one attempt and launchd's wake-coalesce
# never fired a retry trigger that day. The in-script retry loop fixes that.

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

# Single-instance lock. mkdir is atomic — only one launchd invocation can win
# the create. If we lose, check whether the holder is still alive; if not,
# the lock is stale (script killed without trap firing) and we claim it.
LOCK_DIR="$STATE_DIR/mbs_daily.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  HOLDER_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -n "${HOLDER_PID:-}" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
    echo "$(ts) — another instance is running (PID $HOLDER_PID), exiting cleanly" >> "$LOG"
    exit 0
  fi
  echo "$(ts) — stale lock detected (holder PID was ${HOLDER_PID:-unknown}), claiming" >> "$LOG"
  rm -rf "$LOCK_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$(ts) — ERROR: could not claim lock after cleanup, aborting" >> "$LOG"
    exit 1
  fi
fi
echo $$ > "$LOCK_DIR/pid"
# Release the lock on any exit path (success, error, SIGTERM from `launchctl bootout`).
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

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

# Retry loop with backoff. Sleeps between attempts (in seconds): 5min, 10min,
# 30min, 60min. So a transient outage of up to ~1.75 hr gets covered without
# relying on launchd to coalesce a wake-trigger.
MAX_ATTEMPTS=5
RETRY_DELAYS=(300 600 1800 3600)

rc=1
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  echo "$(ts) — attempt $attempt/$MAX_ATTEMPTS" >> "$LOG"
  if "$CLAUDE_BIN" -p "$PROMPT" --dangerously-skip-permissions >> "$LOG" 2>&1; then
    echo "$TODAY" > "$STAMP"
    echo "$(ts) — completed successfully on attempt $attempt; stamped $TODAY" >> "$LOG"
    exit 0
  fi
  rc=$?
  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    delay="${RETRY_DELAYS[$((attempt - 1))]}"
    echo "$(ts) — attempt $attempt failed (exit $rc); sleeping ${delay}s before retry $((attempt + 1))" >> "$LOG"
    sleep "$delay"
  fi
done
echo "$(ts) — all $MAX_ATTEMPTS attempts failed (final exit $rc); will retry on next launchd trigger" >> "$LOG"
exit "$rc"
