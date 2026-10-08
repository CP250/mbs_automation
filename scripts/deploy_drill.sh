#!/bin/bash
# deploy_drill.sh - exercises deploy.sh against a scratch bare repo.
#
# Safe on any machine: it runs in a temp dir with its own HOME, a stub
# lib_email.sh (records the alert instead of sending it), and a launchctl shim,
# so it never touches real launchd, the real state dir or the real mail.
#
#   bash scripts/deploy_drill.sh
#
# Cases: per-repo branch (a master repo and a wrong-branch checkout); no change; signed fast-forward; unsigned commit; alert throttle;
# non-fast-forward; a script that does not parse; dirty live tree; installed
# plist (bootout then bootstrap then loaded); busy repo (deferred, not failed);
# test-count high-water (smaller count, zero count). Exits 1 on any miss.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/deploy_drill.XXXXXX")"
trap 'rm -rf "$T"' EXIT

export HOME="$T/home"
mkdir -p "$HOME" "$T/bin" "$T/state" "$T/dev" "$T/la" "$T/work"
STATE="$T/state"
LOG="$STATE/deploy.log"
EMAILS="$T/emails"
LCLOG="$T/launchctl.log"
: > "$EMAILS"; : > "$LCLOG"

cp "$HERE/deploy.sh" "$T/bin/deploy.sh"
cat > "$T/bin/lib_email.sh" <<'EOF'
send_email() { echo "$1|$2" >> "$EMAILS_FILE"; return 0; }
EOF
cat > "$T/bin/launchctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$LCLOG_FILE"
case "$1" in
  list)
    printf 'PID\tStatus\tLabel\n'
    if [ -f "$BUSY_FLAG" ]; then printf '4242\t0\tcom.mbs.busy\n'; fi
    ;;
  print)
    case "$2" in
      *com.mbs.busy) echo "arguments = { /bin/bash $DEV_ROOT/mbs_automation/scripts/x.sh }" ;;
      *) echo "state = running" ;;
    esac
    ;;
esac
exit 0
EOF
chmod +x "$T/bin/launchctl"
export EMAILS_FILE="$EMAILS" LCLOG_FILE="$LCLOG" BUSY_FLAG="$T/busy" DEV_ROOT="$T/dev"

ssh-keygen -q -t ed25519 -N '' -f "$T/key" -C drill >/dev/null
printf 'drill@example.com namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$T/key.pub")" > "$STATE/allowed_signers"

gsigned() { git -c user.name=drill -c user.email=drill@example.com -c gpg.format=ssh -c user.signingkey="$T/key.pub" -c commit.gpgsign=true "$@"; }
gplain()  { git -c user.name=drill -c user.email=drill@example.com -c commit.gpgsign=false "$@"; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }

run_deploy() {
  STATE_DIR="$STATE" DEPLOY_REPOS="${REPOS_UNDER_TEST:-mbs_automation}" DEPLOY_LA_DIR="$T/la" \
  LAUNCHCTL="$T/bin/launchctl" DEPLOY_BUSY_WAIT_SECONDS=0 DEPLOY_ALLOWED_SIGNERS="$STATE/allowed_signers" \
  /bin/bash "$T/bin/deploy.sh" >/dev/null 2>&1
  return $?
}
lastline() { tail -1 "$LOG" | sed 's/^[0-9-]* [0-9:]* - //'; }
head_of() { git -C "$T/dev/$1" rev-parse HEAD; }
emails() { wc -l < "$EMAILS" | tr -d ' '; }

ORIGIN="$T/origin.git"
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$T/work/w" 2>/dev/null
cd "$T/work/w" || exit 1
mkdir -p scripts launchd
echo '#!/bin/bash' > scripts/ok.sh
echo 'echo hi' >> scripts/ok.sh
gsigned add -A >/dev/null; gsigned commit -q -m c1 && gsigned push -q origin HEAD:main
git clone -q "$ORIGIN" "$T/dev/mbs_automation"
C1="$(head_of mbs_automation)"

echo "case: nothing to deploy"
run_deploy; expect "exit 0" "$?" "0"
expect "terminal line" "$(lastline)" "completed successfully"

echo "case: signed fast-forward"
echo 'echo two' >> scripts/ok.sh; gsigned commit -q -am c2 && gsigned push -q origin HEAD:main
run_deploy; expect "exit 0" "$?" "0"
expect "live HEAD is c2" "$(head_of mbs_automation)" "$(git rev-parse HEAD)"
grep -q 'deployed mbs_automation' "$LOG" && ok "log says deployed" || bad "log says deployed"
C2="$(git rev-parse HEAD)"

echo "case: unsigned commit refused, one email, throttled"
echo 'echo three' >> scripts/ok.sh; gplain commit -q -am c3 && gplain push -q origin HEAD:main
run_deploy; expect "exit 1" "$?" "1"
expect "live HEAD unchanged" "$(head_of mbs_automation)" "$C2"
expect "one email" "$(emails)" "1"
run_deploy
expect "no second email within 6h" "$(emails)" "1"
case "$(lastline)" in FAILED*) ok "terminal line FAILED" ;; *) bad "terminal line FAILED" ;; esac

echo "case: non-fast-forward refused"
git reset -q --hard "$C1"; echo 'echo diverged' >> scripts/ok.sh; gsigned commit -q -am diverged && gsigned push -q -f origin HEAD:main
run_deploy; expect "exit 1" "$?" "1"
expect "live HEAD unchanged" "$(head_of mbs_automation)" "$C2"
grep -q 'not a fast-forward' "$LOG" && ok "reason names fast-forward" || bad "reason names fast-forward"

echo "case: script that does not parse under bash 3.2"
git reset -q --hard "$C2"; printf '#!/bin/bash\nif then fi\n' > scripts/broken.sh
gsigned add -A >/dev/null; gsigned commit -q -m broken && gsigned push -q -f origin HEAD:main
run_deploy; expect "exit 1" "$?" "1"
expect "live HEAD unchanged" "$(head_of mbs_automation)" "$C2"
grep -q 'broken.sh does not parse' "$LOG" && ok "reason names the file" || bad "reason names the file"

echo "case: dirty live tree"
git reset -q --hard "$C2"; gsigned push -q -f origin HEAD:main
echo junk > "$T/dev/mbs_automation/stray.txt"
run_deploy; expect "exit 1" "$?" "1"
grep -q 'uncommitted changes' "$LOG" && ok "reason names the dirty tree" || bad "reason names the dirty tree"
rm -f "$T/dev/mbs_automation/stray.txt"

echo "case: installed plist is bootout, copied, bootstrapped, loaded"
cat > launchd/com.mbs.drill.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.mbs.drill</string></dict></plist>
EOF
cp launchd/com.mbs.drill.plist "$T/la/com.mbs.drill.plist"
sed -i.bak 's/com.mbs.drill/com.mbs.drill/' launchd/com.mbs.drill.plist; rm -f launchd/com.mbs.drill.plist.bak
echo '<!-- v2 -->' >> launchd/com.mbs.drill.plist
gsigned add -A >/dev/null; gsigned commit -q -m plist && gsigned push -q origin HEAD:main
: > "$LCLOG"
run_deploy; expect "exit 0" "$?" "0"
cmp -s launchd/com.mbs.drill.plist "$T/la/com.mbs.drill.plist" && ok "installed copy updated" || bad "installed copy updated"
BO="$(grep -n 'bootout' "$LCLOG" | head -1 | cut -d: -f1)"; BS="$(grep -n 'bootstrap' "$LCLOG" | head -1 | cut -d: -f1)"
[ -n "$BO" ] && [ -n "$BS" ] && [ "$BO" -lt "$BS" ] && ok "bootout before bootstrap" || bad "bootout before bootstrap"
grep -q 'print gui/.*/com.mbs.drill' "$LCLOG" && ok "loaded state proven" || bad "loaded state proven"
C4="$(git rev-parse HEAD)"

echo "case: busy repo is deferred, not failed"
touch "$T/busy"
echo 'echo five' >> scripts/ok.sh; gsigned commit -q -am c5 && gsigned push -q origin HEAD:main
run_deploy; expect "exit 0" "$?" "0"
expect "live HEAD unchanged" "$(head_of mbs_automation)" "$C4"
grep -q 'deferred: mbs_automation' "$LOG" && ok "log says deferred" || bad "log says deferred"
rm -f "$T/busy"
run_deploy; expect "deploys once idle" "$(head_of mbs_automation)" "$(git rev-parse HEAD)"

echo "case: per-repo branch (mbs-oura-sync deploys master) and test-count high-water (stub venv python prints the count in n_tests)"
git clone -q "$ORIGIN" "$T/work/o" 2>/dev/null
rm -rf "$T/work/o"
OR="$T/origin_o.git"
git init -q --bare -b master "$OR"
git clone -q "$OR" "$T/work/o" 2>/dev/null; cd "$T/work/o" || exit 1
echo 5 > n_tests; gsigned add -A >/dev/null; gsigned commit -q -m t1 && gsigned push -q origin HEAD:master
git clone -q "$OR" "$T/dev/mbs-oura-sync"
mkdir -p "$T/dev/mbs-oura-sync/.venv/bin"
cat > "$T/dev/mbs-oura-sync/.venv/bin/python" <<'EOF'
#!/bin/bash
echo "$(cat n_tests) passed in 0.1s"
exit 0
EOF
chmod +x "$T/dev/mbs-oura-sync/.venv/bin/python"
git -C "$T/dev/mbs-oura-sync" update-index --assume-unchanged .venv 2>/dev/null
echo ".venv/" > "$T/dev/mbs-oura-sync/.git/info/exclude"
REPOS_UNDER_TEST="mbs-oura-sync"
expect "oura checkout is on master" "$(git -C "$T/dev/mbs-oura-sync" symbolic-ref --short HEAD)" "master"
echo 6 > n_tests; gsigned commit -q -am t2 && gsigned push -q origin HEAD:master
run_deploy; grep -q "deployed mbs-oura-sync (master)" "$LOG" && ok "log says deployed from master" || bad "log says deployed from master"
expect "6 tests deploys and records the mark" "$(cat "$STATE/deploy_testcount_mbs-oura-sync" 2>/dev/null)" "6"
echo 3 > n_tests; gsigned commit -q -am t3 && gsigned push -q origin HEAD:master
run_deploy; expect "smaller count refused" "$?" "1"
grep -q 'high-water mark is 6' "$LOG" && ok "reason names the mark" || bad "reason names the mark"
echo 0 > n_tests; gsigned commit -q -am t4 && gsigned push -q origin HEAD:master
run_deploy; expect "zero count refused" "$?" "1"
echo 7 > n_tests; gsigned commit -q -am t5 && gsigned push -q origin HEAD:master
run_deploy; expect "bigger count deploys again" "$?" "0"


echo "case: checkout on the wrong branch is refused"
cd "$T/work/o" || exit 1
git -C "$T/dev/mbs-oura-sync" checkout -q -b side
echo 8 > n_tests; gsigned commit -q -am t6 && gsigned push -q origin HEAD:master
BEFORE="$(git -C "$T/dev/mbs-oura-sync" rev-parse HEAD)"
run_deploy; expect "exit 1" "$?" "1"
grep -q "is on 'side', not 'master'" "$LOG" && ok "reason names both branches" || bad "reason names both branches"
expect "live HEAD unchanged" "$(git -C "$T/dev/mbs-oura-sync" rev-parse HEAD)" "$BEFORE"
git -C "$T/dev/mbs-oura-sync" checkout -q master
run_deploy; expect "deploys again on master" "$?" "0"

echo "case: the old global-main behaviour would fail here (remote has no main)"
run_deploy_forced_main() {
  STATE_DIR="$STATE" DEPLOY_BRANCH=main DEPLOY_REPOS="mbs-oura-sync" DEPLOY_LA_DIR="$T/la" LAUNCHCTL="$T/bin/launchctl" \
  DEPLOY_ALLOWED_SIGNERS="$STATE/allowed_signers" /bin/bash "$T/bin/deploy.sh" >/dev/null 2>&1
}
git -C "$T/dev/mbs-oura-sync" checkout -q -b main 2>/dev/null
run_deploy_forced_main; expect "forcing main on a master remote fails" "$?" "1"
grep -q "fetch origin main failed" "$LOG" && ok "reason names the missing branch" || bad "reason names the missing branch"
git -C "$T/dev/mbs-oura-sync" checkout -q master
echo
echo "deploy_drill: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
