#!/bin/bash
# mount_garm_assets_drill.sh - exercises mount_garm_assets.sh with shimmed commands.
# Touches nothing real: temp HOME, fake mount/nc/osascript/ls. Must run on bash 3.2.
#   bash scripts/mount_garm_assets_drill.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/mount_garm_assets.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/mount_drill.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.mbs_automation" "$T/bin"
LOG="$HOME/.mbs_automation/mount_garm_assets.log"
STAMP="$HOME/.mbs_automation/.mount_garm_assets_last_failed"
MARK="$T/mounted"; CALLS="$T/osascript_calls"; : > "$CALLS"

cat > "$T/bin/mount" <<EOS
#!/bin/bash
echo "/dev/disk3s1 on / (apfs)"
[ -f "$MARK" ] && echo "//u@192.168.1.205/storage_mbs_assets on /Volumes/storage_mbs_assets (smbfs)"
exit 0
EOS
cat > "$T/bin/nc" <<EOS
#!/bin/bash
[ "\${NC_RC:-0}" = "0" ]
EOS
cat > "$T/bin/osascript" <<EOS
#!/bin/bash
echo call >> "$CALLS"
[ "\${OSA_MOUNTS:-1}" = "1" ] && : > "$MARK"
[ "\${OSA_MOUNTS:-1}" = "1" ] || echo "execution error: authentication failed (-60008)"
exit 0
EOS
cat > "$T/bin/ls" <<EOS
#!/bin/bash
[ "\${LS_HANG:-0}" = "1" ] && sleep 30
exit 0
EOS
chmod +x "$T/bin/"*

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
run() { MOUNT_BIN="$T/bin/mount" NC_BIN="$T/bin/nc" OSA_BIN="$T/bin/osascript" LS_BIN="$T/bin/ls" GARM_ASSETS_LS_TIMEOUT=1 /bin/bash "$SCRIPT"; echo $?; }
calls() { wc -l < "$CALLS" | tr -d ' '; }
loglines() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }
reset() { rm -f "$MARK" "$STAMP" "$LOG"; : > "$CALLS"; unset NC_RC OSA_MOUNTS LS_HANG; }

echo "mounted and responsive"
reset; : > "$MARK"
[ "$(run)" = "0" ] && ok "exit 0" || bad "exit code"
[ "$(calls)" = "0" ] && ok "no mount attempt" || bad "attempted a mount"
[ "$(loglines)" = "0" ] && ok "silent (no log)" || bad "wrote a log line"

echo "mounted but the share hangs"
reset; : > "$MARK"; export LS_HANG=1
run >/dev/null 2>"$T/err"
[ ! -s "$T/err" ] && ok "nothing written to stderr (no Alarm clock message)" || bad "stderr: $(head -c 100 "$T/err")"
[ "$(calls)" = "0" ] && ok "does not touch a stale mount" || bad "tried to remount a stale mount"
grep -q "FAILED: /Volumes/storage_mbs_assets is mounted but did not answer" "$LOG" && ok "reports it as FAILED" || bad "no FAILED line"
run >/dev/null
[ "$(loglines)" = "1" ] && ok "reported once inside the retry window" || bad "reported again"

echo "not mounted, garm unreachable"
reset; export NC_RC=1
[ "$(run)" = "0" ] && ok "exit 0" || bad "exit code"
[ "$(calls)" = "0" ] && ok "no mount attempt" || bad "attempted a mount"
[ "$(loglines)" = "0" ] && ok "silent (away from home is normal)" || bad "wrote a log line"

echo "not mounted, garm reachable"
reset
run >/dev/null
[ "$(calls)" = "1" ] && ok "one mount attempt" || bad "attempts: $(calls)"
grep -q "mounted smb://192.168.1.205/storage_mbs_assets" "$LOG" && ok "logged the mount" || bad "no mount line"
tail -1 "$LOG" | grep -q "completed successfully" && ok "last line is the terminal success line" || bad "no success terminal line"
[ ! -f "$STAMP" ] && ok "no failure stamp" || bad "failure stamp left behind"
run >/dev/null
[ "$(calls)" = "1" ] && ok "second run finds it mounted, no second attempt" || bad "re-attempted while mounted"

echo "not mounted, garm reachable, the mount fails"
reset; export OSA_MOUNTS=0
run >/dev/null
[ "$(calls)" = "1" ] && ok "one attempt" || bad "attempts: $(calls)"
grep -q "FAILED: could not mount" "$LOG" && ok "logged FAILED with the reason" || bad "no FAILED line"
grep -q "authentication failed" "$LOG" && ok "keeps the first words of the error" || bad "error text lost"
run >/dev/null
[ "$(calls)" = "1" ] && ok "no second attempt inside the 10 minute pause" || bad "retried too soon"
echo $(( $(date +%s) - 700 )) > "$STAMP"
run >/dev/null
[ "$(calls)" = "2" ] && ok "tries again once the pause has passed" || bad "attempts after pause: $(calls)"

echo; echo "mount_garm_assets_drill: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
