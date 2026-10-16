#!/bin/bash
# deferred_checks.sh - run the checks a build session left for later, and speak
# only when one did not work (com.mbs.deferred-checks, garm only, 2026-10-16).
#
# Modeled on mbs_daily.sh (STATE_DIR, ts(), mkdir lock with stale-PID cleanup,
# explicit PATH, the estate terminal vocabulary) and on tasks_rollover.sh (the
# other garm-only interval job: host gate, one decision per run, the next
# trigger is the retry). Read both before changing this.
#
# WHY. Build sessions ended with "P, run this block tomorrow after 10:20 and
# paste the output back". P asked (2026-10-16) for that to be automatic, with
# an alert only when something did not work. So a session now commits a small
# check file to checks/pending/ instead (checks/README.md), and this job runs
# it when it comes due. Checks live in this repo, never in the vault: they are
# code run unattended on garm, so they arrive only as signed commits through
# com.mbs.deploy, like everything else that runs there.
#
# Each run (hourly plus RunAtLoad):
#   - not garm (hostname -s; DEFERRED_HOST overrides): exit 0, no log.
#   - for each checks/pending/*.sh with no result file yet and a due time
#     (header "# due: YYYY-MM-DD HH:MM") that has passed, run it in a fresh
#     /bin/bash with lib_checks.sh, under a CHECK_TIMEOUT_SECONDS cap:
#       pass          -> result PASS; a line in its session log; silent.
#       fail, before  -> no result; retried next hour (the job it checks may
#       expiry           simply be late). Expiry: "# expires:", default due + 4h.
#       fail at expiry-> result FAIL; one alert line in today's tasks note; a
#                        line in its session log; heartbeat check 41 repeats it
#                        for 3 days.
#       error         -> result ERROR (the check itself broke: bad header,
#                        syntax error, non-zero exit outside the helpers, or
#                        timeout); alerted at once, never retried, because a
#                        broken check must never read as a pass.
#   - results live in ~/.mbs_automation/deferred_checks/<name>.result, never in
#     the repo: garm's checkout must stay clean or deploys stop.
#   - stamp last_deferred_checks_run (epoch) and end the log with "completed
#     successfully; ..." (check 26 reads it; check 41 reads the stamp).
#
# Log: ~/.mbs_automation/deferred_checks.log. Drill: scripts/deferred_checks_drill.sh.
# Test hooks (env): STATE_DIR, VAULT, CHECKS_DIR, DEFERRED_HOST, DEFERRED_NOW
# (epoch), CHECK_TIMEOUT_SECONDS, LAUNCHCTL.

set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${STATE_DIR:-$HOME/.mbs_automation}"
VAULT="${VAULT:-$HOME/Vaults/storage_mbs}"
CHECKS_DIR="${CHECKS_DIR:-$(cd "$HERE/.." && pwd)/checks/pending}"
RESULTS="$STATE_DIR/deferred_checks"
LOG="$STATE_DIR/deferred_checks.log"
STAMP="$STATE_DIR/last_deferred_checks_run"
LOCK_DIR="$STATE_DIR/deferred_checks.lock"
TIMEOUT="${CHECK_TIMEOUT_SECONDS:-120}"
DEFAULT_GRACE_SECONDS=14400

[ "${DEFERRED_HOST:-$(hostname -s)}" = "garm" ] || exit 0

mkdir -p "$STATE_DIR" "$RESULTS"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) - $*" >> "$LOG"; }

# shellcheck source=./lib_auth.sh
source "$HERE/lib_auth.sh"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  HOLDER="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -n "${HOLDER:-}" ] && kill -0 "$HOLDER" 2>/dev/null; then
    log "another run is in progress (PID $HOLDER); exiting"
    exit 0
  fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || { log "could not claim the lock; exiting"; exit 0; }
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

NOW="${DEFERRED_NOW:-$(date +%s)}"

# Header field $2 of check file $1 ("# due: ...").
header() { sed -n "s/^# $2:[[:space:]]*//p" "$1" | head -1; }
to_epoch() { date -j -f '%Y-%m-%d %H:%M' "$1" +%s 2>/dev/null; }

# Append one result line to the check's session log, under a heading created on
# first use. Best effort: a missing or unset log is noted in this job's log.
note_in_session_log() {
  local rel="$1" line="$2" f
  [ -n "$rel" ] || return 0
  f="$VAULT/$rel"
  if [ ! -f "$f" ]; then log "  (session log $rel not found; result kept in $RESULTS only)"; return 0; fi
  grep -qF -- "$line" "$f" 2>/dev/null && return 0
  grep -qx '## Deferred check results' "$f" 2>/dev/null || printf '\n## Deferred check results\n\n' >> "$f"
  printf -- '%s\n' "$line" >> "$f"
}

record() {  # name verdict detail
  printf '%s\t%s\t%s\n' "$2" "$(date '+%Y-%m-%d %H:%M')" "$3" > "$RESULTS/$1.result"
}

# Run one check in a fresh bash with the helpers; sets RUN_RC and leaves the
# failure lines in $FAILS. RUN_RC: 0 pass, 1 assertion failure, 2 error, 3 timeout.
run_check() {
  local f="$1" due_day="$2" pid waited=0
  : > "$FAILS"
  STATE_DIR="$STATE_DIR" VAULT="$VAULT" ASSETS="${ASSETS:-$HOME/storage_mbs_assets}" \
  DUE_DAY="$due_day" CHECK_FAILS="$FAILS" LAUNCHCTL="${LAUNCHCTL:-launchctl}" \
    /bin/bash -c 'set -u; source "$1" || exit 90; source "$2"' _ "$HERE/lib_checks.sh" "$f" \
    > "$OUT" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$TIMEOUT" ]; then
      kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      RUN_RC=3; return
    fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid"; local rc=$?
  if [ -s "$FAILS" ]; then RUN_RC=1
  elif [ "$rc" -ne 0 ]; then RUN_RC=2
  else RUN_RC=0; fi
}

FAILS="$(mktemp "$STATE_DIR/deferred_fails.XXXXXX")"
OUT="$(mktemp "$STATE_DIR/deferred_out.XXXXXX")"
trap 'rm -rf "$LOCK_DIR" "$FAILS" "$OUT" 2>/dev/null' EXIT INT TERM

N_DUE=0; N_PASS=0; N_FAIL=0; N_ERR=0; N_WAIT=0; N_LATER=0
for F in "$CHECKS_DIR"/*.sh; do
  [ -f "$F" ] || continue
  NAME="$(basename "$F" .sh)"
  [ -f "$RESULTS/$NAME.result" ] && continue
  WHAT="$(header "$F" what)"; [ -n "$WHAT" ] || WHAT="$NAME"
  SLOG="$(header "$F" log)"
  DUE_S="$(header "$F" due)"
  DUE="$(to_epoch "$DUE_S")"
  if [ -z "$DUE" ]; then
    N_ERR=$((N_ERR + 1))
    record "$NAME" ERROR "no readable '# due: YYYY-MM-DD HH:MM' header"
    log "$NAME: ERROR, no readable due header"
    alert_tasks_note "Deferred check could not run: \`$NAME\` has no readable '# due: YYYY-MM-DD HH:MM' header, so it was never evaluated; fix it in ~/dev/mbs_automation/checks/pending/ on hoest and commit"
    continue
  fi
  if [ "$DUE" -gt "$NOW" ]; then N_LATER=$((N_LATER + 1)); continue; fi
  EXP_S="$(header "$F" expires)"
  if [ -n "$EXP_S" ]; then EXP="$(to_epoch "$EXP_S")"; else EXP=$((DUE + DEFAULT_GRACE_SECONDS)); fi
  [ -n "$EXP" ] || EXP=$((DUE + DEFAULT_GRACE_SECONDS))
  N_DUE=$((N_DUE + 1))
  run_check "$F" "${DUE_S%% *}"
  LINK="${SLOG:+ (session log [[$(basename "$SLOG" .md)]])}"
  case "$RUN_RC" in
    0)
      N_PASS=$((N_PASS + 1))
      record "$NAME" PASS "all assertions held"
      log "$NAME: PASS"
      note_in_session_log "$SLOG" "- $(date '+%Y-%m-%d %H:%M') PASS \`$NAME\`: $WHAT"
      ;;
    1)
      FIRST="$(head -1 "$FAILS")"; NF="$(wc -l < "$FAILS" | tr -d ' ')"
      if [ "$NOW" -lt "$EXP" ]; then
        N_WAIT=$((N_WAIT + 1))
        log "$NAME: not yet ($NF assertion(s) failing, first: $FIRST); retrying until $(date -r "$EXP" '+%Y-%m-%d %H:%M')"
      else
        N_FAIL=$((N_FAIL + 1))
        record "$NAME" FAIL "$NF assertion(s): $(tr '\n' ';' < "$FAILS")"
        log "$NAME: FAIL, $NF assertion(s):"
        sed 's/^/    /' "$FAILS" >> "$LOG"
        note_in_session_log "$SLOG" "- $(date '+%Y-%m-%d %H:%M') did NOT pass \`$NAME\`: $WHAT. $(tr '\n' ';' < "$FAILS")"
        alert_tasks_note "Deferred check did not pass: $WHAT (\`$NAME\`): $FIRST$( [ "$NF" -gt 1 ] && echo " (+$((NF - 1)) more)")${LINK}; all detail in ~/.mbs_automation/deferred_checks.log on garm"
      fi
      ;;
    *)
      N_ERR=$((N_ERR + 1))
      if [ "$RUN_RC" -eq 3 ]; then WHY="timed out after ${TIMEOUT}s"; else WHY="the check itself errored: $(tail -2 "$OUT" | tr '\n' ' ' | cut -c1-200)"; fi
      record "$NAME" ERROR "$WHY"
      log "$NAME: ERROR, $WHY"
      note_in_session_log "$SLOG" "- $(date '+%Y-%m-%d %H:%M') could not run \`$NAME\`: $WHY"
      alert_tasks_note "Deferred check could not run: $WHAT (\`$NAME\`): $WHY${LINK}; nothing was verified, so check it by hand"
      ;;
  esac
done

echo "$NOW" > "$STAMP"
if [ "$N_DUE" -gt 0 ] || [ "$N_ERR" -gt 0 ]; then
  log "completed successfully; $N_DUE due: $N_PASS passed, $N_FAIL did not pass, $N_ERR could not run, $N_WAIT waiting to retry; $N_LATER not yet due"
else
  # Quiet hours write one line a day, not twenty-four.
  if ! grep -q "^$(date +%Y-%m-%d).*completed successfully" "$LOG" 2>/dev/null; then
    log "completed successfully; nothing due ($N_LATER pending, not yet due)"
  fi
fi
exit 0
