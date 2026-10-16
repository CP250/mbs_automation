#!/bin/bash
# heartbeat_garm_drill.sh - exercises heartbeat checks 32 to 38b, check 29 (moved
# beside them 2026-10-15), checks 39 and 39b (garm's Obsidian, 2026-10-16), check
# 14c with oura-sync's wrapper end to end into check 26 (2026-10-16) and the per-host
# LD_EXPECTED switch by extracting those blocks from mbs_heartbeat.sh and running
# them against a temp HOME with a stubbed add_finding. Uses macOS date -j, so run
# it on the Mac. Touches nothing outside the temp dir.
#   bash scripts/heartbeat_garm_drill.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Captured before HOME moves to the temp dir: the oura-sync wrapper drill runs
# the real scripts/oura_sync.sh and the real oura_sync.py from this checkout.
OURA_REPO="${OURA_REPO:-$(cd "$HERE/../../mbs-oura-sync" 2>/dev/null && pwd)}"
HB="${HB:-$HERE/mbs_heartbeat.sh}"
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
export SECRET_STORE_RELAY_GRACE_START="$(date +%Y-%m-%d)"
# Check 39 (garm's Obsidian) runs in every case below, because the drill's host is
# garm: give it a healthy world by default (Obsidian running via the pgrep shim,
# today's health note, a fresh multi_git.log) so it is silent unless a case
# breaks one part on purpose. Its log line goes to $T/hb.log.
mkdir -p "$T/vault/daily_notes/health/daily"
HEALTH_NOTE="$T/vault/daily_notes/health/daily/daily_note_health_$(date +%Y-%m-%d).md"
: > "$HEALTH_NOTE"
: > "$STATE_DIR/multi_git.log"
# Check 40 (the midnight rollover) likewise: rolled today by the job, ticking.
printf '%s\n00:12 by tasks-rollover\n' "$(date +%Y-%m-%d)" > "$STATE_DIR/last_tasks_rollover"
: > "$STATE_DIR/tasks_rollover_tick"

S="$(grep -n '^# --- check 32:' "$HB" | cut -d: -f1)"
E="$(grep -n '^# --- verdict' "$HB" | cut -d: -f1)"
[ -n "$S" ] && [ -n "$E" ] || { echo "could not find the check 32 to verdict region"; exit 1; }
sed -n "${S},$((E - 1))p" "$HB" > "$T/region.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
findings() {
  STATE_DIR="$STATE_DIR" HOME="$HOME" VAULT="$T/vault" LOG="$T/hb.log" LD_EXPECTED_COMMON="${LD_TEST:-com.mbs.aws-repo-backup com.mbs.mount-garm-assets}" /bin/bash -c '
    set -uo pipefail
    hostname() { echo "${HB_HOST:-garm}"; }
    pgrep() { [ "${PG_RUN:-1}" = 1 ] || return 1; echo 4242; }
    ts() { date "+%Y-%m-%d %H:%M:%S"; }
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
LD_TEST="com.mbs.mount-garm-assets"
expect_none "not armed when aws-repo-backup is not in the laptop list, even with a stale relay"
unset LD_TEST
rm -f "$RELAY"; export AWS_BACKUP_RELAY_GRACE_START="$(date +%Y-%m-%d)"

echo "check 38: this machine's transcripts are archived"
LD_TEST="com.mbs.mount-garm-assets"
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

echo "check 29: hoest Obsidian secret-store relay"
SSR="$T/vault/admin/mbs_system/homelab/state_hoest_obsidian_secret_store.md"
ssrelay() { printf -- '---\ntype: state\nhost: hoest\nlast_probe_epoch: %s\nlast_probe: 2026-10-15 16:30:49\nsecret_count: %s\nencryption_available: %s\nbrat_token_name: %s\nbrat_token_resolves: %s\nprobe: mbs-companion 0.3.5\n---\n\nbody\n' "$1" "$2" "$3" "$4" "$5" > "$SSR"; }
rm -f "$SSR"
expect_none "relay missing, inside the 3 day grace"
SECRET_STORE_RELAY_GRACE_START=2026-01-01 expect_has "relay missing, past the grace" "no relay file from hoest at"
ssrelay "$(now)" 3 true '"brat-pat"' true
expect_none "healthy relay"
ssrelay "$(now)" 0 true '"brat-pat"' false
HB_HOST=hoest expect_none "on hoest itself the check does not run, even on a bad reading"
ssrelay "$(now)" 0 true '"brat-pat"' false
expect_has "zero secrets" "ZERO secrets in hoest's Obsidian secret store"
ssrelay "$(now)" 2 true '"brat-pat"' false
expect_has "BRAT name no longer resolves" "BRAT on hoest points at secret 'brat-pat' but it no longer resolves"
ssrelay "$(now)" 2 true none none
expect_none "no BRAT token configured is not a finding"
ssrelay "$(now)" 2 false '"brat-pat"' true
expect_has "encryption unavailable" "encryption UNAVAILABLE"
ssrelay "$(now)" 2 unknown '"brat-pat"' true
expect_none "encryption unknown (older Obsidian) is not a finding"
ssrelay "$(( $(now) - 169 * 3600 ))" 3 true '"brat-pat"' true
expect_has "reading 169 hours old" "last reported 169 hours ago"
ssrelay "$(( $(now) - 167 * 3600 ))" 3 true '"brat-pat"' true
expect_none "reading 167 hours old (under the 168 hour threshold)"
ssrelay "$(( $(now) - 2 * 3600 ))" 3 true '"brat-pat"' true
SECRET_STORE_RELAY_MAX_HOURS=1 expect_has "threshold override to 1 hour, reading 2 hours old" "threshold 1 hours"
printf -- '---\ntype: state\nsecretCount: 3\n---\n' > "$SSR"
expect_has "relay with drifted field names" "no readable last_probe_epoch/secret_count"
ssrelay "$(now)" "" true none none
expect_has "relay with an empty secret_count" "no readable last_probe_epoch/secret_count"
rm -f "$SSR"

echo "check 39: garm's Obsidian"
: > "$T/hb.log"
expect_none "healthy: Obsidian running, health note present, multi_git fresh, no pause"
if grep -q 'check 39: Obsidian running=yes; health note .*=present; multi_git.log last written 0 min ago; keepalive pause=none' "$T/hb.log"; then ok "healthy run still logs what it saw"; else bad "check 39 log line ($(tail -1 "$T/hb.log"))"; fi
PG_RUN=0 expect_has "Obsidian not running: part a" "Obsidian is NOT running on garm (check 39, part a)"
PG_RUN=0 expect_has "part a names checks 36 and 38b" "checks 36 and 38b may fire too"
PG_RUN=0 expect_has "part a gives the ssh fix from hoest" "cd ~ && ssh garm 'tail -5 ~/.mbs_automation/obsidian_keepalive.log; open -ga Obsidian"
PG_RUN=0 HB_HOST=hoest expect_none "not garm: check 39 does not run even with Obsidian dead (negative control on the host gate)"
rm -f "$HEALTH_NOTE"
if [ "$(date +%H)" -ge 1 ]; then
  expect_has "health note missing: part b" "today's health note does not exist on garm (check 39, part b)"
else
  expect_none "health note missing before 01:00 is not yet due"
fi
: > "$HEALTH_NOTE"
touch -t "$(date -v-3H +%Y%m%d%H%M)" "$STATE_DIR/multi_git.log"
expect_has "multi_git.log 3 hours old: part c" "(check 39, part c; last: 18"
touch -t "$(date -v-1H +%Y%m%d%H%M)" "$STATE_DIR/multi_git.log"
expect_none "multi_git.log 1 hour old"
rm -f "$STATE_DIR/multi_git.log"
expect_has "multi_git.log missing: part c, never" "(check 39, part c; last: never"
: > "$STATE_DIR/multi_git.log"
echo "2026-10-16T13:12:24.944Z [notes] committed: vault backup" > "$STATE_DIR/multi_git.log"
expect_none "last commit succeeded: part e silent"
echo "2026-10-16T14:28:39.602Z [notes] commit GUARD blocked: admin/x/state_secret_store.md" >> "$STATE_DIR/multi_git.log"
expect_has "guard blocked: part e names the file" "(check 39, part e): its credential guard"
expect_has "guard blocked: part e gives the git add block" "git add -- admin/x/state_secret_store.md"
echo "2026-10-16T15:28:39.602Z [notes] commit: no changes" >> "$STATE_DIR/multi_git.log"
expect_none "a later clean run clears part e"
echo "2026-10-16T16:28:39.602Z [notes] commit ERROR: fatal: something" >> "$STATE_DIR/multi_git.log"
expect_has "commit error: part e" "failed its last vault commit (check 39, part e): fatal: something"
: > "$STATE_DIR/multi_git.log"
touch -t "$(date -v-25H +%Y%m%d%H%M)" "$STATE_DIR/obsidian_keepalive.pause"
expect_has "pause 25 hours old: part d" "paused for 25 hours (check 39, part d)"
touch -t "$(date -v-1H +%Y%m%d%H%M)" "$STATE_DIR/obsidian_keepalive.pause"
expect_none "pause 1 hour old is not a finding"
rm -f "$STATE_DIR/obsidian_keepalive.pause"

echo "check 39b: the keepalive relaunched Obsidian in the last 24 hours"
KL="$STATE_DIR/obsidian_keepalive.log"
expect_none "no keepalive log"
printf '%s - relaunched Obsidian (pid 1, up after 5s); completed successfully\n' "$(date -v-2H '+%Y-%m-%d %H:%M:%S')" > "$KL"
expect_has "relaunch 2 hours ago" "relaunched it at $(date -v-2H '+%Y-%m-%d %H:%M') (check 39b; 1 relaunch(es)"
printf '%s - relaunched Obsidian (pid 1, up after 5s); completed successfully\n' "$(date -v-30H '+%Y-%m-%d %H:%M:%S')" > "$KL"
expect_none "relaunch 30 hours ago"
printf '%s - paused: x\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$KL"
expect_none "log without a relaunch"
rm -f "$KL"

echo "check 40: the midnight rollover"
: > "$T/hb.log"; : > "$STATE_DIR/tasks_rollover_tick"
expect_none "rolled today by the job, ticking"
if grep -q "check 40: today's tasks note rolled at 00:12 by tasks-rollover; rollover tick 0 min ago" "$T/hb.log"; then ok "logs who rolled it and when"; else bad "check 40 log line ($(grep 'check 40' "$T/hb.log" | tail -1))"; fi
printf '%s\n06:00 by mbs_daily (06:00 fallback: the rollover job is not running here)\n' "$(date +%Y-%m-%d)" > "$STATE_DIR/last_tasks_rollover"
: > "$T/hb.log"
expect_none "rolled today by the 06:00 fallback: not a finding"
grep -q "rolled at 06:00 by mbs_daily (06:00 fallback: the rollover job is not running here)" "$T/hb.log" && ok "logs the fallback and why" || bad "fallback log line ($(grep 'check 40' "$T/hb.log" | tail -1))"
printf '%s\n00:09 by tasks-rollover\n' "$(date -v-1d +%Y-%m-%d)" > "$STATE_DIR/last_tasks_rollover"
expect_has "last rollover yesterday" "today's tasks note has not been rolled over (check 40; last rollover $(date -v-1d +%Y-%m-%d), 00:09 by tasks-rollover)"
rm -f "$STATE_DIR/last_tasks_rollover"
expect_has "never rolled" "(check 40; last rollover never)"
printf '%s\n00:12 by tasks-rollover\n' "$(date +%Y-%m-%d)" > "$STATE_DIR/last_tasks_rollover"
touch -t "$(date -v-20M +%Y%m%d%H%M)" "$STATE_DIR/tasks_rollover_tick"
expect_has "tick 20 minutes old" "has not ticked in 15 minutes (check 40; last tick 20 min ago"
touch -t "$(date -v-14M +%Y%m%d%H%M)" "$STATE_DIR/tasks_rollover_tick"
expect_none "tick 14 minutes old"
rm -f "$STATE_DIR/tasks_rollover_tick"
expect_has "no tick file" "(check 40; last tick never"
HB_HOST=hoest expect_none "not garm: check 40 does not run (negative control on the host gate)"
: > "$STATE_DIR/tasks_rollover_tick"

echo "check 27: duplicate-block ledger, renames carry their count"
C27S="$(grep -n '^# --- check 27:' "$HB" | cut -d: -f1)"
C27E="$(awk -v s="$C27S" 'NR > s && /^# --- (check|verdict)/ { print NR; exit }' "$HB")"
sed -n "${C27S},$((C27E - 1))p" "$HB" > "$T/c27.sh"
DV="$T/dupvault"; DS="$T/dupstate"; mkdir -p "$DV/a" "$DV/b" "$DS"
c27() { STATE_DIR="$DS" VAULT="$DV" LOG="$DS/log" /bin/bash -c 'set -uo pipefail; ts() { date; }; add_finding() { echo "FINDING: $1"; }; source "$1"' _ "$T/c27.sh" 2>&1; }
c27_none() { local out; out="$(c27)"; if [ -z "$out" ]; then ok "$1"; else bad "$1 ($out)"; fi; }
c27_has()  { local out; out="$(c27)"; case "$out" in *"$2"*) ok "$1" ;; *) bad "$1 (got: $out)" ;; esac; }
dupfile() { local f="$1" n="$2" i; : > "$f"; for i in $(seq 0 "$n"); do printf '## Same\ntext %s\n' "$i" >> "$f"; done; printf '## Unique\n' >> "$f"; }
dupfile "$DV/a/legit.md" 3; dupfile "$DV/a/other.md" 1; printf '## One\n' > "$DV/a/clean.md"
c27_none "first run writes the ledger and reports nothing"
c27_none "unchanged vault"
mv "$DV/a/legit.md" "$DV/b/legit.md"
c27_none "file moved to another folder keeps its count (3 to 3 is not a rise)"
if grep -q "/b/legit.md	3" "$DS/dupblock_baseline.txt" && ! grep -q "/a/legit.md" "$DS/dupblock_baseline.txt"; then ok "ledger now holds the new path and not the old one"; else bad "ledger after the move: $(cat "$DS/dupblock_baseline.txt")"; fi
c27_none "the moved file stays silent on the next run"
mv "$DV/b/legit.md" "$DV/legit.md"; dupfile "$DV/legit.md" 4
c27_has "moved AND gained a block fires against the carried count" "legit.md (3 to 4)"
dupfile "$DV/legit.md" 3
c27_none "back to its carried count"
dupfile "$DV/a/other.md" 2
c27_has "an unmoved file that gains a block still fires" "a/other.md (1 to 2)"
dupfile "$DV/a/other.md" 1
mkdir -p "$DV/c" "$DV/d" "$DV/e"; dupfile "$DV/c/notes.md" 1; dupfile "$DV/d/notes.md" 1
c27_has "two new files with duplicates fire from 0" "(0 to 1)"
printf '%s\t1\n%s\t1\n' "$DV/c/notes.md" "$DV/d/notes.md" >> "$DS/dupblock_baseline.txt"
sort -o "$DS/dupblock_baseline.txt" "$DS/dupblock_baseline.txt"
c27_none "both accepted by hand"
mv "$DV/c/notes.md" "$DV/e/notes.md"; rm "$DV/d/notes.md"
c27_has "two gone files share the basename: no carry, fires from 0" "e/notes.md (0 to 1)"
rm "$DV/e/notes.md"
dupfile "$DV/legit.md" 2
c27_none "a file that drops below its count is quiet"
if grep -q "/legit.md	2" "$DS/dupblock_baseline.txt"; then ok "and its ledger count falls"; else bad "ledger did not fall: $(grep legit.md "$DS/dupblock_baseline.txt")"; fi

echo "check 14c: oura-sync stamp"
C14S="$(grep -n '^# --- check 14c:' "$HB" | cut -d: -f1)"
C14E="$(grep -n '^# --- check 15:' "$HB" | cut -d: -f1)"
C26S="$(grep -n '^# --- check 26:' "$HB" | cut -d: -f1)"
C26E="$(awk -v s="$C26S" 'NR>s && /^# --- check /{print NR; exit}' "$HB")"
sed -n "${C14S},$((C14E - 1))p" "$HB" > "$T/c14c.sh"
sed -n "${C26S},$((C26E - 1))p" "$HB" > "$T/c26.sh"
OS="$T/oura_state"; mkdir -p "$OS"
region() {
  STATE_DIR="$OS" HOME="$T/ohome" TODAY="$(date +%Y-%m-%d)" /bin/bash -c '
    set -uo pipefail
    MCS_STALE_REPORTED=0; DEFER_DAILY=0; DEFER_TEAM_BRIEF=0
    add_finding() { echo "FINDING: $1"; }
    source "$1"
  ' _ "$1" 2>&1
}
r_none() { local out; out="$(region "$2")"; if [ -z "$out" ]; then ok "$1"; else bad "$1 ($out)"; fi; }
r_has()  { local out; out="$(region "$2")"; case "$out" in *"$3"*) ok "$1" ;; *) bad "$1 (got: $out)" ;; esac; }
mkdir -p "$T/ohome/Library/LaunchAgents"
r_none "no plist: silent even with no stamp" "$T/c14c.sh"
touch "$T/ohome/Library/LaunchAgents/com.mbs.oura-sync.plist"
r_has "plist, never stamped" "$T/c14c.sh" "oura-sync has not completed since none"
date +%Y-%m-%d > "$OS/last_oura_sync_run"
r_none "stamped today" "$T/c14c.sh"
date -v-1d +%Y-%m-%d > "$OS/last_oura_sync_run"
r_none "stamped yesterday (late wake)" "$T/c14c.sh"
date -v-2d +%Y-%m-%d > "$OS/last_oura_sync_run"
r_has "stamped two days ago" "$T/c14c.sh" "oura-sync has not completed since $(date -v-2d +%Y-%m-%d)"

echo "oura-sync wrapper into check 26 (real wrapper and oura_sync.py, faked Oura API)"
if [ -z "$OURA_REPO" ] || [ ! -f "$OURA_REPO/scripts/oura_sync.sh" ] || [ ! -x "$OURA_REPO/.venv/bin/python" ]; then
  bad "no mbs-oura-sync checkout with scripts/oura_sync.sh and a .venv beside this repo (set OURA_REPO)"
else
  SR="$T/oura_repo"; mkdir -p "$SR/scripts" "$SR/src" "$SR/.venv/bin" "$T/ovault"
  cp "$OURA_REPO/scripts/oura_sync.sh" "$SR/scripts/"
  ln -s "$OURA_REPO/.venv/bin/python" "$SR/.venv/bin/python"
  # The driver stands in for src/oura_sync.py: it runs the real module with
  # api.requests.get answering every call 200 with empty data, except the slug
  # named in DRILL_FAIL_SLUG, which gets HTTP 500.
  cat > "$SR/src/oura_sync.py" <<PYEOF
import os, sys
sys.path.insert(0, "$OURA_REPO/src")
import api, oura_sync
class R:
    def __init__(self, code): self.status_code = code; self.response = self
    def raise_for_status(self):
        if self.status_code >= 400:
            e = api.requests.HTTPError("HTTP %d" % self.status_code); e.response = self; raise e
    def json(self): return {"data": [], "next_token": None}
fail = os.environ.get("DRILL_FAIL_SLUG", "")
api.requests.get = lambda url, **k: R(500 if fail and url.endswith("/" + fail) else 200)
sys.exit(oura_sync.main(sys.argv[1:] + ["--vault", "$T/ovault"]))
PYEOF
  OH="$T/ohome"
  owrap() {
    HOME="$OH" OURA_NET_URL="file:///dev/null" OURA_PERSONAL_ACCESS_TOKEN=drill \
      OURA_LOCK_PATH="$OH/.mbs_automation/oura_sync.lock" \
      OURA_FAILURES_PATH="$OH/.mbs_automation/oura_endpoint_failures.txt" \
      DRILL_FAIL_SLUG="${1:-}" /bin/bash "$SR/scripts/oura_sync.sh"
  }
  OS="$OH/.mbs_automation"; rm -rf "$OS"
  OLOG="$OS/oura_sync.log"
  lastterm() { grep -E 'completed successfully|FAILED' "$OLOG" | tail -1; }
  owrap daily_spo2; RC=$?
  if [ "$RC" -eq 0 ] && lastterm | grep -q "completed successfully; stamped"; then ok "one failing run: exit 0, stamped"; else bad "one failing run: rc=$RC, $(lastterm)"; fi
  if grep -q 'endpoints: .*failed: daily_spo2=http-500' "$OLOG"; then ok "the endpoints: line names daily_spo2=http-500"; else bad "no endpoints: line naming daily_spo2 ($(grep endpoints: "$OLOG" | tail -1))"; fi
  if [ "$(grep -c Syncing "$OLOG")" -eq 14 ]; then ok "lookback 14 from the wrapper (14 Syncing lines)"; else bad "Syncing lines: $(grep -c Syncing "$OLOG")"; fi
  r_none "check 26 silent after one failing run" "$T/c26.sh"
  owrap daily_spo2; RC=$?
  if [ "$RC" -eq 0 ] && tail -1 "$OLOG" | grep -q "already ran for"; then ok "stamped day: second fire is a no-op"; else bad "stamped day: rc=$RC, $(tail -1 "$OLOG")"; fi
  rm -f "$OS/last_oura_sync_run"
  owrap daily_spo2; RC=$?
  if [ "$RC" -eq 5 ] && lastterm | grep -q "FAILED (rc=5)"; then ok "second consecutive failing run: exit 5, FAILED"; else bad "second failing run: rc=$RC, $(lastterm)"; fi
  if [ ! -f "$OS/last_oura_sync_run" ]; then ok "no stamp after FAILED"; else bad "stamp written after FAILED"; fi
  r_has "check 26 reports oura_sync.log" "$T/c26.sh" "oura_sync.log ($(date +%Y-%m-%d))"
  owrap; RC=$?
  if [ "$RC" -eq 0 ] && lastterm | grep -q "completed successfully"; then ok "clean run after FAILED: exit 0"; else bad "clean run: rc=$RC, $(lastterm)"; fi
  if [ ! -s "$OS/oura_endpoint_failures.txt" ]; then ok "clean run resets the counts"; else bad "counts not reset: $(cat "$OS/oura_endpoint_failures.txt")"; fi
  r_none "check 26 clears after the clean run" "$T/c26.sh"
  rm -f "$OS/last_oura_sync_run"; owrap; RC1=$?
  rm -f "$OS/last_oura_sync_run"; owrap; RC2=$?
  if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && grep 'endpoints:' "$OLOG" | tail -1 | grep -q 'failed: none'; then ok "empty-data 200s on two runs are not failures"; else bad "empty data: rc=$RC1/$RC2"; fi
  date +%Y-%m-%d > "$OS/last_oura_sync_run"
  r_none "the wrapper's stamp satisfies check 14c" "$T/c14c.sh"
fi

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
