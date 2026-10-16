#!/bin/bash
# reauth_fix_drill.sh - drill for the host-aware failure text (2026-10-16) and
# for scripts/garm_claude_token_renew.sh.
#
# WHY: on garm the CLI runs on a setup-token file, so every "run claude then
# /login" message the estate printed there sent P to a fix that cannot work.
# lib_auth.sh's la_reauth_fix now returns the fix for the host it runs on (token
# file present = garm shape), and mbs_daily.sh's no-network banner names the
# real causes on garm (it is wired and never sleeps).
#
# What it proves, on a garm-shaped and a laptop-shaped host:
#   A  la_reauth_fix text per host, md and plain, constant across calls.
#   B  every banner mbs_daily.sh can write (401, timed out, no report, model
#      never ran, no network, abandoned) renders, printed for reading.
#   C  mark_reauth_needed's notification and two-strike vault alert, and
#      needs_reauth_skip's log line and notification, per host.
#   D  heartbeat check 4's finding per host; mbs_review_prep's log line.
#   E  a backtick trap: `claude` and the renew script on PATH / under HOME are
#      sentinels that record any run; none may run while banners render.
#   F  REAUTH_ALERT_PREFIX is byte-identical to the baseline, and
#      unalert_tasks_note still strikes the reauth alert.
#   G  garm_claude_token_renew.sh against a shimmed ssh: empty paste refused,
#      wrong prefix refused (nothing written either time), a good paste
#      completes, the token never appears in output or in ssh's argv, and a
#      probe that cannot tell a wrong token from a good one is refused.
#
# Safe anywhere: scratch HOME, VAULT and STATE_DIR, stub notify and email, no
# network, no model calls, no ssh. Prints the rendered text: read it.
#
#   /bin/bash scripts/reauth_fix_drill.sh
#   LIB=... DAILY=... /bin/bash scripts/reauth_fix_drill.sh   negative control
#       (baseline lib_auth.sh / mbs_daily.sh from git show, lib_email.sh beside
#       the old lib_auth.sh): the garm-shape cases must FAIL.
# Must stay compatible with macOS /bin/bash 3.2 and /usr/bin/awk.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${LIB:-$HERE/lib_auth.sh}"
DAILY="${DAILY:-$HERE/mbs_daily.sh}"
HB="${HB:-$HERE/mbs_heartbeat.sh}"
PREP="${PREP:-$HERE/mbs_review_prep.sh}"
RENEW="${RENEW:-$HERE/garm_claude_token_renew.sh}"
BASELINE_PREFIX="Automated runs paused: Claude CLI authentication failed"

T="$(mktemp -d "${TMPDIR:-/tmp}/reauth_fix_drill.XXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
has()  { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1 (missing '$2' in $(basename "$3"))"; fi; }
hasnt() { if grep -qF -- "$2" "$3"; then bad "$1 (found '$2' in $(basename "$3"))"; else ok "$1"; fi; }
show() { echo "  ---- $1"; sed 's/^/  | /' "$2"; echo "  ----"; }

# Sentinels for case E: anything that would run because of a live backtick.
mkdir -p "$T/bin" "$T/sentinel"
for c in claude garm_claude_token_renew.sh; do
  printf '#!/bin/bash\ntouch "%s/%s.ran"\n' "$T/sentinel" "$c" > "$T/bin/$c"; chmod +x "$T/bin/$c"
done

GARM_RE='scripts/garm_claude_token_renew.sh'
LAPTOP_RE='then `/login`'
LAPTOP_PLAIN='claude then /login'

# Sets up one host shape under $T/<shape>: HOME, VAULT, STATE_DIR, token file.
setup_host() {
  local shape="$1" h="$T/$1"
  rm -rf "$h"; mkdir -p "$h/home/.mbs_automation" "$h/vault/daily_notes/tasks" "$h/home/dev/mbs_automation/scripts"
  cp "$T/bin/garm_claude_token_renew.sh" "$h/home/dev/mbs_automation/scripts/"
  [ "$shape" = garm ] && printf 'sk-ant-oat01-fixture' > "$h/home/.mbs_automation/claude_oauth_token"
  printf -- '---\njournal: tasks\njournal-date: %s\n---\n\n' "$(date +%Y-%m-%d)" > "$h/vault/daily_notes/tasks/tasks_$(date +%Y-%m-%d).md"
}

# Runs a snippet with lib_auth.sh sourced into the host's sandbox, notify and
# email stubbed to a file. $1 shape, $2 snippet; the snippet sees $H.
in_host() {
  local h="$T/$1"
  HOME="$h/home" VAULT="$h/vault" STATE_DIR="$h/home/.mbs_automation" \
  REAUTH_SENTINEL="$h/home/.mbs_automation/needs_reauth" REAUTH_STRIKES="$h/home/.mbs_automation/reauth_strikes" \
  LA_TOKEN_FILE="$h/home/.mbs_automation/claude_oauth_token" CLAUDE_CODE_OAUTH_TOKEN=drill \
  PATH="$T/bin:$PATH" H="$h" LIBF="$LIB" "$BASH" -c '
    source "$LIBF"
    _la_notify() { printf "NOTIFY %s | %s\n" "$1" "$2" >> "$H/notify"; }
    _la_email() { :; }
    ts() { date "+%Y-%m-%d %H:%M:%S"; }
    '"$2" >> "$h/out" 2>&1
}

for shape in garm laptop; do
  echo "=== host shape: $shape"
  setup_host "$shape"; H="$T/$shape"
  if [ "$shape" = garm ]; then want="$GARM_RE"; other="$LAPTOP_RE"; else want="$LAPTOP_RE"; other="$GARM_RE"; fi

  echo "case A: la_reauth_fix"
  in_host "$shape" 'la_reauth_fix md > "$H/fix_md"; la_reauth_fix md > "$H/fix_md2"; la_reauth_fix plain > "$H/fix_plain"'
  if [ -s "$H/fix_md" ]; then show "md" "$H/fix_md"; show "plain" "$H/fix_plain"; fi
  has "md text names this host's fix" "$want" "$H/fix_md"
  hasnt "md text does not give the other host's fix" "$other" "$H/fix_md"
  if cmp -s "$H/fix_md" "$H/fix_md2"; then ok "text is constant across calls"; else bad "text varies between calls"; fi
  hasnt "plain text carries no backticks" '`' "$H/fix_plain"

  echo "case B: every mbs_daily.sh banner renders"
  NL="$(grep -n '^if \[ -f "\$TODAYS_TASKS" \] && ! grep -qE' "$DAILY" | tail -1 | cut -d: -f1)"
  tail -n +"$NL" "$DAILY" | sed '$d' > "$T/final_block.sh"
  awk '/^  if \[ "\$rc" -eq 2 \]; then$/ {on=1} on {print} on && /^  fi$/ {exit}' "$DAILY" > "$T/auth_block.sh"
  awk '/^  if \[ "\$NOW_DAY" != "\$TODAY" \]; then$/ {on=1} on {print} on && /^  fi$/ {exit}' "$DAILY" > "$T/abandon_block.sh"
  [ -s "$T/auth_block.sh" ] && [ -s "$T/final_block.sh" ] && [ -s "$T/abandon_block.sh" ] && ok "extracted the 401, final and abandoned banner blocks" || bad "could not extract the banner blocks"
  note="$H/vault/daily_notes/tasks/tasks_$(date +%Y-%m-%d).md"
  for rc in 2 124 5 6 1 abandon; do
    printf -- '---\njournal: tasks\n---\n\n' > "$note"
    rm -f "$H/home/.mbs_automation/needs_reauth"
    echo 1 > "$H/home/.mbs_automation/reauth_strikes"
    case "$rc" in
      2) in_host "$shape" 'LOG="$H/daily.log"; TODAYS_TASKS="'"$note"'"; rc=2; ( . "'"$T/auth_block.sh"'" )' ;;
      abandon) in_host "$shape" 'LOG="$H/daily.log"; TODAYS_TASKS="'"$note"'"; TODAY=2000-01-01; NOW_DAY=2000-01-02; attempt=3; MAX_ATTEMPTS=5; ( . "'"$T/abandon_block.sh"'" )' ;;
      *) in_host "$shape" 'LOG="$H/daily.log"; TODAYS_TASKS="'"$note"'"; MAX_ATTEMPTS=5; CLAUDE_TIMEOUT_SECONDS=3600; CLAUDE_IDLE_SECONDS=600; rc='"$rc"'; . "'"$T/final_block.sh"'"' ;;
    esac
    show "banner for rc $rc" "$note"
    has "rc $rc wrote a skipped banner" "## Vault Agent (skipped" "$note"
    if [ "$rc" = 2 ]; then
      has "401 banner gives this host's fix" "$want" "$note"
      hasnt "401 banner does not give the other host's fix" "$other" "$note"
      has "401 path (strike 2) wrote the vault alert" "$BASELINE_PREFIX" "$note"
    fi
    if [ "$rc" = 1 ]; then
      if [ "$shape" = garm ]; then
        has "no-network banner on garm names the wired causes" "wired and never sleeps" "$note"
        has "no-network banner on garm gives the curl check from hoest" "ssh garm 'curl -sS -o /dev/null" "$note"
        hasnt "no-network banner on garm does not blame Wi-Fi" "Wi-Fi" "$note"
      else
        has "no-network banner on a laptop keeps the Wi-Fi text" "before Wi-Fi/DNS reconnected" "$note"
      fi
    fi
  done

  echo "case C: notifications and the reauth skip line"
  : > "$H/notify"; rm -f "$H/home/.mbs_automation/reauth_strikes"
  in_host "$shape" 'mark_reauth_needed "$H/c.log"; needs_reauth_skip "$H/c.log"'
  show "notifications" "$H/notify"
  show "log" "$H/c.log"
  has "mark_reauth_needed notification gives this host's fix" "$(cat "$H/fix_plain")" "$H/notify"
  has "needs_reauth_skip log line gives this host's fix" "To fix: $(cat "$H/fix_plain")" "$H/c.log"
  if [ "$shape" = garm ]; then other_plain="$LAPTOP_PLAIN"; else other_plain="$GARM_RE"; fi
  hasnt "notifications do not give the other host's fix" "$other_plain" "$H/notify"
  hasnt "log lines do not give the other host's fix" "$other_plain" "$H/c.log"

  echo "case D: heartbeat check 4 and review prep"
  awk '/^# --- check 4:/ {on=1} on && /^# --- check 5:/ {exit} on {print}' "$HB" > "$T/check4.sh"
  date '+%Y-%m-%d %H:%M:%S' > "$H/home/.mbs_automation/needs_reauth"
  in_host "$shape" 'add_finding() { printf "%s\n" "$1" >> "$H/findings"; }; . "'"$T/check4.sh"'"'
  show "check 4 finding" "$H/findings"
  has "check 4 gives this host's fix" "$want" "$H/findings"
  hasnt "check 4 does not give the other host's fix" "$other" "$H/findings"
  grep -F 'auth failure; not retrying' "$PREP" | sed 's/^[[:space:]]*//' > "$T/prep_line"
  has "mbs_review_prep's auth log line takes la_reauth_fix" 'la_reauth_fix plain' "$T/prep_line"
done

echo "=== case E: no backtick ran a command while rendering"
if ls "$T/sentinel"/*.ran >/dev/null 2>&1; then bad "a sentinel ran: $(ls "$T/sentinel")"; else ok "no sentinel ran (claude, garm_claude_token_renew.sh)"; fi

echo "=== case F: REAUTH_ALERT_PREFIX and unalert_tasks_note"
setup_host garm
in_host garm 'printf "%s" "$REAUTH_ALERT_PREFIX" > "$H/prefix"'
if [ "$(cat "$T/garm/prefix")" = "$BASELINE_PREFIX" ]; then ok "REAUTH_ALERT_PREFIX is byte-identical to the baseline"; else bad "REAUTH_ALERT_PREFIX changed: '$(cat "$T/garm/prefix")'"; fi
in_host garm 'echo 1 > "$REAUTH_STRIKES"; mark_reauth_needed "$H/f.log"; clear_reauth_sentinel'
hasnt "clear_reauth_sentinel struck the reauth alert from today's note" "$BASELINE_PREFIX" "$T/garm/vault/daily_notes/tasks/tasks_$(date +%Y-%m-%d).md"
hasnt "and the empty alerts heading with it" "## ⚠️ Automation alerts" "$T/garm/vault/daily_notes/tasks/tasks_$(date +%Y-%m-%d).md"

echo "=== case G: garm_claude_token_renew.sh against a shimmed ssh"
GOOD_TOKEN="sk-ant-oat01-DRILLtokenVALUE0123456789"
# The shim plays garm: a fake ~/.mbs_automation under $T/g, argv logged, stdin
# captured for the write step. PROBE_LIES=1 makes the wrong token pass too.
mkdir -p "$T/g/.mbs_automation"
cat > "$T/ssh_shim" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$G/argv"
cmd="${*: -1}"
case "$cmd" in
  *"claude setup-token"*) echo "(shim) setup-token: token printed here" ;;
  *claude_oauth_token.XXXXXX*) cat > "$G/.mbs_automation/claude_oauth_token"; chmod 600 "$G/.mbs_automation/claude_oauth_token" ;;
  *claude_token_created*) date +%Y-%m-%d > "$G/.mbs_automation/claude_token_created" ;;
  *needs_reauth*) rm -f "$G/.mbs_automation/needs_reauth" "$G/.mbs_automation/reauth_strikes" ;;
  *deliberately-wrong*)
    if [ "${PROBE_LIES:-0}" = 1 ]; then echo '{"type":"result","is_error":false,"num_turns":2,"result":"OK"}'
    else echo '{"type":"result","is_error":true,"num_turns":1,"result":"Failed to authenticate. API Error: 401 OAuth access token is invalid."}'; fi ;;
  *"claude -p"*) echo '{"type":"result","is_error":false,"num_turns":2,"result":"OK"}' ;;
  *kickstart*) echo "(shim) kickstarted; mbs_daily.log tail" ;;
  *) echo "(shim) unexpected: $cmd" ;;
esac
SHIM
chmod +x "$T/ssh_shim"
renew() {
  rm -f "$T/g/argv"; rm -f "$T/g/.mbs_automation/claude_oauth_token"
  touch "$T/g/.mbs_automation/needs_reauth"
  printf '%s\n' "$1" | G="$T/g" PROBE_LIES="${2:-0}" RENEW_SSH="$T/ssh_shim" "$BASH" "$RENEW" > "$T/renew.out" 2>&1
  echo $? > "$T/renew.rc"
}
renew ""
show "empty paste" "$T/renew.out"
has "empty paste refused" "FAILED: nothing was pasted" "$T/renew.out"
[ -e "$T/g/.mbs_automation/claude_oauth_token" ] && bad "empty paste wrote a token file" || ok "empty paste wrote nothing on garm"
renew "sk-live-not-a-setup-token"
has "wrong prefix refused" "does not start with sk-ant-oat01-" "$T/renew.out"
[ -e "$T/g/.mbs_automation/claude_oauth_token" ] && bad "wrong prefix wrote a token file" || ok "wrong prefix wrote nothing on garm"
hasnt "the refused value is not echoed" "sk-live-not-a-setup-token" "$T/renew.out"
renew "$GOOD_TOKEN"
show "good paste" "$T/renew.out"
if [ "$(tail -1 "$T/renew.out")" = "token renewed: completed successfully" ]; then ok "good paste ends 'token renewed: completed successfully'"; else bad "good paste last line: $(tail -1 "$T/renew.out")"; fi
if [ "$(cat "$T/g/.mbs_automation/claude_oauth_token")" = "$GOOD_TOKEN" ]; then ok "token file holds exactly the token (no newline)"; else bad "token file content differs"; fi
[ "$(stat -f %Lp "$T/g/.mbs_automation/claude_oauth_token" 2>/dev/null || stat -c %a "$T/g/.mbs_automation/claude_oauth_token")" = 600 ] && ok "token file mode 600" || bad "token file mode is not 600"
[ -e "$T/g/.mbs_automation/needs_reauth" ] && bad "needs_reauth still there" || ok "needs_reauth removed"
[ "$(cat "$T/g/.mbs_automation/claude_token_created" 2>/dev/null)" = "$(date +%Y-%m-%d)" ] && ok "claude_token_created holds today" || bad "claude_token_created not today"
hasnt "token never in the script's output" "$GOOD_TOKEN" "$T/renew.out"
hasnt "token never in ssh argv" "$GOOD_TOKEN" "$T/g/argv"
has "the wrong-token probe ran first" "deliberately-wrong" "$T/g/argv"
renew "$GOOD_TOKEN" 1
has "a probe that passes a wrong token is refused" "FAILED: the probe passed with a deliberately wrong token" "$T/renew.out"

echo
echo "reauth_fix_drill: $PASS passed, $FAIL failed (lib: $LIB, daily: $DAILY, bash $BASH_VERSION)"
[ "$FAIL" -eq 0 ]
