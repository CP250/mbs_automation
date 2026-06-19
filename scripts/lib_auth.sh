#!/bin/bash
# lib_auth.sh - shared Claude Code auth-failure detection for launchd-fired scripts.
#
# When `claude -p` returns an API 401 (authentication_error), there is no point
# in retrying within the same session and no point in launchd re-firing every
# wake event. The right behavior is: detect the auth failure, fire a macOS
# notification once, write a sentinel file so subsequent launchd triggers skip
# cleanly until P re-authenticates, and exit without burning the retry loop.
#
# Sourced by mbs_daily.sh, mbs_weekly.sh, cars_weekly.sh, weekly_blocks.sh,
# web_watchers.sh. Each script:
#   1. Calls `needs_reauth_skip "$LOG"` near the top; exits early if sentinel
#      is fresh.
#   2. Calls `run_claude_p "$PROMPT" "$LOG"` instead of `claude -p` directly;
#      checks return code 2 for auth failure, calls `mark_reauth_needed`, exits.
#   3. Calls `clear_reauth_sentinel` after a successful run.
#
# Do NOT execute directly; source from a launchd-fired script.

# Sentinel file path. Existence + freshness => Claude Code needs re-auth.
REAUTH_SENTINEL="${REAUTH_SENTINEL:-$HOME/.mbs_automation/needs_reauth}"

# Sentinel TTL: 12 hours. If a script runs and the sentinel is older than this,
# the script tries claude anyway. This is the safety net for the case where P
# re-authed but forgot to delete the sentinel manually; once the sentinel goes
# stale, the system attempts to resume on its own. The first successful run
# then clears the sentinel.
REAUTH_SENTINEL_TTL_SECONDS=43200

_la_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Fire a macOS notification. Best-effort; never fails the caller.
_la_notify() {
  local title="$1"
  local message="$2"
  /usr/bin/osascript -e "display notification \"$message\" with title \"$title\" sound name \"Sosumi\"" 2>/dev/null || true
}

# Returns 0 (true) if a fresh sentinel exists. Caller should exit 0 in that case.
# Also fires the notification so each blocked launchd trigger nudges P.
needs_reauth_skip() {
  local log="$1"
  if [ ! -f "$REAUTH_SENTINEL" ]; then
    return 1
  fi
  local now sentinel_mtime sentinel_age
  now="$(date +%s)"
  sentinel_mtime="$(stat -f %m "$REAUTH_SENTINEL" 2>/dev/null || stat -c %Y "$REAUTH_SENTINEL" 2>/dev/null || echo 0)"
  sentinel_age=$((now - sentinel_mtime))
  if [ "$sentinel_age" -gt "$REAUTH_SENTINEL_TTL_SECONDS" ]; then
    echo "$(_la_ts) - reauth sentinel is stale (>${REAUTH_SENTINEL_TTL_SECONDS}s old); proceeding anyway." >> "$log"
    return 1
  fi
  local first_detected
  first_detected="$(cat "$REAUTH_SENTINEL" 2>/dev/null || echo unknown)"
  echo "$(_la_ts) - SKIPPING: Claude Code needs re-auth (first detected $first_detected). Run 'claude' then '/login' to fix; this script will resume normally on the next trigger after that." >> "$log"
  _la_notify "Claude Code needs re-auth" "401 detected. Run: claude then /login. Launchd jobs paused until fixed."
  return 0
}

# Write the sentinel and fire notification. Called when a 401 is detected.
mark_reauth_needed() {
  local log="$1"
  date '+%Y-%m-%d %H:%M:%S' > "$REAUTH_SENTINEL"
  echo "$(_la_ts) - AUTH FAILURE detected (HTTP 401 from Anthropic API). Wrote sentinel at $REAUTH_SENTINEL. Notifying P. Skipping retries (retrying a 401 is pointless until re-auth)." >> "$log"
  _la_notify "Claude Code needs re-auth" "401 detected. Run: claude then /login. Launchd jobs paused until fixed."
}

# Delete the sentinel. Called after any successful Claude run.
clear_reauth_sentinel() {
  if [ -f "$REAUTH_SENTINEL" ]; then
    rm -f "$REAUTH_SENTINEL"
  fi
}

# Run claude -p with auth-failure detection.
# Args: $1 = prompt string, $2 = log file path
# Returns:
#   0  = success
#   2  = auth failure (401 / authentication_error in output)
#   other = other claude failure (transient API, network, etc.)
#
# Requires $CLAUDE_BIN to be set by the caller.
run_claude_p() {
  local prompt="$1"
  local log="$2"
  local temp
  temp="$(mktemp)"
  "$CLAUDE_BIN" -p "$prompt" --dangerously-skip-permissions > "$temp" 2>&1
  local rc=$?
  cat "$temp" >> "$log"
  # Auth detection runs regardless of exit code. The claude CLI has been
  # observed (2026-06-18) returning exit 0 even on 401 responses, so we
  # cannot rely on rc alone.
  if grep -q -iE "authentication_error|Invalid authentication credentials|API Error: 401" "$temp"; then
    rm -f "$temp"
    return 2
  fi
  rm -f "$temp"
  return "$rc"
}
