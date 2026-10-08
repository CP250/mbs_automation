#!/bin/bash
# deploy.sh - pull-deploy of the runtime repos onto garm.
#
# Fires every 5 minutes (com.mbs.deploy, StartInterval 300, plus RunAtLoad).
# GitHub main is production. garm checkouts are read-only: nobody edits code
# on garm, and this job is the only thing that moves their HEAD.
#
# For each repo in REPOS, in order:
#   1. Refuse if the live checkout is dirty (code is never edited on garm).
#   2. Fetch origin/main with the repo's own read-only deploy key.
#   3. Refuse unless the new tip is a fast-forward of HEAD AND every new
#      commit carries a good SSH signature from deploy/allowed_signers
#      (installed outside any repo, at $ALLOWED, so a deployed commit cannot
#      widen its own trust).
#   4. In a scratch clone, run the gates: bash 3.2 parse of every tracked .sh,
#      plutil -lint on changed plists, and the repo's own test suite with the
#      passed-count held to a per-repo high-water mark (a missing test file is a
#      smaller number, which pytest reports as success).
#   5. Wait until no running com.mbs job uses this repo, then fast-forward.
#   6. Changed plists that are already installed: bootout, copy, bootstrap, then
#      prove the label is loaded (bootstrap of a disabled label is a silent no-op).
#   7. Changed lockfiles: rebuild the venv or node_modules.
#   8. Log in the estate vocabulary. The run's last line is either
#      "completed successfully" or "FAILED: ..." so heartbeat check 26 reads it.
#      On FAILED the old version keeps running and P gets one email per failing
#      commit, with a reminder every 6 hours.
#
# Never runs on the laptop. "Deploy now": ssh garm 'launchctl kickstart gui/$(id -u)/com.mbs.deploy'
#
# Test hooks (env): DEV_ROOT, STATE_DIR, DEPLOY_REPOS, DEPLOY_BRANCH (forces one
# branch for every repo; unset in production),
# DEPLOY_ALLOWED_SIGNERS, DEPLOY_LA_DIR, LAUNCHCTL, DEPLOY_BUSY_WAIT_SECONDS.

set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DEV_ROOT="${DEV_ROOT:-$HOME/dev}"
STATE_DIR="${STATE_DIR:-$HOME/.mbs_automation}"
REPOS="${DEPLOY_REPOS:-mbs_automation mbs-oura-sync mbs-music-discovery mbs-mychart-sync claude_mbs}"
FORCE_BRANCH="${DEPLOY_BRANCH:-}"
ALLOWED="${DEPLOY_ALLOWED_SIGNERS:-$STATE_DIR/allowed_signers}"
LA_DIR="${DEPLOY_LA_DIR:-$HOME/Library/LaunchAgents}"
LAUNCHCTL="${LAUNCHCTL:-launchctl}"
BUSY_WAIT_SECONDS="${DEPLOY_BUSY_WAIT_SECONDS:-600}"
REMIND_SECONDS=21600
LOG="$STATE_DIR/deploy.log"
STAMP="$STATE_DIR/last_deploy_run"
LOCK_DIR="$STATE_DIR/deploy.lock"
SCRATCH="$STATE_DIR/deploy_scratch"
ALERT_TO="${LA_EMAIL_TO:-chris.preston@gmail.com}"
SELF_LABEL="com.mbs.deploy"

mkdir -p "$STATE_DIR"

ts() { TZ=America/New_York date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) - $*" >> "$LOG"; }

# shellcheck source=./lib_email.sh
source "$(dirname "$0")/lib_email.sh"

# Single-instance lock, same shape as mbs_daily.sh.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  HOLDER="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -n "$HOLDER" ] && kill -0 "$HOLDER" 2>/dev/null; then
    log "another deploy run (pid $HOLDER) holds the lock; exiting."
    exit 0
  fi
  rm -rf "$LOCK_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "FAILED: could not take $LOCK_DIR"
    exit 1
  fi
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR" "$SCRATCH" 2>/dev/null' EXIT INT TERM

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

FAILED_REPOS=""
DEPLOYED_ANY=0
CHECK_REASON=""

short() { echo "$1" | cut -c1-9; }

# The branch each repo deploys from. Per repo since 2026-10-08: mbs-oura-sync's
# default branch is master, the rest are main, and one global branch made the
# first live run on garm fail with "couldn't find remote ref main" (10-07). An
# explicit map, not origin/HEAD detection: it is offline, it cannot change
# under us when a remote's default branch is renamed, and a new repo has to be
# added here on purpose, with a drill case.
branch_for() {
  if [ -n "$FORCE_BRANCH" ]; then
    echo "$FORCE_BRANCH"
    return
  fi
  case "$1" in
    mbs-oura-sync) echo master ;;
    *) echo main ;;
  esac
}

alert_key_stamp() { echo "$STATE_DIR/deploy_alerted_$1"; }

# One email per failing key, then a reminder every REMIND_SECONDS. The key is
# repo plus tip sha, so a new commit is a new incident.
alert() {
  local repo="$1" key="$2" reason="$3"
  local stamp now mt body
  stamp="$(alert_key_stamp "${repo}_${key}")"
  now="$(date +%s)"
  if [ -f "$stamp" ]; then
    mt="$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp" 2>/dev/null || echo 0)"
    case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
    if [ "$mt" -gt 0 ] && [ $((now - mt)) -lt "$REMIND_SECONDS" ]; then
      return 0
    fi
  fi
  body="$(mktemp "${TMPDIR:-/tmp}/deploy_alert.XXXXXX")" || return 0
  printf 'garm deploy refused %s at %s.\n\nReason: %s\n\nThe previous version keeps running. Detail: %s\n' \
    "$repo" "$key" "$reason" "$LOG" > "$body"
  if send_email "$ALERT_TO" "[mbs] deploy FAILED: $repo" "$body"; then
    : > "$stamp"
  fi
  rm -f "$body"
  return 0
}

clear_alerts() { rm -f "$STATE_DIR"/deploy_alerted_"$1"_* 2>/dev/null; }

fail_repo() {
  local repo="$1" key="$2" reason="$3"
  log "FAILED: $repo ($key): $reason"
  FAILED_REPOS="${FAILED_REPOS}${FAILED_REPOS:+ }$repo"
  alert "$repo" "$key" "$reason"
}

# True when a running com.mbs job has a program argument under this repo.
# Output is captured into variables, never piped into grep -q: under pipefail an
# early-exiting grep -q turns a match into a SIGPIPE failure of the pipeline.
repo_busy() {
  local repo="$1" labels label detail
  labels="$($LAUNCHCTL list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $3}' | grep -E '^com\.mbs\.' | grep -vx "$SELF_LABEL")"
  for label in $labels; do
    detail="$($LAUNCHCTL print "gui/$(id -u)/$label" 2>/dev/null)"
    case "$detail" in
      *"/dev/$repo/"*) return 0 ;;
    esac
  done
  return 1
}

test_floor_file() { echo "$STATE_DIR/deploy_testcount_$1"; }

# Run the repo's own suite in the scratch clone. Sets CHECK_REASON on failure.
run_tests() {
  local repo="$1" scratch="$2" live="$3"
  local out count floor floorf
  case "$repo" in
    mbs-oura-sync|mbs-mychart-sync)
      if [ ! -x "$live/.venv/bin/python" ]; then
        CHECK_REASON="no $live/.venv/bin/python to run the tests with"
        return 1
      fi
      out="$(cd "$scratch" && PYTHONPATH="$scratch/src:$scratch" "$live/.venv/bin/python" -m pytest -q 2>&1)"
      if [ $? -ne 0 ]; then
        CHECK_REASON="tests failed: $(echo "$out" | tail -1)"
        return 1
      fi
      count="$(echo "$out" | sed -n 's/^\([0-9][0-9]*\) passed.*/\1/p' | tail -1)"
      ;;
    mbs-music-discovery)
      if [ ! -d "$live/node_modules" ]; then
        CHECK_REASON="no $live/node_modules to run the tests with"
        return 1
      fi
      ln -s "$live/node_modules" "$scratch/node_modules"
      out="$(cd "$scratch" && node test/run-parsers.js 2>&1)"
      if [ $? -ne 0 ]; then
        CHECK_REASON="tests failed: $(echo "$out" | tail -1)"
        return 1
      fi
      count="$(echo "$out" | grep -c '^  PASS')"
      ;;
    *)
      return 0
      ;;
  esac
  case "$count" in
    ''|*[!0-9]*) CHECK_REASON="could not read a passed-test count from the test output"; return 1 ;;
  esac
  if [ "$count" -lt 1 ]; then
    CHECK_REASON="the test run reported zero passing tests"
    return 1
  fi
  floorf="$(test_floor_file "$repo")"
  floor="$(cat "$floorf" 2>/dev/null || echo 0)"
  case "$floor" in ''|*[!0-9]*) floor=0 ;; esac
  if [ "$count" -lt "$floor" ]; then
    CHECK_REASON="only $count tests passed, the high-water mark is $floor (a test file went missing?); if tests were removed on purpose, delete $floorf"
    return 1
  fi
  echo "$count" > "$floorf.pending"
  return 0
}

run_checks() {
  local repo="$1" scratch="$2" live="$3" old="$4" new="$5"
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! /bin/bash -n "$scratch/$f" 2>/dev/null; then
      CHECK_REASON="$f does not parse under /bin/bash $(/bin/bash -c 'echo $BASH_VERSION')"
      return 1
    fi
  done <<EOF
$(git -C "$scratch" ls-files '*.sh')
EOF
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$scratch/$f" ] || continue
    if ! plutil -lint "$scratch/$f" >/dev/null 2>&1; then
      CHECK_REASON="$f is not a valid plist"
      return 1
    fi
  done <<EOF
$(git -C "$live" diff --name-only "$old" "$new" -- '*.plist')
EOF
  run_tests "$repo" "$scratch" "$live" || return 1
  return 0
}

install_plist() {
  local repo="$1" live="$2" rel="$3"
  local src installed label uid
  src="$live/$rel"
  installed="$LA_DIR/$(basename "$rel")"
  [ -f "$src" ] || return 0
  if [ ! -f "$installed" ]; then
    log "NOTE: $repo ships $rel, which is not installed in $LA_DIR; not auto-installed (install by hand, then add its label to the garm list in mbs_heartbeat.sh)"
    return 0
  fi
  label="$(plutil -extract Label raw -o - "$src" 2>/dev/null)"
  if [ -z "$label" ]; then
    log "FAILED: $repo $rel: could not read its Label"
    return 1
  fi
  if [ "$label" = "$SELF_LABEL" ]; then
    cp "$src" "$installed"
    log "NOTE: $rel is this job's own plist; copied, but it cannot restart itself mid-run. Apply: launchctl bootout gui/$(id -u)/$SELF_LABEL; launchctl bootstrap gui/$(id -u) $installed"
    return 0
  fi
  uid="$(id -u)"
  $LAUNCHCTL bootout "gui/$uid/$label" >/dev/null 2>&1
  cp "$src" "$installed"
  if ! $LAUNCHCTL bootstrap "gui/$uid" "$installed" >/dev/null 2>&1; then
    log "FAILED: $repo $label: bootstrap returned an error"
    return 1
  fi
  if ! $LAUNCHCTL print "gui/$uid/$label" >/dev/null 2>&1; then
    log "FAILED: $repo $label: not loaded after bootstrap (disabled label?)"
    return 1
  fi
  log "plist updated: $label (bootout, copy, bootstrap, loaded)"
  return 0
}

rebuild_deps() {
  local repo="$1" live="$2" changed="$3"
  if grep -qx 'uv.lock' <<< "$changed"; then
    (cd "$live" && uv sync --frozen >/dev/null 2>&1) || return 1
    log "deps: uv sync --frozen in $repo"
  elif grep -qxE 'requirements.*\.txt|pyproject.toml' <<< "$changed"; then
    if [ -x "$live/.venv/bin/python" ]; then
      if [ -f "$live/requirements.txt" ]; then
        "$live/.venv/bin/python" -m pip install -q -r "$live/requirements.txt" >/dev/null 2>&1 || return 1
      else
        "$live/.venv/bin/python" -m pip install -q -e "$live" >/dev/null 2>&1 || return 1
      fi
      log "deps: pip install in $repo's .venv"
    fi
  fi
  if grep -qx 'package-lock.json' <<< "$changed"; then
    (cd "$live" && npm ci --silent >/dev/null 2>&1) || return 1
    log "deps: npm ci in $repo"
  fi
  return 0
}

process_repo() {
  local repo="$1"
  local live="$DEV_ROOT/$repo"
  local old new bad scratch waited changed n f branch cur

  if [ ! -d "$live/.git" ]; then
    log "skip $repo: no checkout at $live"
    return 0
  fi
  if [ -n "$(git -C "$live" status --porcelain 2>&1)" ]; then
    fail_repo "$repo" "dirty" "the live checkout has uncommitted changes (code on garm is never edited)"
    return 0
  fi
  branch="$(branch_for "$repo")"
  cur="$(git -C "$live" symbolic-ref --short -q HEAD)"
  if [ "$cur" != "$branch" ]; then
    fail_repo "$repo" "branch" "the live checkout is on '${cur:-a detached HEAD}', not '$branch' (deploy fast-forwards $branch only)"
    return 0
  fi
  if ! git -C "$live" fetch --quiet origin "$branch" 2>>"$LOG"; then
    fail_repo "$repo" "fetch" "git fetch origin $branch failed (deploy key, network, or the remote has no branch named $branch)"
    return 0
  fi
  old="$(git -C "$live" rev-parse HEAD)"
  new="$(git -C "$live" rev-parse "origin/$branch")"
  if [ "$old" = "$new" ]; then
    clear_alerts "$repo"
    return 0
  fi
  if ! git -C "$live" merge-base --is-ancestor "$old" "$new"; then
    fail_repo "$repo" "$(short "$new")" "origin/$branch is not a fast-forward of garm's HEAD $(short "$old")"
    return 0
  fi
  if [ ! -s "$ALLOWED" ]; then
    fail_repo "$repo" "$(short "$new")" "no allowed_signers file at $ALLOWED, so no commit can be verified"
    return 0
  fi
  bad="$(git -C "$live" -c gpg.ssh.allowedSignersFile="$ALLOWED" log --format='%h %G?' "$old..$new" 2>/dev/null | grep -v ' G$')"
  if [ -n "$bad" ]; then
    fail_repo "$repo" "$(short "$new")" "commit(s) without a good signature from allowed_signers: $(echo "$bad" | tr '\n' ';')"
    return 0
  fi

  scratch="$SCRATCH/$repo"
  if ! git clone -q --local --no-checkout "$live" "$scratch" 2>>"$LOG" || ! git -C "$scratch" checkout -q --detach "$new" 2>>"$LOG"; then
    fail_repo "$repo" "$(short "$new")" "could not build the scratch checkout"
    return 0
  fi
  CHECK_REASON=""
  if ! run_checks "$repo" "$scratch" "$live" "$old" "$new"; then
    fail_repo "$repo" "$(short "$new")" "$CHECK_REASON"
    rm -f "$(test_floor_file "$repo").pending"
    return 0
  fi

  waited=0
  while repo_busy "$repo"; do
    if [ "$waited" -ge "$BUSY_WAIT_SECONDS" ]; then
      log "deferred: $repo still has a running job after ${waited}s; will retry next run (not a failure)"
      rm -f "$(test_floor_file "$repo").pending"
      return 0
    fi
    sleep 15
    waited=$((waited + 15))
  done

  if ! git -C "$live" merge --ff-only -q "$new" 2>>"$LOG"; then
    fail_repo "$repo" "$(short "$new")" "fast-forward of the live checkout failed"
    rm -f "$(test_floor_file "$repo").pending"
    return 0
  fi
  [ -f "$(test_floor_file "$repo").pending" ] && mv "$(test_floor_file "$repo").pending" "$(test_floor_file "$repo")"
  changed="$(git -C "$live" diff --name-only "$old" "$new")"
  n="$(git -C "$live" rev-list --count "$old..$new")"
  log "deployed $repo ($branch) $(short "$old")..$(short "$new") ($n commit(s), all signed)"
  DEPLOYED_ANY=1
  clear_alerts "$repo"

  while IFS= read -r f; do
    case "$f" in
      *.plist) install_plist "$repo" "$live" "$f" || { fail_repo "$repo" "$(short "$new")" "plist step failed for $f (code is already live)"; return 0; } ;;
    esac
  done <<EOF
$changed
EOF
  if ! rebuild_deps "$repo" "$live" "$changed"; then
    fail_repo "$repo" "$(short "$new")" "dependency rebuild failed (code is already live)"
  fi
  return 0
}

log "starting deploy run on $(hostname -s) (repos: $REPOS)"
for r in $REPOS; do
  process_repo "$r"
done

if [ -n "$FAILED_REPOS" ]; then
  log "FAILED: deploy refused or failed for: $FAILED_REPOS (previous versions keep running)"
  exit 1
fi
date +%s > "$STAMP"
log "completed successfully"
exit 0
