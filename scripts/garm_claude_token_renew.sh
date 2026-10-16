#!/bin/bash
# garm_claude_token_renew.sh - renew garm's headless Claude token, run by P on hoest.
#
# garm's scheduled jobs run `claude -p` on a `claude setup-token` token kept in
# ~/.mbs_automation/claude_oauth_token on garm (mode 600, raw, no trailing
# newline, prefix sk-ant-oat01-), exported by lib_auth.sh. `/login` cannot fix a
# 401 there. This script is the fix every garm auth alert names (la_reauth_fix in
# lib_auth.sh, 2026-10-16). It does what P did by hand on 2026-10-05:
#   1. ssh -t garm runs `claude setup-token`; P completes the login in a browser
#      and the CLI prints the new token.
#   2. P pastes the token at a hidden prompt here (never echoed, never in argv,
#      never logged; it reaches garm on ssh's stdin).
#   3. Refuses an empty value or one not starting sk-ant-oat01-.
#   4. Writes it on garm through a temp file and mv, mode 600, no newline.
#   5. Writes today's date to ~/.mbs_automation/claude_token_created (check 34).
#   6. Removes ~/.mbs_automation/needs_reauth and reauth_strikes on garm.
#   7. Proves it: a headless `claude -p` over ssh, first with a deliberately
#      wrong token (must fail, or the probe proves nothing), then with the new
#      token from the file (must answer OK). Proven 2026-10-16: over ssh, the
#      wrong token gives is_error true / "401 OAuth access token is invalid",
#      the real one is_error false / "OK".
#   8. Kickstarts com.mbs.daily and prints the tail of its log.
# Last line: "token renewed: completed successfully" or "FAILED: <reason>".
#
# Usage, on hoest, in Terminal:
#   cd ~/dev/mbs_automation && scripts/garm_claude_token_renew.sh
#
# Test hooks (env): RENEW_SSH (ssh binary), RENEW_HOST (default garm).
# Drill: scripts/garm_token_renew_drill.sh (shimmed ssh, no real renewal).

set -uo pipefail

SSH_BIN="${RENEW_SSH:-ssh}"
HOST="${RENEW_HOST:-garm}"
REMOTE_PATH='export PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH'
PROBE_PROMPT='Reply with the single word OK.'

fail() { echo "FAILED: $*"; exit 1; }

echo "Step 1 of 8: on $HOST, run claude setup-token. Complete the login in the browser; the CLI then prints the new token (it starts sk-ant-oat01-). Copy it."
"$SSH_BIN" -t "$HOST" "$REMOTE_PATH; claude setup-token" || fail "claude setup-token on $HOST did not finish (exit $?)"

echo
printf 'Step 2 of 8: paste the token and press Return (nothing will show): ' >&2
TOKEN=""
IFS= read -rs TOKEN
echo >&2
TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"

echo "Step 3 of 8: checking the pasted value."
[ -n "$TOKEN" ] || fail "nothing was pasted; nothing was changed on $HOST"
case "$TOKEN" in
  sk-ant-oat01-?*) : ;;
  *) TOKEN=""; fail "the pasted value does not start with sk-ant-oat01-; nothing was changed on $HOST" ;;
esac

echo "Step 4 of 8: writing the token on $HOST (mode 600, temp file then mv)."
printf '%s' "$TOKEN" | "$SSH_BIN" "$HOST" 'umask 077; d="$HOME/.mbs_automation"; t="$(mktemp "$d/.claude_oauth_token.XXXXXX")" && cat > "$t" && chmod 600 "$t" && mv "$t" "$d/claude_oauth_token" && test "$(wc -c < "$d/claude_oauth_token" | tr -d " ")" -gt 13' \
  || { TOKEN=""; fail "could not write the token file on $HOST"; }
TOKEN=""

echo "Step 5 of 8: recording today's date in claude_token_created."
"$SSH_BIN" "$HOST" 'date +%Y-%m-%d > "$HOME/.mbs_automation/claude_token_created"' || fail "could not write claude_token_created on $HOST"

echo "Step 6 of 8: clearing the re-auth sentinel and strike counter."
"$SSH_BIN" "$HOST" 'rm -f "$HOME/.mbs_automation/needs_reauth" "$HOME/.mbs_automation/reauth_strikes"' || fail "could not clear needs_reauth on $HOST"

echo "Step 7 of 8: proving the token with a headless claude -p on $HOST."
BAD="$("$SSH_BIN" "$HOST" "$REMOTE_PATH; cd ~ && CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-deliberately-wrong claude -p '$PROBE_PROMPT' --model haiku --output-format json 2>&1")"
case "$BAD" in
  *'"is_error":false'*'"result":"OK"'*|*'"result":"OK"'*'"is_error":false'*)
    fail "the probe passed with a deliberately wrong token, so it cannot tell a good token from a bad one; do not trust it" ;;
esac
echo "  negative control: the wrong token was refused, as it must be."
GOOD="$("$SSH_BIN" "$HOST" "$REMOTE_PATH; cd ~ && CLAUDE_CODE_OAUTH_TOKEN=\"\$(cat \"\$HOME/.mbs_automation/claude_oauth_token\")\" claude -p '$PROBE_PROMPT' --model haiku --output-format json 2>&1")"
case "$GOOD" in
  *'"is_error":false'*) : ;;
  *) fail "claude -p on $HOST did not succeed with the new token: $(printf '%s' "$GOOD" | grep -o '"result":"[^"]*"' | head -1)" ;;
esac
case "$GOOD" in
  *'"result":"OK'*) echo "  the new token reached a model turn: claude answered OK." ;;
  *) fail "claude -p on $HOST ran but did not answer OK: $(printf '%s' "$GOOD" | grep -o '"result":"[^"]*"' | head -1)" ;;
esac

echo "Step 8 of 8: kickstarting com.mbs.daily on $HOST (it exits at once if today's report already ran)."
"$SSH_BIN" "$HOST" 'launchctl kickstart gui/$(id -u)/com.mbs.daily; sleep 5; tail -5 "$HOME/.mbs_automation/mbs_daily.log"' || fail "kickstart of com.mbs.daily on $HOST failed"

echo "token renewed: completed successfully"
exit 0
