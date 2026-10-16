#!/bin/bash
# obsidian_keepalive_drill.sh - drill for scripts/obsidian_keepalive.sh
# (com.mbs.obsidian-keepalive, 2026-10-16) with shimmed pgrep, open and
# hostname. Touches nothing outside a temp dir and never launches Obsidian.
#
# Cases: running (silent); dead then relaunched; dead and relaunch fails (open
# succeeds but no process); dead and open itself fails; the recovery line after
# a FAILED (and only once); paused (logged once, nothing launched); resumed;
# not garm (no log, no launch).
#
#   /bin/bash scripts/obsidian_keepalive_drill.sh
#   KA=/path/to/other/obsidian_keepalive.sh /bin/bash scripts/obsidian_keepalive_drill.sh
# Must stay compatible with macOS /bin/bash 3.2.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KA="${KA:-$HERE/obsidian_keepalive.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/keepalive_drill.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# Shims. $T/obsidian_up is "the process exists"; open records each call and,
# unless OPEN_MODE says otherwise, brings the process up.
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/bash
[ -f "$KT/obsidian_up" ] && { echo 4242; exit 0; }
exit 1
EOF
cat > "$T/bin/open" <<'EOF'
#!/bin/bash
echo "$*" >> "$KT/open_calls"
case "${OPEN_MODE:-up}" in
  up) : > "$KT/obsidian_up" ;;
  noproc) : ;;
  error) echo "open: unable to find application" >&2; exit 1 ;;
esac
EOF
cat > "$T/bin/hostname" <<'EOF'
#!/bin/bash
echo "${SHIM_HOST:-garm}"
EOF
cat > "$T/bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/"*

run() {
  KT="$T" KEEPALIVE_PATH_PREFIX="$T/bin" STATE_DIR="$T/state" KEEPALIVE_WAIT_SECONDS=10 /bin/bash "$KA" > "$T/stdout" 2>&1
  echo $? > "$T/rc"
}
LOG="$T/state/obsidian_keepalive.log"
lines() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }
opens() { [ -f "$T/open_calls" ] && wc -l < "$T/open_calls" | tr -d ' ' || echo 0; }
last() { tail -1 "$LOG" 2>/dev/null; }

echo "case 1: Obsidian running, healthy log"
: > "$T/obsidian_up"
run
[ "$(lines)" = 0 ] && ok "silent while running" || bad "wrote to the log while running: $(last)"
[ "$(opens)" = 0 ] && ok "did not call open" || bad "called open while running"

echo "case 2: dead, then relaunched"
rm -f "$T/obsidian_up"
run
case "$(last)" in *"relaunched Obsidian (pid 4242"*"completed successfully") ok "logged the relaunch with completed successfully" ;; *) bad "last line: $(last)" ;; esac
[ "$(opens)" = 1 ] && ok "called open once" || bad "open calls: $(opens)"
grep -q -- '-ga Obsidian' "$T/open_calls" && ok "used open -ga Obsidian (background)" || bad "open args: $(cat "$T/open_calls")"
[ "$(cat "$T/rc")" = 0 ] && ok "exit 0" || bad "exit $(cat "$T/rc")"

echo "case 3: running again after a success: silent"
n="$(lines)"; run
[ "$(lines)" = "$n" ] && ok "no line after a success" || bad "wrote: $(last)"

echo "case 4: dead, open succeeds but no process appears"
rm -f "$T/obsidian_up"
OPEN_MODE=noproc run
case "$(last)" in *"FAILED: launched Obsidian but no Obsidian process after 10s") ok "logged FAILED" ;; *) bad "last line: $(last)" ;; esac
[ "$(cat "$T/rc")" = 1 ] && ok "exit 1" || bad "exit $(cat "$T/rc")"

echo "case 5: dead, open itself fails"
OPEN_MODE=error run
case "$(last)" in *"FAILED: open -ga Obsidian returned non-zero"*) ok "logged FAILED for the open error" ;; *) bad "last line: $(last)" ;; esac
grep -q "unable to find application" "$LOG" && ok "open's own error kept in the log" || bad "open's stderr lost"
[ -s "$T/stdout" ] && bad "wrote to stdout/stderr (would land in the err log): $(cat "$T/stdout")" || ok "nothing on stdout or stderr"

echo "case 6: recovery line after a FAILED, once"
: > "$T/obsidian_up"
run
case "$(last)" in *"Obsidian is running again (pid 4242); completed successfully") ok "recovery line written" ;; *) bad "last line: $(last)" ;; esac
n="$(lines)"; run
[ "$(lines)" = "$n" ] && ok "recovery line written only once" || bad "second recovery line: $(last)"

echo "case 7: paused"
rm -f "$T/obsidian_up"; : > "$T/state/obsidian_keepalive.pause"; o="$(opens)"
run; run
[ "$(grep -c '^.* - paused: ' "$LOG")" = 1 ] && ok "pause logged exactly once over two runs" || bad "pause lines: $(grep -c 'paused:' "$LOG")"
[ "$(opens)" = "$o" ] && ok "nothing launched while paused" || bad "launched while paused"

echo "case 8: resumed"
rm -f "$T/state/obsidian_keepalive.pause"
run
grep -q ' - resumed: pause file removed' "$LOG" && ok "resume logged" || bad "no resume line"
case "$(last)" in *"relaunched Obsidian"*"completed successfully") ok "then relaunched the dead Obsidian" ;; *) bad "last line: $(last)" ;; esac

echo "case 9: not garm"
rm -f "$T/obsidian_up"; rm -rf "$T/state"; mkdir -p "$T/state"; o="$(opens)"
SHIM_HOST=hoest run
[ ! -f "$LOG" ] && ok "no log on hoest" || bad "logged on hoest: $(last)"
[ "$(opens)" = "$o" ] && ok "no launch on hoest" || bad "launched on hoest"
[ "$(cat "$T/rc")" = 0 ] && ok "exit 0 on hoest" || bad "exit $(cat "$T/rc") on hoest"

echo
echo "obsidian_keepalive_drill: $PASS passed, $FAIL failed (bash $BASH_VERSION)"
[ "$FAIL" -eq 0 ]
