#!/bin/bash
# deadman_drill.sh - exercises deadman.sh with stubbed security, curl and aws.
# Safe anywhere: temp HOME and state, no network, no Keychain, no AWS.
#   bash scripts/deadman_drill.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/deadman_drill.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" TMPDIR="$T"
mkdir -p "$HOME" "$T/state"
SECRET="s3cr3t-webhook-id-9f2c"

printf '#!/bin/bash\nif [ -f "%s/kc_hang" ]; then sleep 30; fi\nif [ -f "%s/kc_fail" ]; then exit 44; fi\necho %s\n' "$T" "$T" "$SECRET" > "$T/security"
printf '#!/bin/bash\ncfg="$(cat)"\necho "$cfg" >> "%s/curl_cfg"\nif [ -f "%s/curl_fail" ]; then echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; fi\nexit 0\n' "$T" "$T" > "$T/curl"
printf '#!/bin/bash\necho "$*" >> "%s/aws_args"\nif [ -f "%s/aws_fail" ]; then echo "An error occurred (AccessDenied)" >&2; exit 254; fi\nexit 0\n' "$T" "$T" > "$T/aws"
chmod +x "$T/security" "$T/curl" "$T/aws"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }
run() {
  STATE_DIR="$T/state" DEADMAN_SECURITY="$T/security" DEADMAN_CURL="$T/curl" DEADMAN_AWS="$T/aws" \
  DEADMAN_HOST=garm MBS_KEYCHAIN_TIMEOUT_S=2 /bin/bash "$HERE/deadman.sh" >"$T/stdout" 2>&1
}
last() { tail -1 "$T/state/deadman.log" | sed 's/^[0-9-]* [0-9:]* - //'; }
reset() { rm -f "$T/kc_hang" "$T/kc_fail" "$T/curl_fail" "$T/aws_fail" "$T/curl_cfg" "$T/aws_args" "$T/state/last_deadman_run"; : > "$T/state/deadman.log"; }

echo "case: both sides succeed"; reset
run; expect "exit 0" "$?" "0"
expect "terminal line" "$(last)" "completed successfully"
[ -f "$T/state/last_deadman_run" ] && ok "stamp written" || bad "stamp written"
grep -q "url = \"http://10.99.0.1:8123/api/webhook/$SECRET\"" "$T/curl_cfg" && ok "webhook URL built from keychain id" || bad "webhook URL built from keychain id"
grep -q -- '--namespace MBS/Garm --metric-name DeadmanCheckin --value 1' "$T/aws_args" && ok "CloudWatch args per contract" || bad "CloudWatch args per contract"
grep -q -- '--profile mbs-deadman' "$T/aws_args" && grep -q 'Host=garm' "$T/aws_args" && ok "profile and Host dimension" || bad "profile and Host dimension"
if grep -rq "$SECRET" "$T/state" "$T/stdout"; then bad "secret absent from log and stdout"; else ok "secret absent from log and stdout"; fi

echo "case: HA rejects, CloudWatch still called"; reset
touch "$T/curl_fail"; run; expect "exit 1" "$?" "1"
[ -s "$T/aws_args" ] && ok "B still attempted" || bad "B still attempted"
case "$(last)" in "FAILED: dead-man check-in side(s) failed: A") ok "terminal line names A" ;; *) bad "terminal line names A ($(last))" ;; esac
[ ! -f "$T/state/last_deadman_run" ] && ok "no stamp on failure" || bad "no stamp on failure"
if grep -q "$SECRET" "$T/state/deadman.log"; then bad "secret absent from failure log"; else ok "secret absent from failure log"; fi

echo "case: CloudWatch rejects"; reset
touch "$T/aws_fail"; run; expect "exit 1" "$?" "1"
case "$(last)" in *"side(s) failed: B") ok "terminal line names B" ;; *) bad "terminal line names B ($(last))" ;; esac

echo "case: keychain read fails, B still called"; reset
touch "$T/kc_fail"; run; expect "exit 1" "$?" "1"
[ -s "$T/aws_args" ] && ok "B still attempted" || bad "B still attempted"
[ ! -s "$T/curl_cfg" ] && ok "no POST without an id" || bad "no POST without an id"

echo "case: keychain hangs (dialog), bounded by the timeout"; reset
touch "$T/kc_hang"; S0=$(date +%s); run; RC=$?; S1=$(date +%s)
expect "exit 1" "$RC" "1"
[ $((S1 - S0)) -lt 15 ] && ok "returned in $((S1 - S0))s, not 30" || bad "returned in $((S1 - S0))s"
grep -q 'did not answer within 2s' "$T/state/deadman.log" && ok "log names the keychain wait" || bad "log names the keychain wait"

echo; echo "deadman_drill: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
