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

# ---------------------------------------------------------------------------
# Failure-string detection — single source of truth (added 2026-07-26).
#
# WHY THIS EXISTS: the original detector matched only the API-key shape of an
# auth failure ("authentication_error", "API Error: 401"). On 2026-07-25 the
# CLI's OAuth session expired and it emitted instead:
#     Failed to authenticate: OAuth session expired and could not be refreshed
# which matched nothing. Result: no sentinel, no notification, no alert line in
# the daily note, and the daily/weekly-blocks/web-watchers jobs failed silently
# for two days. Every call site now shares these patterns, so widening the
# detector is a one-line change in one file rather than four greps in two files.
#
# Keep these deliberately broad. A false positive costs one skipped run plus a
# notification; a false negative costs silent days.
# ---------------------------------------------------------------------------
LA_AUTH_FAIL_RE='authentication_error|Invalid authentication credentials|API Error: 401|Failed to authenticate|OAuth session expired|OAuth token (has )?expired|could not be refreshed|Please run .?/login|not logged in|session (has )?expired'
LA_CREDIT_FAIL_RE='out of usage credits|usage limit reached|insufficient (usage )?credits'

# Returns 0 if the given file contains an auth-failure string.
la_is_auth_failure() { grep -q -iE "$LA_AUTH_FAIL_RE" "$1" 2>/dev/null; }

# Returns 0 if the given file contains a usage-credit-exhaustion string.
la_is_credit_failure() { grep -q -iE "$LA_CREDIT_FAIL_RE" "$1" 2>/dev/null; }

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
  echo "$(_la_ts) - AUTH FAILURE detected (401 / expired OAuth session). Wrote sentinel at $REAUTH_SENTINEL. Notifying P. Skipping retries (retrying an auth failure is pointless until re-auth)." >> "$log"
  _la_notify "Claude Code needs re-auth" "Auth failure detected. Run: claude then /login. Launchd jobs paused until fixed."
  # Also leave a visible line in today's tasks note. A macOS notification is
  # transient and easy to miss (and never fires at all if the Mac was asleep);
  # the vault is where P actually looks. Mirrors the credit-exhaustion path.
  alert_tasks_note "Automated runs paused: Claude CLI authentication failed (expired session or 401). Reports not generated — run \`claude\` then \`/login\` in Terminal; jobs resume on the next trigger."
}

# Delete the sentinel. Called after any successful Claude run.
clear_reauth_sentinel() {
  if [ -f "$REAUTH_SENTINEL" ]; then
    rm -f "$REAUTH_SENTINEL"
  fi
}

# Append a visible one-line alert into today's tasks note so an automation
# failure (out of usage credits, etc.) is never silent in the vault — the way a
# missing ## Vault Agent report was on 2026-07-24. Best-effort; never fails the
# caller. Deduped by message text so a retry loop (or per-row job) writes once.
# Uses $VAULT if the caller set it, else the canonical vault path.
# Args: $1 = short message.
alert_tasks_note() {
  local msg="$1"
  local vault="${VAULT:-$HOME/Vaults/storage_mbs}"
  local note="$vault/daily_notes/tasks/tasks_$(date '+%Y-%m-%d').md"
  local heading="## ⚠️ Automation alerts"
  [ -d "$(dirname "$note")" ] || return 0
  if [ ! -f "$note" ]; then
    printf -- '---\njournal: tasks\njournal-date: %s\n---\n' "$(date '+%Y-%m-%d')" > "$note" 2>/dev/null || return 0
  fi
  # Dedupe: if this exact message already alerted in today's note, do nothing.
  grep -qF -- "$msg" "$note" 2>/dev/null && return 0
  grep -qF -- "$heading" "$note" 2>/dev/null || printf '\n%s\n' "$heading" >> "$note" 2>/dev/null
  printf -- '- **%s ET** — %s\n' "$(date '+%H:%M')" "$msg" >> "$note" 2>/dev/null || true
}

# Hard timeout for claude -p calls, in seconds. Observed 2026-06-18 and
# 2026-06-20: claude -p occasionally hangs without exiting (CPU near 0,
# blocking on network I/O that never returns). The old retry loop never
# fires because it only triggers on non-zero exit. The lock then holds
# forever, every launchd trigger no-ops, the daily report never lands.
# This timeout kills any single attempt after CLAUDE_TIMEOUT_SECONDS and
# returns 124, which the caller's retry loop handles like any other failure.
# Default 25 minutes per attempt; ~1 hr for the typical work the agent does
# (read files, web search, write notes), should be plenty.
CLAUDE_TIMEOUT_SECONDS="${CLAUDE_TIMEOUT_SECONDS:-1500}"

# Model for every launchd-fired `claude -p` call. Pinned to opus 2026-07-24 after
# the CLI default (Fable) silently ran out of usage credits and killed a day's
# runs. Pinning here means one model backs every scheduled job; override by
# exporting CLAUDE_MODEL before invoking a script. Change this one line to
# repoint every job (mbs_daily, mbs_weekly, cars_weekly, the_record,
# weekly_blocks; web_watchers pins opus at its own call sites).
CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"

# Pure-bash timeout wrapper - no Homebrew coreutils dependency.
# Runs the command in a background subshell, polls for completion with a
# 5-second resolution, and SIGTERMs (then SIGKILLs) the process if elapsed
# exceeds the limit. Returns the command's exit code on success, 124 on
# timeout (matching GNU `timeout`'s convention).
_la_run_with_timeout() {
  local timeout_sec="$1"; shift
  local outfile="$1"; shift
  "$@" > "$outfile" 2>&1 &
  local cmd_pid=$!
  local elapsed=0
  while kill -0 "$cmd_pid" 2>/dev/null; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [ "$elapsed" -ge "$timeout_sec" ]; then
      kill -TERM "$cmd_pid" 2>/dev/null
      sleep 3
      kill -KILL "$cmd_pid" 2>/dev/null
      wait "$cmd_pid" 2>/dev/null
      return 124
    fi
  done
  wait "$cmd_pid"
  return $?
}

# Run claude -p with auth-failure detection and hard timeout.
# Args: $1 = prompt string, $2 = log file path
# Returns:
#   0   = success
#   2   = auth failure (401 / authentication_error in output)
#   124 = hard timeout (process exceeded CLAUDE_TIMEOUT_SECONDS without exiting)
#   other = other claude failure (transient API, network, etc.)
#
# Requires $CLAUDE_BIN to be set by the caller.
run_claude_p() {
  local prompt="$1"
  local log="$2"
  local temp
  temp="$(mktemp)"
  _la_run_with_timeout "$CLAUDE_TIMEOUT_SECONDS" "$temp" \
    "$CLAUDE_BIN" -p "$prompt" --model "$CLAUDE_MODEL" --dangerously-skip-permissions
  local rc=$?
  cat "$temp" >> "$log"
  # Hard timeout - the claude process was killed because it took longer than
  # CLAUDE_TIMEOUT_SECONDS to exit. Log clearly and return 124 so the
  # caller's retry loop kicks in (don't treat as auth failure).
  if [ "$rc" -eq 124 ]; then
    echo "$(_la_ts) - claude -p TIMED OUT after ${CLAUDE_TIMEOUT_SECONDS}s; killed. Treating as transient failure." >> "$log"
    rm -f "$temp"
    return 124
  fi
  # Usage-credit exhaustion. Like a 401, retrying inside this session is
  # pointless until P tops up credits (/usage-credits) or switches model
  # (/model) — but unlike a 401 it must stay visible in the vault, so drop a
  # deduped line into today's tasks note here and return 3. Detection runs
  # regardless of exit code (the CLI may exit 0 while printing this message).
  if la_is_credit_failure "$temp"; then
    alert_tasks_note "Automated run failed: Claude CLI is out of usage credits (model: $CLAUDE_MODEL). Report not generated — top up (/usage-credits) or switch model (/model), then it recovers on the next run."
    rm -f "$temp"
    return 3
  fi
  # Auth detection runs regardless of exit code. The claude CLI has been
  # observed (2026-06-18) returning exit 0 even on 401 responses, so we
  # cannot rely on rc alone. Patterns live in $LA_AUTH_FAIL_RE at the top of
  # this file — widened 2026-07-26 to cover the OAuth-expiry wording.
  if la_is_auth_failure "$temp"; then
    rm -f "$temp"
    return 2
  fi
  rm -f "$temp"
  return "$rc"
}
