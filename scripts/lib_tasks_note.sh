#!/bin/bash
# lib_tasks_note.sh - everything that makes or rewrites the daily tasks note.
#
# Moved out of mbs_daily.sh on 2026-10-16 (brief_daily_note_garm_fixes, 3.0) so
# that ONE code path serves both writers: com.mbs.tasks-rollover
# (scripts/tasks_rollover.sh, every 5 minutes on garm, rolls the note over just
# after midnight) and mbs_daily.sh (06:00 grid, the fallback when the rollover
# has not run, then the residue pass, the rescue and the open_tasks snapshot).
# The functions above the rollover section are the pre-2026-10-16 code, moved
# verbatim except where a comment dated 2026-10-16 says otherwise.
#
# Sourced, never executed. Callers define ts() and set VAULT; carry_extra_source
# calls alert_tasks_note from lib_auth.sh, so source that first.
# macOS bash 3.2 and BSD awk/sed/find/xargs; no date -v / date -d in the note
# logic. Drill: scripts/tasks_rollover_drill.sh.

# --- carry-forward: pull yesterday's above-Vault-Agent region into today ------
# Moves the region above the first "## Vault Agent" heading from the most-recent
# prior tasks note into today's note (verbatim, minus resolved - [x] / - [-]
# lines, which are archived in the source since 2026-10-15) and blanks that
# region in the source. Runs after the skeleton pre-flight
# below and before the claude -p call, so the morning report sees the carried
# tasks. Deterministic and idempotent: blanking the source means a launchd retry
# on the same day finds nothing to carry. Never touches the "## Vault Agent"
# section, the sibling agent sections, or "# Archived" - only P's own region.
# Work-session blocks (2026-08-02, P's top-of-note placement decision): a
# "### Work session" heading through its "<!-- /work-session -->" terminator is
# the on-demand /obsidian-work-session command's own of-the-moment section. It
# NEVER carries forward (stateless-by-design); it is routed into the preserved
# tail instead, so it stays readable in its own day's note above "## Vault
# Agent" rather than being destroyed or ratcheting into tomorrow.
# Garden-leave blocks (2026-10-12) are routed the same way: "### Garden leave"
# through "<!-- /garden-leave -->" is the per-day record write_garden_leave_block
# puts at the top of the note; it stays in its own day's note, never carries.
# Machine-written "## " sections (2026-08-19, same principle generalized): any
# sibling job that appends its own section to the tasks note BEFORE the daily
# report has written "## Vault Agent" that day (or on a day the report never
# runs at all: 401, no network) lands its section inside P's region, and every
# following morning sweeps it forward with his real open items. Observed:
# "## Oslo - Weekly Stale-Drafts (2026-08-17)" and "## ⚠️ Automation alerts"
# both rode 08-17 -> 08-18 -> 08-19, the Oslo one twice. Fix: the carry boundary
# is now ANY level-2 heading, not just "## Vault Agent". Everything from the
# first "## " onward is preserved in its own day's note, exactly like a
# work-session block, and nothing machine-written ratchets into tomorrow.
# This is a structural rule, not a registry of known job headings, so a job
# added later inherits it. Justification, empirical (2026-08-19, scan of all 97
# tasks notes): every "## " heading that has ever appeared in this journal is
# machine-written (Vault Agent + its skipped/car-sweep variants, Oslo weekly and
# monthly, Automation alerts, Web Watchers, Weekly review, The Record). P's own
# region is plain lines, bullets and checkboxes, never a heading.
# Known tradeoff, accepted: a line P types BELOW a banner on a broken morning
# does not carry. It is preserved in that day's note, not lost, and the log line
# below names every section left behind, which is where to look for it. Fixing
# that properly needs each writer to emit a terminator the way
# /obsidian-work-session emits "<!-- /work-session -->"; not done here because
# one of the writers (com.mbs.oslo-weekly) lives in ~/dev/oslo, out of scope.
#
# 2026-10-16: split into pieces so the midnight rollover (tasks_rollover.sh),
# the 06:00 fallback, the residue pass and the rescue all move a region the same
# way. The primary carry below is the pre-2026-10-16 code path, unchanged in
# effect: on a quiet note its output is byte-identical to d6b9312's (proven by
# scripts/tasks_rollover_drill.sh case k on copies of real note pairs).

# _carry_split SRC_FILE SRC_DATE TMP: the splitter, verbatim from the original
# function. Writes $TMP/fm, carry, tail, machine (maybe), done (maybe).
_carry_split() {
  local prior_file="$1" prior_date="$2" tmp="$3"
  # Split prior note: fm (frontmatter) / carry (region, resolved lines dropped) /
  # tail (first boundary heading onward, plus any work-session block above it).
  # Boundary = the first level-2 heading of any kind, which on a healthy day is
  # "## Vault Agent"; a "# Archived" also stops carry as a fallback for notes
  # with no agent section. machf collects the machine headings that sat ABOVE
  # "## Vault Agent", i.e. the ones this fix stops sweeping forward, for the log.
  # Ticked lines (2026-10-15, P: "unacceptable" that they vanished). A resolved
  # - [x] / - [-] line in P's region, with its indented children, is no longer
  # dropped: it goes to donef with the Archiver's own metadata (lock + date +
  # spider + heading chain, the format task-archiver writes on Cmd+A), stamped
  # with the PRIOR note's date, and is appended to that note's "# Archived"
  # section below. Same morning, the archived-comment sweep (obsidian-daily.md
  # step 3d) reads exactly those lines. Lines P already archived with Cmd+A are
  # under "# Archived" in the tail and are not touched again.
  awk -v carryf="$tmp/carry" -v tailf="$tmp/tail" -v fmf="$tmp/fm" -v machf="$tmp/machine" \
      -v donef="$tmp/done" -v stamp="🔒 [[$prior_date]] 🕸️" -v chain0="tasks_$prior_date" '
    BEGIN{ inbody=0; intail=0; fmc=0; ws=0; gl=0; dind=-1; chain=chain0 }
    { if (NR==1 && $0!="---") inbody=1
      if (!inbody){ print >> fmf; if($0=="---"){fmc++; if(fmc==2)inbody=1} next }
      if (!intail && ($0 ~ /^## / || $0 ~ /^# Archived/)) { intail=1; ws=0; gl=0; dind=-1 }
      if (intail){
        if ($0 ~ /^## Vault Agent/) va=1
        if (!va && $0 ~ /^## / && $0 !~ /^## Vault Agent/) print >> machf
        print >> tailf; next }
      if (!ws && !gl && $0 ~ /^### Work session/) { ws=1; dind=-1 }
      if (ws){ print >> tailf; if ($0 ~ /<!-- \/work-session -->/) ws=0; next }
      if (!gl && $0 ~ /^### Garden leave/) { gl=1; dind=-1 }
      if (gl){ print >> tailf; if ($0 ~ /<!-- \/garden-leave -->/) gl=0; next }
      if (dind >= 0) {
        if ($0 ~ /^[ \t]*$/) dind=-1
        else { match($0, /^[ \t]*/)
               if (RLENGTH > dind) { print substr($0, dind+1) >> donef; next }
               dind=-1 } }
      if ($0 ~ /^[[:space:]]*- \[[xX-]\]$/) next
      if ($0 ~ /^[[:space:]]*- \[[xX-]\][[:space:]]/) {
        match($0, /^[ \t]*/); dind=RLENGTH
        line=substr($0, dind+1); sub(/[ \t]+$/, "", line)
        print line " " stamp " " chain >> donef; next }
      if ($0 ~ /^#+ /) { chain=$0; sub(/^#+ +/, "", chain) }
      print >> carryf }' "$prior_file"
  [ -f "$tmp/fm" ] || : > "$tmp/fm"; [ -f "$tmp/carry" ] || : > "$tmp/carry"
  [ -f "$tmp/tail" ] || : > "$tmp/tail"; [ -f "$tmp/done" ] || : > "$tmp/done"
}

# _carry_build_source TMP: the blanked source, verbatim from the original
# function. Tail with the ticked lines appended to the end of its "# Archived"
# section (or a new "# Archived" section at the end when the note has none),
# then frontmatter + 3-line writing gap + tail, into $TMP/prior.
_carry_build_source() {
  local tmp="$1"
  if [ -s "$tmp/done" ]; then
    awk -v donef="$tmp/done" '
      { L[++n]=$0 }
      END{ a=0; for(i=1;i<=n;i++) if (L[i] ~ /^# Archived/) { a=i; break }
        if (!a) {
          last=0; for(i=1;i<=n;i++) if (L[i] ~ /[^ \t]/) last=i
          for(i=1;i<=last;i++) print L[i]
          if (last) print ""
          print "# Archived"; print ""
          while ((getline d < donef) > 0) print d
          exit }
        e=n; for(i=a+1;i<=n;i++) if (L[i] ~ /^# / || L[i] ~ /^## /) { e=i-1; break }
        last=a; for(i=a+1;i<=e;i++) if (L[i] ~ /[^ \t]/) last=i
        for(i=1;i<=last;i++) print L[i]
        if (last==a) print ""
        while ((getline d < donef) > 0) print d
        if (e < n) print ""
        for(i=last+1;i<=n;i++) if (i > e || L[i] ~ /[^ \t]/) print L[i] }' \
      "$tmp/tail" > "$tmp/tail2" && mv "$tmp/tail2" "$tmp/tail"
  fi
  { cat "$tmp/fm"; printf '\n\n\n'; cat "$tmp/tail"; } > "$tmp/prior"
}

# _carry_insert TODAY_FILE CARRY_FILE OUT: today's note with CARRY_FILE inserted.
# Insert point (2026-10-16): directly below the garden leave block's terminator
# when today's note already holds one (a residue or rescue pass after the
# rollover wrote the block); otherwise directly after the frontmatter, which is
# the original behaviour, and the block is then written above the carried
# lines. A blank line goes before the inserted lines either way.
_carry_insert() {
  local today_file="$1" carryf="$2" out="$3" glt=0
  grep -qF '<!-- /garden-leave -->' "$today_file" && glt=1
  awk -v carryf="$carryf" -v glt="$glt" '
    BEGIN{ fmc=0; inbody=0; pc=0 }
    { if(!inbody){ print; if($0=="---"){fmc++; if(fmc==2)inbody=1} next }
      if(glt){ print; if(!pc && $0 ~ /<!-- \/garden-leave -->/){ print ""; while((getline l < carryf)>0) print l; close(carryf); pc=1 } next }
      if(!pc){ print ""; while((getline l < carryf)>0) print l; close(carryf); pc=1 }
      print }
    END{ if(!pc){ print ""; while((getline l < carryf)>0) print l; close(carryf) } }' \
    "$today_file" > "$out"
}

# Latest tasks note dated before $1 in $2, as a date, or empty.
tasks_prior_date() {
  ls "$2"/tasks_*.md 2>/dev/null \
    | grep -oE 'tasks_[0-9]{4}-[0-9]{2}-[0-9]{2}\.md' \
    | sed -E 's/tasks_(.*)\.md/\1/' \
    | awk -v t="$1" '$0 < t' | sort | tail -1
}

carry_forward_prior_tasks() {
  local today="$1" tasks_dir="$2" today_file="$3" log="$4"
  local prior_date prior_file
  prior_date="$(tasks_prior_date "$today" "$tasks_dir")"
  [ -z "$prior_date" ] && { echo "$(ts) - carry-forward: no prior note, skip" >> "$log"; return 0; }
  prior_file="$tasks_dir/tasks_${prior_date}.md"
  [ -f "$today_file" ] || { echo "$(ts) - carry-forward: today file missing, skip" >> "$log"; return 0; }
  # Temp dir inside the tasks folder so the final mv is same-filesystem (atomic).
  local tmp; tmp="$(mktemp -d "${tasks_dir}/.carry.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  _carry_split "$prior_file" "$prior_date" "$tmp"
  local has_carry=0 n_done
  grep -q '[^[:space:]]' "$tmp/carry" && has_carry=1
  n_done="$(grep -c '🔒' "$tmp/done" | tr -d ' ')"
  if [ "$has_carry" -eq 0 ] && [ ! -s "$tmp/done" ]; then
    echo "$(ts) - carry-forward: empty region, skip" >> "$log"; return 0
  fi
  _carry_build_source "$tmp"
  # Today = today frontmatter + carried region + today's existing body (prepend).
  [ "$has_carry" -eq 1 ] && _carry_insert "$today_file" "$tmp/carry" "$tmp/today"
  [ "$has_carry" -eq 1 ] && mv "$tmp/today" "$today_file"
  mv "$tmp/prior" "$prior_file"
  if [ "$has_carry" -eq 1 ]; then
    echo "$(ts) - carry-forward: moved $prior_date region into $today, blanked source" >> "$log"
  else
    echo "$(ts) - carry-forward: nothing open to carry from $prior_date" >> "$log"
  fi
  [ -s "$tmp/done" ] && echo "$(ts) - carry-forward: archived ${n_done} ticked line(s) into $prior_date # Archived" >> "$log"
  # Name every machine-written section left behind, so an unexpected one (P
  # starting a "## " heading of his own) is visible here rather than silent.
  if [ -s "$tmp/machine" ]; then
    echo "$(ts) - carry-forward: left $(wc -l < "$tmp/machine" | tr -d ' ') machine-written section(s) in $prior_date: $(tr '\n' '|' < "$tmp/machine")" >> "$log"
  fi
}

# --- triage first-seen state (project_task_triage phase 1, 2026-08-01) --------
# Records the date each open line in P's region was first seen, so the claude
# triage step (obsidian-daily.md step 3c) can age errands with 14-day staleness
# flags. Runs AFTER carry-forward, so resolved [x]/[-] lines never enter the
# state. It stops at the first level-2 heading, the same boundary the
# carry-forward splitter uses, so an alert bullet a sibling job wrote into
# today's note before the report landed is never aged as one of P's errands
# (2026-08-19; previously it stopped only at "## Vault Agent"). Work-session
# and garden-leave blocks are skipped for the same reason (2026-10-12 for the
# latter): machine-written, never P's errands.
# Format: YYYY-MM-DD<TAB>normalized line text; append-only, deduped on
# the exact line text (an edited line is a new identity and restarts its age;
# accepted). Pure bash/BSD, no network, bash-3.2 safe (no arrays needed).
update_triage_first_seen() {
  local today="$1" today_file="$2" state="$3" log="$4"
  [ -f "$today_file" ] || return 0
  local tmp tab added=0 line
  tmp="$(mktemp)"; tab="$(printf '\t')"
  awk 'NR==1 && $0=="---" {fm=1; next}
       fm==1 {if ($0=="---") fm=0; next}
       /^## / || /^# Archived/ {exit}
       /^### Work session/ {ws=1}
       ws==1 {if ($0 ~ /<!-- \/work-session -->/) ws=0; next}
       /^### Garden leave/ {gl=1}
       gl==1 {if ($0 ~ /<!-- \/garden-leave -->/) gl=0; next}
       {print}' "$today_file" \
    | sed -E 's/^[[:space:]]*- \[[ xX-]\][[:space:]]*//; s/^[[:space:]]*-[[:space:]]+//; s/[[:space:]]+/ /g; s/^ //; s/ $//' \
    | grep -v '^$' | sort -u > "$tmp"
  touch "$state"
  while IFS= read -r line; do
    grep -qF "${tab}${line}" "$state" || { printf '%s\t%s\n' "$today" "$line" >> "$state"; added=$((added + 1)); }
  done < "$tmp"
  rm -f "$tmp"
  echo "$(ts) - triage first-seen: recorded $added new line(s)" >> "$log"
}

# --- garden leave daily block (2026-10-12) -----------------------------------
# P's garden leave program (admin/betterment/project_garden_leave.md, read it):
# six skill goals with a Dec 13 test each, and seven things he does every day.
# This writes the day's record at the TOP of today's tasks note, after the
# carry-forward has prepended his region and before the claude call:
#
#   ### Garden leave: day N of T, Ddd YYYY-MM-DD (L days to <end>)
#   - [ ] read #leave/read                       (seven boxes, one tag each)
#   - skill advanced today, tick each one that moved:
#       - [ ] shirt #leave/skill/shirt
#           - next: <first unchecked box of that skill's project file>
#   - at the houses, open #at/ boxes: <count and top 3 per place>
#   <!-- /garden-leave -->
#
# Why the top of the note and not a "## " section: his region is 600 lines on
# a normal day and a "## " section lands below it, where he would never scroll
# on the phone. The block is a level-3 heading with a terminator, so the
# carry-forward routes it into its own day's preserved tail exactly like a
# work-session block (it never rides into tomorrow, and yesterday's ticks stay
# in yesterday's note), update_triage_first_seen skips it, and the claude
# triage step is told not to classify it (obsidian-daily.md step 3c). The
# dashboard (admin/betterment/dashboard_garden_leave.md) counts the ticks by
# tag and done date. Heartbeat check 37 reports a morning the report landed
# without this block.
#
# Roster, window and labels come from the program note's frontmatter, so P can
# change the skills or the end date in Obsidian without touching this script:
#   gl_start: YYYY-MM-DD        gl_end: YYYY-MM-DD
#   gl_skills: [shirt, kintsugi, ...]      gl_skill_<name>: <vault-relative path>
#   gl_label_<name>: <display label>       (optional; defaults to the name)
# Idempotent: a note that already holds the terminator is left alone, so the
# 30-minute retry grid never writes a second block. Outside the window, or with
# the program note missing, it logs one line and does nothing. No network.
# Written for macOS bash 3.2 and BSD awk/sed/find/xargs; no date -v / date -d
# (the day arithmetic is the civil-to-days formula in awk so the same code
# runs under GNU tools in a test VM).

# Day number of YYYY-MM-DD (days since 1970-01-01), pure awk, no date binary.
gl_daynum() {
  printf '%s\n' "$1" | awk -F- '{
    y=$1+0; m=$2+0; d=$3+0
    if (m<=2) y--
    era=int(y/400); yoe=y-era*400
    mp=(m>2)?m-3:m+9
    doy=int((153*mp+2)/5)+d-1
    doe=yoe*365+int(yoe/4)-int(yoe/100)+doy
    print era*146097+doe-719468 }'
}

# One frontmatter scalar from a note: gl_fm_get <file> <key>. Strips quotes.
gl_fm_get() {
  awk 'NR==1 && $0!="---"{exit} NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$1" \
    | sed -n "s/^$2:[[:space:]]*//p" | head -1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" | tr -d '\r'
}

# The first unchecked "- [ ]" line of a note, as P would read it in the block:
# checkbox and tags removed, the 🆔 id kept in parentheses, a 📅 date kept as
# "due <date>", scheduled/start/created/recurrence fields dropped, long lines
# cut at a word boundary. Emoji are matched as literal byte strings, never in a
# character class, so this works under launchd's C locale as well as UTF-8.
# Angle brackets are dropped from every copied line (here and in gl_at_place):
# Obsidian reads a bare <word> as an unclosed HTML tag, and Live Preview then
# stops rendering the rest of the block as checkboxes (2026-10-14).
gl_next_action() {
  local f="$1"
  [ -f "$f" ] || { printf 'project file not found: %s' "$f"; return 0; }
  local line
  line="$(awk 'NR==1 && $0=="---"{fm=1; next} fm==1{ if ($0 ~ /^---[[:space:]]*$/) fm=0; next }
               /^[[:space:]]*- \[ \][[:space:]]/{print; exit}' "$f")"
  [ -n "$line" ] || { printf 'no open box in %s: write one' "$(basename "$f" .md)"; return 0; }
  printf '%s\n' "$line" \
    | sed -E 's/^[[:space:]]*- \[ \][[:space:]]*//' \
    | sed -E 's/🆔 ([A-Za-z0-9_-]+)/(\1)/g; s/📅 ([0-9]{4}-[0-9]{2}-[0-9]{2})/due \1/g' \
    | sed -E 's/ ?(⏳|🛫|➕|✅) ?[0-9-]*//g; s/ ?🔁 [^#(]*//g' \
    | sed -E 's/\[\[([^]|]*\|)?([^]]*)\]\]/\2/g; s/\[[a-zA-Z_]+:: ?[^]]*\]//g; s/#[^[:space:]]+//g; s/[<>]//g; s/[[:space:]]+/ /g; s/^ //; s/ $//' \
    | awk '{ if (length($0) > 200) { out=""; for (i=1; i<=NF; i++) { if (length(out " " $i) > 190) break; out=(out=="" ? $i : out " " $i) } print out " ..." } else print }'
}

# Open "- [ ]" lines carrying #at/<place>: the whole vault with the same
# exclusion set as count_open_tasks plus _corpora and oura/raw (opaque and
# historical trees), and daily_notes/ excluded for the same reason it is there
# (the Vault Agent proposals quote #at/ tags in their own boxes), plus P's own
# region of today's note read separately (everything above the first "## "),
# which is where his loose #at/ lines live. Printed as "<count>" then up to
# three stripped texts, one per line; wikilinks are reduced to their display
# text so a truncated line never carries a broken [[...
gl_at_place() {
  local vault="$1" place="$2" today_file="$3" tmp
  tmp="$(mktemp)"
  { find "$vault" -type d \( -name trash -o -name .obsidian -o -name .git -o -name daily_notes \
        -o -name _archive -o -name _logs -o -name _corpora -o -path '*/oura/raw' \) -prune \
      -o -type f -name '*.md' ! -name 'pn.md' -print0 2>/dev/null \
      | xargs -0 grep -hE "^[[:space:]]*- \[ \][[:space:]].*#at/${place}([^A-Za-z0-9_/]|\$)" /dev/null 2>/dev/null
    [ -f "$today_file" ] && awk '/^## / || /^# Archived/ {exit} {print}' "$today_file" \
      | grep -E "^[[:space:]]*- \[ \][[:space:]].*#at/${place}([^A-Za-z0-9_/]|\$)" 2>/dev/null
  } | sed -E 's/^[[:space:]]*- \[ \][[:space:]]*//; s/🆔 [A-Za-z0-9_-]+//g; s/📅 [0-9-]+//g; s/ ?(⏳|🛫|➕|✅) ?[0-9-]*//g; s/\[\[([^]|]*\|)?([^]]*)\]\]/\2/g; s/\[[a-zA-Z_]+:: ?[^]]*\]//g; s/#[^[:space:]]+//g; s/[<>]//g; s/[[:space:]]+/ /g; s/^ //; s/ $//' \
    | grep -v '^$' | sort -u > "$tmp"
  wc -l < "$tmp" | tr -d ' '
  head -3 "$tmp" | awk '{ if (length($0) > 70) print substr($0, 1, 67) "..."; else print }'
  rm -f "$tmp"
}

write_garden_leave_block() {
  local today="$1" today_file="$2" vault="$3" log="$4"
  local prog="$vault/admin/betterment/project_garden_leave.md"
  [ -f "$today_file" ] || { echo "$(ts) - garden-leave: today file missing, skip" >> "$log"; return 0; }
  [ -f "$prog" ] || { echo "$(ts) - garden-leave: program note missing ($prog), skip" >> "$log"; return 0; }
  if grep -qF '<!-- /garden-leave -->' "$today_file"; then
    echo "$(ts) - garden-leave: block already present in $(basename "$today_file"), left as is" >> "$log"
    return 0
  fi
  local start end
  start="$(gl_fm_get "$prog" gl_start)"; end="$(gl_fm_get "$prog" gl_end)"
  case "$start" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *)
    echo "$(ts) - garden-leave: gl_start unreadable in program note ('${start}'), skip" >> "$log"; return 0 ;; esac
  case "$end" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *)
    echo "$(ts) - garden-leave: gl_end unreadable in program note ('${end}'), skip" >> "$log"; return 0 ;; esac
  if [ "$today" \< "$start" ] || [ "$today" \> "$end" ]; then
    echo "$(ts) - garden-leave: $today is outside the window $start to $end, skip" >> "$log"; return 0
  fi
  local d_start d_end d_today day total left dow
  d_start="$(gl_daynum "$start")"; d_end="$(gl_daynum "$end")"; d_today="$(gl_daynum "$today")"
  day=$((d_today - d_start + 1)); total=$((d_end - d_start + 1)); left=$((d_end - d_today))
  # 1970-01-01 was a Thursday, so the weekday is the day number mod 7 from Thu.
  dow="$(printf '%s\n' "$d_today" | awk '{ split("Thu Fri Sat Sun Mon Tue Wed", n, " "); print n[($1 % 7) + 1] }')"
  local skills s label path next
  skills="$(gl_fm_get "$prog" gl_skills | sed -e 's/^\[//' -e 's/\]$//' | tr ',' ' ')"
  [ -n "$skills" ] || { echo "$(ts) - garden-leave: gl_skills empty in program note, skip" >> "$log"; return 0; }
  local tab tmp; tab="$(printf '\t')"
  tmp="$(mktemp -d "$(dirname "$today_file")/.gl.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  {
    printf '### Garden leave: day %s of %s, %s %s (%s days to %s)\n' "$day" "$total" "$dow" "$today" "$left" "$end"
    printf -- '- [ ] read #leave/read\n'
    printf -- '- [ ] admin (the admin set in [[project_garden_leave]]) #leave/admin\n'
    printf -- '- [ ] exercise (stretch and strength, not sport) #leave/exercise\n'
    printf -- '- [ ] fix something at the house (add the place tag when you tick) #leave/fix\n'
    printf -- '- skill advanced today, tick each one that moved:\n'
    for s in $skills; do
      label="$(gl_fm_get "$prog" "gl_label_$s")"; [ -n "$label" ] || label="$s"
      path="$(gl_fm_get "$prog" "gl_skill_$s")"
      printf -- '%s- [ ] %s #leave/skill/%s\n' "$tab" "$label" "$s"
      if [ -n "$path" ]; then
        next="$(gl_next_action "$vault/$path")"
        printf -- '%s%s- next: %s [[%s]]\n' "$tab" "$tab" "$next" "$(basename "$path" .md)"
      else
        printf -- '%s%s- next: no gl_skill_%s path in [[project_garden_leave]]\n' "$tab" "$tab" "$s"
      fi
    done
    printf -- '- [ ] sport, or sport prep (write which) #leave/sport\n'
    printf -- '- [ ] relax with Madi #leave/madi\n'
    local place n lines summary=""
    for place in new_canaan collinsville montreal toronto; do
      lines="$(gl_at_place "$vault" "$place" "$today_file")"
      n="$(printf '%s\n' "$lines" | head -1)"
      summary="${summary}${summary:+, }${place} ${n}"
      printf '%s\n' "$lines" | tail -n +2 | awk -v p="$place" -v t="$tab" 'NF { printf "%s- %s: %s\n", t, p, $0 }' > "$tmp/at_$place"
    done
    printf -- '- at the houses, open #at/ boxes ([[dashboard_places]]): %s\n' "$summary"
    for place in new_canaan collinsville montreal toronto; do cat "$tmp/at_$place"; done
    printf '<!-- /garden-leave -->\n'
  } > "$tmp/block"
  # Insert after the frontmatter, above the carried region; a note with no
  # frontmatter (should not happen after ensure_tasks_frontmatter) gets it at line 1.
  awk -v blockf="$tmp/block" '
    BEGIN{ fmc=0; inbody=0; pc=0 }
    { if (NR==1 && $0!="---") inbody=1
      if(!inbody){ print; if($0=="---"){fmc++; if(fmc==2)inbody=1} next }
      if(!pc){ print ""; while((getline l < blockf)>0) print l; close(blockf); pc=1 }
      print }
    END{ if(!pc){ print ""; while((getline l < blockf)>0) print l; close(blockf) } }' \
    "$today_file" > "$tmp/today" && mv "$tmp/today" "$today_file"
  echo "$(ts) - garden-leave: wrote day $day of $total block into $(basename "$today_file") (skills: $(echo $skills | tr ' ' ','); at-houses: $summary)" >> "$log"
}

# --- open_tasks frontmatter stamp (P decision 2026-08-07) ---------------------
# Counts every unchecked "- [ ]" checkbox in the vault and writes it into
# today's tasks note frontmatter as `open_tasks:`. Deliberately a MORNING
# SNAPSHOT, not a live gauge: the value is written once, at note creation, and
# is never refreshed later in the day (P: "static, morning snapshot only").
#
# Counting rules, all P-chosen after an empirical scan on 2026-08-07 (1531):
#   - open = "- [ ]" only. "- [/]" in progress and "- [-]" cancelled do not count.
#   - every unchecked box counts, with or without a Tasks-plugin 🆔.
#   - excluded trees: trash/ and admin/pn.md (opaque by hard rule), _archive/
#     and _logs/ (ranked historical by the search-tier rule), daily_notes/
#     (the carry-forward region duplicates lines that also live at source, so
#     counting it would inflate and would make the note count itself),
#     plus .obsidian/ and .git/.
# The /dev/null argument to grep is load-bearing: BSD xargs still runs the
# command once when the input is empty, and grep with no file argument would
# then block reading stdin. Written for macOS bash 3.2 and BSD find/xargs/grep.
count_open_tasks() {
  local vault="$1"
  find "$vault" -type d \( -name trash -o -name .obsidian -o -name .git \
      -o -name _archive -o -name _logs -o -name daily_notes \) -prune \
    -o -type f -name '*.md' ! -name 'pn.md' -print0 2>/dev/null \
    | xargs -0 grep -hE '^[[:space:]]*- \[ \][[:space:]]' /dev/null 2>/dev/null \
    | wc -l | tr -d ' '
}

# Insert `open_tasks: <count>` into a tasks note's frontmatter, directly after
# journal-date. Idempotent and non-destructive: if the field is already there
# (a same-day retry, or P edited it) the value is left alone, which is what
# "static snapshot" means. Used for notes that already existed when the daily
# run started, e.g. one created by alert_tasks_note() during an earlier failure.
ensure_open_tasks_field() {
  local file="$1" count="$2" log="$3"
  [ -f "$file" ] || return 0
  [ "$(head -1 "$file")" = "---" ] || {
    echo "$(ts) - open_tasks: $(basename "$file") has no frontmatter, skipped" >> "$log"; return 0; }
  if awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$file" | grep -q '^open_tasks:'; then
    echo "$(ts) - open_tasks: already present in $(basename "$file"), left as is" >> "$log"
    return 0
  fi
  local tmp; tmp="$(mktemp "${file%.md}.opentasksXXXXXX")"
  awk -v c="$count" '
    BEGIN{ fm=0; done=0 }
    NR==1 && $0=="---" { print; fm=1; next }
    fm==1 && done==0 && $0 ~ /^journal-date:/ { print; print "open_tasks: " c; done=1; next }
    fm==1 && done==0 && $0 ~ /^---[[:space:]]*$/ { print "open_tasks: " c; print; done=1; fm=0; next }
    fm==1 && $0 ~ /^---[[:space:]]*$/ { fm=0 }
    { print }' "$file" > "$tmp" && mv "$tmp" "$file"
  echo "$(ts) - open_tasks: stamped $count into $(basename "$file")" >> "$log"
}

# --- skip-banner self-heal (2026-08-22) --------------------------------------
# Strikes a "## Vault Agent (skipped...)" banner that an EARLIER ladder wrote
# into today's note, so a later grid fire that succeeds does not append a real
# "## Vault Agent" report underneath a banner announcing that no report was
# generated. Before the 30-minute grid there could only be one ladder per day,
# so the banner was always the last word and this could not happen.
#
# Same self-healing principle as lib_auth.sh's unalert_tasks_note (2026-08-19),
# and the same lesson behind it: an alert with no way to un-fire outlives the
# condition it describes and then rides the carry-forward for days.
#
# Called once per run, AFTER carry-forward (so yesterday's note keeps its own
# banner in its own day, which is accurate history) and BEFORE the claude
# ladder (so the claude step never sees a "(skipped" heading it might try to
# refresh instead of appending a clean one). If this run also fails, the ladder
# rewrites the banner at the end, which is again accurate.
#
# Matching is anchored on the "(skipped" suffix, so the real "## Vault Agent"
# section is never touched. Removes the heading, the blank line above it, and
# every line down to the next "## " heading or EOF. Best-effort: any implausible
# rewrite is discarded and logged rather than moved into place. bash 3.2 / BSD safe.
clear_skip_banner() {
  local note="$1" log="$2"
  [ -f "$note" ] || return 0
  grep -qE '^## Vault Agent \(skipped' "$note" 2>/dev/null || return 0
  local tmp
  tmp="$(mktemp "${note%.md}.skipbannerXXXXXX" 2>/dev/null)" || return 0
  awk '
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) drop[i] = 0
      for (i = 1; i <= NR; i++) {
        if (lines[i] ~ /^## Vault Agent \(skipped/) {
          drop[i] = 1
          # Take the blank line above the heading too. The banner heredoc opens
          # with a blank, so that line is the banner\047s own. Leaving it behind
          # would add one blank line per write-then-strike cycle and, on a day
          # that fails a dozen ladders, ratchet the note full of them. Same trap
          # unalert_tasks_note documents.
          if (i > 1 && lines[i-1] == "") drop[i-1] = 1
          # Boundary is the next heading at ANY level, not just "## ". Found
          # the hard way on the real 2026-08-21 note: com.mbs.pointer-check
          # appends a "### Pointer check" section, so a "## "-only boundary ran
          # to EOF and swallowed it. The sanity check below caught the rewrite
          # and refused it, which would have made this function a silent no-op
          # in exactly the case it exists for.
          for (j = i + 1; j <= NR; j++) {
            if (substr(lines[j], 1, 1) == "#") break
            drop[j] = 1
          }
        }
      }
      # Re-separate on the way out: taking the blank above the heading can glue
      # the line before the banner onto the heading that followed it. Repair
      # ONLY at that seam, i.e. where the line we are about to print follows a
      # line we dropped. Reformatting headings elsewhere is not this function\047s
      # business and would touch sections it has no reason to rewrite.
      prev = ""; started = 0
      for (i = 1; i <= NR; i++) {
        if (drop[i]) continue
        if (started && substr(lines[i], 1, 1) == "#" && prev != "" && drop[i-1]) print ""
        print lines[i]
        prev = lines[i]; started = 1
      }
    }' "$note" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  local before after
  before="$(wc -l < "$note" 2>/dev/null | tr -d ' ')"
  after="$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')"
  case "$before$after" in
    *[!0-9]*|'') rm -f "$tmp"; return 0 ;;
  esac
  # A banner is 6 lines at most (blank, heading, blank, one paragraph, blank).
  # Anything bigger means the awk matched something it should not have.
  if [ "$after" -lt 1 ] || [ "$after" -ge "$before" ] || [ $((before - after)) -gt 12 ]; then
    rm -f "$tmp"
    echo "$(ts) - skip-banner: implausible rewrite (${before} -> ${after} lines), left as is" >> "$log"
    return 0
  fi
  mv "$tmp" "$note" 2>/dev/null || rm -f "$tmp"
  echo "$(ts) - skip-banner: struck stale skip banner from $(basename "$note")" >> "$log"
  return 0
}

# --- frontmatter self-heal (2026-10-12) -------------------------------------
# The Obsidian Archiver plugin (Cmd+A on hoest) creates today's tasks note on
# its own when P archives before this job has run (midnight to the first
# successful run), and it creates it with NO frontmatter, body "# Archived".
# Every later step assumes frontmatter: open_tasks stamping skips the file, and
# carry-forward's insert awk never leaves its frontmatter branch, so it appends
# the carried region at the END, below "# Archived", where the next morning's
# carry boundary stops short of it and P's open items stop rolling forward.
# Fix: give such a file the same frontmatter the pre-flight would have written,
# above its existing body, before anything else touches it.
# An empty count (the midnight rollover, 2026-10-16) writes no open_tasks line:
# that field is the 06:00 snapshot, stamped by mbs_daily.sh.
ensure_tasks_frontmatter() {
  local file="$1" day="$2" count="$3" log="$4"
  [ -f "$file" ] || return 0
  [ "$(head -1 "$file")" = "---" ] && return 0
  local tmp; tmp="$(mktemp "${file%.md}.fmheal.XXXXXX")"
  {
    if [ -n "$count" ]; then
      printf '%s\n' '---' 'journal: tasks' "journal-date: $day" "open_tasks: $count" '---' '' '' ''
    else
      printf '%s\n' '---' 'journal: tasks' "journal-date: $day" '---' '' '' ''
    fi
    cat "$file"
  } > "$tmp" && mv "$tmp" "$file"
  echo "$(ts) - pre-flight: $(basename "$file") existed without frontmatter (made outside this job, e.g. by the Archiver), prepended it" >> "$log"
}

# =============================================================================
# Midnight rollover, residue, rescue, quiet guard and note lock (2026-10-16)
# =============================================================================
# Brief: admin/mbs_system/design/brief_daily_note_garm_fixes.md (sections 3.0,
# 3.4) in the vault. P works past midnight and that work counts for the new
# day, so the tasks note now rolls over just after midnight on garm
# (com.mbs.tasks-rollover), guarded so it never rewrites a note P is typing in.
# mbs_daily.sh at 06:00 does the same rollover itself if it has not happened,
# then a residue pass and the rescue, then stamps open_tasks (the 06:00
# snapshot, P's 2026-08-07 rule; the rollover never writes it).
#
# Rails (brief section 4): no automation deletes or duplicates a line P wrote;
# no automation rewrites a tasks note P changed within the quiet window, except
# after the deadline, and then it says so in its log.

ROLLOVER_QUIET_MINUTES="${ROLLOVER_QUIET_MINUTES:-10}"
ROLLOVER_FORCE_AFTER="${ROLLOVER_FORCE_AFTER:-09:00}"
CARRY_LOOKBACK_DAYS="${CARRY_LOOKBACK_DAYS:-14}"
# The carry-forward began on 2026-07-13: notes before it were never carried and
# hold old content on purpose (2026-05-25, 06-06, 06-13, 06-17, 07-12).
CARRY_RESCUE_FLOOR="2026-07-13"
TASKS_NOTE_LOCK_WAIT_SECONDS="${TASKS_NOTE_LOCK_WAIT_SECONDS:-120}"

# Epoch mtime, or 0. BSD stat first (macOS), GNU form for a Linux test host;
# the shape is validated because GNU stat -f succeeds with garbage.
_tn_mtime() {
  local m
  m="$(stat -f %m "$1" 2>/dev/null)"
  case "$m" in ''|*[!0-9]*) m="$(stat -c %Y "$1" 2>/dev/null)" ;; esac
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  echo "$m"
}

# Current HH:MM; ROLLOVER_CLOCK_HHMM overrides it for drills only.
_tn_hhmm() { if [ -n "${ROLLOVER_CLOCK_HHMM:-}" ]; then echo "$ROLLOVER_CLOCK_HHMM"; else date +%H:%M; fi; }

# tasks_quiet_check FILE LOG STATE_DIR WHO: 0 if FILE was not modified within
# ROLLOVER_QUIET_MINUTES, or the clock is past ROLLOVER_FORCE_AFTER (logged as
# forced); 1 if the write must wait. The deferral line is written at most once
# per 30 minutes per WHO, so a 5-minute job does not fill its log while P types.
# P's edits on hoest or the phone reach garm through Sync, so the file's mtime
# on garm follows his typing.
tasks_quiet_check() {
  local file="$1" log="$2" state_dir="$3" who="$4"
  [ -f "$file" ] || return 0
  local now m age_min hhmm marker last
  now="$(date +%s)"; m="$(_tn_mtime "$file")"
  age_min=$(( (now - m) / 60 ))
  [ "$age_min" -ge "$ROLLOVER_QUIET_MINUTES" ] && return 0
  hhmm="$(_tn_hhmm)"
  if [ ! "$hhmm" \< "$ROLLOVER_FORCE_AFTER" ]; then
    echo "$(ts) - rollover: $(basename "$file" .md) changed ${age_min} min ago, but it is ${hhmm}, past ROLLOVER_FORCE_AFTER ${ROLLOVER_FORCE_AFTER}: quiet guard skipped, writing anyway (forced)" >> "$log"
    return 0
  fi
  marker="$state_dir/tasks_rollover_deferred_${who}"
  last="$(cat "$marker" 2>/dev/null)"; case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -ge 1800 ]; then
    echo "$(ts) - rollover: deferred, $(basename "$file" .md) changed ${age_min} min ago (quiet window ${ROLLOVER_QUIET_MINUTES} min, forced from ${ROLLOVER_FORCE_AFTER})" >> "$log"
    echo "$now" > "$marker"
  fi
  return 1
}

# Note lock shared by com.mbs.tasks-rollover and mbs_daily.sh around their
# note-writing steps only (never around the daily's Claude ladder), so the two
# never write a tasks note at the same moment. Atomic mkdir, holder PID inside,
# a dead holder's lock is claimed (the same stale-lock rule as mbs_daily.sh).
# tasks_note_lock_acquire STATE_DIR LOG WAIT_SECONDS: 0 = held, 1 = busy.
tasks_note_lock_acquire() {
  local state_dir="$1" log="$2" wait="${3:-0}" lock="$1/tasks_note.lock" holder waited=0
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      echo $$ > "$lock/pid"
      TASKS_NOTE_LOCK_HELD="$lock"
      return 0
    fi
    holder="$(cat "$lock/pid" 2>/dev/null)"
    if [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; then
      # A holder that has not written its pid yet is given one second.
      if [ -z "$holder" ] && [ "$waited" -eq 0 ]; then sleep 1; waited=1; continue; fi
      echo "$(ts) - note lock: stale (holder PID ${holder:-unknown} is gone), claiming" >> "$log"
      rm -rf "$lock"
      continue
    fi
    if [ "$waited" -ge "$wait" ]; then
      echo "$(ts) - note lock: held by PID $holder, not writing this run" >> "$log"
      return 1
    fi
    sleep 5; waited=$((waited + 5))
  done
}
tasks_note_lock_release() {
  [ -n "${TASKS_NOTE_LOCK_HELD:-}" ] || return 0
  [ "$(cat "$TASKS_NOTE_LOCK_HELD/pid" 2>/dev/null)" = "$$" ] && rm -rf "$TASKS_NOTE_LOCK_HELD"
  TASKS_NOTE_LOCK_HELD=""
}

# P's region of a note, raw: below the frontmatter, above the first "## " or
# "# Archived", outside garden leave and work session blocks (the split the
# carry splitter uses).
_tasks_region() {
  awk 'NR==1 && $0=="---" {fm=1; next}
       fm==1 {if ($0=="---") fm=0; next}
       /^## / || /^# Archived/ {exit}
       /^### Work session/ {ws=1}
       ws==1 {if ($0 ~ /<!-- \/work-session -->/) ws=0; next}
       /^### Garden leave/ {gl=1}
       gl==1 {if ($0 ~ /<!-- \/garden-leave -->/) gl=0; next}
       {print}' "$1"
}

# Checkbox lines of stdin, normalized for the overlap test: outer whitespace,
# the checkbox and its state, and a trailing done date removed. Sorted, unique.
_tasks_norm_boxes() {
  grep -E '^[[:space:]]*- \[.\]' \
    | sed -E 's/^[[:space:]]*- \[.\][[:space:]]*//; s/[[:space:]]+$//; s/[[:space:]]*✅ [0-9]{4}-[0-9]{2}-[0-9]{2}$//; s/[[:space:]]+$//' \
    | grep -v '^$' | sort -u
}

# carry_extra_source KIND TODAY SRC_DATE TASKS_DIR TODAY_FILE LOG STATE_DIR
# KIND is residue (lines typed into the primary source after the rollover) or
# rescue (an older note whose region still holds lines: the stranding fix).
# Never the first carry. Returns 0 when it moved something, 1 otherwise.
#   - not quiet: left for later (the next run, or a later day's rescue).
#   - overlap with today's region (normalized checkbox lines): left untouched,
#     WARNING logged, one alert line in today's note asking P to merge by hand.
#     This is the stale device restoring an old region: no automation deletes
#     or duplicates a line P wrote.
#   - otherwise processed exactly like the primary: ticked lines archived into
#     the source's own "# Archived" with the source's own date, region moved
#     into today's note (below the garden leave block when it is there), source
#     blanked.
carry_extra_source() {
  local kind="$1" today="$2" src_date="$3" tasks_dir="$4" today_file="$5" log="$6" state_dir="$7"
  local src="$tasks_dir/tasks_${src_date}.md"
  [ -f "$src" ] && [ -f "$today_file" ] || return 1
  local tmp; tmp="$(mktemp -d "${tasks_dir}/.carry.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  _carry_split "$src" "$src_date" "$tmp"
  local has_carry=0
  grep -q '[^[:space:]]' "$tmp/carry" && has_carry=1
  [ "$has_carry" -eq 0 ] && [ ! -s "$tmp/done" ] && return 1
  tasks_quiet_check "$src" "$log" "$state_dir" "$kind" || return 1
  local n m
  n="$(_tasks_region "$src" | grep -c '[^[:space:]]' | tr -d ' ')"
  _tasks_region "$src" | _tasks_norm_boxes > "$tmp/src_boxes"
  _tasks_region "$today_file" | _tasks_norm_boxes > "$tmp/today_boxes"
  m="$(comm -12 "$tmp/src_boxes" "$tmp/today_boxes" | grep -c . | tr -d ' ')"
  if [ "$m" -gt 0 ]; then
    echo "$(ts) - carry-forward: WARNING tasks_${src_date} holds ${n} line(s), ${m} already in today's list; left untouched" >> "$log"
    alert_tasks_note "Carry-forward left tasks_${src_date} untouched: it holds ${n} line(s) and ${m} of them are already in today's list, which is what a device restoring an old copy looks like. Merge it by hand: open tasks_${src_date}, copy anything not already here into today's note, then delete those lines from tasks_${src_date}."
    return 1
  fi
  _carry_build_source "$tmp"
  if [ "$has_carry" -eq 1 ]; then
    _carry_insert "$today_file" "$tmp/carry" "$tmp/today" && mv "$tmp/today" "$today_file"
  fi
  mv "$tmp/prior" "$src"
  local nc nd
  nc="$(grep -c '[^[:space:]]' "$tmp/carry" | tr -d ' ')"
  nd="$(grep -c '🔒' "$tmp/done" | tr -d ' ')"
  if [ "$kind" = "residue" ]; then
    echo "$(ts) - carry-forward: residue ${nc} line(s) from tasks_${src_date}" >> "$log"
  else
    echo "$(ts) - carry-forward: rescued ${nc} line(s) from tasks_${src_date}" >> "$log"
  fi
  [ -s "$tmp/done" ] && echo "$(ts) - carry-forward: archived ${nd} ticked line(s) into ${src_date} # Archived" >> "$log"
  return 0
}

# carry_rescue TODAY TASKS_DIR TODAY_FILE LOG STATE_DIR: every tasks note dated
# before the primary source (the latest note before TODAY), no more than
# CARRY_LOOKBACK_DAYS before TODAY and never before CARRY_RESCUE_FLOOR, whose
# region holds a non-blank or ticked line. Processed newest first, each one
# inserted at the top of the carried lines, so they end up oldest first, above
# the primary's region. SETUP's "Task carry-forward" section always said the
# carry reaches back to the last note with content; until 2026-10-16 it did not.
carry_rescue() {
  local today="$1" tasks_dir="$2" today_file="$3" log="$4" state_dir="$5"
  local primary floor d_today d
  primary="$(tasks_prior_date "$today" "$tasks_dir")"
  [ -n "$primary" ] || return 0
  d_today="$(gl_daynum "$today")"
  local checked=0 moved=0
  for d in $(ls "$tasks_dir"/tasks_*.md 2>/dev/null \
      | grep -oE 'tasks_[0-9]{4}-[0-9]{2}-[0-9]{2}\.md' \
      | sed -E 's/tasks_(.*)\.md/\1/' \
      | awk -v p="$primary" -v f="$CARRY_RESCUE_FLOOR" '$0 < p && !($0 < f)' | sort -r); do
    [ $((d_today - $(gl_daynum "$d"))) -le "$CARRY_LOOKBACK_DAYS" ] || continue
    checked=$((checked + 1))
    carry_extra_source rescue "$today" "$d" "$tasks_dir" "$today_file" "$log" "$state_dir" && moved=$((moved + 1))
  done
  echo "$(ts) - carry-forward: rescue looked at ${checked} older note(s) before tasks_${primary} (lookback ${CARRY_LOOKBACK_DAYS} days, not before ${CARRY_RESCUE_FLOOR}), rescued ${moved}" >> "$log"
  return 0
}

# tasks_rollover_steps TODAY VAULT STATE_DIR LOG WHO: the rollover proper.
# Caller holds the note lock and has passed the quiet guard. Heals an
# Archiver-made note's frontmatter and creates today's note, both WITHOUT
# open_tasks (the 06:00 run stamps it), carries the primary region, rescues,
# writes the garden leave block, records triage first-seen, stamps
# last_tasks_rollover (line 1 the date, line 2 when and by whom: heartbeat check
# 40 reads both). Prints the "rolled" sentence on stdout for the caller's log
# line. Returns non-zero, without stamping, if a step failed.
tasks_rollover_steps() {
  local today="$1" vault="$2" state_dir="$3" log="$4" who="$5"
  local tasks_dir="$vault/daily_notes/tasks" today_file prior
  today_file="$tasks_dir/tasks_${today}.md"
  prior="$(tasks_prior_date "$today" "$tasks_dir")"
  mkdir -p "$tasks_dir" || return 1
  ensure_tasks_frontmatter "$today_file" "$today" "" "$log" || return 1
  if [ ! -f "$today_file" ]; then
    printf '%s\n' '---' 'journal: tasks' "journal-date: ${today}" '---' '' '' '' > "$today_file" || return 1
    echo "$(ts) - pre-flight: created minimal $today_file" >> "$log"
  fi
  carry_forward_prior_tasks "$today" "$tasks_dir" "$today_file" "$log" || return 1
  carry_rescue "$today" "$tasks_dir" "$today_file" "$log" "$state_dir" || return 1
  write_garden_leave_block "$today" "$today_file" "$vault" "$log" || return 1
  update_triage_first_seen "$today" "$today_file" "$state_dir/triage_first_seen" "$log" || return 1
  local hhmm; hhmm="$(date +%H:%M)"
  printf '%s\n%s by %s\n' "$today" "$hhmm" "$who" > "$state_dir/last_tasks_rollover" || return 1
  rm -f "$state_dir"/tasks_rollover_deferred_*
  echo "rolled tasks_${prior:-none} into tasks_${today} at ${hhmm}"
}

# 0 if last_tasks_rollover's first line is $1.
tasks_rollover_done() { [ "$(head -1 "$2/last_tasks_rollover" 2>/dev/null)" = "$1" ]; }
