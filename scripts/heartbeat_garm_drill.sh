#!/bin/bash
# heartbeat_garm_drill.sh - exercises heartbeat checks 32 to 38b and the per-host
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
mkdir -p "$STATE_DIR" "$HOME/Library/LaunchAgents" "$HOME/dev" "$T/vault/admin/mbs_system/homelab"
# Checks 36 and 38b count a missing-relay grace from a fixed build date. Pin both
# to today so every case that expects silence stays silent on any later run.
# Before this (found 2026-10-15) check 36's grace ran out on 2026-10-11 and the
# drill failed twelve unrelated cases from then on.
export AWS_BACKUP_RELAY_GRACE_START="$(date +%Y-%m-%d)"
export SESSION_ARCHIVE_RELAY_GRACE_START="$(date +%Y-%m-%d)"

S="$(grep -n '^# --- check 32:' "$HB" | cut -d: -f1)"
E="$(grep -n '^# --- verdict' "$HB" | cut -d: -f1)"
[ -n "$S" ] && [ -n "$E" ] || { echo "could not find the check 32 to verdict region"; exit 1; }
sed -n "${S},$((E - 1))p" "$HB" > "$T/region.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
findings() {
  STATE_DIR="$STATE_DIR" HOME="$HOME" VAULT="$T/vault" LD_EXPECTED_COMMON="${LD_TEST:-com.mbs.aws-repo-backup com.mbs.weekly-blocks}" /bin/bash -c '
    set -uo pipefail
    hostname() { echo "${HB_HOST:-garm}"; }
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
echo $(( $(now) - 840 )) > "$STATE_DIR/last_deadman_run"
expect_none "checked in 14 min ago (under three missed intervals)"
echo $(( $(now) - 960 )) > "$STATE_DIR/last_deadman_run"
expect_has "16 minutes stale (over three missed intervals)" "16 minutes ago"
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

echo "check 35: dead-man key age"
rm -f "$STATE_DIR/claude_token_created"
expect_none "no key file"
echo "$(date -v-30d +%Y-%m-%d)" > "$STATE_DIR/deadman_key_created"
expect_none "30 days old"
echo "$(date -v-85d +%Y-%m-%d)" > "$STATE_DIR/deadman_key_created"
expect_has "85 days: reminder" "reaches the 90 day rotation limit"
echo "$(date -v-95d +%Y-%m-%d)" > "$STATE_DIR/deadman_key_created"
expect_has "95 days: overdue" "past the 90 day rotation limit"
echo "not a date" > "$STATE_DIR/deadman_key_created"
expect_has "malformed file" "deadman_key_created is not a YYYY-MM-DD date"
rm -f "$STATE_DIR/deadman_key_created"

echo "check 36: hoest aws-repo-backup relay"
RELAY="$T/vault/admin/mbs_system/homelab/state_hoest_aws_repo_backup.md"
write_relay() { printf -- '---\ntype: state\nhost: hoest\nlast_success_epoch: %s\n---\n\nbody\n' "$1" > "$RELAY"; }
rm -f "$RELAY"
export AWS_BACKUP_RELAY_GRACE_START="$(date +%Y-%m-%d)"
expect_none "relay file missing, inside the 3 day grace"
export AWS_BACKUP_RELAY_GRACE_START="2026-01-01"
expect_has "relay file missing, past the grace" "no relay file for hoest"
write_relay "$(( $(now) - 3600 ))"
expect_none "relay 1 hour old"
write_relay "$(( $(now) - 119 * 3600 ))"
expect_none "relay 119 hours old (under the 120 hour threshold)"
write_relay "$(( $(now) - 121 * 3600 ))"
expect_has "relay 121 hours old" "last succeeded 121 hours ago"
write_relay "$(( $(now) - 2 * 3600 ))"
export AWS_BACKUP_RELAY_MAX_HOURS=1
expect_has "threshold override to 1 hour, relay 2 hours old" "threshold 1 hours"
unset AWS_BACKUP_RELAY_MAX_HOURS
printf -- '---\ntype: state\n---\nno epoch here\n' > "$RELAY"
expect_has "relay file without a readable epoch" "no readable last_success_epoch"
write_relay "$(( $(now) - 500 * 3600 ))"
LD_TEST="com.mbs.weekly-blocks"
expect_none "not armed when aws-repo-backup is not in the laptop list, even with a stale relay"
unset LD_TEST
rm -f "$RELAY"; export AWS_BACKUP_RELAY_GRACE_START="$(date +%Y-%m-%d)"

echo "check 38: this machine's transcripts are archived"
LD_TEST="com.mbs.weekly-blocks"
SAS="$HOME/.claude/projects"; SAD="$HOME/storage_mbs_assets/admin/claude_code_sessions/garm"
mkdir -p "$SAS/proj A/sess1/subagents" "$SAS/proj A/memory" "$SAD"
printf 'hello\n' > "$SAS/proj A/s1.jsonl"; printf 'sub\n' > "$SAS/proj A/sess1/subagents/a.jsonl"; printf 'm\n' > "$SAS/proj A/memory/MEMORY.md"
touch -t 202601010000 "$SAS/proj A/s1.jsonl" "$SAS/proj A/sess1/subagents/a.jsonl" "$SAS/proj A/memory/MEMORY.md"
expect_none "hook not registered: silent"
mkdir -p "$HOME/.claude"; echo '{"hooks":{"SessionEnd":[{"hooks":[{"command":"/usr/bin/python3 /x/session_archive.py --hook"}]}]}}' > "$HOME/.claude/settings.json"
expect_has "registered, nothing archived" "2 file(s) under"
mkdir -p "$SAD/proj A/sess1/subagents"; printf 'hello\n' > "$SAD/proj A/s1.jsonl"
expect_has "one still missing" "(1 missing, 0 shorter"
printf 'sub\n' > "$SAD/proj A/sess1/subagents/a.jsonl"
expect_none "both archived (memory/ excluded)"
printf 'he' > "$SAD/proj A/s1.jsonl"
expect_has "archive copy shorter than the source" "(0 missing, 1 shorter"
printf 'hello\n' > "$SAD/proj A/s1.jsonl"
printf 'new\n' > "$SAS/proj A/s2.jsonl"
expect_none "a file modified within the settle window is not yet owed"
touch -t 202601010000 "$SAS/proj A/s2.jsonl"
expect_has "the same file once settled" "first: proj A/s2.jsonl"
printf 'new\n' > "$SAD/proj A/s2.jsonl"
printf 'shrunk_skipped: 2\n' > "$STATE_DIR/session_archive_state.txt"
expect_has "status shrunk_skipped 2" "2 transcript file(s) on garm are now SMALLER"
printf 'shrunk_skipped: 0\n' > "$STATE_DIR/session_archive_state.txt"
expect_none "status shrunk_skipped 0"

echo "check 38b: hoest relay"
rm -f "$HOME/.claude/settings.json"
SBR="$T/vault/admin/mbs_system/homelab/state_hoest_session_archive.md"
HOD="$HOME/storage_mbs_assets/admin/claude_code_sessions/hoest/p"; mkdir -p "$HOD"
for i in 1 2 3; do echo x > "$HOD/f$i.jsonl"; done
relay() { printf -- '---\ntype: state\nhost: hoest\nlast_run_epoch: %s\nlast_success_epoch: %s\nsource_files: 3\nsource_bytes: 6\narchived_files: %s\npending_files: %s\nshrunk_skipped: %s\nlast_result: %s\n---\n\nbody\n' "$1" "$2" "$3" "$4" "$5" "$6" > "$SBR"; }
expect_none "relay missing, inside the 3 day grace"
SESSION_ARCHIVE_RELAY_GRACE_START=2026-01-01 expect_has "relay missing, past the grace" "no relay file from hoest"
relay "$(now)" "$(now)" 3 0 0 "completed successfully"
expect_none "healthy relay, 3 archived and 3 present"
HB_HOST=hoest expect_none "on hoest itself the check does not run"
relay "$(now)" "$(( $(now) - 121 * 3600 ))" 3 0 0 "deferred (share not mounted: x)"
expect_has "last success 121 hours ago" "121 hours ago"
relay "$(now)" "$(( $(now) - 119 * 3600 ))" 3 0 0 "deferred (share not mounted: x)"
expect_none "last success 119 hours ago"
relay "$(now)" "" 0 3 0 "deferred (share not mounted: x)"
expect_has "never succeeded" "no successful run yet (last result: deferred"
relay "$(( $(now) - 25 * 3600 ))" "$(( $(now) - 25 * 3600 ))" 3 2 0 "partial"
expect_has "pending left by a run 25 hours ago" "left 2 file(s) pending"
relay "$(( $(now) - 3600 ))" "$(( $(now) - 3600 ))" 3 2 0 "partial"
expect_none "pending from a run 1 hour ago"
relay "$(now)" "$(now)" 3 0 1 "completed successfully"
expect_has "shrunk_skipped 1" "1 transcript file(s) on hoest are now SMALLER"
relay "$(now)" "$(now)" 5 0 0 "completed successfully"
expect_has "relay claims 5, garm holds 3" "reports 5 archived file(s) but only 3 exist"
rm -f "$SBR"; rm -rf "$HOME/.claude" "$HOME/storage_mbs_assets" "$STATE_DIR/session_archive_state.txt"; unset LD_TEST

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
