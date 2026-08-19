#!/bin/bash
# mbs_daily.sh - run the /obsidian-daily morning report at most once per day.
#
# Triggered by launchd three ways (see scripts/com.mbs.daily.plist):
#   1. StartCalendarInterval at 06:00 local - runs on time if the Mac is awake.
#   2. Wake from sleep - launchd coalesces the missed 06:00 fire and runs it
#      when you open the lid. (Native launchd behavior; not cron.)
#   3. RunAtLoad at login - covers the case where the Mac was fully powered off
#      at 06:00, so the report runs shortly after you log back in.
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
# - If all in-script retries fail, the script exits non-zero with no stamp, so
#   the next launchd trigger (next wake event or tomorrow's 06:00) will retry.
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
PROMPT="Read the file $HOME/.claude/commands/obsidian-daily.md and carry out its instructions exactly, using the mbs_automation skill, against the vault at $VAULT. This is the unattended scheduled morning run: append or refresh the bounded ## Vault Agent section in today's tasks note via the filesystem, and do not touch P's own sections."

# Pre-flight network gate (2026-07-06 hardening): the 06:00 fire (or a
# wake-coalesced fire) can land before Wi-Fi/DNS has reconnected, so the first
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
  echo "$(ts) - attempt $attempt/$MAX_ATTEMPTS" >> "$LOG"
  run_claude_p "$PROMPT" "$LOG"
  rc=$?
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

Claude Code authentication expired (HTTP 401 from Anthropic API). Daily report not generated. Re-authenticate by running `claude` then `/login` in Terminal. Once auth is restored, the next launchd trigger (next wake event or tomorrow's 06:00) will produce the report normally.

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
if [ -f "$TODAYS_TASKS" ] && ! grep -qE '^## Vault Agent' "$TODAYS_TASKS"; then
  cat >> "$TODAYS_TASKS" <<BANNER

## Vault Agent (skipped, no network)

Daily report not generated: could not reach the Anthropic API after ${MAX_ATTEMPTS} attempts. This was a connection or DNS failure, not an auth problem, most often the Mac waking for the scheduled run before Wi-Fi/DNS reconnected. The next launchd trigger (next wake event or tomorrow's 06:00) retries automatically. No action needed unless it recurs for several days.

BANNER
  echo "$(ts) - wrote no-network skipped banner to $TODAYS_TASKS" >> "$LOG"
fi
exit "$rc"
