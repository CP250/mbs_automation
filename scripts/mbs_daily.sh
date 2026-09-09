#!/bin/bash
# mbs_daily.sh - run the /obsidian-daily morning report at most once per day.
#
# Triggered by launchd three ways (see scripts/com.mbs.daily.plist):
#   1. StartCalendarInterval, a 30-minute grid from 06:00 to 21:30 local (P
#      decision 2026-08-22; it was a single 06:00 fire before that). 06:00 is
#      still the on-time fire; the rest of the grid exists so a day that fails
#      early gets retried later instead of being lost.
#   2. Wake from sleep - launchd coalesces every grid entry missed while asleep
#      into exactly ONE fire on wake. (Native launchd behavior; not cron. The
#      man page is explicit that StartInterval does NOT do this, which is why
#      the grid is a calendar array and not an interval.)
#   3. RunAtLoad at login - covers the case where the Mac was fully powered off
#      all morning, so the report runs shortly after you log back in.
#
# Firing this often is safe because the per-day stamp check below is the third
# thing this script does, before the lock and before the vault scan: on a day
# that already succeeded, every later grid fire exits in milliseconds. Fires
# that land mid-ladder hit the live PID lock and exit cleanly, so the grid only
# takes over once a ladder has actually given up.
#
# Idempotence + retry (2026-06-06 hardening):
# - A per-day stamp file ($STAMP) records the last successful day. Any trigger
#   on a stamped day exits immediately. The stamp is written only on success.
# - A directory lock ($LOCK_DIR) prevents two instances from running at once
#   (e.g. a launchd wake-trigger firing while a previous instance is still in
#   its retry-sleep). Stale locks (PID no longer alive) are cleaned up.
# - On Claude failure (transient API outage, network blip), the script retries
#   in-process with exponential backoff before giving up. Five attempts total,
#   sleeps of 5/10/30/60 min between attempts. Total elapsed up to ~1.75 hr.
#   macOS sleep pauses the sleep timer (CLOCK_MONOTONIC), so retries effectively
#   wait for "Mac awake" time rather than wall-clock time. This is the right
#   behavior - retrying while the network is asleep has no value.
# - The ladder is bound to its own calendar day (2026-08-25). Before each
#   attempt, if the date no longer matches the day the run started for, the
#   ladder is abandoned (exit 4) and the lock released. Without this a ladder
#   whose sleeps paused across Mac sleep could squat the lock into the next day
#   and silently swallow it whole, because launchd will not start a second copy
#   of a running job and the heartbeat deferred on the live PID. That is exactly
#   what happened to 2026-08-24.
# - If all in-script retries fail, the script exits non-zero with no stamp, so
#   the next launchd trigger (the next 30-minute grid entry, the next wake, or
#   tomorrow's 06:00) will retry with a fresh ladder. Before the grid existed
#   this was the hole that lost 2026-08-21 entirely: the ladder died at 12:00
#   and nothing fired again that day.
#
# Why this matters: on 2026-06-05 a 06:00 FailedToOpenSocket killed that day's
# report because the script exited after one attempt and launchd's wake-coalesce
# never fired a retry trigger that day. The in-script retry loop fixes that.

set -uo pipefail

VAULT="/Users/cpreston/Vaults/storage_mbs"
STATE_DIR="$HOME/.mbs_automation"
STAMP="$STATE_DIR/last_daily_run"
LOG="$STATE_DIR/mbs_daily.log"

mkdir -p "$STATE_DIR"

TODAY="$(date +%Y-%m-%d)"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Structure-review 2026-08-01 drain REMOVED 2026-08-03. It moved sweep reports
# out of the legacy admin/obsidian_optimize/session_awareness/ landing dir. That
# dir is gone (disposed to trash/) and the Cowork task's report path was verified
# canonical, so the loop was dead code. History: design/session_awareness/CLAUDE.md.

# Per-attempt budget for this job (2026-09-09). lib_auth.sh's estate default
# is 1500s; the morning report normally takes 6 to 12 minutes but on 09-09
# three attempts in a row were killed at 1500s and the fourth needed 24m47s.
# Since the same change, a HUNG attempt is killed by the idle watchdog
# (CLAUDE_IDLE_SECONDS, default 600s of no output) rather than by this cap, so
# raising the cap costs nothing on a hang and stops a working run from being
# thrown away. Both are overridable from the environment (the plist).
export CLAUDE_TIMEOUT_SECONDS="${CLAUDE_TIMEOUT_SECONDS:-3600}"
export CLAUDE_IDLE_SECONDS="${CLAUDE_IDLE_SECONDS:-600}"

# Source the auth-failure detection helpers (lib_auth.sh).
# shellcheck source=./lib_auth.sh
source "$(dirname "$0")/lib_auth.sh"

# Pre-flight: if the reauth sentinel is fresh, the API will 401 again. Skip
# cleanly so launchd doesn't burn cycles, and re-fire the notification.
if needs_reauth_skip "$LOG"; then
  exit 0
fi

# Already ran successfully today? Stop.
if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$TODAY" ]; then
  echo "$(ts) - already ran for $TODAY, skipping." >> "$LOG"
  exit 0
fi

# Single-instance lock. mkdir is atomic - only one launchd invocation can win
# the create. If we lose, check whether the holder is still alive; if not,
# the lock is stale (script killed without trap firing) and we claim it.
LOCK_DIR="$STATE_DIR/mbs_daily.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  HOLDER_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -n "${HOLDER_PID:-}" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
    echo "$(ts) - another instance is running (PID $HOLDER_PID), exiting cleanly" >> "$LOG"
    exit 0
  fi
  echo "$(ts) - stale lock detected (holder PID was ${HOLDER_PID:-unknown}), claiming" >> "$LOG"
  rm -rf "$LOCK_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$(ts) - ERROR: could not claim lock after cleanup, aborting" >> "$LOG"
    exit 1
  fi
fi
echo $$ > "$LOCK_DIR/pid"
# Stamp the lock with the day it was claimed FOR (2026-08-25). mbs_heartbeat.sh
# reads this to tell "mbs_daily is still working, not late yet" apart from "a
# ladder from an earlier day is still squatting here". Before this existed the
# watchdog deferred on any live PID, which is how 2026-08-24 passed in total
# silence: see the day bound in the retry loop below.
echo "$TODAY" > "$LOCK_DIR/day"
# Release the lock on any exit path (success, error, SIGTERM from `launchctl bootout`).
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

# launchd starts jobs with a minimal PATH; prepend the common install locations
# for the `claude` binary before resolving it.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  echo "$(ts) - ERROR: 'claude' not found on PATH. Edit PATH in this script. Aborting." >> "$LOG"
  exit 1
fi

echo "$(ts) - starting /obsidian-daily for $TODAY (claude: $CLAUDE_BIN)" >> "$LOG"

cd "$VAULT" || { echo "$(ts) - ERROR: cannot cd to $VAULT" >> "$LOG"; exit 1; }

# --- carry-forward: pull yesterday's above-Vault-Agent region into today ------
# Moves the region above the first "## Vault Agent" heading from the most-recent
# prior tasks note into today's note (verbatim, minus resolved - [x] / - [-]
# lines) and blanks that region in the source. Runs after the skeleton pre-flight
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
carry_forward_prior_tasks() {
  local today="$1" tasks_dir="$2" today_file="$3" log="$4"
  local prior_date prior_file
  prior_date="$(ls "$tasks_dir"/tasks_*.md 2>/dev/null \
    | grep -oE 'tasks_[0-9]{4}-[0-9]{2}-[0-9]{2}\.md' \
    | sed -E 's/tasks_(.*)\.md/\1/' \
    | awk -v t="$today" '$0 < t' | sort | tail -1)"
  [ -z "$prior_date" ] && { echo "$(ts) - carry-forward: no prior note, skip" >> "$log"; return 0; }
  prior_file="$tasks_dir/tasks_${prior_date}.md"
  [ -f "$today_file" ] || { echo "$(ts) - carry-forward: today file missing, skip" >> "$log"; return 0; }
  # Temp dir inside the tasks folder so the final mv is same-filesystem (atomic).
  local tmp; tmp="$(mktemp -d "${tasks_dir}/.carry.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  # Split prior note: fm (frontmatter) / carry (region, resolved lines dropped) /
  # tail (first boundary heading onward, plus any work-session block above it).
  # Boundary = the first level-2 heading of any kind, which on a healthy day is
  # "## Vault Agent"; a "# Archived" also stops carry as a fallback for notes
  # with no agent section. machf collects the machine headings that sat ABOVE
  # "## Vault Agent", i.e. the ones this fix stops sweeping forward, for the log.
  awk -v carryf="$tmp/carry" -v tailf="$tmp/tail" -v fmf="$tmp/fm" -v machf="$tmp/machine" '
    BEGIN{ inbody=0; intail=0; fmc=0; ws=0 }
    { if (NR==1 && $0!="---") inbody=1
      if (!inbody){ print >> fmf; if($0=="---"){fmc++; if(fmc==2)inbody=1} next }
      if (!intail && ($0 ~ /^## / || $0 ~ /^# Archived/)) { intail=1; ws=0 }
      if (intail){
        if ($0 ~ /^## Vault Agent/) va=1
        if (!va && $0 ~ /^## / && $0 !~ /^## Vault Agent/) print >> machf
        print >> tailf; next }
      if (!ws && $0 ~ /^### Work session/) ws=1
      if (ws){ print >> tailf; if ($0 ~ /<!-- \/work-session -->/) ws=0; next }
      if ($0 ~ /^[[:space:]]*- \[[xX-]\][[:space:]]/) next
      if ($0 ~ /^[[:space:]]*- \[[xX-]\]$/) next
      print >> carryf }' "$prior_file"
  [ -f "$tmp/fm" ] || : > "$tmp/fm"; [ -f "$tmp/carry" ] || : > "$tmp/carry"; [ -f "$tmp/tail" ] || : > "$tmp/tail"
  grep -q '[^[:space:]]' "$tmp/carry" || { echo "$(ts) - carry-forward: empty region, skip" >> "$log"; return 0; }
  # Today = today frontmatter + carried region + today's existing body (prepend).
  awk -v carryf="$tmp/carry" '
    BEGIN{ fmc=0; inbody=0; pc=0 }
    { if(!inbody){ print; if($0=="---"){fmc++; if(fmc==2)inbody=1} next }
      if(!pc){ print ""; while((getline l < carryf)>0) print l; close(carryf); pc=1 }
      print }
    END{ if(!pc){ print ""; while((getline l < carryf)>0) print l; close(carryf) } }' \
    "$today_file" > "$tmp/today"
  # Source = its frontmatter + 3-line writing gap + tail (agent + archived kept).
  { cat "$tmp/fm"; printf '\n\n\n'; cat "$tmp/tail"; } > "$tmp/prior"
  mv "$tmp/today" "$today_file"; mv "$tmp/prior" "$prior_file"
  echo "$(ts) - carry-forward: moved $prior_date region into $today, blanked source" >> "$log"
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
# (2026-08-19; previously it stopped only at "## Vault Agent").
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

# Pre-flight: guarantee today's tasks file exists on this Mac's local disk
# BEFORE invoking Claude. Why: the Journals plugin's `tasks.autoCreate` is now
# intentionally disabled (to prevent phone-Mac sync races - phone Journals would
# otherwise create an empty competing version while Mac Obsidian is closed).
# Mac is now solely responsible for tasks-file creation; pre-flight here means
# the file exists even if the Claude call later fails (API overload, network,
# whatever) and the user always has somewhere to write. See SETUP.md.
TODAYS_TASKS="$VAULT/daily_notes/tasks/tasks_${TODAY}.md"
OPEN_TASKS="$(count_open_tasks "$VAULT")"
if [ ! -f "$TODAYS_TASKS" ]; then
  mkdir -p "$(dirname "$TODAYS_TASKS")"
  cat > "$TODAYS_TASKS" <<EOF
---
journal: tasks
journal-date: ${TODAY}
open_tasks: ${OPEN_TASKS}
---



EOF
  echo "$(ts) - pre-flight: created minimal $TODAYS_TASKS" >> "$LOG"
  echo "$(ts) - open_tasks: stamped ${OPEN_TASKS} at creation" >> "$LOG"
else
  ensure_open_tasks_field "$TODAYS_TASKS" "$OPEN_TASKS" "$LOG"
fi

# Carry yesterday's above-Vault-Agent region forward into today (see function
# definition above). Runs whether or not the pre-flight just created the file.
carry_forward_prior_tasks "$TODAY" "$VAULT/daily_notes/tasks" "$TODAYS_TASKS" "$LOG"

# Record first-seen dates for the post-carry open lines in P's region: the age
# source for the claude triage step's errand staleness flags (project_task_triage).
update_triage_first_seen "$TODAY" "$TODAYS_TASKS" "$STATE_DIR/triage_first_seen" "$LOG"

# Strike any "(skipped" banner an earlier ladder left in today's note, so this
# run's report does not land underneath a notice saying it was never generated.
clear_skip_banner "$TODAYS_TASKS" "$LOG"

# Headless run. NOTE: custom slash commands (/obsidian-daily) do NOT expand in
# `claude -p` non-interactive mode - they only work in an interactive session. So
# instead of invoking the slash command, we point Claude at the command file and
# tell it to execute those instructions. The command file is symlinked from the
# repo, so this always runs the current logic (single source of truth).
#
# --dangerously-skip-permissions allows the unattended write without a prompt
# (skipDangerousModePermissionPrompt:true in ~/.claude/settings.json suppresses the
# mode warning). The command is hardened to use the filesystem, not the Obsidian
# MCP, so it does not require Obsidian to be running.
PROMPT="Read the file $HOME/.claude/commands/obsidian-daily.md and carry out its instructions exactly, using the mbs_automation skill, against the vault at $VAULT. This is the unattended scheduled morning run: append or refresh the bounded ## Vault Agent section in today's tasks note via the filesystem, and do not touch P's own sections. Budget: the wrapper kills this run after ${CLAUDE_TIMEOUT_SECONDS}s of wall clock, or after ${CLAUDE_IDLE_SECONDS}s with no output, and a killed run loses its report; work steadily and do not spend turns measuring elapsed time. End the section with the single vault-agent-status line the command file specifies: complete when every step ran, partial (naming the skipped steps) only if you truly could not finish."

# Pre-flight network gate (2026-07-06 hardening): the 06:00 fire (or a
# wake-coalesced grid fire) can land before Wi-Fi/DNS has reconnected, so the first
# attempt would burn on a ConnectionRefused / could-not-resolve failure that has
# nothing to do with the API or with auth (this is what silently killed the
# 2026-07-05 run). Poll the API host for up to ~2 min before starting; proceed
# regardless once reachable or the budget is exhausted (the retry loop below
# still covers a genuine outage). On a healthy morning the first probe returns
# immediately, so this adds no meaningful delay.
wait_for_network() {
  local log="$1"
  local url="https://api.anthropic.com/"
  local max_tries=12 i rc
  for i in $(seq 1 "$max_tries"); do
    curl -sS --max-time 5 -o /dev/null "$url" 2>/dev/null
    rc=$?
    # curl exit 0 = connected (an HTTP 401/404 still counts as reachable).
    # Exit 6 (DNS), 7 (connect refused), 28 (timeout), 35 (TLS) => not ready.
    case "$rc" in
      6|7|28|35)
        echo "$(ts) - network not ready (curl exit $rc); waiting 10s ($i/$max_tries)" >> "$log"
        sleep 10 ;;
      *)
        echo "$(ts) - network reachable (curl exit $rc after $i check(s))" >> "$log"
        return 0 ;;
    esac
  done
  echo "$(ts) - network still not ready after $max_tries checks; proceeding anyway" >> "$log"
  return 1
}
wait_for_network "$LOG"

# Retry loop with backoff. Sleeps between attempts (in seconds): 5min, 10min,
# 30min, 60min. So a transient outage of up to ~1.75 hr gets covered without
# relying on launchd to coalesce a wake-trigger.
MAX_ATTEMPTS=5
RETRY_DELAYS=(300 600 1800 3600)

rc=1
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  # --- day bound (2026-08-25) -------------------------------------------------
  # The sleeps below use CLOCK_MONOTONIC and pause while the Mac sleeps, so a
  # ladder can outlive its own calendar day. On 2026-08-23 this loop started at
  # 06:10 and fired attempt 5 at 20:12 the FOLLOWING day, then wrote its banner
  # into tasks_2026-08-23.md at 20:49 on 08-24 because $TODAY was fixed at
  # process start.
  #
  # The cost was not that one late banner. It was the whole of 08-24, lost in
  # total silence, for two compounding reasons:
  #   1. launchd will not start a second copy of a job that is already running,
  #      so not one of 08-24's triggers ever fired. Note the corroborating
  #      evidence: the lock's "another instance is running" branch above has
  #      never been reached once in the entire life of mbs_daily.log.
  #   2. mbs_heartbeat.sh deferred on the live PID ("still running, not late
  #      yet"), so the watchdog was silenced by the very thing it should have
  #      reported.
  # Result: 08-24 got no carry-forward, no report, and no banner explaining the
  # absence. tasks_2026-08-24.md was left holding a single unrelated heading.
  #
  # So: once the date no longer matches the day this run was started FOR, stop.
  # Releasing the lock is the entire point; the next trigger then starts a
  # fresh, correctly dated ladder for the new day. Exit 4 is this case (0/1/2/3
  # and run_claude_p's 124 were already taken).
  NOW_DAY="$(date +%Y-%m-%d)"
  if [ "$NOW_DAY" != "$TODAY" ]; then
    echo "$(ts) - abandoning ladder at attempt $attempt/$MAX_ATTEMPTS: started for $TODAY, it is now $NOW_DAY. Releasing the lock so $NOW_DAY gets its own run." >> "$LOG"
    if [ -f "$TODAYS_TASKS" ] && ! grep -qE '^## Vault Agent' "$TODAYS_TASKS"; then
      cat >> "$TODAYS_TASKS" <<BANNER

## Vault Agent (skipped, run abandoned)

Daily report not generated for ${TODAY}. The retry ladder was still running when the date rolled over to ${NOW_DAY}, so it was abandoned at attempt ${attempt} of ${MAX_ATTEMPTS} and its lock released. Retry sleeps pause while the Mac sleeps, which is how a run stretches past its own day. ${NOW_DAY} gets its own run on the next trigger. No action needed unless this recurs.

BANNER
      echo "$(ts) - wrote abandoned-run banner to $TODAYS_TASKS" >> "$LOG"
    fi
    exit 4
  fi
  echo "$(ts) - attempt $attempt/$MAX_ATTEMPTS" >> "$LOG"
  run_claude_p "$PROMPT" "$LOG"
  rc=$?
  # --- artifact check (2026-09-09) --------------------------------------------
  # The exit code alone has been shown to lie in both directions (09-03: report
  # written, exit non-zero, three redundant attempts; 09-04: side effects
  # written, no report, exit 124). Success now also requires that today's note
  # carries a real ## Vault Agent section AND that the agent's own last line
  # says the report is complete. A "partial" marker (the agent ran out of
  # budget and said so, as on 09-09) is a failed attempt: no stamp, the ladder
  # continues, and the next attempt refreshes the section in place. A MISSING
  # marker is logged and tolerated (an agent that forgot the line should not
  # cost a whole re-run); heartbeat check 2c reports it.
  if [ "$rc" -eq 0 ]; then
    if [ ! -f "$TODAYS_TASKS" ] || ! grep -qE '^## Vault Agent' "$TODAYS_TASKS" \
       || grep -qE '^## Vault Agent \(skipped' "$TODAYS_TASKS"; then
      echo "$(ts) - claude -p exited 0 but today's note has no real ## Vault Agent section; treating as a failed attempt (exit 5)" >> "$LOG"
      rc=5
    else
      VA_STATUS="$(grep -E '^<!-- vault-agent-status: ' "$TODAYS_TASKS" | tail -1)"
      case "$VA_STATUS" in
        *"vault-agent-status: complete"*)
          echo "$(ts) - report marker: ${VA_STATUS}" >> "$LOG" ;;
        *"vault-agent-status: partial"*)
          echo "$(ts) - report is marked PARTIAL by the agent: ${VA_STATUS}" >> "$LOG"
          echo "$(ts) - not stamping; treating the partial report as a failed attempt (exit 5) so a later attempt refreshes it in place" >> "$LOG"
          rc=5 ;;
        *)
          echo "$(ts) - WARNING: report carries no vault-agent-status marker; stamping on exit code alone (heartbeat check 2c will flag it)" >> "$LOG" ;;
      esac
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    clear_reauth_sentinel
    echo "$TODAY" > "$STAMP"
    echo "$(ts) - completed successfully on attempt $attempt; stamped $TODAY" >> "$LOG"
    exit 0
  fi
  if [ "$rc" -eq 2 ]; then
    # Auth failure (401). Retrying is pointless. Mark sentinel, write a banner
    # into today's tasks note so P sees why the report is missing, and exit.
    mark_reauth_needed "$LOG"
    # Only write the banner if no ## Vault Agent section exists yet. A report may
    # have landed from a hand-run or a concurrent attempt while this ladder slept;
    # appending "not generated" under a real report is worse than saying nothing.
    if [ -f "$TODAYS_TASKS" ] && ! grep -qE '^## Vault Agent' "$TODAYS_TASKS"; then
      cat >> "$TODAYS_TASKS" <<'BANNER'

## Vault Agent (skipped)

Claude Code authentication expired (HTTP 401 from Anthropic API). Daily report not generated. Re-authenticate by running `claude` then `/login` in Terminal. Once auth is restored, the next launchd trigger produces the report normally and this banner is struck automatically. Triggers run every 30 minutes from 06:00 to 21:30, plus once on each wake from sleep.

BANNER
      echo "$(ts) - wrote auth-skipped banner to $TODAYS_TASKS" >> "$LOG"
    fi
    exit 2
  fi
  if [ "$rc" -eq 3 ]; then
    # Out of usage credits. run_claude_p already wrote a visible alert line into
    # today's tasks note. Retrying is pointless until credits/model are fixed, so
    # stop the loop (mirrors the 401 path) and exit non-zero with no stamp; the
    # next launchd trigger retries once credits are restored.
    echo "$(ts) - out of usage credits (model ${CLAUDE_MODEL:-opus}); alert written to today's note, not retrying" >> "$LOG"
    exit 3
  fi
  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    delay="${RETRY_DELAYS[$((attempt - 1))]}"
    echo "$(ts) - attempt $attempt failed (exit $rc); sleeping ${delay}s before retry $((attempt + 1))" >> "$LOG"
    sleep "$delay"
  fi
done
echo "$(ts) - all $MAX_ATTEMPTS attempts failed (final exit $rc); will retry on next launchd trigger" >> "$LOG"

# Connectivity-failure banner (2026-07-06 hardening): unlike a 401, a pure
# connection/DNS failure used to leave NO explanation in today's note (the
# silent 2026-07-05 miss), so a missing report looked identical to "nothing
# ran". Write a one-time banner so P sees why. Idempotent: skip if any Vault
# Agent skip banner (this one or the 401 one) is already present in today's file.
# Banner wording follows the final exit code (2026-09-09). This block used to
# call every all-attempts failure "no network", which is how 2026-08-17 (five
# 1500s kills with curl reporting the API reachable) went into the estate's
# own records as a no-network morning. A kill is a kill; say so.
if [ -f "$TODAYS_TASKS" ] && ! grep -qE '^## Vault Agent' "$TODAYS_TASKS"; then
  if [ "$rc" -eq 124 ]; then
    cat >> "$TODAYS_TASKS" <<BANNER

## Vault Agent (skipped, timed out)

Daily report not generated: every one of ${MAX_ATTEMPTS} attempts was killed by the wrapper's watchdog (hard cap ${CLAUDE_TIMEOUT_SECONDS}s, or ${CLAUDE_IDLE_SECONDS}s with no output). The network was reachable, so this is the run hanging or running long, not a connection failure. The tail of ~/.mbs_automation/mbs_daily.log names what each attempt was doing when it died, and the per-attempt traces are in ~/.mbs_automation/claude_traces/. A fresh attempt runs on the next trigger. If a later attempt today succeeds, this banner is struck automatically and replaced by the real report.

BANNER
    echo "$(ts) - wrote timed-out skipped banner to $TODAYS_TASKS" >> "$LOG"
  elif [ "$rc" -eq 5 ]; then
    cat >> "$TODAYS_TASKS" <<BANNER

## Vault Agent (skipped, no report written)

Daily report not generated: claude exited cleanly on all ${MAX_ATTEMPTS} attempts but never wrote a ## Vault Agent section into this note (the wrapper checks the artifact, not just the exit code, since 2026-09-09). The network and auth were fine, so this is the agent failing the write step: read the final message of each attempt in ~/.mbs_automation/mbs_daily.log, and the traces in ~/.mbs_automation/claude_traces/. A fresh attempt runs on the next trigger.

BANNER
    echo "$(ts) - wrote no-report skipped banner to $TODAYS_TASKS" >> "$LOG"
  else
    cat >> "$TODAYS_TASKS" <<BANNER

## Vault Agent (skipped, no network)

Daily report not generated: could not reach the Anthropic API after ${MAX_ATTEMPTS} attempts (final exit ${rc}). This was a connection or DNS failure, not an auth problem, most often the Mac waking for the scheduled run before Wi-Fi/DNS reconnected. A fresh attempt runs on the next trigger: every 30 minutes from 06:00 to 21:30, plus once on each wake from sleep. If a later attempt today succeeds, this banner is struck automatically and replaced by the real report. No action needed unless it recurs for several days.

BANNER
    echo "$(ts) - wrote no-network skipped banner to $TODAYS_TASKS" >> "$LOG"
  fi
fi
exit "$rc"
