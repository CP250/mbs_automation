#!/bin/bash
# tasks_rollover_drill.sh - drill for the midnight rollover (tasks_rollover.sh),
# mbs_daily.sh's new pre-flight (fallback rollover, residue, rescue, open_tasks)
# and the carry-forward rescue in lib_tasks_note.sh. Added 2026-10-16 with them.
# Brief: admin/mbs_system/design/brief_daily_note_garm_fixes.md, section 6.0
# (cases a to k) and 6.4 (the carry rescue, cases s1 to s5).
#
# Sandbox only: VAULT, STATE_DIR and HOME point at a temp dir. mbs_daily.sh is
# NEVER run end to end (its PATH would find the real claude first); its
# pre-flight region is extracted and run in a harness with an end marker in
# place of the Claude ladder. The old-versus-new case (k) extracts the baseline
# functions with git show and reads three real note pairs from garm's vault git
# (git archive, read-only). Isolation is proven by the real files' mtimes.
#
#   /bin/bash scripts/tasks_rollover_drill.sh
#   BASE=<commit> /bin/bash scripts/tasks_rollover_drill.sh    (baseline, default d6b9312)
#   NO_REAL=1 ...    skip case k (no ssh to garm); the case count then says so.
# Must stay compatible with macOS /bin/bash 3.2 and /usr/bin/awk.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BASE="${BASE:-d6b9312}"
REAL_VAULT="/Users/cpreston/Vaults/storage_mbs"
T="$(mktemp -d "${TMPDIR:-/tmp}/tasks_rollover_drill.XXXXXX")"
HOLDER_PID=""
trap '[ -n "$HOLDER_PID" ] && kill "$HOLDER_PID" 2>/dev/null; rm -rf "$T"' EXIT

PASS=0; FAIL=0; CASES=""
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
case_() { CASES="$CASES $1"; echo "case $1: $2"; }
has()  { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1 (missing '$2' in $(basename "$3"))"; fi; }
hasnt() { if grep -qF -- "$2" "$3" 2>/dev/null; then bad "$1 (found '$2' in $(basename "$3"))"; else ok "$1"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }
cnt() { grep -cF -- "$1" "$2" 2>/dev/null | tr -d ' '; }
sum() { cksum < "$1" 2>/dev/null | cut -d' ' -f1; }
ago_min() { touch -t "$(date -v-"$2"M +%Y%m%d%H%M.%S)" "$1"; }
dago() { date -v-"$1"d +%Y-%m-%d; }

# --- isolation snapshot: the real tasks folder and state the drill must not touch
REAL_STATE="$HOME/.mbs_automation"
snap() {
  { ls -lT "$REAL_VAULT/daily_notes/tasks/" 2>/dev/null
    ls -lT "$REAL_STATE/last_tasks_rollover" "$REAL_STATE/triage_first_seen" "$REAL_STATE/tasks_rollover.log" "$REAL_STATE/tasks_note.lock" 2>&1; } | cksum
}
SNAP0="$(snap)"

# --- the daily pre-flight region, run in a harness -------------------------
DAILY="$HERE/mbs_daily.sh"
S="$(grep -n "^# Pre-flight: today's tasks note" "$DAILY" | cut -d: -f1)"
E="$(grep -n '^# Headless run. NOTE' "$DAILY" | cut -d: -f1)"
[ -n "$S" ] && [ -n "$E" ] || { echo "cannot find the pre-flight region in mbs_daily.sh"; exit 1; }
sed -n "${S},$((E - 1))p" "$DAILY" > "$T/daily_region.sh"

# One sandbox per case: $W/vault, $W/state, $W/home. Program note with a window
# around today and one skill, so the garden leave block is written.
TODAY="$(date +%Y-%m-%d)"
new_world() {
  W="$T/$1"; rm -rf "$W"
  mkdir -p "$W/vault/daily_notes/tasks" "$W/vault/admin/betterment" "$W/vault/skills/sewing" "$W/state" "$W/home/.mbs_automation"
  printf -- '---\ngl_start: %s\ngl_end: %s\ngl_skills: [shirt]\ngl_skill_shirt: skills/sewing/project_sewing.md\n---\n\n# Garden leave\n' "$(dago 3)" "$(date -v+30d +%Y-%m-%d)" > "$W/vault/admin/betterment/project_garden_leave.md"
  printf -- '---\ntype: project\n---\n\n## Next action\n- [ ] cut the pattern #skills 🆔 abc123\n' > "$W/vault/skills/sewing/project_sewing.md"
  TD="$W/vault/daily_notes/tasks"; NOTE="$TD/tasks_${TODAY}.md"
}
# A prior note in the shape the 06:00 job leaves it, with P's region in it.
mk_note() {
  local f="$TD/tasks_$1.md"; shift
  { printf -- '---\njournal: tasks\njournal-date: %s\nopen_tasks: 100\n---\n\n' "$(basename "$f" .md | sed 's/tasks_//')"
    printf '%s\n' "$@"
    printf '\n## Vault Agent\n\nreport\n'; } > "$f"
  ago_min "$f" 120
}
rollover() {
  HOME="$W/home" VAULT="$W/vault" STATE_DIR="$W/state" ROLLOVER_HOST=garm ROLLOVER_CLOCK_HHMM="${CLOCK:-00:05}" \
    ROLLOVER_TODAY="${RTODAY:-$TODAY}" /bin/bash "$HERE/tasks_rollover.sh" > "$W/rollover.out" 2>&1
}
daily() {
  rm -f "$W/reached"
  HOME="$W/home" VAULT="$W/vault" STATE_DIR="$W/state" LOG="$W/state/mbs_daily.log" TODAY="${RTODAY:-$TODAY}" \
    ROLLOVER_CLOCK_HHMM="${CLOCK:-06:00}" TASKS_NOTE_LOCK_WAIT_SECONDS="${LWAIT:-120}" HERE="$HERE" R="$T/daily_region.sh" M="$W/reached" \
    /bin/bash -c '
      set -uo pipefail
      export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
      ts() { date "+%Y-%m-%d %H:%M:%S"; }
      REAUTH_SENTINEL="$STATE_DIR/needs_reauth"
      source "$HERE/lib_auth.sh"; source "$HERE/lib_tasks_note.sh"
      trap "tasks_note_lock_release 2>/dev/null" EXIT
      . "$R"
      echo reached > "$M"
    ' > "$W/daily.out" 2>&1
}
RL() { echo "$W/state/tasks_rollover.log"; }
region() { awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{f=0;next} f{next} /^## /||/^# Archived/{exit} {print}' "$1"; }

echo "=== tasks_rollover_drill (bash $BASH_VERSION, awk $(command -v awk))"

case_ a "quiet note at 00:05: rolled, stamped, garden leave on top, no open_tasks"
new_world a
mk_note "$(dago 1)" "- [ ] buy milk" "- [ ] call the vet 🆔 aaa111" "- [x] done thing ✅ $(dago 1)" "loose line"
rollover
has "log says rolled ... completed successfully" "rolled tasks_$(dago 1) into tasks_${TODAY} at" "$(RL)"
has "the same line ends completed successfully" "completed successfully" "$(RL)"
eq "last_tasks_rollover line 1 is today" "$(head -1 "$W/state/last_tasks_rollover" 2>/dev/null)" "$TODAY"
case "$(sed -n 2p "$W/state/last_tasks_rollover" 2>/dev/null)" in *" by tasks-rollover") ok "line 2 names the rollover job" ;; *) bad "line 2: $(sed -n 2p "$W/state/last_tasks_rollover" 2>/dev/null)" ;; esac
eq "first body line is the garden leave heading" "$(awk 'NR>1&&/^---$/{f=1;next} f&&NF{print;exit}' "$NOTE" | cut -c1-17)" "### Garden leave:"
hasnt "no open_tasks in today's note" "open_tasks:" "$NOTE"
has "carried line present" "- [ ] call the vet 🆔 aaa111" "$NOTE"
eq "carried below the garden leave terminator" "$(awk '/<!-- \/garden-leave -->/{g=NR} /buy milk/{b=NR} END{print (g&&b>g)?"yes":"no"}' "$NOTE")" "yes"
eq "yesterday's region blanked" "$(region "$TD/tasks_$(dago 1).md" | grep -c '[^[:space:]]' | tr -d ' ')" "0"
has "ticked line archived in yesterday's note with its date" "- [x] done thing ✅ $(dago 1) 🔒 [[$(dago 1)]]" "$TD/tasks_$(dago 1).md"
[ -s "$W/state/triage_first_seen" ] && ok "triage first-seen recorded" || bad "no triage_first_seen"
[ -f "$W/state/tasks_rollover_tick" ] && ok "tick touched" || bad "no tick"

case_ d "a second run the same day: nothing"
S1="$(sum "$NOTE")"; S2="$(sum "$TD/tasks_$(dago 1).md")"; L1="$(wc -l < "$(RL)")"
rollover
eq "today unchanged" "$(sum "$NOTE")" "$S1"
eq "yesterday unchanged" "$(sum "$TD/tasks_$(dago 1).md")" "$S2"
eq "log unchanged" "$(wc -l < "$(RL)")" "$L1"

case_ e "the 06:00 run after a rollover: no double carry, residue below the block, open_tasks once"
# A phone still showing yesterday: P adds two lines to yesterday's region after the rollover.
awk 'NR==1{print;next} !d && /^---$/{print; print "- [ ] residue from the phone"; print "- [ ] second residue"; d=1; next} {print}' "$TD/tasks_$(dago 1).md" > "$W/x" && mv "$W/x" "$TD/tasks_$(dago 1).md"
ago_min "$TD/tasks_$(dago 1).md" 30
daily
has "daily log says the rollover was already done" "rollover: already done for ${TODAY} (" "$W/state/mbs_daily.log"
has "residue logged" "carry-forward: residue 2 line(s) from tasks_$(dago 1)" "$W/state/mbs_daily.log"
eq "main region not carried twice" "$(cnt 'buy milk' "$NOTE")" "1"
eq "residue directly below the garden leave terminator" "$(awk '/<!-- \/garden-leave -->/{g=NR} /residue from the phone/{r=NR} END{print (r>g && r<=g+2)?"yes":"no"}' "$NOTE")" "yes"
eq "residue above the primary region" "$(awk '/residue from the phone/{r=NR} /buy milk/{b=NR} END{print (r<b)?"yes":"no"}' "$NOTE")" "yes"
eq "open_tasks stamped once" "$(grep -c '^open_tasks:' "$NOTE" | tr -d ' ')" "1"
[ -f "$W/reached" ] && ok "region finished (the Claude ladder would run)" || bad "region did not finish: $(tail -3 "$W/daily.out")"
S1="$(sum "$NOTE")"; daily
eq "a second 06:00 grid fire changes nothing" "$(sum "$NOTE")" "$S1"

case_ b "note changed 3 minutes earlier: deferred, nothing written, one log line"
new_world b
mk_note "$(dago 1)" "- [ ] typing now"
ago_min "$TD/tasks_$(dago 1).md" 3
rollover; rollover
[ -f "$NOTE" ] && bad "today's note was created" || ok "today's note not created"
[ -f "$W/state/last_tasks_rollover" ] && bad "stamped" || ok "not stamped"
eq "one deferral line over two runs" "$(cnt 'rollover: deferred, tasks_' "$(RL)")" "1"
has "it names the minutes" "changed 3 min ago" "$(RL)"
hasnt "no completed successfully" "completed successfully" "$(RL)"

case_ c "after the deadline: rolled, the log says forced"
CLOCK=09:05 rollover
has "forced" "past ROLLOVER_FORCE_AFTER 09:00: quiet guard skipped, writing anyway (forced)" "$(RL)"
has "rolled" "completed successfully" "$(RL)"
has "carried" "- [ ] typing now" "$NOTE"

case_ f "the 06:00 run with no rollover"
new_world f1
mk_note "$(dago 1)" "- [ ] quiet item"
daily
eq "quiet note: the daily rolls and stamps the rollover" "$(head -1 "$W/state/last_tasks_rollover" 2>/dev/null)" "$TODAY"
case "$(sed -n 2p "$W/state/last_tasks_rollover")" in *"by mbs_daily (06:00 fallback: the rollover job is not running here)") ok "line 2 names the 06:00 fallback and why" ;; *) bad "line 2: $(sed -n 2p "$W/state/last_tasks_rollover")" ;; esac
has "daily log names it" "by mbs_daily (the rollover job is not running here)" "$W/state/mbs_daily.log"
eq "open_tasks stamped once" "$(grep -c '^open_tasks:' "$NOTE" | tr -d ' ')" "1"
has "carried" "- [ ] quiet item" "$NOTE"
[ -f "$W/reached" ] && ok "went on to the report" || bad "did not reach the report"
new_world f2
mk_note "$(dago 1)" "- [ ] busy item"
ago_min "$TD/tasks_$(dago 1).md" 2
CLOCK=06:00 daily
[ -f "$W/reached" ] && bad "active note: went on to the report" || ok "active note before the deadline: exits before the report (no daily stamp)"
[ -f "$NOTE" ] && bad "active note: today's note written" || ok "active note: nothing written"
has "says why" "is not quiet yet; not stamping" "$W/state/mbs_daily.log"
[ -d "$W/state/tasks_note.lock" ] && bad "note lock left behind" || ok "note lock released"

case_ g "a stale device restores yesterday's region after the rollover"
new_world g
mk_note "$(dago 1)" "- [ ] alpha task" "- [ ] beta task" "- [ ] gamma task"
cp "$TD/tasks_$(dago 1).md" "$W/orig"
rollover
cp "$W/orig" "$TD/tasks_$(dago 1).md"; ago_min "$TD/tasks_$(dago 1).md" 30
S2="$(sum "$TD/tasks_$(dago 1).md")"
daily
eq "yesterday left untouched" "$(sum "$TD/tasks_$(dago 1).md")" "$S2"
has "WARNING logged" "carry-forward: WARNING tasks_$(dago 1) holds 3 line(s), 3 already in today's list; left untouched" "$W/state/mbs_daily.log"
eq "one alert line" "$(cnt "Carry-forward left tasks_$(dago 1) untouched" "$NOTE")" "1"
daily
eq "a second run: still one alert line" "$(cnt "Carry-forward left tasks_$(dago 1) untouched" "$NOTE")" "1"
eq "alpha task once in today's region" "$(region "$NOTE" | grep -c 'alpha task' | tr -d ' ')" "1"

case_ h "an Archiver-made today note before the rollover"
new_world h
mk_note "$(dago 1)" "- [ ] region item one" "- [ ] region item two"
printf '# Archived\n\n- [x] archived early ✅ %s 🔒 [[%s]] 🕸️ tasks_%s\n' "$TODAY" "$TODAY" "$TODAY" > "$NOTE"
rollover
eq "frontmatter healed" "$(head -1 "$NOTE")" "---"
hasnt "without open_tasks" "open_tasks:" "$NOTE"
eq "P's region lands above # Archived" "$(awk '/region item one/{r=NR} /^# Archived/{a=NR} END{print (r&&r<a)?"yes":"no"}' "$NOTE")" "yes"
has "the archived line kept" "- [x] archived early" "$NOTE"
daily
eq "06:00 stamps open_tasks once" "$(grep -c '^open_tasks:' "$NOTE" | tr -d ' ')" "1"

case_ i "the note lock: the two jobs never write at once"
new_world i
mk_note "$(dago 1)" "- [ ] locked item"
sleep 300 & HOLDER_PID=$!
mkdir "$W/state/tasks_note.lock"; echo "$HOLDER_PID" > "$W/state/tasks_note.lock/pid"
rollover
[ -f "$NOTE" ] && bad "rollover wrote while the lock was held" || ok "rollover did not write while the lock was held"
has "rollover says the lock is held" "note lock: held by PID $HOLDER_PID" "$(RL)"
LWAIT=5 daily
[ -f "$NOTE" ] && bad "daily wrote while the lock was held" || ok "daily did not write while the lock was held"
[ -f "$W/reached" ] && bad "daily went on to the report" || ok "daily exits without the report (grid retries)"
kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""
rollover
has "a dead holder's lock is claimed" "note lock: stale (holder PID" "$(RL)"
has "then it rolls" "completed successfully" "$(RL)"
[ -d "$W/state/tasks_note.lock" ] && bad "lock left behind after the run" || ok "lock released after the run"

case_ j "macOS truth"
case "$BASH_VERSION" in 3.2*) ok "running under bash $BASH_VERSION" ;; *) bad "not bash 3.2 ($BASH_VERSION): run as /bin/bash scripts/tasks_rollover_drill.sh" ;; esac
eq "the jobs' PATH resolves awk to /usr/bin/awk" "$(PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" command -v awk)" "/usr/bin/awk"
/bin/bash -n "$HERE/tasks_rollover.sh" && /bin/bash -n "$HERE/lib_tasks_note.sh" && /bin/bash -n "$HERE/mbs_daily.sh" && ok "all three parse under /bin/bash" || bad "parse failure"

echo "=== carry rescue (6.4)"
case_ s1 "stranding: an Archiver-shaped primary with older notes holding regions"
new_world s1
mk_note "$(dago 3)" "- [ ] OLDEST line"
mk_note "$(dago 2)" "- [ ] OLDER line" "- [x] older ticked ✅ $(dago 2)"
printf '# Archived\n\n- [x] x ✅ %s 🔒 [[%s]] 🕸️ tasks_%s\n' "$(dago 1)" "$(dago 1)" "$(dago 1)" > "$TD/tasks_$(dago 1).md"; ago_min "$TD/tasks_$(dago 1).md" 60
rollover
has "rescued logged for the older one" "carry-forward: rescued 1 line(s) from tasks_$(dago 2)" "$(RL)"
has "rescued logged for the oldest one" "carry-forward: rescued 1 line(s) from tasks_$(dago 3)" "$(RL)"
eq "order: oldest first" "$(awk '/OLDEST line/{a=NR} /OLDER line/{b=NR} END{print (a&&b&&a<b)?"yes":"no"}' "$NOTE")" "yes"
eq "rescued lines below the garden leave block" "$(awk '/<!-- \/garden-leave -->/{g=NR} /OLDEST line/{a=NR} END{print (g&&a>g)?"yes":"no"}' "$NOTE")" "yes"
eq "older source blanked" "$(region "$TD/tasks_$(dago 2).md" | grep -c '[^[:space:]]' | tr -d ' ')" "0"
has "s4: rescued ticked line archived in its own note with its own date" "- [x] older ticked ✅ $(dago 2) 🔒 [[$(dago 2)]]" "$TD/tasks_$(dago 2).md"

case_ s1b "rescue order relative to a primary with content"
new_world s1b
mk_note "$(dago 3)" "- [ ] OLDEST line"
mk_note "$(dago 2)" "- [ ] OLDER line"
mk_note "$(dago 1)" "- [ ] PRIMARY line"
rollover
eq "order: oldest, older, primary" "$(awk '/OLDEST line/{a=NR} /OLDER line/{b=NR} /PRIMARY line/{c=NR} END{print (a<b && b<c)?"yes":"no"}' "$NOTE")" "yes"

case_ s2 "one overlapping checkbox line: untouched, WARNING, one alert"
new_world s2
mk_note "$(dago 2)" "- [x] shared task ✅ $(dago 2)" "- [ ] only in the old note"
mk_note "$(dago 1)" "- [ ] shared task" "- [ ] primary only"
S2="$(sum "$TD/tasks_$(dago 2).md")"
rollover
eq "old note untouched" "$(sum "$TD/tasks_$(dago 2).md")" "$S2"
has "WARNING" "carry-forward: WARNING tasks_$(dago 2) holds 2 line(s), 1 already in today's list; left untouched" "$(RL)"
eq "one alert line" "$(cnt "Carry-forward left tasks_$(dago 2) untouched" "$NOTE")" "1"
hasnt "nothing from the old note carried" "only in the old note" "$NOTE"
has "the rollover still completed" "completed successfully" "$(RL)"

case_ s3 "a 15-day-old note and a 2026-07-12 note are never touched"
new_world s3
mk_note "$(dago 15)" "- [ ] fifteen days old"
mk_note "2026-07-12" "- [ ] before the carry began"
mk_note "$(dago 1)" "- [ ] primary"
A="$(sum "$TD/tasks_$(dago 15).md")"; B="$(sum "$TD/tasks_2026-07-12.md")"
rollover
eq "15-day-old note untouched" "$(sum "$TD/tasks_$(dago 15).md")" "$A"
eq "2026-07-12 note untouched" "$(sum "$TD/tasks_2026-07-12.md")" "$B"
hasnt "neither carried" "fifteen days old" "$NOTE"
mk_note "$(dago 14)" "- [ ] fourteen days old"
rm -f "$W/state/last_tasks_rollover"; ago_min "$TD/tasks_$(dago 1).md" 60; rollover
has "control: a 14-day-old note IS rescued" "fourteen days old" "$NOTE"

case_ s5 "read-only dry run on a copy of the real daily_notes/tasks: zero rescues"
new_world s5
rm -rf "$TD"; cp -Rp "$REAL_VAULT/daily_notes/tasks" "$TD"
find "$TD" -name '*.md' -exec touch -t 202601010000 {} +
HOME="$W/home" VAULT="$W/vault" STATE_DIR="$W/state" ROLLOVER_CLOCK_HHMM=12:00 /bin/bash -c '
  ts() { date "+%Y-%m-%d %H:%M:%S"; }
  source "'"$HERE"'/lib_auth.sh"; source "'"$HERE"'/lib_tasks_note.sh"
  carry_rescue "$(date -v+1d +%Y-%m-%d)" "$VAULT/daily_notes/tasks" "$VAULT/daily_notes/tasks/tasks_$(date +%Y-%m-%d).md" "$STATE_DIR/s5.log" "$STATE_DIR"
' > "$W/s5.out" 2>&1
# Tomorrow's view: the primary is today's live note, every older one in the
# lookback is a rescue candidate. Today's note stands in for "today's list".
S5L="$(grep 'rescue looked at' "$W/state/s5.log" 2>/dev/null)"
echo "       (s5: ${S5L#* - })"
case "$S5L" in *"rescue looked at "[1-9]*"rescued 0") ok "the rescue looked at the real older notes and rescued none" ;; *) bad "s5 summary: ${S5L:-none}" ;; esac
eq "zero rescued lines" "$(cnt 'carry-forward: rescued' "$W/state/s5.log")" "0"
eq "zero warnings" "$(cnt 'WARNING' "$W/state/s5.log")" "0"

case_ k "old versus new on real note pairs from garm's vault git"
if [ "${NO_REAL:-0}" = 1 ]; then
  bad "case k skipped by NO_REAL=1: the identity proof did not run"
else
  git -C "$REPO" show "$BASE:scripts/mbs_daily.sh" > "$T/base_daily.sh" || bad "git show $BASE"
  BS="$(grep -n '^# --- carry-forward: pull' "$T/base_daily.sh" | cut -d: -f1)"
  BE="$(grep -n '^# Headless run. NOTE' "$T/base_daily.sh" | cut -d: -f1)"
  sed -n "${BS},$((BE - 1))p" "$T/base_daily.sh" > "$T/base_region.sh"
  # The baseline must honour the sandbox: it reads only VAULT, STATE_DIR, LOG, TODAY.
  if grep -qE '/Users/cpreston|\$HOME' "$T/base_region.sh"; then bad "baseline region names a real path"; else ok "baseline region uses only the sandbox variables"; fi
  for pair in "2026-10-13 2026-10-14 70ea064d" "2026-10-14 2026-10-15 bf566f00" "2026-10-15 2026-10-16 7cb14f10"; do
    set -- $pair; P="$1"; D="$2"; C="$3"
    for side in base new; do
      W="$T/k_${D}_$side"; rm -rf "$W"; mkdir -p "$W/vault" "$W/state" "$W/home/.mbs_automation"
      ssh -o BatchMode=yes garm "cd ~/Vaults/storage_mbs && git archive $C daily_notes/tasks admin/betterment/project_garden_leave.md skills/sewing/project_sewing.md skills/kintsugi/project_kintsugi.md skills/mahjong/project_mahjong.md skills/backgammon/project_backgammon_rating.md create/ch8/project_two_songs.md create/oslo/project_oslo_first_submission.md" 2>/dev/null | tar -x -C "$W/vault" 2>/dev/null
      find "$W/vault/daily_notes/tasks" -name '*.md' -exec touch -t 202601010000 {} +
    done
    [ -f "$T/k_${D}_base/vault/daily_notes/tasks/tasks_${P}.md" ] || { bad "pair $P/$D: could not read $C from garm"; continue; }
    KR="$(region "$T/k_${D}_base/vault/daily_notes/tasks/tasks_${P}.md" | grep -c '[^[:space:]]' | tr -d ' ')"
    [ "$KR" -gt 0 ] && ok "pair $P/$D: the real source holds a region ($KR non-blank lines), so the comparison has something to carry" || bad "pair $P/$D: empty source region proves nothing"
    [ -f "$T/k_${D}_base/vault/daily_notes/tasks/tasks_${D}.md" ] && echo "       (pair $P/$D: tasks_${D} already existed at $C)"
    # Baseline 06:00 pre-flight; count_open_tasks returns the same figure both sides.
    W="$T/k_${D}_base"
    VAULT="$W/vault" STATE_DIR="$W/state" LOG="$W/state/mbs_daily.log" TODAY="$D" R="$T/base_region.sh" /bin/bash -c '
      set -uo pipefail; ts() { date "+%Y-%m-%d %H:%M:%S"; }
      . "$R"' > "$W/out" 2>&1
    W="$T/k_${D}_new"
    CLOCK=00:05 RTODAY="$D" rollover
    TN="$W/vault/daily_notes/tasks/tasks_${D}.md"; TB="$T/k_${D}_base/vault/daily_notes/tasks/tasks_${D}.md"
    grep -v '^open_tasks:' "$TB" > "$T/k_base_noot"
    if cmp -s "$TN" "$T/k_base_noot"; then ok "pair $P/$D: rolled note equals the baseline's 06:00 output apart from open_tasks"; else bad "pair $P/$D: rolled note differs: $(diff "$T/k_base_noot" "$TN" | head -5 | tr '\n' '|')"; fi
    RTODAY="$D" CLOCK=06:00 daily
    if cmp -s "$TN" "$TB"; then ok "pair $P/$D: after the 06:00 run, today's note is byte-identical to the baseline's"; else bad "pair $P/$D: after 06:00 differs: $(diff "$TB" "$TN" | head -5 | tr '\n' '|')"; fi
    if cmp -s "$W/vault/daily_notes/tasks/tasks_${P}.md" "$T/k_${D}_base/vault/daily_notes/tasks/tasks_${P}.md"; then ok "pair $P/$D: blanked source byte-identical"; else bad "pair $P/$D: source differs"; fi
    eq "pair $P/$D: open_tasks value equal" "$(grep '^open_tasks:' "$TN")" "$(grep '^open_tasks:' "$TB")"
    eq "pair $P/$D: same set of notes" "$(ls "$W/vault/daily_notes/tasks" | cksum)" "$(ls "$T/k_${D}_base/vault/daily_notes/tasks" | cksum)"
    hasnt "pair $P/$D: no rescue on real history" "carry-forward: rescued" "$(RL)"
  done
fi

echo "=== isolation"
eq "real tasks folder and real state untouched (ls -lT checksum)" "$(snap)" "$SNAP0"

echo
EXPECT=" a d e b c f g h i j s1 s1b s2 s3 s5 k"
eq "case list" "$CASES" "$EXPECT"
echo "tasks_rollover_drill: $PASS passed, $FAIL failed, cases:$CASES"
[ "$FAIL" -eq 0 ]
