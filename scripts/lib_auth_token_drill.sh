#!/bin/bash
# lib_auth_token_drill.sh - drill for the setup-token export in lib_auth.sh.
#
# Sources lib_auth.sh under a scratch HOME in a clean subshell and checks what
# CLAUDE_CODE_OAUTH_TOKEN ends up as. Runs anywhere; touches nothing real.
# Must stay compatible with macOS /bin/bash 3.2.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/lib_auth.sh"
PASS=0
FAIL=0

check() {
  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "PASS: $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (expected '$2', got '$3')"
  fi
}

# Print the token as seen after sourcing, with a given HOME and a given
# pre-exported value ("-" means unset). Child processes see it only if exported.
seen() {
  local home="$1" pre="$2"
  (
    export HOME="$home"
    if [ "$pre" = "-" ]; then unset CLAUDE_CODE_OAUTH_TOKEN; else export CLAUDE_CODE_OAUTH_TOKEN="$pre"; fi
    # shellcheck disable=SC1090
    . "$LIB"
    /usr/bin/env | sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p'
  )
}

T="$(mktemp -d "${TMPDIR:-/tmp}/lib_auth_token_drill.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/with/.mbs_automation" "$T/without" "$T/empty/.mbs_automation"
printf '%s' 'drill-token-value' > "$T/with/.mbs_automation/claude_oauth_token"
chmod 600 "$T/with/.mbs_automation/claude_oauth_token"
: > "$T/empty/.mbs_automation/claude_oauth_token"

check "file present: exported to child processes" "drill-token-value" "$(seen "$T/with" "-")"
check "no file (hoest): nothing exported" "" "$(seen "$T/without" "-")"
check "empty file: nothing exported" "" "$(seen "$T/empty" "-")"
check "already-exported token wins over the file" "preset" "$(seen "$T/with" "preset")"
V="$(seen "$T/with" "-")"
check "value is exactly the file contents (17 characters)" "17" "${#V}"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
