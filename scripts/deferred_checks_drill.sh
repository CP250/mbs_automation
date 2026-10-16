#!/bin/bash
# deferred_checks_drill.sh - exercises deferred_checks.sh and every helper in
# lib_checks.sh against a temp STATE_DIR, VAULT and CHECKS_DIR. Touches nothing
# outside the temp dir. Uses macOS date -j / -v, so run it on the Mac.
#   bash scripts/deferred_checks_drill.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/dc_drill.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
SD="$T/state"; V="$T/vault"; CD="$T/checks"
mkdir -p "$HOME" "$SD" "$V/daily_notes/tasks" "$V/logs" "$CD"
TODAY="$(date +%Y-%m-%d)"; YDAY="$(date -v-1d +%Y-%m-%d)"
NOTE="$V/daily_notes/tasks/tasks_$TODAY.md"
SLOG="$V/logs/log_x.md"; printf -- '---\ntype: log\n---\n\n# x\n' > "$SLOG"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# run the runner; $1 = minutes offset added to now (default 0)
runner() {
  local now; now=$(( $(date +%s) + ${1:-0} * 60 ))
  STATE_DIR="$SD" VAULT="$V" CHECKS_DIR="$CD" DEFERRED_HOST=garm DEFERRED_NOW="$now" \
    CHECK_TIMEOUT_SECONDS="${TO:-20}" LAUNCHCTL="${LC:-false}" /bin/bash "$HERE/deferred_checks.sh"
}
# a check file: $1 name, $2 due offset in minutes (negative = past), $3 body, [$4 expires offset]
mkcheck() {
  local due exp=""
  due="$(date -v"${2}"M '+%Y-%m-%d %H:%M')"
  [ -n "${4:-}" ] && exp="# expires: $(date -v"${4}"M '+%Y-%m-%d %H:%M')"
  printf '# what: drill %s\n# due: %s\n%s\n# log: logs/log_x.md\n%s\n' "$1" "$due" "$exp" "$3" > "$CD/$1.sh"
}
verdict() { cut -f1 "$SD/deferred_checks/$1.result" 2>/dev/null; }
alerts() { grep -c "Deferred check" "$NOTE" 2>/dev/null || echo 0; }

echo "host gate"
STATE_DIR="$SD" VAULT="$V" CHECKS_DIR="$CD" DEFERRED_HOST=hoest /bin/bash "$HERE/deferred_checks.sh"
if [ ! -f "$SD/deferred_checks.log" ]; then ok "not garm: exits silently"; else bad "ran on a non-garm host"; fi

echo "runner"
printf '%s 09:00:01 - msk: complete; 0 new note(s)\n%s 09:00:02 - completed successfully; stamped %s\n%s 09:00:00 - fetched 3 clinical-document attachment(s)\n' "$TODAY" "$TODAY" "$TODAY" "$TODAY" > "$SD/job.log"
echo "$TODAY" > "$SD/last_job_run"
mkcheck pass1 -10 'expect_log_line job.log "msk: complete;"
expect_stamp last_job_run'
mkcheck later1 +60 'expect_log_line job.log "never there"'
runner
[ "$(verdict pass1)" = PASS ] && ok "due and passing: PASS" || bad "pass1: $(verdict pass1)"
[ "$(alerts)" = 0 ] && ok "a pass alerts nothing" || bad "pass alerted: $(cat "$NOTE")"
grep -q "PASS \`pass1\`" "$SLOG" && grep -q '^## Deferred check results' "$SLOG" && ok "pass recorded in the session log" || bad "session log: $(cat "$SLOG")"
[ -z "$(verdict later1)" ] && ok "not yet due: untouched" || bad "later1 evaluated early"
tail -1 "$SD/deferred_checks.log" | grep -q "completed successfully; 1 due: 1 passed" && ok "terminal line in the estate vocabulary" || bad "terminal: $(tail -1 "$SD/deferred_checks.log")"
[ -f "$SD/last_deferred_checks_run" ] && ok "stamp written" || bad "no stamp"
runner
[ "$(grep -c "PASS \`pass1\`" "$SLOG")" = 1 ] && ok "a passed check is not run again" || bad "pass1 re-ran"

echo "retry window"
mkcheck late1 -10 'expect_log_line job.log "not written yet"'
runner
[ -z "$(verdict late1)" ] && [ "$(alerts)" = 0 ] && ok "failing before expiry: no verdict, no alert" || bad "late1 judged early: $(verdict late1)"
printf '%s 10:30:00 - not written yet\n' "$TODAY" >> "$SD/job.log"
runner
[ "$(verdict late1)" = PASS ] && ok "the late job arrives: PASS on retry" || bad "late1: $(verdict late1)"
mkcheck fail1 -300 'expect_log_line job.log "msk: complete;"
expect_no_log_line job.log "fetched"
expect_log_max job.log "fetched [0-9]+" 2'
runner
[ "$(verdict fail1)" = FAIL ] && ok "failing past the default 4h expiry: FAIL" || bad "fail1: $(verdict fail1)"
[ "$(alerts)" = 1 ] && grep -q "did not pass: drill fail1 (\`fail1\`): job.log: a line dated $TODAY matches /fetched/.*(+1 more).*\[\[log_x\]\]" "$NOTE" && ok "one alert line naming the check, first failure, count and log" || bad "alert: $(cat "$NOTE" 2>/dev/null)"
grep -q "did NOT pass \`fail1\`" "$SLOG" && ok "failure recorded in the session log" || bad "no failure line in the session log"
if grep -q "FAILED" "$SD/deferred_checks.log"; then bad "runner log carries the word check 26 reads as a verdict"; else ok "runner log never says FAILED"; fi
runner
[ "$(alerts)" = 1 ] && ok "no second alert for the same check" || bad "alerted twice"
mkcheck exp1 -10 'expect_log_line job.log "nope"' -5
runner
[ "$(verdict exp1)" = FAIL ] && ok "an explicit '# expires:' is honoured" || bad "exp1: $(verdict exp1)"

echo "errors"
mkcheck err1 -10 'if then fi'
runner
[ "$(verdict err1)" = ERROR ] && grep -q "could not run: drill err1" "$NOTE" && ok "syntax error: ERROR and alerted at once" || bad "err1: $(verdict err1)"
mkcheck err2 -10 'echo "$UNSET_THING"'
runner
[ "$(verdict err2)" = ERROR ] && ok "unset variable (set -u): ERROR" || bad "err2: $(verdict err2)"
printf '# what: no due\nexpect_file x\n' > "$CD/nodue.sh"
runner
[ "$(verdict nodue)" = ERROR ] && grep -q "nodue\` has no readable" "$NOTE" && ok "missing due header: ERROR and alerted" || bad "nodue: $(verdict nodue)"
mkcheck hang1 -10 'sleep 30'
TO=2 runner
[ "$(verdict hang1)" = ERROR ] && grep -q "timed out after 2s" "$SD/deferred_checks/hang1.result" && ok "a hanging check is killed: ERROR" || bad "hang1: $(cat "$SD/deferred_checks/hang1.result" 2>/dev/null)"

echo "helpers (each positive and negative)"
mkdir -p "$T/files" "$V/daily_notes/health/daily"
: > "$T/files/a"; : > "$T/files/b"; echo hi > "$SD/x.err.log"; : > "$SD/y.err.log"
printf -- '---\ndate: x\nsleep_score: 82\nhrv_avg_ms:\n---\nbody text\n' > "$V/daily_notes/health/daily/n.md"
H="$(md5 -q "$T/files/a")"
helper() {  # $1 label, $2 expect pass|fail, $3 body
  local f="$T/h.fails"; : > "$f"
  STATE_DIR="$SD" VAULT="$V" DUE_DAY="$TODAY" CHECK_FAILS="$f" LAUNCHCTL="${LC:-false}" \
    /bin/bash -c 'set -u; source "$1"; eval "$2"' _ "$HERE/lib_checks.sh" "$3" >/dev/null 2>&1
  if [ "$2" = pass ]; then [ ! -s "$f" ] && ok "$1" || bad "$1 ($(cat "$f"))"
  else [ -s "$f" ] && ok "$1" || bad "$1 (no failure recorded)"; fi
}
helper "expect_log_line finds today's line" pass 'expect_log_line job.log "msk: complete"'
helper "expect_log_line misses another day" fail "expect_log_line --day $YDAY job.log 'msk: complete'"
helper "expect_log_line on a missing file" fail 'expect_log_line nope.log x'
helper "expect_no_log_line, absent" pass 'expect_no_log_line job.log "zzz"'
helper "expect_no_log_line, present" fail 'expect_no_log_line job.log "fetched"'
helper "expect_log_max within" pass 'expect_log_max job.log "fetched [0-9]+" 5'
helper "expect_log_max above" fail 'expect_log_max job.log "fetched [0-9]+" 2'
helper "expect_stamp today" pass 'expect_stamp last_job_run'
helper "expect_stamp other day" fail "expect_stamp --day $YDAY last_job_run"
helper "expect_empty, empty" pass 'expect_empty y.err.log'
helper "expect_empty, missing counts as empty" pass 'expect_empty nothere.err.log'
helper "expect_empty, not empty" fail 'expect_empty x.err.log'
helper "expect_file present" pass 'expect_file job.log'
helper "expect_file absent" fail 'expect_file nope'
helper "expect_file_count eq" pass "expect_file_count $T/files eq 2"
helper "expect_file_count ge, short" fail "expect_file_count $T/files ge 3"
helper "expect_file_count le" pass "expect_file_count $T/files le 2"
helper "expect_md5 match" pass "expect_md5 $T/files/a $H"
helper "expect_md5 mismatch" fail "expect_md5 $T/files/a 0000"
helper "expect_frontmatter filled" pass 'expect_frontmatter daily_notes/health/daily/n.md sleep_score "^[0-9]+$"'
helper "expect_frontmatter empty value" fail 'expect_frontmatter daily_notes/health/daily/n.md hrv_avg_ms'
helper "expect_frontmatter ignores the body" fail 'expect_frontmatter daily_notes/health/daily/n.md body'
helper "expect_frontmatter pattern mismatch" fail 'expect_frontmatter daily_notes/health/daily/n.md sleep_score "^9"'
helper "expect_vault_contains" pass 'expect_vault_contains daily_notes/health/daily/n.md "body text"'
helper "expect_vault_contains, absent" fail 'expect_vault_contains daily_notes/health/daily/n.md "zzz"'
LC=true helper "expect_loaded, loaded" pass 'expect_loaded com.mbs.x'
LC=false helper "expect_loaded, not loaded" fail 'expect_loaded com.mbs.x'
helper "expect_cmd exit 0" pass 'expect_cmd "true works" true'
helper "expect_cmd exit 1" fail 'expect_cmd "false fails" false'

echo "the committed checks parse and carry a due header"
for C in "$HERE"/../checks/pending/*.sh; do
  [ -f "$C" ] || continue
  if /bin/bash -n "$C" && grep -Eq '^# due: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$' "$C"; then ok "$(basename "$C")"; else bad "$(basename "$C") does not parse or has no due header"; fi
done

echo; echo "deferred_checks_drill: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
