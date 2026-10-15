#!/bin/bash
# run_claude_p_blocked_drill.sh - drill for the no-model-turn guard in
# lib_auth.sh's run_claude_p, plus the matching guards in mbs_daily.sh (banner
# for rc 6) and web_watchers.sh (ask_claude), added 2026-10-10.
#
# WHY: a UserPromptSubmit hook that exits 2 (the vault gate in
# ~/.claude/settings.json, which refuses every run while brain/CLAUDE.md is
# unreadable) blocks the prompt, and `claude -p` then exits 0 with
# is_error:false, num_turns:0, cost 0. run_claude_p used to return that 0, so
# the_record appended its manifest, cars_weekly / mbs_weekly / mbs_review_prep /
# weekly_blocks stamped, and nothing was done. run_claude_p now returns 6.
# web_watchers.sh calls claude directly in text mode, where a blocked run prints
# the hook message plus the whole original prompt: ask_claude now returns an
# empty answer so the loop counts an error and keeps the baseline.
#
# Safe anywhere: scratch HOME, a stub claude replaying recorded streams, no
# network, no model calls. The fixtures are trimmed from a real capture on
# claude 2.1.296 (key order preserved, usage blocks dropped). The 401 and
# credit streams are HAND-BUILT: a real 401 result was never captured.
#
#   bash scripts/run_claude_p_blocked_drill.sh
#       Runs under whatever bash you invoke it with. On the Macs run it as
#       /bin/bash scripts/run_claude_p_blocked_drill.sh, which is bash 3.2.
#   LIB=... DAILY=... WW=... bash scripts/run_claude_p_blocked_drill.sh
#       NEGATIVE CONTROL. Point LIB, DAILY and WW at lib_auth.sh, mbs_daily.sh
#       and web_watchers.sh from before the guard (git show HEAD:scripts/<file>
#       into a scratch directory; lib_email.sh must sit beside the old
#       lib_auth.sh). The guard cases (B, C, E, H, J, K, M) must then FAIL and
#       the controls (A, F, G, I and the normal-answer case) must still pass.
#       If everything passes against the old files, the drill proves nothing.
#   bash scripts/run_claude_p_blocked_drill.sh --live
#       Also runs the REAL claude binary once with a temporary
#       UserPromptSubmit hook that exits 2. The hook blocks before any API
#       call, so it costs nothing and needs no network. Uses your real HOME
#       for auth and settings, scratch dirs for the log and traces. This is
#       also the only check of what the INSTALLED claude version prints for a
#       blocked run in text mode, which the web_watchers guard depends on.
#
# Takes about a minute: the supervisor in lib_auth.sh polls every 5 seconds.
# Must stay compatible with macOS /bin/bash 3.2.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${LIB:-$HERE/lib_auth.sh}"
DAILY="${DAILY:-$HERE/mbs_daily.sh}"
WW="${WW:-$HERE/web_watchers.sh}"
LIVE=0
[ "${1:-}" = "--live" ] && LIVE=1

T="$(mktemp -d "${TMPDIR:-/tmp}/run_claude_p_blocked_drill.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.mbs_automation" "$T/traces"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }
has()  { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1 (missing '$2' in $(basename "$3"))"; fi; }
hasnt() { if grep -qF -- "$2" "$3"; then bad "$1 (found '$2' in $(basename "$3"))"; else ok "$1"; fi; }

# --- fixtures ---------------------------------------------------------------
HOOKMSG='VAULT NOT ACCESSIBLE: all work stopped until the vault is readable.'

cat > "$T/fx_blocked.jsonl" <<'EOF'
{"type":"system","subtype":"hook_started","hook_id":"drill","hook_name":"UserPromptSubmit","hook_event":"UserPromptSubmit"}
{"type":"system","subtype":"hook_response","hook_id":"drill","hook_name":"UserPromptSubmit","hook_event":"UserPromptSubmit","output":"VAULT NOT ACCESSIBLE: all work stopped until the vault is readable.\n","stdout":"","stderr":"VAULT NOT ACCESSIBLE: all work stopped until the vault is readable.\n","exit_code":2,"outcome":"error"}
{"type":"system","subtype":"init","cwd":"/drill","model":"drill","claude_code_version":"2.1.296"}
{"type":"system","subtype":"informational","content":"UserPromptSubmit operation blocked by hook:\n[test -r /Users/cpreston/Vaults/storage_mbs/admin/mbs_system/brain/CLAUDE.md || { echo 'VAULT NOT ACCESSIBLE: all work stopped until the vault is readable.' >&2; exit 2; }]: VAULT NOT ACCESSIBLE: all work stopped until the vault is readable.\n\n\nOriginal prompt: drill prompt","level":"warning","prevent_continuation":true}
{"is_error":false,"duration_api_ms":0,"num_turns":0,"stop_reason":null,"total_cost_usd":0,"subtype":"success","result":"UserPromptSubmit operation blocked by hook:\n[test -r /Users/cpreston/Vaults/storage_mbs/admin/mbs_system/brain/CLAUDE.md || { echo 'VAULT NOT ACCESSIBLE: all work stopped until the vault is readable.' >&2; exit 2; }]: VAULT NOT ACCESSIBLE: all work stopped until the vault is readable.\n\n\nOriginal prompt: drill prompt","type":"result","duration_ms":72}
EOF

# The same block, but the CLI echoes back a prompt that contains an auth
# phrase. Ordering control: it must still be 6, never 2.
sed 's/Original prompt: drill prompt/Original prompt: if the session expired, re-authenticate/g' "$T/fx_blocked.jsonl" > "$T/fx_blocked_echo_auth.jsonl"

cat > "$T/fx_normal.jsonl" <<'EOF'
{"type":"system","subtype":"init","cwd":"/drill","model":"drill","claude_code_version":"2.1.296"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hi! What would you like to work on?"}]}}
{"duration_api_ms":2195,"stop_reason":"end_turn","total_cost_usd":0.29,"is_error":false,"num_turns":1,"subtype":"success","api_error_status":null,"result":"Hi! What would you like to work on?","type":"result","duration_ms":2300}
EOF

# Zero turns but NOT the hook wording: what a CLI that rewords the message
# would emit. The num_turns signal alone must catch it.
cat > "$T/fx_zero_other_text.jsonl" <<'EOF'
{"type":"system","subtype":"init","cwd":"/drill","model":"drill","claude_code_version":"9.9.9"}
{"is_error":false,"duration_api_ms":0,"num_turns":0,"stop_reason":null,"total_cost_usd":0,"subtype":"success","result":"Prompt rejected before the model ran.","type":"result","duration_ms":50}
EOF

# HAND-BUILT: a 401 that reports zero turns. Must stay 2 (auth), not 6.
cat > "$T/fx_auth_zero.jsonl" <<'EOF'
{"type":"system","subtype":"init","cwd":"/drill","model":"drill","claude_code_version":"2.1.285"}
{"is_error":true,"duration_api_ms":0,"num_turns":0,"stop_reason":null,"total_cost_usd":0,"subtype":"success","api_error_status":401,"result":"Failed to authenticate. API Error: 401 authentication_error: Invalid authentication credentials","type":"result","duration_ms":90}
EOF

# HAND-BUILT: out of credits, zero turns. Must stay 3, not 6.
cat > "$T/fx_credit_zero.jsonl" <<'EOF'
{"type":"system","subtype":"init","cwd":"/drill","model":"drill","claude_code_version":"2.1.285"}
{"is_error":true,"duration_api_ms":0,"num_turns":0,"stop_reason":null,"total_cost_usd":0,"subtype":"success","result":"You are out of usage credits. Top up to continue.","type":"result","duration_ms":90}
EOF

cat > "$T/claude" <<'EOF'
#!/bin/bash
case "${1:-}" in
  --help) echo "  --debug-file <path>   write debug log"; exit 0 ;;
esac
cat "$STUB_STREAM"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$T/claude"

# runcase <fixture> <exit code> [outfile|-] [jq|nojq]  ->  RC, $T/job.log, $T/stderr.txt
runcase() {
  local fx="$1" ex="$2" use_out="${3:--}" jqmode="${4:-jq}"
  : > "$T/job.log"; : > "$T/stderr.txt"; rm -f "$T/out.txt" "$T/rc"
  (
    export HOME="$T/home" CLAUDE_TRACE_DIR="$T/traces" STUB_STREAM="$T/$fx" STUB_EXIT="$ex"
    export CLAUDE_TIMEOUT_SECONDS=60 CLAUDE_IDLE_SECONDS=30
    # shellcheck disable=SC1090
    . "$LIB"
    CLAUDE_BIN="$T/claude"
    alert_tasks_note() { :; }
    if [ "$jqmode" = "nojq" ]; then _la_have_jq() { return 1; }; fi
    if [ "$use_out" = "-" ]; then
      run_claude_p "drill prompt" "$T/job.log"
    else
      run_claude_p "drill prompt" "$T/job.log" "$T/$use_out"
    fi
    echo $? > "$T/rc"
  ) 2> "$T/stderr.txt"
  RC="$(cat "$T/rc" 2>/dev/null || echo none)"
}

echo "case A: a normal run still returns 0 (no false positive)"
runcase fx_normal.jsonl 0
expect "rc" "$RC" "0"
hasnt "no failure line in the job log" "NO MODEL TURN" "$T/job.log"
hasnt "nothing on stderr" "NO MODEL TURN" "$T/stderr.txt"

echo "case B: hook-blocked run (real stream shape) returns 6"
runcase fx_blocked.jsonl 0
expect "rc" "$RC" "6"
has "job log names it" "NO MODEL TURN RAN (hook: $HOOKMSG" "$T/job.log"
has "stderr carries the same line (heartbeat check 24 reads .err.log)" "NO MODEL TURN RAN (hook: $HOOKMSG" "$T/stderr.txt"
has "the CLI's own hook text is still in the job log" "UserPromptSubmit operation blocked by hook" "$T/job.log"

echo "case C: the same, without jq (grep fallback)"
runcase fx_blocked.jsonl 0 - nojq
expect "rc" "$RC" "6"
has "job log names it" "NO MODEL TURN RAN (hook" "$T/job.log"
runcase fx_normal.jsonl 0 - nojq
expect "normal run without jq still 0" "$RC" "0"

echo "case E: zero turns with different wording is still caught (num_turns signal)"
runcase fx_zero_other_text.jsonl 0
expect "rc" "$RC" "6"
has "job log says zero" "NO MODEL TURN RAN (zero" "$T/job.log"
runcase fx_zero_other_text.jsonl 0 - nojq
expect "same without jq" "$RC" "6"

echo "case F: a zero-turn 401 keeps its own code"
runcase fx_auth_zero.jsonl 0
expect "rc" "$RC" "2"
hasnt "not reported as a hook block" "NO MODEL TURN" "$T/job.log"

echo "case G: a zero-turn credit failure keeps its own code"
runcase fx_credit_zero.jsonl 0
expect "rc" "$RC" "3"
hasnt "not reported as a hook block" "NO MODEL TURN" "$T/job.log"

echo "case H: ordering control, a block whose echoed prompt contains an auth phrase"
runcase fx_blocked_echo_auth.jsonl 0
expect "rc is 6, not 2 (the re-auth sentinel must not be set by a vault block)" "$RC" "6"

echo "case I: a real failure exit code is not masked"
runcase fx_blocked.jsonl 1
expect "exit 1 stays 1" "$RC" "1"

echo "case J: with a result file (team_brief shape)"
runcase fx_blocked.jsonl 0 out.txt
expect "rc" "$RC" "6"
echo "       (the result file holds the hook text; the caller discards it on a non-zero rc)"

echo "case K: mbs_daily.sh banner for rc 6 does not say no network"
NL="$(grep -n '^if \[ -f "\$TODAYS_TASKS" \] && ! grep -qE' "$DAILY" | tail -1 | cut -d: -f1)"
if [ -z "$NL" ]; then
  bad "found the final banner block in mbs_daily.sh"
else
  ok "found the final banner block in mbs_daily.sh (line $NL)"
  tail -n +"$NL" "$DAILY" > "$T/banner_block.sh"
  for want in 6 1; do
    printf -- '---\njournal: tasks\n---\n\n' > "$T/tasks.md"
    "$BASH" -c '
      ts() { date "+%Y-%m-%d %H:%M:%S"; }
      LOG="$1"; TODAYS_TASKS="$2"; MAX_ATTEMPTS=5; CLAUDE_TIMEOUT_SECONDS=3600; CLAUDE_IDLE_SECONDS=600
      rc="$3"
      . "$4"
    ' _ "$T/daily.log" "$T/tasks.md" "$want" "$T/banner_block.sh" >/dev/null 2>&1
    if [ "$want" = "6" ]; then
      has "rc 6 writes the model-never-ran banner" "## Vault Agent (skipped, model never ran)" "$T/tasks.md"
      hasnt "rc 6 does not claim no network" "no network" "$T/tasks.md"
    else
      has "rc 1 control still writes the no-network banner" "## Vault Agent (skipped, no network)" "$T/tasks.md"
    fi
  done
fi


echo "case M: web_watchers.sh ask_claude (text mode) never hands back a block message as an answer"
awk '/^ask_claude\(\) \{$/ {on=1} on {print} on && /^\}$/ {exit}' "$WW" > "$T/ask_claude.fn"
if [ ! -s "$T/ask_claude.fn" ]; then
  bad "extracted ask_claude from web_watchers.sh"
else
  mkdir -p "$T/bin" "$T/ww.state"
  printf '#!/bin/bash\ncat "$STUB_TEXT"\n' > "$T/bin/claude"
  chmod +x "$T/bin/claude"
  printf '%s\n' 'UserPromptSubmit operation blocked by hook:' \
    "[test -r /Users/cpreston/Vaults/storage_mbs/admin/mbs_system/brain/CLAUDE.md || { echo '$HOOKMSG' >&2; exit 2; }]: $HOOKMSG" \
    '' '' 'Original prompt: PAGE TEXT: your session has expired, please log in again' > "$T/fx_ww_blocked.txt"
  printf 'ITEM ONE\nITEM TWO\n' > "$T/fx_ww_normal.txt"
  printf 'page text\n' > "$T/page.txt"

  # wwcase <stub text file> [live]  ->  WWRC, $T/ww.out, $T/ww.log, $T/ww.err
  wwcase() {
    local stub="$1" live="${2:-}" binpath="$T/bin"
    : > "$T/ww.log"; : > "$T/ww.err"; : > "$T/ww.out"
    rm -f "$T/ww.state/.web_watchers_auth_failed" "$T/ww.marked" "$T/ww.rc"
    [ "$live" = "live" ] && binpath="$T/livebin"
    (
      if [ "$live" != "live" ]; then export HOME="$T/home"; fi
      export PATH="$binpath:$PATH" STUB_TEXT="$stub" CLAUDE_TRACE_DIR="$T/traces"
      # shellcheck disable=SC1090
      . "$LIB"
      STATE_DIR="$T/ww.state"; LOG="$T/ww.log"
      ts() { date '+%Y-%m-%d %H:%M:%S'; }
      alert_tasks_note() { :; }
      mark_reauth_needed() { echo marked > "$T/ww.marked"; }
      # shellcheck disable=SC1090
      . "$T/ask_claude.fn"
      ask_claude "what to watch" "$T/page.txt" > "$T/ww.out"
      echo $? > "$T/ww.rc"
    ) 2> "$T/ww.err"
    WWRC="$(cat "$T/ww.rc" 2>/dev/null || echo none)"
  }

  wwcase "$T/fx_ww_normal.txt"
  expect "normal answer: rc" "$WWRC" "0"
  expect "normal answer: passed through unchanged" "$(cat "$T/ww.out")" "$(printf 'ITEM ONE\nITEM TWO')"
  wwcase "$T/fx_ww_blocked.txt"
  expect "blocked: rc 6" "$WWRC" "6"
  expect "blocked: stdout is empty, so the loop counts an error and keeps the baseline" "$(cat "$T/ww.out")" ""
  [ ! -e "$T/ww.state/.web_watchers_auth_failed" ] && ok "blocked: auth-failed flag not set by the echoed page text" || bad "blocked: auth-failed flag not set by the echoed page text"
  [ ! -e "$T/ww.marked" ] && ok "blocked: re-auth sentinel not set" || bad "blocked: re-auth sentinel not set"
  has "blocked: job log names it" "NO MODEL TURN RAN" "$T/ww.log"
  has "blocked: stderr carries it (check 24 reads web_watchers.err.log)" "NO MODEL TURN RAN" "$T/ww.err"
  has "blocked: the hook's own message is quoted" "$HOOKMSG" "$T/ww.err"
  # The baseline-poisoning case: echoed page text with NO auth phrase in it. The
  # old code printed the whole block message as the answer.
  sed 's/PAGE TEXT: your session has expired, please log in again/PAGE TEXT: Available works: 4. Sold: 2./' "$T/fx_ww_blocked.txt" > "$T/fx_ww_blocked_benign.txt"
  wwcase "$T/fx_ww_blocked_benign.txt"
  expect "blocked, benign page text: rc 6" "$WWRC" "6"
  expect "blocked, benign page text: stdout is empty, never stored as a baseline" "$(cat "$T/ww.out")" ""
fi

if [ "$LIVE" -eq 1 ]; then
  echo "case L (--live): the real claude binary, a temporary hook that exits 2"
  REAL="$(command -v claude || true)"
  if [ -z "$REAL" ]; then
    bad "claude not found on PATH"
  else
    printf '%s\n' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo drill-live-block >&2; exit 2","timeout":10}]}]}}' > "$T/live_block.json"
    printf '#!/bin/bash\nexec "%s" --settings "%s" "$@"\n' "$REAL" "$T/live_block.json" > "$T/claude_live"
    chmod +x "$T/claude_live"
    : > "$T/job.log"; : > "$T/stderr.txt"
    (
      export CLAUDE_TRACE_DIR="$T/traces" CLAUDE_TIMEOUT_SECONDS=120 CLAUDE_IDLE_SECONDS=60
      # shellcheck disable=SC1090
      . "$LIB"
      CLAUDE_BIN="$T/claude_live"
      alert_tasks_note() { :; }
      run_claude_p "drill prompt" "$T/job.log"
      echo $? > "$T/rc"
    ) 2> "$T/stderr.txt"
    RC="$(cat "$T/rc" 2>/dev/null || echo none)"
    echo "       claude: $("$REAL" --version 2>&1 | head -1)"
    expect "rc" "$RC" "6"
    has "job log names it" "NO MODEL TURN RAN" "$T/job.log"
    has "stderr carries it" "NO MODEL TURN RAN" "$T/stderr.txt"

    if [ -s "$T/ask_claude.fn" ]; then
      echo "case M (--live): web_watchers ask_claude against the real claude in text mode"
      mkdir -p "$T/livebin"
      printf '#!/bin/bash\nexec "%s" --settings "%s" "$@"\n' "$REAL" "$T/live_block.json" > "$T/livebin/claude"
      chmod +x "$T/livebin/claude"
      wwcase "" live
      expect "rc 6 (the installed CLI prints the marker the guard looks for)" "$WWRC" "6"
      expect "stdout is empty" "$(cat "$T/ww.out")" ""
      has "stderr carries it" "NO MODEL TURN RAN" "$T/ww.err"
    fi
  fi
fi

echo
echo "run_claude_p_blocked_drill: $PASS passed, $FAIL failed (lib: $LIB)"
[ "$FAIL" -eq 0 ]
