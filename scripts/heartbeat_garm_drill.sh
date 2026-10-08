#!/bin/bash
# heartbeat_garm_drill.sh - exercises heartbeat checks 32 to 34 and the per-host
# LD_EXPECTED switch by extracting those blocks from mbs_heartbeat.sh and running
# them against a temp HOME with a stubbed add_finding. Uses macOS date -j, so run
# it on the Mac. Touches nothing outside the temp dir.
#   bash scripts/heartbeat_garm_drill.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HB="$HERE/mbs_heartbeat.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/hb_drill.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; STATE_DIR="$HOME/.mbs_automation"
mkdir -p "$STATE_DIR" "$HOME/Library/LaunchAgents" "$HOME/dev"

S="$(grep -n '^# --- check 32:' "$HB" | cut -d: -f1)"
E="$(grep -n '^# --- verdict' "$HB" | cut -d: -f1)"
[ -n "$S" ] && [ -n "$E" ] || { echo "could not find the check 32 to verdict region"; exit 1; }
sed -n "${S},$((E - 1))p" "$HB" > "$T/region.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
findings() {
  STATE_DIR="$STATE_DIR" HOME="$HOME" /bin/bash -c '
    set -uo pipefail
    add_finding() { echo "FINDING: $1"; }
    source "$1"
  ' _ "$T/region.sh" 2>&1
}
expect_none() { local out; out="$(findings)"; if [ -z "$out" ]; then ok "$1"; else bad "$1 ($out)"; fi; }
expect_has()  { local out; out="$(findings)"; case "$out" in *"$2"*) ok "$1" ;; *) bad "$1 (got: $out)" ;; esac; }

now() { date +%s; }

echo "check 32: silent without the plist"
expect_none "no plist, no findings"

touch "$HOME/Library/LaunchAgents/com.mbs.deploy.plist"
echo "check 32a: run freshness"
expect_has "never ran" "has not completed a run"
echo $(( $(now) - 120 )) > "$STATE_DIR/last_deploy_run"
expect_none "ran 2 min ago"
echo $(( $(now) - 1900 )) > "$STATE_DIR/last_deploy_run"
expect_has "ran 31 min ago" "31 minutes ago"
echo "$(now)" > "$STATE_DIR/last_deploy_run"

echo "check 32b: drift"
ORIGIN="$T/o.git"; git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$HOME/dev/mbs_automation" 2>/dev/null
cd "$HOME/dev/mbs_automation" || exit 1
git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m base && git push -q origin HEAD:main
git clone -q "$ORIGIN" "$T/w" 2>/dev/null
( cd "$T/w" && GIT_COMMITTER_DATE="$(date -v-2H '+%Y-%m-%dT%H:%M:%S')" GIT_AUTHOR_DATE="$(date -v-2H '+%Y-%m-%dT%H:%M:%S')" git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m old && git push -q origin HEAD:main )
git fetch -q origin main
expect_has "2-hour-old commit not applied" "behind its origin branch for: mbs_automation (1 commit(s)"
git merge -q --ff-only origin/main
expect_none "caught up"
( cd "$T/w" && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m fresh && git push -q origin HEAD:main )
git fetch -q origin main
expect_none "fresh commit within 30 min is not drift"

echo "check 32b: a repo on master is compared with origin/master"
OM="$T/om.git"; git init -q --bare -b master "$OM"
git clone -q "$OM" "$HOME/dev/mbs-oura-sync" 2>/dev/null
( cd "$HOME/dev/mbs-oura-sync" && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m base && git push -q origin HEAD:master )
git clone -q "$OM" "$T/wm" 2>/dev/null
( cd "$T/wm" && GIT_COMMITTER_DATE="$(date -v-2H '+%Y-%m-%dT%H:%M:%S')" GIT_AUTHOR_DATE="$(date -v-2H '+%Y-%m-%dT%H:%M:%S')" git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m old && git push -q origin HEAD:master )
git -C "$HOME/dev/mbs-oura-sync" fetch -q origin master
expect_has "master repo behind is reported" "mbs-oura-sync (1 commit(s)"
git -C "$HOME/dev/mbs-oura-sync" merge -q --ff-only origin/master
expect_none "master repo caught up"
cd "$T" || exit 1

echo "check 33: dead-man freshness"
expect_none "no deadman plist"
touch "$HOME/Library/LaunchAgents/com.mbs.deadman.plist"
expect_has "never checked in" "dead-man sender has not completed"
echo $(( $(now) - 600 )) > "$STATE_DIR/last_deadman_run"
expect_none "checked in 10 min ago"
echo $(( $(now) - 2800 )) > "$STATE_DIR/last_deadman_run"
expect_has "46 minutes stale" "46 minutes ago"
echo "$(now)" > "$STATE_DIR/last_deadman_run"

echo "check 34: token age"
expect_none "no token file"
echo "$(date -v-100d +%Y-%m-%d)" > "$STATE_DIR/claude_token_created"
expect_none "100 days old"
echo "$(date -v-340d +%Y-%m-%d)" > "$STATE_DIR/claude_token_created"
expect_has "340 days: reminder (25 or 26 across a DST boundary)" "expires in about 2"
echo "$(date -v-370d +%Y-%m-%d)" > "$STATE_DIR/claude_token_created"
expect_has "370 days: expired" "passed its one-year life"
echo "not a date" > "$STATE_DIR/claude_token_created"
expect_has "malformed file" "not a YYYY-MM-DD date"

echo "per-host LD_EXPECTED"
LDS="$(grep -n '^case "\$(hostname -s)" in' "$HB" | cut -d: -f1)"
LDB="$(grep -n '^LD_EXPECTED_COMMON=' "$HB" | cut -d: -f1)"
sed -n "${LDB},$((LDS + 3))p" "$HB" > "$T/ld.sh"
# Asserts properties, not a fixed roster, so a cutover batch (which moves labels
# from COMMON to GARM in one commit) needs no drill edit.
LD_ALL="$(/bin/bash -c 'hostname() { echo garm; }; source "'"$T/ld.sh"'"; echo "$LD_EXPECTED_COMMON|$LD_EXPECTED_GARM"')"
LD_COMMON="${LD_ALL%%|*}"
LD_GARMALL="${LD_ALL#*|}"
OVERLAP=""
for L in $LD_GARMALL; do
  case " $LD_COMMON " in *" $L "*) OVERLAP="$OVERLAP $L" ;; esac
done
if [ -z "$OVERLAP" ]; then ok "no label is in both the garm list and the laptop list"; else bad "labels in both lists:$OVERLAP"; fi
for H in garm hoest somethingelse; do
  OUT="$(/bin/bash -c 'hostname() { echo "$H"; }; export H="'"$H"'"; source "'"$T/ld.sh"'"; echo "$LD_EXPECTED"')"
  case "$H" in
    garm)
      case "$OUT" in
        "com.mbs.deploy com.mbs.deadman"|"com.mbs.deploy com.mbs.deadman "*) ok "garm gets the garm list (starts with deploy and deadman)" ;;
        *) bad "garm list ($OUT)" ;;
      esac ;;
    *)
      if [ -z "$OUT" ]; then
        bad "$H gets an empty list"
      else
        case " $OUT " in
          *" com.mbs.deploy "*|*" com.mbs.deadman "*) bad "$H must not expect deploy or deadman" ;;
          *) if [ "$OUT" = "$LD_COMMON" ]; then ok "$H gets the laptop list"; else bad "$H list ($OUT)"; fi ;;
        esac
      fi ;;
  esac
done

echo; echo "heartbeat_garm_drill: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
