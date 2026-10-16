#!/bin/bash
# lib_checks.sh - the assertion vocabulary for deferred checks (checks/pending/).
#
# Sourced by deferred_checks.sh into a fresh /bin/bash for each check, never by
# a launchd job directly. Every helper READS: none writes, moves or deletes
# anything, and a check must not either (checks/README.md). A failed assertion
# appends one line to $CHECK_FAILS and returns 1; the check keeps going so one
# run reports every failure, not just the first.
#
# Set by the runner before a check is sourced:
#   STATE_DIR   ~/.mbs_automation (relative log and stamp names resolve here)
#   VAULT       the vault root (vault-relative paths resolve here)
#   ASSETS      ~/storage_mbs_assets
#   DUE_DAY     YYYY-MM-DD of the check's due time: the default day for every
#               "on the day" helper, so a check evaluated late still asks about
#               the day it was written for
#   CHECK_FAILS file collecting failure lines
#   LAUNCHCTL   launchctl (overridable for drills)
#
# Never write "FAILED" in a failure line: heartbeat check 26 reads the runner's
# log for that word as a job verdict.

_ck_fail() { printf '%s\n' "$*" >> "$CHECK_FAILS"; return 1; }
_ck_state_path() { case "$1" in /*) echo "$1" ;; *) echo "$STATE_DIR/$1" ;; esac; }
_ck_vault_path() { case "$1" in /*) echo "$1" ;; *) echo "$VAULT/$1" ;; esac; }

# Parse an optional leading --day YYYY-MM-DD; sets _CK_DAY and _CK_SHIFT.
_ck_day() {
  _CK_DAY="$DUE_DAY"; _CK_SHIFT=0
  if [ "${1:-}" = "--day" ]; then _CK_DAY="$2"; _CK_SHIFT=2; fi
}

# expect_log_line [--day D] <log> <ERE>: some line dated D (the line starts with
# D, as every estate log line does) matches ERE.
expect_log_line() {
  _ck_day "$@"; shift "$_CK_SHIFT"
  local f; f="$(_ck_state_path "$1")"
  [ -f "$f" ] || { _ck_fail "$1: file missing ($f)"; return 1; }
  if ! grep "^$_CK_DAY" "$f" 2>/dev/null | grep -Eq -- "$2"; then
    _ck_fail "$1: no line dated $_CK_DAY matches /$2/"
  fi
}

# expect_no_log_line [--day D] <log> <ERE>: no line dated D matches ERE.
expect_no_log_line() {
  _ck_day "$@"; shift "$_CK_SHIFT"
  local f hit; f="$(_ck_state_path "$1")"
  [ -f "$f" ] || return 0
  hit="$(grep "^$_CK_DAY" "$f" 2>/dev/null | grep -E -- "$2" | head -1)"
  [ -z "$hit" ] || _ck_fail "$1: a line dated $_CK_DAY matches /$2/: ${hit:0:200}"
}

# expect_log_max [--day D] <log> <ERE with the number as the first integer after
# the match start> <max>: every line dated D matching ERE carries a number <= max.
# Example: expect_log_max mychart_sync.log 'fetched [0-9]+ clinical' 5
expect_log_max() {
  _ck_day "$@"; shift "$_CK_SHIFT"
  local f n bad=""; f="$(_ck_state_path "$1")"
  [ -f "$f" ] || return 0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ "$n" -le "$3" ] || bad="$bad $n"
  done <<EOF
$(grep "^$_CK_DAY" "$f" 2>/dev/null | grep -Eo -- "$2" | grep -Eo '[0-9]+' | head -50)
EOF
  [ -z "$bad" ] || _ck_fail "$1: /$2/ on $_CK_DAY carried${bad}, above the maximum $3"
}

# expect_stamp [--day D] <stamp file>: the file's first line is D.
expect_stamp() {
  _ck_day "$@"; shift "$_CK_SHIFT"
  local f v; f="$(_ck_state_path "$1")"
  v="$(head -1 "$f" 2>/dev/null)"
  [ "$v" = "$_CK_DAY" ] || _ck_fail "$1: holds '${v:-nothing}', expected $_CK_DAY"
}

# expect_empty <file>: missing or zero bytes (an .err.log that stayed quiet).
expect_empty() {
  local f; f="$(_ck_state_path "$1")"
  [ ! -s "$f" ] || _ck_fail "$1: not empty ($(wc -c < "$f" | tr -d ' ') bytes)"
}

# expect_file <path>: exists (absolute, or relative to STATE_DIR).
expect_file() {
  local f; f="$(_ck_state_path "$1")"
  [ -e "$f" ] || _ck_fail "$1: does not exist"
}

# expect_file_count <dir> <eq|ge|le> <n>: count of regular files directly in dir.
expect_file_count() {
  local d="$1" op="$2" want="$3" n
  [ -d "$d" ] || { _ck_fail "$d: directory missing"; return 1; }
  n="$(find "$d" -maxdepth 1 -type f | wc -l | tr -d ' ')"
  case "$op" in
    eq) [ "$n" -eq "$want" ] ;;
    ge) [ "$n" -ge "$want" ] ;;
    le) [ "$n" -le "$want" ] ;;
    *) _ck_fail "expect_file_count: unknown operator '$op'"; return 1 ;;
  esac || _ck_fail "$d: $n file(s), expected $op $want"
}

# expect_md5 <path> <md5>: the file exists with exactly this md5.
expect_md5() {
  local got; got="$(md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | cut -d' ' -f1)"
  [ "$got" = "$2" ] || _ck_fail "$1: md5 ${got:-missing}, expected $2"
}

# expect_frontmatter <vault-relative note> <field> [ERE]: the note's frontmatter
# has the field with a non-empty value (matching ERE when given).
expect_frontmatter() {
  local f v; f="$(_ck_vault_path "$1")"
  [ -f "$f" ] || { _ck_fail "$1: note missing"; return 1; }
  v="$(awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit} NR>1 {print}' "$f" \
        | sed -n "s/^$2:[[:space:]]*//p" | head -1)"
  if [ -z "$v" ]; then _ck_fail "$1: frontmatter field $2 missing or empty"; return 1; fi
  if [ -n "${3:-}" ] && ! printf '%s' "$v" | grep -Eq -- "$3"; then
    _ck_fail "$1: $2 is '$v', expected /$3/"
  fi
}

# expect_vault_contains <vault-relative note> <fixed string>
expect_vault_contains() {
  local f; f="$(_ck_vault_path "$1")"
  grep -qF -- "$2" "$f" 2>/dev/null || _ck_fail "$1: does not contain '$2'"
}

# expect_loaded <launchd label>: the job is loaded in the gui domain.
expect_loaded() {
  ${LAUNCHCTL:-launchctl} print "gui/$(id -u)/$1" >/dev/null 2>&1 || _ck_fail "$1: not loaded in launchd"
}

# expect_cmd <description> <command...>: the escape hatch. The command must exit
# 0. It must only read; the runner cannot enforce that, the author must.
expect_cmd() {
  local what="$1"; shift
  "$@" >/dev/null 2>&1 || _ck_fail "$what (exit $?)"
}
