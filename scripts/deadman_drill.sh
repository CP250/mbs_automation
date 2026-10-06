#!/bin/bash
# deadman_drill.sh - exercises deadman.sh with stubbed curl and aws and a temp
# webhook file. Safe anywhere: temp HOME and state, no network, no AWS.
#   bash scripts/deadman_drill.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/deadman_drill.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" TMPDIR="$T"
mkdir -p "$HOME" "$T/state"
SECRET="s3cr3t-webhook-id-9f2c"

printf %s "$SECRET" > "$T/webhook"; chmod 600 "$T/webhook"
printf '#!/bin/bash\ncfg="$(cat)"\necho "$cfg" >> "%s/curl_cfg"\nif [ -f "%s/curl_fail" ]; then echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; fi\nexit 0\n' "$T" "$T" > "$T/curl"
printf '#!/bin/bash\necho "$*" >> "%s/aws_args"\nif [ -f "%s/aws_fail" ]; then echo "An error occurred (AccessDenied)" >&2; exit 254; fi\nexit 0\n' "$T" "$T" > "$T/aws"
chmod +x "$T/curl" "$T/aws"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }
run() {
  STATE_DIR="$T/state" DEADMAN_WEBHOOK_FILE="$T/webhook" DEADMAN_CURL="$T/curl" DEADMAN_AWS="$T/aws" \
  DEADMAN_HOST=garm /bin/bash "$HERE/deadman.sh" >"$T/stdout" 2>&1
}
last() { tail -1 "$T/state/deadman.log" | sed 's/^[0-9-]* [0-9:]* - //'; }
reset() { chmod 600 "$T/webhook" 2>/dev/null; printf %s "$SECRET" > "$T/webhook"; rm -f "$T/curl_fail" "$T/aws_fail" "$T/curl_cfg" "$T/aws_args" "$T/state/last_deadman_run"; : > "$T/state/deadman.log"; }

echo "case: both sides succeed"; reset
run; expect "exit 0" "$?" "0"
expect "terminal line" "$(last)" "completed successfully"
[ -f "$T/state/last_deadman_run" ] && ok "stamp written" || bad "stamp written"
grep -q "url = \"http://10.99.0.1:8123/api/webhook/$SECRET\"" "$T/curl_cfg" && ok "webhook URL built from the file id" || bad "webhook URL built from the file id"
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

echo "case: webhook file missing, B still called"; reset
rm -f "$T/webhook"; run; expect "exit 1" "$?" "1"
[ -s "$T/aws_args" ] && ok "B still attempted" || bad "B still attempted"
[ ! -s "$T/curl_cfg" ] && ok "no POST without an id" || bad "no POST without an id"
case "$(last)" in "FAILED: dead-man check-in side(s) failed: A") ok "terminal line FAILED naming A" ;; *) bad "terminal line ($(last))" ;; esac
grep -q 'A FAILED: webhook file .* is missing' "$T/state/deadman.log" && ok "log says missing" || bad "log says missing"

echo "case: webhook file unreadable"; reset
chmod 000 "$T/webhook"; run; expect "exit 1" "$?" "1"
[ -s "$T/aws_args" ] && ok "B still attempted" || bad "B still attempted"
[ ! -s "$T/curl_cfg" ] && ok "no POST without an id" || bad "no POST without an id"
grep -q 'A FAILED: webhook file .* is not readable' "$T/state/deadman.log" && ok "log says not readable" || bad "log says not readable"
chmod 600 "$T/webhook"

echo "case: webhook file empty (and whitespace only)"; reset
: > "$T/webhook"; run; expect "exit 1 on empty" "$?" "1"
grep -q 'A FAILED: webhook file .* is empty' "$T/state/deadman.log" && ok "log says empty" || bad "log says empty"
[ ! -s "$T/curl_cfg" ] && ok "no POST on empty" || bad "no POST on empty"
reset; printf '  \n' > "$T/webhook"; run; expect "exit 1 on whitespace only" "$?" "1"
[ ! -s "$T/curl_cfg" ] && ok "no POST on whitespace" || bad "no POST on whitespace"

echo "case: trailing newline in the file is tolerated"; reset
printf '%s\n' "$SECRET" > "$T/webhook"; run; expect "exit 0" "$?" "0"
grep -q "webhook/$SECRET\"" "$T/curl_cfg" && ok "id used without the newline" || bad "id used without the newline"

echo; echo "deadman_drill: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
