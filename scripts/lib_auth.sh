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

# Headless auth on garm (2026-10-08). garm has no interactive login: its `claude`
# runs on a `claude setup-token` token kept in a 0600 file, never in a plist.
# Exported here, at source time, so every job that sources this library inherits
# it. On hoest the file does not exist and the interactive login is used, so this
# does nothing there. An already-exported token wins (tests, manual runs).
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -r "$HOME/.mbs_automation/claude_oauth_token" ]; then
  CLAUDE_CODE_OAUTH_TOKEN="$(cat "$HOME/.mbs_automation/claude_oauth_token" 2>/dev/null)"
  if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then export CLAUDE_CODE_OAUTH_TOKEN; else unset CLAUDE_CODE_OAUTH_TOKEN; fi
fi

# ---------------------------------------------------------------------------
# Failure-string detection - single source of truth (added 2026-07-26).
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
# Keep these deliberately broad. A false negative costs silent days.
#
# COST CORRECTION (2026-08-19): this used to say a false positive costs "one
# skipped run plus a notification". It does not. On 2026-08-16 a single
# transient "Not logged in" match cost four days of a standing, false,
# self-propagating alarm in the vault, because the tasks-note line had no
# counterpart that removed it. Breadth here is still correct; the fix was to
# make the expensive half of the response (the vault line) two-strike and
# self-clearing. See mark_reauth_needed and unalert_tasks_note below.
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

# Modification time of $1 as an integer epoch, or 0 if it cannot be determined.
#
# Added 2026-08-19 after a functional test caught the naive idiom failing hard.
# These scripts run on macOS, where BSD stat wants -f %m. GNU stat wants -c %Y
# and reads -f as "filesystem status", which SUCCEEDS with exit 0 and prints a
# multi-line block report, so the usual `stat -f %m ... || stat -c %Y ...`
# fallback never fires and the caller does arithmetic on a block report. Under
# bash that is a fatal expression error, not a warning: the calling function
# aborts mid-way. Validate the shape of the output instead of trusting $?.
_la_mtime() {
  local m
  m="$(stat -f %m "$1" 2>/dev/null)"
  case "$m" in
    ''|*[!0-9]*) m="$(stat -c %Y "$1" 2>/dev/null)" ;;
  esac
  case "$m" in
    ''|*[!0-9]*) m=0 ;;
  esac
  echo "$m"
}

# Email alert address and throttle (2026-10-06, garm has no screen, so a macOS
# notification alone reaches nobody there). One email per incident, then a
# reminder every LA_EMAIL_REMIND_SECONDS while it stays blocked. The stamp is
# per title and lives beside the sentinel; clear_reauth_sentinel removes it so
# the next incident emails at once.
LA_EMAIL_TO="${LA_EMAIL_TO:-chris.preston@gmail.com}"
LA_EMAIL_REMIND_SECONDS="${LA_EMAIL_REMIND_SECONDS:-21600}"
# shellcheck source=./lib_email.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_email.sh"

_la_email_stamp() {
  echo "$(dirname "$REAUTH_SENTINEL")/notify_email_$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
}

# Best-effort; never fails the caller. A send failure writes to stderr, which
# heartbeat check 24 sweeps, so a dead SMTP path does not stay silent.
_la_email() {
  local title="$1"
  local message="$2"
  local stamp now stamp_mtime body
  stamp="$(_la_email_stamp "$title")"
  now="$(date +%s)"
  if [ -f "$stamp" ]; then
    stamp_mtime="$(_la_mtime "$stamp")"
    if [ "$stamp_mtime" -gt 0 ] && [ $((now - stamp_mtime)) -lt "$LA_EMAIL_REMIND_SECONDS" ]; then
      return 0
    fi
  fi
  body="$(mktemp "${TMPDIR:-/tmp}/la_email.XXXXXX")" || return 0
  printf '%s\n\nHost: %s\nTime: %s\n' "$message" "$(hostname -s)" "$(date '+%Y-%m-%d %H:%M:%S')" > "$body"
  if send_email "$LA_EMAIL_TO" "[mbs] $title" "$body"; then
    : > "$stamp"
  fi
  rm -f "$body"
  return 0
}

# Fire a macOS notification and an email. Best-effort; never fails the caller.
_la_notify() {
  local title="$1"
  local message="$2"
  /usr/bin/osascript -e "display notification \"$message\" with title \"$title\" sound name \"Sosumi\"" 2>/dev/null || true
  _la_email "$title" "$message"
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
  sentinel_mtime="$(_la_mtime "$REAUTH_SENTINEL")"
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

# Strike counter for the VAULT alert (added 2026-08-19). See mark_reauth_needed
# for why the note alert is gated on two consecutive failures.
REAUTH_STRIKES="${REAUTH_STRIKES:-$HOME/.mbs_automation/reauth_strikes}"
# Exact prefix of the line mark_reauth_needed writes into the tasks note, and
# the needle clear_reauth_sentinel strikes back out. Keep the two in sync.
REAUTH_ALERT_PREFIX="Automated runs paused: Claude CLI authentication failed"
REAUTH_STRIKE_WINDOW_SECONDS=86400

# Write the sentinel and fire notification. Called when a 401 is detected.
#
# TWO-STRIKE RULE (2026-08-19). This used to alert the tasks note on the very
# first detection. On 2026-08-16 at 08:44:09 the Mac woke and ~20 launchd jobs
# fired at once; one `claude -p` lost a token-refresh race and printed
# "Not logged in . Please run /login". weekly_blocks.sh wrote the sentinel and
# the note line. 41 seconds later team_brief's claude call succeeded, 50 seconds
# later mbs_daily's succeeded, and weekly_blocks itself succeeded on its 17:00
# re-run. Nothing was ever actually paused: no job logged a single
# "SKIPPING: Claude Code needs re-auth". But the note line had no counterpart
# that removed it, so a 13-minute transient stood in the vault as a live alarm
# for four days, riding the carry-forward from note to note, and P went looking
# for an auth problem that did not exist.
#
# The old comment above LA_AUTH_FAIL_RE priced a false positive at "one skipped
# run plus a notification". That was wrong, and this is the correction. The
# sentinel and the macOS notification are still written on the FIRST failure:
# both are cheap and both self-heal (the sentinel has a 12h TTL and is deleted
# by the next success). Only the vault line, which is permanent and propagates,
# waits for a second consecutive failure. A real outage still reaches the note
# on the next trigger, minutes to hours later, which is soon enough for a
# problem whose fix is P typing /login.
mark_reauth_needed() {
  local log="$1"
  date '+%Y-%m-%d %H:%M:%S' > "$REAUTH_SENTINEL"

  # Strikes older than the window are a different incident, not a streak.
  local now strikes_mtime strikes
  if [ -f "$REAUTH_STRIKES" ]; then
    now="$(date +%s)"
    strikes_mtime="$(_la_mtime "$REAUTH_STRIKES")"
    # mtime 0 means unknown. Do NOT reset on unknown: resetting every time
    # would hold the counter at 1 forever and the vault line would never fire
    # on a real outage. Keeping a stale streak is the safe direction here.
    if [ "$strikes_mtime" -gt 0 ] && [ $((now - strikes_mtime)) -gt "$REAUTH_STRIKE_WINDOW_SECONDS" ]; then
      rm -f "$REAUTH_STRIKES"
    fi
  fi
  strikes="$(cat "$REAUTH_STRIKES" 2>/dev/null || echo 0)"
  case "$strikes" in
    ''|*[!0-9]*) strikes=0 ;;
  esac
  strikes=$((strikes + 1))
  echo "$strikes" > "$REAUTH_STRIKES"

  echo "$(_la_ts) - AUTH FAILURE detected (401 / expired OAuth session), consecutive strike $strikes. Wrote sentinel at $REAUTH_SENTINEL. Notifying P. Skipping retries (retrying an auth failure is pointless until re-auth)." >> "$log"
  _la_notify "Claude Code needs re-auth" "Auth failure detected. Run: claude then /login. Launchd jobs paused until fixed."

  # The vault line waits for strike 2. A macOS notification is transient and
  # easy to miss (and never fires at all if the Mac was asleep); the vault is
  # where P actually looks, which is exactly why a false line there is costly.
  if [ "$strikes" -ge 2 ]; then
    # Message text is deliberately CONSTANT (no ${strikes} in it). Interpolating
    # the strike count would defeat alert_tasks_note's exact-text dedupe and
    # append a fresh line on every trigger of a continuing outage. The count
    # lives in the log, where repetition is free.
    alert_tasks_note "$REAUTH_ALERT_PREFIX (expired session or 401) on two or more consecutive runs. Reports not generated: run \`claude\` then \`/login\` in Terminal; jobs resume on the next trigger."
  else
    echo "$(_la_ts) - holding the vault alert until a second consecutive failure (strike 1 of 2); sentinel and notification are already out. A success before then clears everything." >> "$log"
  fi
}

# Delete the sentinel, reset the strike counter, and strike any standing auth
# alert back out of today's tasks note. Called after any successful Claude run.
#
# The note cleanup is the half that was missing before 2026-08-19: the old
# version cleared the sentinel file and left the vault line standing forever.
clear_reauth_sentinel() {
  if [ -f "$REAUTH_SENTINEL" ]; then
    rm -f "$REAUTH_SENTINEL"
  fi
  if [ -f "$REAUTH_STRIKES" ]; then
    rm -f "$REAUTH_STRIKES"
  fi
  rm -f "$(_la_email_stamp "Claude Code needs re-auth")"
  unalert_tasks_note "$REAUTH_ALERT_PREFIX"
}

# Append a visible one-line alert into today's tasks note so an automation
# failure (out of usage credits, etc.) is never silent in the vault - the way a
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
  printf -- '- **%s ET**: %s\n' "$(date '+%H:%M')" "$msg" >> "$note" 2>/dev/null || true
}

# Remove any alert bullet matching $1 from today's tasks note, and drop the
# "## Automation alerts" heading if nothing is left under it. The inverse of
# alert_tasks_note. Best-effort; never fails the caller; never touches a line
# that is not an alert bullet.
#
# Added 2026-08-19. Without this, every alert_tasks_note line was permanent:
# a transient failure at 08:44 on 2026-08-16 was still being reported as live
# on 2026-08-19 because nothing ever took it back.
#
# Safety rails, because this writes into the vault:
#   - only lines starting with "- " AND containing the needle are dropped;
#   - the heading goes only when no alert bullet survives beneath it;
#   - the result must be non-empty and no more than 6 lines shorter than the
#     original, or the rewrite is abandoned and the note is left alone.
# Args: $1 = the message prefix to remove.
unalert_tasks_note() {
  local needle="$1"
  local vault="${VAULT:-$HOME/Vaults/storage_mbs}"
  local note="$vault/daily_notes/tasks/tasks_$(date '+%Y-%m-%d').md"
  local heading="## ⚠️ Automation alerts"
  [ -n "$needle" ] || return 0
  [ -f "$note" ] || return 0
  grep -qF -- "$needle" "$note" 2>/dev/null || return 0

  local tmp
  tmp="$(mktemp "${note}.unalert.XXXXXX" 2>/dev/null)" || return 0
  awk -v needle="$needle" -v heading="$heading" '
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        drop[i] = 0
        if (substr(lines[i], 1, 2) == "- " && index(lines[i], needle) > 0) drop[i] = 1
      }
      for (i = 1; i <= NR; i++) {
        if (lines[i] == heading) {
          survivors = 0
          for (j = i + 1; j <= NR; j++) {
            if (substr(lines[j], 1, 3) == "## ") break
            if (substr(lines[j], 1, 2) == "- " && drop[j] == 0) survivors++
          }
          if (survivors == 0) {
            drop[i] = 1
            # alert_tasks_note writes "\n<heading>\n", so the heading owns the
            # blank line above it. Take it back, or every alert-then-clear
            # cycle leaves one more blank line in the note forever.
            if (i > 1 && lines[i-1] == "" && drop[i-1] == 0) drop[i-1] = 1
          }
        }
      }
      for (i = 1; i <= NR; i++) if (!drop[i]) print lines[i]
    }' "$note" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }

  local before after
  before="$(wc -l < "$note" 2>/dev/null | tr -d ' ')"
  after="$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')"
  case "$before$after" in
    *[!0-9]*|'') rm -f "$tmp"; return 0 ;;
  esac
  if [ "$after" -lt 1 ] || [ "$after" -ge "$before" ] || [ $((before - after)) -gt 6 ]; then
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$note" 2>/dev/null || rm -f "$tmp"
  return 0
}

# ---------------------------------------------------------------------------
# claude -p supervision: hard cap, idle watchdog, per-attempt trace (2026-09-09)
#
# HISTORY. The hard timeout was added 2026-06-18/20 after claude -p was seen
# hanging without exiting (CPU near 0, blocking on network I/O that never
# returned); the old retry loop only fired on non-zero exit, so the lock held
# forever and the report never landed. 25 minutes per attempt was sized then
# for "read files, web search, write notes".
#
# WHAT 2026-09-09 SHOWED. The daily report now normally takes 6 to 12 minutes
# (measured over 08-18 to 09-08). On 09-09 attempts 1, 2 and 3 were each
# killed at 1500s with the network up, and attempt 4 completed in 24m47s only
# by deliberately writing a partial report. 09-04 attempt 1 was likewise killed
# while executing P's approvals, having written six files and no report. A
# hard cap is the wrong tool for both shapes: it kills a run that is working
# (losing all of its work) and it waits the full budget on a run that is hung.
# And because text-mode claude -p prints nothing until it finishes, a killed
# attempt left no trace of what it was doing: four kills on 09-09, zero bytes
# of evidence.
#
# THE DESIGN NOW.
#   1. claude -p runs with --output-format stream-json --verbose, writing every
#      event (init, each assistant message, each tool call and result, and the
#      streamed text deltas) to a per-attempt trace file under
#      $CLAUDE_TRACE_DIR as it happens. The trace is the forensic record; the
#      final result text is extracted from it and appended to the job's log
#      exactly where the old text output used to land, so nothing that reads
#      the log sees a different shape.
#   2. Two independent kill conditions, each reported by name:
#        hard cap  CLAUDE_TIMEOUT_SECONDS  total wall clock for one attempt
#        idle      CLAUDE_IDLE_SECONDS     seconds with NO growth of the trace
#      A hung run (nothing coming back from the network, a tool call that
#      never returns) trips idle in 10 minutes instead of costing the whole
#      cap. A run that is working keeps producing events and is left alone up
#      to the cap. So the cap can be raised per job without making hangs more
#      expensive. Set CLAUDE_IDLE_SECONDS=0 to disable the idle kill.
#   3. On a kill, the log gets the reason, the elapsed time, how many tool
#      calls were made, the last three of them, and whether the last one ever
#      returned. That last item is the hang diagnosis: "killed while waiting
#      for mcp__google-calendar__list-events" versus "killed mid-generation".
#   4. Auth and credit detection run over the VERDICT text only (the result
#      event's text plus any non-JSON line, i.e. stderr), never over the whole
#      trace. The trace contains every file the agent read, and mbs_daily.log
#      itself contains the strings LA_AUTH_FAIL_RE matches, so grepping the
#      trace would trip the reauth sentinel every morning the agent read its
#      own log.
#   5. A CLI debug log per attempt (--debug-file, same directory, .debug.log),
#      when the installed CLI supports the flag (probed once per process via
#      --help, so an older CLI just runs without it). This is the STARTUP
#      forensic: 09-09's three killed attempts left no session transcript at
#      all, which places the stall before the first message (auth refresh, MCP
#      connect, hooks), and the stream trace is empty in exactly that case.
#      The debug log is timestamped per phase, so a kill with zero events
#      quotes its last lines. The accounting line also records how many
#      seconds passed before the FIRST byte of output, which is the startup
#      latency, so a creeping stall is visible across days in the job log.
#
# Callers see the same contract as before: run_claude_p "$PROMPT" "$LOG"
# returns 0 / 2 (auth) / 3 (credits) / 124 (killed) / other. Two optional
# arguments (2026-09-09, for team_brief.sh): $3 = a file to receive the result
# text INSTEAD of the log (stderr lines still go to the log), $4 = a file fed to
# claude on stdin (default /dev/null). Per-job overrides: export
# CLAUDE_TIMEOUT_SECONDS / CLAUDE_IDLE_SECONDS before sourcing this file
# (mbs_daily.sh sets a 3600s cap; the estate default stays 1500s).
# ---------------------------------------------------------------------------
CLAUDE_TIMEOUT_SECONDS="${CLAUDE_TIMEOUT_SECONDS:-1500}"
CLAUDE_IDLE_SECONDS="${CLAUDE_IDLE_SECONDS:-600}"
CLAUDE_TRACE_DIR="${CLAUDE_TRACE_DIR:-$HOME/.mbs_automation/claude_traces}"
CLAUDE_TRACE_KEEP_DAYS="${CLAUDE_TRACE_KEEP_DAYS:-14}"

# Model for every launchd-fired `claude -p` call. Pinned to opus 2026-07-24 after
# the CLI default (Fable) silently ran out of usage credits and killed a day's
# runs. Pinning here means one model backs every scheduled job; override by
# exporting CLAUDE_MODEL before invoking a script. Change this one line to
# repoint every job (mbs_daily, mbs_weekly, cars_weekly, the_record,
# weekly_blocks; web_watchers pins opus at its own call sites).
CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"

# Set by _la_run_with_timeout on a kill: "hard" or "idle", plus the elapsed
# seconds at the kill. Empty / 0 when the command exited on its own.
# LA_FIRST_OUTPUT is the elapsed seconds (5s resolution) when the output file
# first grew, or -1 if it never did: the startup latency of the run.
# LA_STDIN_FILE, when set by the caller, is fed to the command on stdin.
LA_KILL_REASON=""
LA_KILL_ELAPSED=0
LA_FIRST_OUTPUT=-1
LA_STDIN_FILE=""

# Pure-bash supervisor - no Homebrew coreutils dependency, bash 3.2 safe.
# Usage: _la_run_with_timeout TIMEOUT_SEC IDLE_SEC OUTFILE CMD...
# Runs CMD in the background with stdout+stderr into OUTFILE, polls every 5s,
# and kills it (SIGTERM, then SIGKILL) when either the total elapsed reaches
# TIMEOUT_SEC or OUTFILE has not grown for IDLE_SEC. Returns the command's
# exit code, or 124 on a kill (GNU timeout's convention).
_la_run_with_timeout() {
  local timeout_sec="$1"; shift
  local idle_sec="$1"; shift
  local outfile="$1"; shift
  LA_KILL_REASON=""
  LA_KILL_ELAPSED=0
  LA_FIRST_OUTPUT=-1
  "$@" < "${LA_STDIN_FILE:-/dev/null}" > "$outfile" 2>&1 &
  local cmd_pid=$!
  local elapsed=0 idle=0 size=0 newsize=0
  while kill -0 "$cmd_pid" 2>/dev/null; do
    sleep 5
    elapsed=$((elapsed + 5))
    newsize="$(wc -c < "$outfile" 2>/dev/null | tr -d ' ')"
    case "$newsize" in ''|*[!0-9]*) newsize="$size" ;; esac
    if [ "$newsize" -ne "$size" ]; then
      [ "$LA_FIRST_OUTPUT" -lt 0 ] && LA_FIRST_OUTPUT="$elapsed"
      size="$newsize"; idle=0
    else
      idle=$((idle + 5))
    fi
    if [ "$elapsed" -ge "$timeout_sec" ]; then
      LA_KILL_REASON="hard"; break
    fi
    if [ "$idle_sec" -gt 0 ] && [ "$idle" -ge "$idle_sec" ]; then
      LA_KILL_REASON="idle"; break
    fi
  done
  if [ -n "$LA_KILL_REASON" ]; then
    LA_KILL_ELAPSED="$elapsed"
    # The whole kill/reap sequence runs inside a stderr-suppressed group.
    #
    # WHY (2026-08-19): bash reports a job killed by a signal as
    #   lib_auth.sh: line NNN: 74952 Terminated: 15   "$@" > "$outfile" 2>&1
    # on the SCRIPT's stderr when the job is reaped. That is the shell talking
    # about itself, not the job failing, and launchd files it into the job's
    # StandardErrorPath. Heartbeat check 24 treats a non-empty recent stderr
    # log as a real finding, so this noise has to go. `wait ... 2>/dev/null`
    # alone does NOT suppress it (measured under bash 3.2 and bash 5); the
    # message is emitted by the enclosing command's context, so the redirect
    # has to wrap the group. The command's own stdout and stderr are
    # unaffected: both already go to $outfile.
    { kill -TERM "$cmd_pid" 2>/dev/null
      sleep 3
      kill -KILL "$cmd_pid" 2>/dev/null
      wait "$cmd_pid"; } 2>/dev/null
    return 124
  fi
  wait "$cmd_pid"
  local rc=$?
  if [ "$LA_FIRST_OUTPUT" -lt 0 ] && [ -s "$outfile" ]; then LA_FIRST_OUTPUT="$elapsed"; fi
  return "$rc"
}

# Does the installed CLI accept --debug-file? Probed once per process; an older
# CLI simply runs without the debug log rather than failing every job on an
# unknown option. LA_DEBUG_FILE_OK: "" = not probed, 1 = yes, 0 = no.
LA_DEBUG_FILE_OK=""
_la_claude_supports_debug_file() {
  if [ -z "$LA_DEBUG_FILE_OK" ]; then
    if "$CLAUDE_BIN" --help 2>/dev/null | grep -q -- '--debug-file'; then
      LA_DEBUG_FILE_OK=1
    else
      LA_DEBUG_FILE_OK=0
    fi
  fi
  [ "$LA_DEBUG_FILE_OK" = "1" ]
}

# Is jq available? Resolved once; every trace reader below degrades to a raw
# grep without it rather than failing the job.
_la_have_jq() { command -v jq >/dev/null 2>&1; }

# Result text of a trace: the result event's text, i.e. what text-mode
# claude -p used to print. Deliberately NOT the tool results or file contents.
_la_trace_result() {
  local trace="$1"
  [ -f "$trace" ] || return 0
  if _la_have_jq; then
    grep '^{' "$trace" 2>/dev/null \
      | jq -rR 'fromjson? | select(.type=="result") | (.result // "") | tostring' 2>/dev/null
  else
    grep '"type":"result"' "$trace" 2>/dev/null | tail -1
  fi
}

# Everything in the trace that is not an event line: stderr, or a CLI that died
# before emitting any event. Goes to the job log, never to a result file.
_la_trace_stderr() {
  local trace="$1"
  [ -f "$trace" ] || return 0
  grep -v '^{' "$trace" 2>/dev/null | grep -v '^[[:space:]]*$'
}

# One-line accounting from the result event: turns, API time, cost, subtype.
_la_trace_summary() {
  local trace="$1"
  [ -f "$trace" ] && _la_have_jq || return 0
  grep '^{' "$trace" 2>/dev/null \
    | jq -rR 'fromjson? | select(.type=="result")
        | "subtype=" + (.subtype // "?")
          + " turns=" + ((.num_turns // 0) | tostring)
          + " api=" + (((.duration_api_ms // 0) / 1000) | floor | tostring) + "s"
          + " cost=$" + ((.total_cost_usd // 0) * 100 | floor / 100 | tostring)' 2>/dev/null \
    | tail -1
}

# Forensics for a killed attempt, written into the job log so the log itself
# says what the run was doing when it died. Reads only the trace.
_la_trace_forensics() {
  local trace="$1" dbg="${2:-}"
  local total tools init pairs last_state
  [ -f "$trace" ] || { echo "  trace: (no trace file)"; return 0; }
  total="$(grep -c '^{' "$trace" 2>/dev/null | tr -d ' ')"
  echo "  trace: $trace (${total:-0} event line(s), $(wc -c < "$trace" | tr -d ' ') bytes)"
  if [ "${LA_FIRST_OUTPUT:--1}" -ge 0 ]; then
    echo "  first output: after ${LA_FIRST_OUTPUT}s"
  else
    echo "  first output: never"
  fi
  if [ "${total:-0}" -eq 0 ]; then
    echo "  diagnosis: claude emitted NO events at all - it never reached its init step; suspect CLI startup, MCP server startup, or auth, not the agent's work"
    grep -v '^[[:space:]]*$' "$trace" 2>/dev/null | tail -3 | sed 's/^/  raw: /' | cut -c1-300
    if [ -n "$dbg" ] && [ -s "$dbg" ]; then
      echo "  debug log: $dbg ($(wc -l < "$dbg" | tr -d ' ') lines); last lines:"
      tail -6 "$dbg" | cut -c1-220 | sed 's/^/    /'
    elif [ -n "$dbg" ]; then
      echo "  debug log: $dbg is absent or empty - the CLI wrote nothing at all"
    fi
    return 0
  fi
  if ! _la_have_jq; then
    echo "  diagnosis: jq not on PATH, cannot pair tool calls; last raw line follows"
    tail -1 "$trace" | cut -c1-300 | sed 's/^/  raw: /'
    return 0
  fi
  init="$(grep '^{' "$trace" | jq -rR 'fromjson? | select(.type=="system" and .subtype=="init") | "model=" + (.model // "?") + " mcp_servers=" + ((.mcp_servers // []) | length | tostring) + " session=" + (.session_id // "?")' 2>/dev/null | head -1)"
  echo "  init: ${init:-(no init event: killed before the session came up)}"
  # USE<tab>id<tab>name<tab>input-summary / RES<tab>id, in stream order.
  pairs="$(grep '^{' "$trace" | jq -rR 'fromjson?
      | if .type=="assistant" then
          (.message.content[]? | select(.type=="tool_use")
           | "USE\t" + (.id // "?") + "\t" + (.name // "?") + "\t" + ((.input // {}) | tostring | .[0:160]))
        elif .type=="user" then
          (.message.content[]? | select(.type=="tool_result") | "RES\t" + (.tool_use_id // "?"))
        else empty end' 2>/dev/null)"
  tools="$(printf '%s\n' "$pairs" | grep -c '^USE' | tr -d ' ')"
  echo "  tool calls: ${tools:-0}"
  printf '%s\n' "$pairs" | grep '^USE' | tail -3 | awk -F'\t' '{ printf "  recent: %s %s\n", $3, $4 }'
  last_state="$(printf '%s\n' "$pairs" | awk -F'\t' '
    $1=="USE" { last_id=$2; last_name=$3; returned=0 }
    $1=="RES" && $2==last_id { returned=1 }
    END {
      if (last_id=="") print "no tool call was ever made - killed during the first model response or before it"
      else if (!returned) print "the LAST tool call never returned: " last_name " - the run was hung inside that tool when killed"
      else print "the last tool call had returned - killed while the model was generating (or waiting on the API) after " last_name
    }')"
  echo "  diagnosis: $last_state"
}

# Log rotation for the trace directory. Traces are large (every tool result is
# in them) and are only ever read after a failure, so two weeks is plenty.
_la_prune_traces() {
  [ -d "$CLAUDE_TRACE_DIR" ] || return 0
  find "$CLAUDE_TRACE_DIR" \( -name '*.jsonl' -o -name '*.debug.log' \) -type f -mtime "+${CLAUDE_TRACE_KEEP_DAYS}" -delete 2>/dev/null
  return 0
}

# Run claude -p under supervision, with auth-failure and credit detection.
# Args: $1 = prompt string, $2 = log file path,
#       $3 = (optional) file to receive the result text instead of the log,
#       $4 = (optional) file fed to claude on stdin (default: /dev/null)
# Returns:
#   0   = success
#   2   = auth failure (401 / authentication_error in output)
#   3   = out of usage credits
#   124 = killed (hard cap or idle watchdog; the log line says which)
#   other = other claude failure (transient API, network, etc.)
#
# Requires $CLAUDE_BIN to be set by the caller.
run_claude_p() {
  local prompt="$1"
  local log="$2"
  local outfile="${3:-}"
  local stdin_file="${4:-}"
  local job stamp trace dbg verdict rc t0 wall summary first
  job="$(basename "$log" .log)"
  mkdir -p "$CLAUDE_TRACE_DIR" 2>/dev/null
  stamp="$(date +%Y-%m-%d_%H%M%S)"
  trace="$CLAUDE_TRACE_DIR/${job}_${stamp}.jsonl"
  dbg="$CLAUDE_TRACE_DIR/${job}_${stamp}.debug.log"
  verdict="$(mktemp)"
  t0="$(date +%s)"
  LA_STDIN_FILE="$stdin_file"
  if _la_claude_supports_debug_file; then
    _la_run_with_timeout "$CLAUDE_TIMEOUT_SECONDS" "$CLAUDE_IDLE_SECONDS" "$trace" \
      "$CLAUDE_BIN" -p "$prompt" --model "$CLAUDE_MODEL" --dangerously-skip-permissions \
      --output-format stream-json --verbose --debug-file "$dbg"
  else
    dbg=""
    _la_run_with_timeout "$CLAUDE_TIMEOUT_SECONDS" "$CLAUDE_IDLE_SECONDS" "$trace" \
      "$CLAUDE_BIN" -p "$prompt" --model "$CLAUDE_MODEL" --dangerously-skip-permissions \
      --output-format stream-json --verbose
  fi
  rc=$?
  LA_STDIN_FILE=""
  wall=$(( $(date +%s) - t0 ))
  # The final message lands where text-mode output used to: the job log, or
  # the caller's result file. stderr lines always go to the log. Both feed the
  # auth and credit detectors.
  _la_trace_result "$trace" > "$verdict" 2>/dev/null
  if [ -n "$outfile" ]; then
    cat "$verdict" > "$outfile"
  else
    cat "$verdict" >> "$log"
  fi
  _la_trace_stderr "$trace" >> "$log" 2>/dev/null
  _la_trace_stderr "$trace" >> "$verdict" 2>/dev/null
  if [ "$rc" -eq 124 ]; then
    if [ "$LA_KILL_REASON" = "idle" ]; then
      echo "$(_la_ts) - claude -p TIMED OUT after ${LA_KILL_ELAPSED}s: no output for ${CLAUDE_IDLE_SECONDS}s (idle watchdog); killed. Treating as transient failure." >> "$log"
    else
      echo "$(_la_ts) - claude -p TIMED OUT after ${LA_KILL_ELAPSED}s: hard cap ${CLAUDE_TIMEOUT_SECONDS}s reached while still producing output; killed. Treating as transient failure." >> "$log"
    fi
    _la_trace_forensics "$trace" "$dbg" >> "$log" 2>&1
    rm -f "$verdict"
    return 124
  fi
  summary="$(_la_trace_summary "$trace")"
  if [ "${LA_FIRST_OUTPUT:--1}" -ge 0 ]; then first="first output after ${LA_FIRST_OUTPUT}s"; else first="no output at all"; fi
  echo "$(_la_ts) - claude -p exited ${rc} after ${wall}s (${first}${summary:+; ${summary}}); trace: $trace${dbg:+; debug: $dbg}" >> "$log"
  # Usage-credit exhaustion. Like a 401, retrying inside this session is
  # pointless until P tops up credits (/usage-credits) or switches model
  # (/model) - but unlike a 401 it must stay visible in the vault, so drop a
  # deduped line into today's tasks note here and return 3. Detection runs
  # regardless of exit code (the CLI may exit 0 while printing this message).
  if la_is_credit_failure "$verdict"; then
    alert_tasks_note "Automated run failed: Claude CLI is out of usage credits (model: $CLAUDE_MODEL). Report not generated: top up (/usage-credits) or switch model (/model), then it recovers on the next run."
    rm -f "$verdict"
    return 3
  fi
  # Auth detection runs regardless of exit code. The claude CLI has been
  # observed (2026-06-18) returning exit 0 even on 401 responses, so we
  # cannot rely on rc alone. Patterns live in $LA_AUTH_FAIL_RE at the top of
  # this file - widened 2026-07-26 to cover the OAuth-expiry wording.
  if la_is_auth_failure "$verdict"; then
    rm -f "$verdict"
    return 2
  fi
  rm -f "$verdict"
  _la_prune_traces
  return "$rc"
}
