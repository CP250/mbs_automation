#!/bin/bash
# mbs_daily.sh - run the /obsidian-daily morning report at most once per day.
#
# Triggered by launchd three ways (see scripts/com.mbs.daily.plist):
#   1. StartCalendarInterval, a 30-minute grid from 06:00 to 21:30 local (P
#      decision 2026-08-22; it was a single 06:00 fire before that). 06:00 is
#      still the on-time fire; the rest of the grid exists so a day that fails
#      early gets retried later instead of being lost.
#   2. Wake from sleep - launchd coalesces every grid entry missed while asleep
#      into exactly ONE fire on wake. (Native launchd behavior; not cron. The
#      man page is explicit that StartInterval does NOT do this, which is why
#      the grid is a calendar array and not an interval.)
#   3. RunAtLoad at login - covers the case where the Mac was fully powered off
#      all morning, so the report runs shortly after you log back in.
#
# Firing this often is safe because the per-day stamp check below is the third
# thing this script does, before the lock and before the vault scan: on a day
# that already succeeded, every later grid fire exits in milliseconds. Fires
# that land mid-ladder hit the live PID lock and exit cleanly, so the grid only
# takes over once a ladder has actually given up.
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
#   behavior - retrying while the network is asleep has no value.
# - The ladder is bound to its own calendar day (2026-08-25). Before each
#   attempt, if the date no longer matches the day the run started for, the
#   ladder is abandoned (exit 4) and the lock released. Without this a ladder
#   whose sleeps paused across Mac sleep could squat the lock into the next day
#   and silently swallow it whole, because launchd will not start a second copy
#   of a running job and the heartbeat deferred on the live PID. That is exactly
#   what happened to 2026-08-24.
# - If all in-script retries fail, the script exits non-zero with no stamp, so
#   the next launchd trigger (the next 30-minute grid entry, the next wake, or
#   tomorrow's 06:00) will retry with a fresh ladder. Before the grid existed
#   this was the hole that lost 2026-08-21 entirely: the ladder died at 12:00
#   and nothing fired again that day.
#
# Why this matters: on 2026-06-05 a 06:00 FailedToOpenSocket killed that day's
# report because the script exited after one attempt and launchd's wake-coalesce
# never fired a retry trigger that day. The in-script retry loop fixes that.

set -uo pipefail

VAULT="${VAULT:-/Users/cpreston/Vaults/storage_mbs}"
STATE_DIR="${STATE_DIR:-$HOME/.mbs_automation}"
STAMP="$STATE_DIR/last_daily_run"
LOG="$STATE_DIR/mbs_daily.log"

mkdir -p "$STATE_DIR"

TODAY="$(date +%Y-%m-%d)"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Structure-review 2026-08-01 drain REMOVED 2026-08-03. It moved sweep reports
# out of the legacy admin/obsidian_optimize/session_awareness/ landing dir. That
# dir is gone (disposed to trash/) and the Cowork task's report path was verified
# canonical, so the loop was dead code. History: design/session_awareness/CLAUDE.md.

# Per-attempt budget for this job (2026-09-09). lib_auth.sh's estate default
# is 1500s; the morning report normally takes 6 to 12 minutes but on 09-09
# three attempts in a row were killed at 1500s and the fourth needed 24m47s.
# Since the same change, a HUNG attempt is killed by the idle watchdog
# (CLAUDE_IDLE_SECONDS, default 600s of no output) rather than by this cap, so
# raising the cap costs nothing on a hang and stops a working run from being
# thrown away. Both are overridable from the environment (the plist).
export CLAUDE_TIMEOUT_SECONDS="${CLAUDE_TIMEOUT_SECONDS:-3600}"
export CLAUDE_IDLE_SECONDS="${CLAUDE_IDLE_SECONDS:-600}"

# Source the auth-failure detection helpers (lib_auth.sh).
# shellcheck source=./lib_auth.sh
source "$(dirname "$0")/lib_auth.sh"

# Everything that makes or rewrites the tasks note (create, frontmatter heal,
# open_tasks, carry-forward, residue, rescue, garden leave block, triage
# first-seen, skip-banner strike, the note lock) lives in lib_tasks_note.sh
# since 2026-10-16, shared with com.mbs.tasks-rollover (tasks_rollover.sh).
# shellcheck source=./lib_tasks_note.sh
source "$(dirname "$0")/lib_tasks_note.sh"

# Pre-flight: if the reauth sentinel is fresh, the API will 401 again. Skip
# cleanly so launchd doesn't burn cycles, and re-fire the notification.
if needs_reauth_skip "$LOG"; then
  exit 0
fi

# Already ran successfully today? Stop.
if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$TODAY" ]; then
  echo "$(ts) - already ran for $TODAY, skipping." >> "$LOG"
  exit 0
fi

# Single-instance lock. mkdir is atomic - only one launchd invocation can win
# the create. If we lose, check whether the holder is still alive; if not,
# the lock is stale (script killed without trap firing) and we claim it.
LOCK_DIR="$STATE_DIR/mbs_daily.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  HOLDER_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -n "${HOLDER_PID:-}" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
    echo "$(ts) - another instance is running (PID $HOLDER_PID), exiting cleanly" >> "$LOG"
    exit 0
  fi
  echo "$(ts) - stale lock detected (holder PID was ${HOLDER_PID:-unknown}), claiming" >> "$LOG"
  rm -rf "$LOCK_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$(ts) - ERROR: could not claim lock after cleanup, aborting" >> "$LOG"
    exit 1
  fi
fi
echo $$ > "$LOCK_DIR/pid"
# Stamp the lock with the day it was claimed FOR (2026-08-25). mbs_heartbeat.sh
# reads this to tell "mbs_daily is still working, not late yet" apart from "a
# ladder from an earlier day is still squatting here". Before this existed the
# watchdog deferred on any live PID, which is how 2026-08-24 passed in total
# silence: see the day bound in the retry loop below.
echo "$TODAY" > "$LOCK_DIR/day"
# Release the lock on any exit path (success, error, SIGTERM from `launchctl bootout`).
trap 'tasks_note_lock_release 2>/dev/null; rm -rf "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

# launchd starts jobs with a minimal PATH; prepend the common install locations
# for the `claude` binary before resolving it.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  echo "$(ts) - ERROR: 'claude' not found on PATH. Edit PATH in this script. Aborting." >> "$LOG"
  exit 1
fi

echo "$(ts) - starting /obsidian-daily for $TODAY (claude: $CLAUDE_BIN)" >> "$LOG"

cd "$VAULT" || { echo "$(ts) - ERROR: cannot cd to $VAULT" >> "$LOG"; exit 1; }

# Pre-flight: today's tasks note. Since 2026-10-16 the note is normally rolled
# over just after midnight by com.mbs.tasks-rollover on garm (P works past
# midnight and that work counts for the new day). This run then only finishes
# the morning's note work; if the rollover has not happened (job not installed,
# not garm, or still waiting for P to pause), this run does it itself, through
# the same functions, guard and deadline. All of it happens under the note
# lock shared with the rollover job, released before the Claude ladder.
# Why the note must exist before Claude runs: Journals' tasks autoCreate is
# off everywhere (phone-Mac sync races, SETUP), so this estate is solely
# responsible for creating it, and P always has somewhere to write even if the
# Claude call fails.
TODAYS_TASKS="$VAULT/daily_notes/tasks/tasks_${TODAY}.md"
OPEN_TASKS="$(count_open_tasks "$VAULT")"
if ! tasks_note_lock_acquire "$STATE_DIR" "$LOG" "$TASKS_NOTE_LOCK_WAIT_SECONDS"; then
  echo "$(ts) - the tasks note lock stayed busy; not stamping, the next grid fire retries" >> "$LOG"
  exit 0
fi
if ! tasks_rollover_done "$TODAY" "$STATE_DIR"; then
  # Why the 06:00 fallback is rolling: the rollover job is not ticking at all
  # (not installed, or not garm), or it is ticking and had not rolled yet.
  RO_TICK_AGE=999999
  [ -f "$STATE_DIR/tasks_rollover_tick" ] && RO_TICK_AGE=$(( ($(date +%s) - $(_tn_mtime "$STATE_DIR/tasks_rollover_tick")) / 60 ))
  if [ "$RO_TICK_AGE" -le 15 ]; then RO_WHY="the rollover job had not rolled yet"; else RO_WHY="the rollover job is not running here"; fi
  RO_PRIOR="$(tasks_prior_date "$TODAY" "$VAULT/daily_notes/tasks")"
  if [ -n "$RO_PRIOR" ] && ! tasks_quiet_check "$VAULT/daily_notes/tasks/tasks_${RO_PRIOR}.md" "$LOG" "$STATE_DIR" daily; then
    tasks_note_lock_release
    echo "$(ts) - rollover not done and tasks_${RO_PRIOR} is not quiet yet; not stamping, the report waits for the next grid fire" >> "$LOG"
    exit 0
  fi
  if ! RO_SAID="$(tasks_rollover_steps "$TODAY" "$VAULT" "$STATE_DIR" "$LOG" "mbs_daily (06:00 fallback: ${RO_WHY})")"; then
    tasks_note_lock_release
    echo "$(ts) - rollover: FAILED inside mbs_daily; not stamping, the next grid fire retries" >> "$LOG"
    exit 1
  fi
  echo "$(ts) - rollover: ${RO_SAID} by mbs_daily (${RO_WHY})" >> "$LOG"
else
  echo "$(ts) - rollover: already done for $TODAY ($(sed -n 2p "$STATE_DIR/last_tasks_rollover" 2>/dev/null))" >> "$LOG"
  # Residue: lines typed into the primary source after the rollover (a phone
  # still showing yesterday). Then the rescue, which is a no-op on a normal day.
  RO_PRIOR="$(tasks_prior_date "$TODAY" "$VAULT/daily_notes/tasks")"
  [ -n "$RO_PRIOR" ] && carry_extra_source residue "$TODAY" "$RO_PRIOR" "$VAULT/daily_notes/tasks" "$TODAYS_TASKS" "$LOG" "$STATE_DIR"
  carry_rescue "$TODAY" "$VAULT/daily_notes/tasks" "$TODAYS_TASKS" "$LOG" "$STATE_DIR"
fi
ensure_tasks_frontmatter "$TODAYS_TASKS" "$TODAY" "$OPEN_TASKS" "$LOG"
# open_tasks stays a 06:00 snapshot (P, 2026-08-07): stamped here, never by the rollover.
ensure_open_tasks_field "$TODAYS_TASKS" "$OPEN_TASKS" "$LOG"

# Record first-seen dates for the open lines in P's region (again after the
# residue pass): the age source for the claude triage step's errand staleness
# flags (project_task_triage). Idempotent.
update_triage_first_seen "$TODAY" "$TODAYS_TASKS" "$STATE_DIR/triage_first_seen" "$LOG"

# Strike any "(skipped" banner an earlier ladder left in today's note, so this
# run's report does not land underneath a notice saying it was never generated.
clear_skip_banner "$TODAYS_TASKS" "$LOG"
tasks_note_lock_release

# Headless run. NOTE: custom slash commands (/obsidian-daily) do NOT expand in
# `claude -p` non-interactive mode - they only work in an interactive session. So
# instead of invoking the slash command, we point Claude at the command file and
# tell it to execute those instructions. The command file is symlinked from the
# repo, so this always runs the current logic (single source of truth).
#
# --dangerously-skip-permissions allows the unattended write without a prompt
# (skipDangerousModePermissionPrompt:true in ~/.claude/settings.json suppresses the
# mode warning). The command is hardened to use the filesystem, not the Obsidian
# MCP, so it does not require Obsidian to be running.
PROMPT="Read the file $HOME/.claude/commands/obsidian-daily.md and carry out its instructions exactly, using the mbs_automation skill, against the vault at $VAULT. This is the unattended scheduled morning run: append or refresh the bounded ## Vault Agent section in today's tasks note via the filesystem, and do not touch P's own sections. Budget: the wrapper kills this run after ${CLAUDE_TIMEOUT_SECONDS}s of wall clock, or after ${CLAUDE_IDLE_SECONDS}s with no output, and a killed run loses its report; work steadily and do not spend turns measuring elapsed time. End the section with the single vault-agent-status line the command file specifies: complete when every step ran, partial (naming the skipped steps) only if you truly could not finish."

# Pre-flight network gate (2026-07-06 hardening): the 06:00 fire (or a
# wake-coalesced grid fire) can land before Wi-Fi/DNS has reconnected, so the first
# attempt would burn on a ConnectionRefused / could-not-resolve failure that has
# nothing to do with the API or with auth (this is what silently killed the
# 2026-07-05 run). Poll the API host for up to ~2 min before starting; proceed
# regardless once reachable or the budget is exhausted (the retry loop below
# still covers a genuine outage). On a healthy morning the first probe returns
# immediately, so this adds no meaningful delay.
wait_for_network() {
  local log="$1"
  local url="https://api.anthropic.com/"
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
wait_for_network "$LOG"

# Retry loop with backoff. Sleeps between attempts (in seconds): 5min, 10min,
# 30min, 60min. So a transient outage of up to ~1.75 hr gets covered without
# relying on launchd to coalesce a wake-trigger.
MAX_ATTEMPTS=5
RETRY_DELAYS=(300 600 1800 3600)

rc=1
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  # --- day bound (2026-08-25) -------------------------------------------------
  # The sleeps below use CLOCK_MONOTONIC and pause while the Mac sleeps, so a
  # ladder can outlive its own calendar day. On 2026-08-23 this loop started at
  # 06:10 and fired attempt 5 at 20:12 the FOLLOWING day, then wrote its banner
  # into tasks_2026-08-23.md at 20:49 on 08-24 because $TODAY was fixed at
  # process start.
  #
  # The cost was not that one late banner. It was the whole of 08-24, lost in
  # total silence, for two compounding reasons:
  #   1. launchd will not start a second copy of a job that is already running,
  #      so not one of 08-24's triggers ever fired. Note the corroborating
  #      evidence: the lock's "another instance is running" branch above has
  #      never been reached once in the entire life of mbs_daily.log.
  #   2. mbs_heartbeat.sh deferred on the live PID ("still running, not late
  #      yet"), so the watchdog was silenced by the very thing it should have
  #      reported.
  # Result: 08-24 got no carry-forward, no report, and no banner explaining the
  # absence. tasks_2026-08-24.md was left holding a single unrelated heading.
  #
  # So: once the date no longer matches the day this run was started FOR, stop.
  # Releasing the lock is the entire point; the next trigger then starts a
  # fresh, correctly dated ladder for the new day. Exit 4 is this case (0/1/2/3
  # and run_claude_p's 124 were already taken).
  NOW_DAY="$(date +%Y-%m-%d)"
  if [ "$NOW_DAY" != "$TODAY" ]; then
    echo "$(ts) - abandoning ladder at attempt $attempt/$MAX_ATTEMPTS: started for $TODAY, it is now $NOW_DAY. Releasing the lock so $NOW_DAY gets its own run." >> "$LOG"
    if [ -f "$TODAYS_TASKS" ] && ! grep -qE '^## Vault Agent' "$TODAYS_TASKS"; then
      cat >> "$TODAYS_TASKS" <<BANNER

## Vault Agent (skipped, run abandoned)

Daily report not generated for ${TODAY}. The retry ladder was still running when the date rolled over to ${NOW_DAY}, so it was abandoned at attempt ${attempt} of ${MAX_ATTEMPTS} and its lock released. Retry sleeps pause while the Mac sleeps, which is how a run stretches past its own day. ${NOW_DAY} gets its own run on the next trigger. No action needed unless this recurs.

BANNER
      echo "$(ts) - wrote abandoned-run banner to $TODAYS_TASKS" >> "$LOG"
    fi
    exit 4
  fi
  echo "$(ts) - attempt $attempt/$MAX_ATTEMPTS" >> "$LOG"
  run_claude_p "$PROMPT" "$LOG"
  rc=$?
  # --- artifact check (2026-09-09) --------------------------------------------
  # The exit code alone has been shown to lie in both directions (09-03: report
  # written, exit non-zero, three redundant attempts; 09-04: side effects
  # written, no report, exit 124). Success now also requires that today's note
  # carries a real ## Vault Agent section AND that the agent's own last line
  # says the report is complete. A "partial" marker (the agent ran out of
  # budget and said so, as on 09-09) is a failed attempt: no stamp, the ladder
  # continues, and the next attempt refreshes the section in place. A MISSING
  # marker is logged and tolerated (an agent that forgot the line should not
  # cost a whole re-run); heartbeat check 2c reports it.
  if [ "$rc" -eq 0 ]; then
    if [ ! -f "$TODAYS_TASKS" ] || ! grep -qE '^## Vault Agent' "$TODAYS_TASKS" \
       || grep -qE '^## Vault Agent \(skipped' "$TODAYS_TASKS"; then
      echo "$(ts) - claude -p exited 0 but today's note has no real ## Vault Agent section; treating as a failed attempt (exit 5)" >> "$LOG"
      rc=5
    else
      VA_STATUS="$(grep -E '^<!-- vault-agent-status: ' "$TODAYS_TASKS" | tail -1)"
      case "$VA_STATUS" in
        *"vault-agent-status: complete"*)
          echo "$(ts) - report marker: ${VA_STATUS}" >> "$LOG" ;;
        *"vault-agent-status: partial"*)
          echo "$(ts) - report is marked PARTIAL by the agent: ${VA_STATUS}" >> "$LOG"
          echo "$(ts) - not stamping; treating the partial report as a failed attempt (exit 5) so a later attempt refreshes it in place" >> "$LOG"
          rc=5 ;;
        *)
          echo "$(ts) - WARNING: report carries no vault-agent-status marker; stamping on exit code alone (heartbeat check 2c will flag it)" >> "$LOG" ;;
      esac
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    clear_reauth_sentinel
    echo "$TODAY" > "$STAMP"
    echo "$(ts) - completed successfully on attempt $attempt; stamped $TODAY" >> "$LOG"
    exit 0
  fi
  if [ "$rc" -eq 2 ]; then
    # Auth failure (401). Retrying is pointless. Mark sentinel, write a banner
    # into today's tasks note so P sees why the report is missing, and exit.
    mark_reauth_needed "$LOG"
    # Only write the banner if no ## Vault Agent section exists yet. A report may
    # have landed from a hand-run or a concurrent attempt while this ladder slept;
    # appending "not generated" under a real report is worse than saying nothing.
    # The fix text comes from la_reauth_fix (lib_auth.sh): on garm it is the
    # token renewal run from hoest, elsewhere claude then /login. The heredoc
    # is unquoted so ${REAUTH_FIX} expands; keep literal backticks OUT of it,
    # since in an unquoted heredoc a backtick is live command substitution.
    REAUTH_FIX="$(la_reauth_fix md)"
    if [ -f "$TODAYS_TASKS" ] && ! grep -qE '^## Vault Agent' "$TODAYS_TASKS"; then
      cat >> "$TODAYS_TASKS" <<BANNER

## Vault Agent (skipped)

Claude Code authentication expired (HTTP 401 from Anthropic API). Daily report not generated. To fix: ${REAUTH_FIX}. Once auth is restored, the next launchd trigger produces the report normally and this banner is struck automatically. Triggers run every 30 minutes from 06:00 to 21:30, plus once on each wake from sleep.

BANNER
      echo "$(ts) - wrote auth-skipped banner to $TODAYS_TASKS" >> "$LOG"
    fi
    exit 2
  fi
  if [ "$rc" -eq 3 ]; then
    # Out of usage credits. run_claude_p already wrote a visible alert line into
    # today's tasks note. Retrying is pointless until credits/model are fixed, so
    # stop the loop (mirrors the 401 path) and exit non-zero with no stamp; the
    # next launchd trigger retries once credits are restored.
    echo "$(ts) - out of usage credits (model ${CLAUDE_MODEL:-opus}); alert written to today's note, not retrying" >> "$LOG"
    exit 3
  fi
  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    delay="${RETRY_DELAYS[$((attempt - 1))]}"
    echo "$(ts) - attempt $attempt failed (exit $rc); sleeping ${delay}s before retry $((attempt + 1))" >> "$LOG"
    sleep "$delay"
  fi
done
echo "$(ts) - all $MAX_ATTEMPTS attempts failed (final exit $rc); will retry on next launchd trigger" >> "$LOG"

# Connectivity-failure banner (2026-07-06 hardening): unlike a 401, a pure
# connection/DNS failure used to leave NO explanation in today's note (the
# silent 2026-07-05 miss), so a missing report looked identical to "nothing
# ran". Write a one-time banner so P sees why. Idempotent: skip if any Vault
# Agent skip banner (this one or the 401 one) is already present in today's file.
# Banner wording follows the final exit code (2026-09-09). This block used to
# call every all-attempts failure "no network", which is how 2026-08-17 (five
# 1500s kills with curl reporting the API reachable) went into the estate's
# own records as a no-network morning. A kill is a kill; say so.
if [ -f "$TODAYS_TASKS" ] && ! grep -qE '^## Vault Agent' "$TODAYS_TASKS"; then
  if [ "$rc" -eq 124 ]; then
    cat >> "$TODAYS_TASKS" <<BANNER

## Vault Agent (skipped, timed out)

Daily report not generated: every one of ${MAX_ATTEMPTS} attempts was killed by the wrapper's watchdog (hard cap ${CLAUDE_TIMEOUT_SECONDS}s, or ${CLAUDE_IDLE_SECONDS}s with no output). The network was reachable, so this is the run hanging or running long, not a connection failure. The tail of ~/.mbs_automation/mbs_daily.log names what each attempt was doing when it died, and the per-attempt traces are in ~/.mbs_automation/claude_traces/. A fresh attempt runs on the next trigger. If a later attempt today succeeds, this banner is struck automatically and replaced by the real report.

BANNER
    echo "$(ts) - wrote timed-out skipped banner to $TODAYS_TASKS" >> "$LOG"
  elif [ "$rc" -eq 5 ]; then
    cat >> "$TODAYS_TASKS" <<BANNER

## Vault Agent (skipped, no report written)

Daily report not generated: claude exited cleanly on all ${MAX_ATTEMPTS} attempts but never wrote a ## Vault Agent section into this note (the wrapper checks the artifact, not just the exit code, since 2026-09-09). The network and auth were fine, so this is the agent failing the write step: read the final message of each attempt in ~/.mbs_automation/mbs_daily.log, and the traces in ~/.mbs_automation/claude_traces/. A fresh attempt runs on the next trigger.

BANNER
    echo "$(ts) - wrote no-report skipped banner to $TODAYS_TASKS" >> "$LOG"
  elif [ "$rc" -eq 6 ]; then
    # run_claude_p returns 6 when claude exited 0 but a hook blocked the prompt
    # before the model ran (2026-10-10). Without this branch the else below
    # would call it a no-network morning.
    cat >> "$TODAYS_TASKS" <<BANNER

## Vault Agent (skipped, model never ran)

Daily report not generated: on all ${MAX_ATTEMPTS} attempts claude exited cleanly but a hook blocked the prompt before the model ran (zero model turns), so no report was attempted. The usual cause is the vault gate in ~/.claude/settings.json, which refuses every Claude Code run while the vault manual (brain/CLAUDE.md) is unreadable. The network and auth were fine. The hook's message is in ~/.mbs_automation/mbs_daily.log and the same line is in ~/.mbs_automation/launchd.err.log (heartbeat check 24 reports it). A fresh attempt runs on the next trigger. If a later attempt today succeeds, this banner is struck automatically and replaced by the real report.

BANNER
    echo "$(ts) - wrote model-never-ran skipped banner to $TODAYS_TASKS" >> "$LOG"
  else
    # garm is wired and never sleeps, so the laptop explanation (woke before
    # Wi-Fi) is wrong there (2026-10-16). Host shape as in la_reauth_fix.
    if la_on_token_host; then
      NET_CAUSE='garm is wired and never sleeps, so the New Canaan internet, the UDM or the Anthropic API itself was down. Check from hoest, in Terminal: `cd ~ && ssh garm '"'"'curl -sS -o /dev/null -w "%{http_code}\n" https://api.anthropic.com/'"'"'` (any three-digit code means the API is reachable now)'
    else
      NET_CAUSE='most often the Mac waking for the scheduled run before Wi-Fi/DNS reconnected'
    fi
    cat >> "$TODAYS_TASKS" <<BANNER

## Vault Agent (skipped, no network)

Daily report not generated: could not reach the Anthropic API after ${MAX_ATTEMPTS} attempts (final exit ${rc}). This was a connection or DNS failure, not an auth problem: ${NET_CAUSE}. A fresh attempt runs on the next trigger: every 30 minutes from 06:00 to 21:30, plus once on each wake from sleep. If a later attempt today succeeds, this banner is struck automatically and replaced by the real report. No action needed unless it recurs for several days.

BANNER
    echo "$(ts) - wrote no-network skipped banner to $TODAYS_TASKS" >> "$LOG"
  fi
fi
exit "$rc"
