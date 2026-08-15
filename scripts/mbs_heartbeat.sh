#!/bin/bash
# mbs_heartbeat.sh - verify that the morning report actually landed.
#
# WHY THIS EXISTS (2026-07-26)
# ----------------------------
# Every automation failure in this system so far was found by P noticing, not
# by the system reporting:
#   2026-07-05  connection/DNS failure at wake - silent
#   2026-07-06  API 401 - caught, because lib_auth.sh knew that wording
#   2026-07-24  out of usage credits (Fable) - caught, same reason
#   2026-07-25  OAuth session expired - SILENT for two days, because the
#               wording did not match lib_auth.sh's patterns
#
# Each fix widened the detector by one string. That approach can only ever
# catch failures whose wording was anticipated. This job takes the opposite
# approach: it does not care WHY the report is missing, only WHETHER it is
# there. It asks one question - "does today's tasks note contain a real
# ## Vault Agent section?" - and shouts if the answer is no.
#
# THE DESIGN RULE: this script must not share fate with what it checks.
# It therefore calls NO network service and NO `claude` binary. Pure bash,
# filesystem only. If it cannot run, the Mac is off, and nothing else ran
# either. Do not add a Claude call to this script - that would recreate the
# exact coupling it exists to break.
#
# Triggered by launchd (scripts/launchd/com.mbs.heartbeat.plist):
#   1. StartCalendarInterval at 11:00 local - well after mbs_daily's 06:00
#      fire plus its full five-attempt retry ladder (~1.75 hr of awake time).
#   2. RunAtLoad at login - so a Mac powered off all morning still gets checked.
#
# Roster as of 2026-08-15: seventeen checks (5b widened to three oura slugs
# and 14b added; both are sub-checks, not new roster entries). 14 (oura-watch ran) and 15
# (oura-trends artifact) were added alongside the Oura analysis layer; see
# SETUP.md 'Heartbeat update (2026-08-07)'. 16 (bulk-sync refused to classify
# an asset dir) was added when bulk_sync.sh was rewritten onto the encrypted
# S3 estate; 17 (the vault itself has a working offsite backup) was added when
# that gap was found and closed. Checks 6, 7, 10, 11, 13, 14, 15, 16 and 17
# self-arm on plist presence.
#
# Idempotence: per-day stamp, written ONLY on a healthy check. A failing check
# deliberately leaves no stamp, so every later trigger re-checks and re-nudges
# until the underlying problem is fixed. That nag is the feature.

set -uo pipefail

VAULT="/Users/cpreston/Vaults/storage_mbs"
STATE_DIR="$HOME/.mbs_automation"
STAMP="$STATE_DIR/last_heartbeat_run"
LOG="$STATE_DIR/mbs_heartbeat.log"

mkdir -p "$STATE_DIR"

TODAY="$(date +%Y-%m-%d)"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Pin the sentinel path to THIS script's STATE_DIR before sourcing. lib_auth.sh
# otherwise derives it from $HOME on its own; the two resolve identically today,
# but a watchdog that reads a different path than the writer is a watchdog that
# reports healthy forever. One source of truth.
REAUTH_SENTINEL="$STATE_DIR/needs_reauth"
export REAUTH_SENTINEL

# Source lib_auth.sh for alert_tasks_note() and the notification helper.
# shellcheck source=./lib_auth.sh
source "$(dirname "$0")/lib_auth.sh"
#
# NOTE the deliberate deviation from every other job in this cluster: we do NOT
# call needs_reauth_skip here. Other jobs skip when the reauth sentinel is fresh
# because calling Claude would be pointless. This job never calls Claude, and a
# fresh sentinel is precisely the condition it most needs to report. Skipping on
# the sentinel would blind the watchdog exactly when the system is broken.

# Already verified healthy today? Stop.
if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$TODAY" ]; then
  echo "$(ts) - already verified healthy for $TODAY, skipping." >> "$LOG"
  exit 0
fi

# If mbs_daily is still working (live PID in its lock), it is not late yet.
# Exit without stamping so the next trigger checks again.
DAILY_LOCK="$STATE_DIR/mbs_daily.lock"
if [ -d "$DAILY_LOCK" ]; then
  HOLDER_PID="$(cat "$DAILY_LOCK/pid" 2>/dev/null)"
  if [ -n "${HOLDER_PID:-}" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
    echo "$(ts) - mbs_daily still running (PID $HOLDER_PID); not late yet, will re-check on next trigger." >> "$LOG"
    exit 0
  fi
fi

# Same not-late-yet guard for team-brief: its 06:45 fire plus a full retry
# ladder (~35 min) is normally long done by 11:00, but a wake-coalesced fire
# can still be mid-run when a login triggers this heartbeat. Live PID in its
# lock = not late yet; exit without stamping so the next trigger re-checks.
TEAM_BRIEF_LOCK="$STATE_DIR/team_brief.lock"
if [ -f "$HOME/Library/LaunchAgents/com.mbs.team-brief.plist" ] && [ -d "$TEAM_BRIEF_LOCK" ]; then
  HOLDER_PID="$(cat "$TEAM_BRIEF_LOCK/pid" 2>/dev/null)"
  if [ -n "${HOLDER_PID:-}" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
    echo "$(ts) - team_brief still running (PID $HOLDER_PID); not late yet, will re-check on next trigger." >> "$LOG"
    exit 0
  fi
fi

TASKS_NOTE="$VAULT/daily_notes/tasks/tasks_${TODAY}.md"

# Findings are accumulated as a counter + newline-joined string rather than a
# bash array. Reason: launchd runs this with /bin/bash, which on macOS is still
# 3.2, and there `${#arr[@]}` on an EMPTY array under `set -u` aborts with
# "unbound variable" - so a perfectly healthy day would crash the watchdog.
# Verified the hard way: the array version passed on the Linux test host
# (bash 5) and would have failed on the Mac.
FINDING_COUNT=0
FINDINGS_TEXT=""
FIRST_FINDING=""
add_finding() {
  FINDING_COUNT=$((FINDING_COUNT + 1))
  [ -z "$FIRST_FINDING" ] && FIRST_FINDING="$1"
  FINDINGS_TEXT="${FINDINGS_TEXT}${1}
"
}

# --- check 1: today's tasks note exists -------------------------------------
if [ ! -f "$TASKS_NOTE" ]; then
  add_finding "today's tasks note does not exist at all (tasks_${TODAY}.md)"
else
  # --- check 2: it carries a REAL ## Vault Agent section --------------------
  # A "## Vault Agent (skipped...)" banner means the daily job explained itself
  # on the way down. That is better than silence, but the report still did not
  # land, so it counts as a finding - with the cause already named in the note.
  if grep -qE '^## Vault Agent \(skipped' "$TASKS_NOTE"; then
    add_finding "the daily report was skipped and said so in today's note - see the '## Vault Agent (skipped' banner there for the reason"
  elif ! grep -qE '^## Vault Agent' "$TASKS_NOTE"; then
    add_finding "today's tasks note has no ## Vault Agent section - the morning report did not land"
  fi

  # --- check 2b: the open_tasks property was stamped ------------------------
  # mbs_daily writes `open_tasks: <n>` into the frontmatter when it creates (or
  # first touches) today's note. Missing field = the stamp did not run, so the
  # property is silently absent for the day. Presence check only: the watchdog
  # asks whether the output exists, never why, and never recounts anything.
  if ! awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$TASKS_NOTE" | grep -q '^open_tasks:'; then
    add_finding "today's tasks note has no open_tasks property - the morning stamp did not run"
  fi
fi

# --- check 3: the daily job's own stamp agrees ------------------------------
DAILY_STAMP="$STATE_DIR/last_daily_run"
LAST_DAILY="$(cat "$DAILY_STAMP" 2>/dev/null || echo none)"
if [ "$LAST_DAILY" != "$TODAY" ]; then
  add_finding "mbs_daily has not completed successfully since ${LAST_DAILY} (its stamp is stale)"
fi

# --- check 4: is Claude Code sitting in a known-broken auth state? ----------
if [ -f "$REAUTH_SENTINEL" ]; then
  FIRST_SEEN="$(cat "$REAUTH_SENTINEL" 2>/dev/null || echo unknown)"
  add_finding "Claude CLI needs re-auth (first detected ${FIRST_SEEN}) - run \`claude\` then \`/login\` in Terminal"
fi

# --- check 5: oura sync archive is fresh ------------------------------------
# Canary: health/health_physical/oura/raw/daily_activity/ - the single most
# fundamental DATED oura endpoint (step count, calories, activity score).
# Every DATED/EVENT endpoint gets a file written on every successful sync run
# even on a no-event day (confirmed 2026-07-30: workout/ and vO2_max/, both
# sparse-data endpoints, had a same-day fresh file anyway) - the archive
# writes something daily, not only when there's a real event.
#
# Checked by mtime, deliberately NOT by the date encoded in the filename:
# Oura's own scoring lag means the newest file is normally named for
# YESTERDAY (activity/sleep finalize the next morning), so a
# same-day-filename check would false-positive every single day by design.
# 2 days of slack tolerates one missed sync (the sync job's own --lookback
# self-heals a gap on the next successful run, but ONLY for days still inside
# that window - raised 3 -> 7 on 2026-08-15 after a 3-day gap was on course to
# age out unrepaired; a gap older than the lookback needs an explicit
# `oura_sync.py --backfill START:END` and no job will ever do it unasked).
#
# The daily note's oura frontmatter fields (sleep_score, readiness_score,
# ...) were considered and rejected as the canary: daily_notes/health/daily/
# is created by the Journals plugin only when Obsidian is opened (see this
# script's own "Known non-findings" note in SETUP.md), so its absence means
# "P didn't open Obsidian today," not "oura sync failed" - using it would
# conflate two independent failure modes into one noisy, wrong signal.
#
# Not gated on which launchd label owns the job (com.cpreston.mbs-oura-sync
# vs. the renamed com.mbs.oura-sync, see Phase 1 build report): the archive
# path is the same either way, and the sync itself is already live today,
# unlike the two new jobs below.
OURA_CANARY_DIR="$VAULT/health/health_physical/oura/raw/daily_activity"
# Declared out here, not inside the else branch: check 14b reads it to avoid
# double-reporting one root cause, and `set -u` aborts on an unset variable if
# the canary directory is missing.
OURA_EMPTY_SLUGS=""
if [ ! -d "$OURA_CANARY_DIR" ]; then
  add_finding "oura sync archive directory missing ($OURA_CANARY_DIR) - the oura-sync launchd job may never have run, or the vault path changed"
else
  OURA_RECENT="$(find "$OURA_CANARY_DIR" -maxdepth 1 -name '*.json' -mtime -2 2>/dev/null | head -1)"
  if [ -z "$OURA_RECENT" ]; then
    add_finding "oura sync: no daily_activity archive file modified in the last 2 days ($OURA_CANARY_DIR) - check the oura-sync launchd job"
  fi

  # --- check 5b: the fresh files aren't just fresh, they have real data -----
  # Added 2026-08-01 after discovering the freshness check above cannot catch
  # this: for the full 2026-05-26 through 2026-07-31 history, daily_activity
  # wrote a fresh, valid, EMPTY {"data": [], "next_token": null} file every
  # single day (a client-side query-parameter bug, not an Oura outage) and
  # check 5 read that as perfectly healthy for over two months. Freshness
  # alone cannot distinguish "the job ran and got real data" from "the job
  # ran and silently got nothing" - the same blind spot check 2 avoids for
  # the daily report by checking for content, not just file presence.
  #
  # The two most recent dated files (by filename, excluding any file dated
  # today - Oura's scoring lag means today's often has not published yet and
  # a same-day empty read is expected, not a fault) are inspected for the
  # exact-empty payload archive.py writes: pretty-printed JSON always
  # serializes an empty result as the literal line `"data": []`. Two
  # consecutive real days both empty is the threshold: verified against the
  # actual archive this session that zero days were genuinely empty for
  # daily_activity in 68 days of history, so two in a row is a strong signal
  # of a regression, not a coincidence of ring-off-charging days.
  #
  # WIDENED 2026-08-15, from daily_activity alone to the three slugs the rest
  # of the system actually consumes. daily_activity is the canary for "did the
  # archive get written"; `sleep` and `daily_readiness` are where all six
  # curated daily-note fields come from (note.py FIELDS_TO_PATCH) and what
  # oura_watch.py reads every morning. A daily_activity-only check passes clean
  # while `sleep` goes empty and four of the six fields silently stop
  # appearing, which is exactly the 2026-06 failure that ran for a week before
  # P spotted it by eye. Each slug is judged on its own two most recent files,
  # so one sparse endpoint cannot mask another.
  #
  # CAUSE REMOVED FROM THE FINDING 2026-08-15. The old text ended "check the
  # oura-sync launchd job and api.py's query params" and that is not something
  # this script can know. Two empty days is equally consistent with a
  # client-side fetch bug and with the ring never reaching Oura's cloud, and
  # telling those apart needs a network call this script is forbidden to make
  # (ADR 2026-07-26, watchdog independence). On 2026-08-14 the asserted cause
  # pointed the investigation at api.py, which had been correct since the
  # 2026-08-01 exclusive-end_date fix, while every endpoint including the
  # inclusive-param ones was equally empty. State the observation, name where
  # the answer lives, stop there.
  for oura_slug in daily_activity sleep daily_readiness; do
    OURA_SLUG_DIR="$VAULT/health/health_physical/oura/raw/$oura_slug"
    [ -d "$OURA_SLUG_DIR" ] || continue
    OURA_CONTENT_CHECK_FILES="$(find "$OURA_SLUG_DIR" -maxdepth 1 -name '*.json' ! -name "${TODAY}.json" 2>/dev/null | sort -r | head -2)"
    OURA_CONTENT_FILE_COUNT="$(printf '%s\n' "$OURA_CONTENT_CHECK_FILES" | grep -c . || true)"
    [ "$OURA_CONTENT_FILE_COUNT" -ge 2 ] || continue
    OURA_ALL_EMPTY=1
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      grep -qF '"data": []' "$f" 2>/dev/null || OURA_ALL_EMPTY=0
    done <<< "$OURA_CONTENT_CHECK_FILES"
    if [ "$OURA_ALL_EMPTY" -eq 1 ]; then
      OURA_EMPTY_SLUGS="${OURA_EMPTY_SLUGS}${OURA_EMPTY_SLUGS:+, }$oura_slug"
    fi
  done
  if [ -n "$OURA_EMPTY_SLUGS" ]; then
    add_finding "oura sync: the 2 most recent archive files are both empty (\"data\": []) for ${OURA_EMPTY_SLUGS} - the files are fresh, so the job ran and wrote what it got; whether the ring stopped reaching Oura or the fetch broke needs ~/Library/Logs/mbs-oura-sync.log plus one direct API query"
  fi
fi

# --- check 6: pointer-check ran recently (once activated) -------------------
# Gated on the job actually being installed
# (~/Library/LaunchAgents/com.mbs.pointer-check.plist present). This
# heartbeat script is LIVE infrastructure - com.mbs.heartbeat already runs
# daily at 11:00 and at every login - so an UNGATED check here would start
# reporting "pointer-check has never run" the moment this file is saved,
# even though Phase 1 is build-only and the architect has not activated
# pointer-check yet. Gating on plist presence means this check switches
# itself on exactly when the architect runs the activation command (cp +
# launchctl bootstrap) - no separate step, no false alarm in the interim.
#
# Stamp comparison is TODAY-or-YESTERDAY, deliberately NOT stamp==TODAY (the
# mbs_daily pattern). com.mbs.pointer-check fires at 23:45 - AFTER this
# heartbeat's own 11:00 check, same calendar day. So on a perfectly healthy
# system, the stamp this heartbeat sees at 11:00 was written by YESTERDAY's
# 23:45 run; today's hasn't fired yet. stamp==TODAY would therefore fire a
# finding every single day regardless of actual health, training P to ignore
# the heartbeat - exactly the failure mode this whole job exists to avoid.
if [ -f "$HOME/Library/LaunchAgents/com.mbs.pointer-check.plist" ]; then
  POINTER_STAMP="$STATE_DIR/last_pointer_check_run"
  LAST_POINTER="$(cat "$POINTER_STAMP" 2>/dev/null || echo none)"
  YESTERDAY="$(date -v-1d +%Y-%m-%d)"
  if [ "$LAST_POINTER" != "$TODAY" ] && [ "$LAST_POINTER" != "$YESTERDAY" ]; then
    add_finding "pointer-check has not completed since ${LAST_POINTER} (expected ${YESTERDAY} or ${TODAY}, given its 23:45 schedule) - check com.mbs.pointer-check"
  fi

  # --- check 6b: the last run actually scanned a vault (2026-08-15) ---------
  # P chose the log as the artifact. pointer_check.sh writes one line per run:
  #   vault_health.py: 9571 notes scanned, 505 broken wikilink(s) after ...
  # Read from the LAST "starting pointer check run" marker forward, so this
  # judges the most recent run rather than finding an old healthy number left
  # by a run three days ago. Two distinct faults are separated deliberately:
  # a run that never reached the scan line died partway, while a run that
  # reached it and reported 0 notes found a vault that is empty or has moved.
  PC_LOG="$STATE_DIR/pointer_check.log"
  if [ -f "$PC_LOG" ]; then
    PC_START_LINE="$(grep -n 'starting pointer check run' "$PC_LOG" 2>/dev/null | tail -1 | cut -d: -f1)"
    if [ -n "$PC_START_LINE" ]; then
      PC_SCANNED="$(tail -n "+${PC_START_LINE}" "$PC_LOG" 2>/dev/null | sed -n 's/.*vault_health.py: \([0-9][0-9]*\) notes scanned.*/\1/p' | tail -1)"
      if [ -z "$PC_SCANNED" ]; then
        add_finding "pointer-check's most recent run never reached its vault_health.py scan line - it started and died partway; check ~/.mbs_automation/pointer_check.log"
      elif [ "$PC_SCANNED" -eq 0 ]; then
        add_finding "pointer-check scanned 0 notes on its most recent run (healthy runs scan ~9,500) - the vault path is wrong or unreadable from the job; check ~/.mbs_automation/pointer_check.log"
      fi
    fi
  fi
fi

# --- check 7: bulk-sync ran today, tolerant of dry-run mode (once activated)
# Gated the same way and for the same reason as check 6 - bulk-sync is not
# yet activated in Phase 1.
#
# Unlike pointer-check, stamp==TODAY IS the right comparison here:
# com.mbs.bulk-sync fires at 03:00, BEFORE this heartbeat's 11:00 check, same
# calendar day - so a healthy run's stamp already reads today by the time
# this runs (matches the mbs_daily pattern).
#
# "Tolerant of dry-run mode": bulk_sync.sh writes its stamp on ANY successful
# completion, whether LIVE=0 (Phase 1, --dryrun, the current hardwired state)
# or LIVE=1 (a later, separately-approved phase). This check only reads that
# stamp - it does not inspect LIVE or look for "--dryrun" anywhere - so a
# healthy dry-run reads as healthy, full stop. It is not something this check
# needs to special-case; it falls out of checking the right thing.
if [ -f "$HOME/Library/LaunchAgents/com.mbs.bulk-sync.plist" ]; then
  BULK_SYNC_STAMP="$STATE_DIR/last_bulk_sync_run"
  LAST_BULK_SYNC="$(cat "$BULK_SYNC_STAMP" 2>/dev/null || echo none)"
  if [ "$LAST_BULK_SYNC" != "$TODAY" ]; then
    add_finding "bulk-sync has not completed since ${LAST_BULK_SYNC} (its stamp is stale) - check com.mbs.bulk-sync"
  else
    # --- check 7b: the stamp means LIVE, and no pillar was skipped ----------
    # 2026-08-15, and this deliberately REVERSES the "tolerant of dry-run mode"
    # reasoning in the comment above. That tolerance was right while bulk-sync
    # was hardwired to LIVE=0 during Phase 1 build-out: a healthy dry-run was
    # then the expected healthy state. bulk-sync has run LIVE since 2026-08-08,
    # so from here a DRY-RUN that stamps success is a silent regression in the
    # job that holds the only offsite copy of P's assets, and the stamp alone
    # cannot see it. bulk_sync.sh writes the mode into its own success line.
    #
    # Second assertion: copy_pillar() returns 0 and logs "not present locally,
    # skipped" for a missing source dir, which does NOT block the stamp. A
    # pillar that quietly stops existing therefore reads as a clean backup of
    # everything while that pillar has no backup at all.
    BS_LOG="$STATE_DIR/bulk_sync.log"
    if [ -f "$BS_LOG" ]; then
      BS_TODAY="$(grep "^${TODAY} " "$BS_LOG" 2>/dev/null)"
      if ! printf '%s\n' "$BS_TODAY" | grep -q 'OK (mode=LIVE): all pillars copied'; then
        if printf '%s\n' "$BS_TODAY" | grep -q 'mode=DRY-RUN'; then
          add_finding "bulk-sync stamped success for ${TODAY} but ran in DRY-RUN mode - nothing reached S3; check the LIVE setting in bulk_sync.sh"
        else
          add_finding "bulk-sync stamped success for ${TODAY} with no 'OK (mode=LIVE): all pillars copied' line in today's log - check ~/.mbs_automation/bulk_sync.log"
        fi
      fi
      BS_SKIPPED="$(printf '%s\n' "$BS_TODAY" | sed -n 's/.* \([a-z_][a-z_]*\): not present locally, skipped.*/\1/p' | tr '\n' ' ')"
      if [ -n "$BS_SKIPPED" ]; then
        add_finding "bulk-sync reported success while skipping pillar(s) missing from the local asset mirror: ${BS_SKIPPED}- those have no offsite copy"
      fi
    fi
  fi
fi

# --- check 8: music-discovery dispatch is fresh (added 2026-08-01) -----------
# Canary: newest dispatch_*.md in culture/listen/project_music_discovery/.
# The job (com.mbs.music-discovery, renamed from com.cp250.* 2026-08-01) fires
# Mondays 06:00 and writes one dispatch per run, so on a healthy system the
# newest dispatch is at most 7 days old; 8 days of slack tolerates a late
# Monday. Checked by mtime like check 5 (filename dates lag). Ungated: the job
# is live, unlike checks 6/7 at their creation. Findings land in today's tasks
# note via alert_tasks_note like every other check (P's requirement 2026-08-01).
MUSIC_DIR="$VAULT/culture/listen/project_music_discovery"
if [ ! -d "$MUSIC_DIR" ]; then
  add_finding "music-discovery output dir missing ($MUSIC_DIR) - check com.mbs.music-discovery"
else
  MUSIC_RECENT="$(find "$MUSIC_DIR" -maxdepth 1 -name 'dispatch_*.md' -mtime -8 2>/dev/null | head -1)"
  if [ -z "$MUSIC_RECENT" ]; then
    add_finding "music-discovery: no dispatch file modified in the last 8 days ($MUSIC_DIR) - check com.mbs.music-discovery"
  else
    # --- check 8b: the fresh dispatch has releases in it (2026-08-15) -------
    # Every dispatch opens with a summary line:
    #   _144 release(s) across 3 store(s), parsed from 6 email(s). ..._
    # Threshold is zero, and that is grounded rather than guessed: all 21
    # dispatches from 2026-03-16 to 2026-08-10 carry the line, and the
    # smallest week on record is 80 releases across 2 stores from 5 emails.
    # A zero has never happened, so one means the Gmail label, the parser or
    # the store emails broke, not a quiet week. A dispatch written with zero
    # releases is otherwise indistinguishable from a healthy one by mtime,
    # which is the same blind spot check 5b was added to close for oura.
    MUSIC_NEWEST="$(ls -t "$MUSIC_DIR"/dispatch_*.md 2>/dev/null | head -1)"
    if [ -n "$MUSIC_NEWEST" ]; then
      MUSIC_RELEASES="$(sed -n 's/^_\([0-9][0-9]*\) release(s) across.*/\1/p' "$MUSIC_NEWEST" 2>/dev/null | head -1)"
      if [ -z "$MUSIC_RELEASES" ]; then
        add_finding "music-discovery: $(basename "$MUSIC_NEWEST") has no '_N release(s) across ...' summary line - the dispatch is fresh but malformed; check com.mbs.music-discovery"
      elif [ "$MUSIC_RELEASES" -eq 0 ]; then
        add_finding "music-discovery: $(basename "$MUSIC_NEWEST") reports 0 releases (smallest week on record is 80) - the Gmail label or the parser is broken, not a quiet week"
      fi
      # --- check 8c: no source failed on the run that wrote it (2026-08-15) --
      # Since v0.2 the job pulls from two independent sources: the Gmail label
      # (four record shops) and the thequietus.com REST API. index.js isolates
      # each one, so a dead source degrades the dispatch instead of killing the
      # run, and it records that in a "sources_failed:" frontmatter key. Without
      # this check a Quietus outage or a Cloudflare block would produce a
      # dispatch that looks entirely healthy to checks 8 and 8b: fresh mtime,
      # non-zero release count, silently missing its whole reviews section.
      MUSIC_FAILED="$(sed -n 's/^sources_failed:[[:space:]]*//p' "$MUSIC_NEWEST" 2>/dev/null | head -1)"
      if [ -n "$MUSIC_FAILED" ]; then
        add_finding "music-discovery: $(basename "$MUSIC_NEWEST") was written with a failed source (${MUSIC_FAILED}) - that section is missing from the dispatch; check ~/dev/mbs-music-discovery/run.log, then regenerate with: cd ~/dev/mbs-music-discovery && node index.js --week=$(basename "$MUSIC_NEWEST" .md | sed 's/^dispatch_//') --force"
      fi
    fi
  fi
fi

# --- check 9: capture triage ran inside the morning report (added 2026-08-01)
# The obsidian-daily command emits a "### Triage" marker inside ## Vault Agent
# on every run, even a nothing-to-triage day (project_task_triage phase 1).
# Fires only when a REAL report landed without the marker: that is "the daily
# ran but the triage step was silently dropped". Mornings with no report at
# all are already covered by checks 2/3; re-flagging here would double the
# noise. First expected live morning: 2026-08-02 (2026-08-01's report predates
# the feature, and that day's heartbeat had already stamped healthy).
if [ -f "$TASKS_NOTE" ] && grep -qE '^## Vault Agent' "$TASKS_NOTE" \
   && ! grep -qE '^## Vault Agent \(skipped' "$TASKS_NOTE" \
   && ! grep -qE '^### Triage' "$TASKS_NOTE"; then
  add_finding "morning report landed without its ### Triage subsection - the capture-triage step did not run; check ~/dev/mbs_automation/commands/obsidian-daily.md step 3c and ~/.mbs_automation/mbs_daily.log"
fi

# --- check 10: review prep drafted into the current review notes (2026-08-01)
# project_task_triage phase 2: com.mbs.review-{monthly,quarterly,yearly} run
# review_reminder.sh (note + notification), then claude drafts a "## Agent
# prep" section into the period's note in admin/reviews/. Artifact check only,
# per the watchdog rule: does the section exist. Grace windows cover the
# creation lag (monthly: first 2 days of the month; quarterly: first 2 days of
# the quarter's opening month; yearly: first 2 days of January). Gated on the
# monthly plist being installed, same self-arming pattern as checks 6/7.
if [ -f "$HOME/Library/LaunchAgents/com.mbs.review-monthly.plist" ]; then
  DOM=$(( 10#$(date +%d) ))
  MON=$(( 10#$(date +%m) ))
  MNOTE="$VAULT/admin/reviews/review_monthly_$(date +%Y-%m).md"
  if [ "$DOM" -ge 3 ] && { [ ! -f "$MNOTE" ] || ! grep -q '^## Agent prep' "$MNOTE"; }; then
    add_finding "monthly review prep missing: review_monthly_$(date +%Y-%m).md has no '## Agent prep' section - check com.mbs.review-monthly and ~/.mbs_automation/mbs_review_prep.log"
  fi
  QQ=$(( (MON - 1) / 3 + 1 ))
  QSTART=$(( (QQ - 1) * 3 + 1 ))
  QNOTE="$VAULT/admin/reviews/review_quarterly_$(date +%Y)-Q${QQ}.md"
  if { [ "$MON" -ne "$QSTART" ] || [ "$DOM" -ge 3 ]; } && { [ ! -f "$QNOTE" ] || ! grep -q '^## Agent prep' "$QNOTE"; }; then
    add_finding "quarterly review prep missing: review_quarterly_$(date +%Y)-Q${QQ}.md has no '## Agent prep' section - check com.mbs.review-quarterly and ~/.mbs_automation/mbs_review_prep.log"
  fi
  YNOTE="$VAULT/admin/reviews/review_yearly_$(date +%Y).md"
  if [ "$MON" -eq 1 ] && [ "$DOM" -ge 3 ] && { [ ! -f "$YNOTE" ] || ! grep -q '^## Agent prep' "$YNOTE"; }; then
    add_finding "yearly review prep missing: review_yearly_$(date +%Y).md has no '## Agent prep' section - check com.mbs.review-yearly and ~/.mbs_automation/mbs_review_prep.log"
  fi
fi

# --- check 11: team brief landed (added 2026-08-03) --------------------------
# Artifact first, per the watchdog rule: does today's brief file exist in
# social/project_team_brief/briefs/. The job (com.mbs.team-brief) fires 06:45,
# before this heartbeat's 11:00 check, so today-scoped checks are correct
# (mbs_daily pattern, unlike check 6's yesterday-tolerant stamp). Gated on the
# plist being installed, same self-arming pattern as checks 6/7. The second
# finding distinguishes the delivery-failed case: team_brief.sh archives the
# brief BEFORE emailing and stamps only after the send, so file-present with
# stamp-stale means generation landed but the email did not.
if [ -f "$HOME/Library/LaunchAgents/com.mbs.team-brief.plist" ]; then
  TEAM_BRIEF_FILE="$VAULT/social/project_team_brief/briefs/brief_${TODAY}.md"
  TEAM_BRIEF_STAMP="$STATE_DIR/last_team_brief_run"
  LAST_TEAM_BRIEF="$(cat "$TEAM_BRIEF_STAMP" 2>/dev/null || echo none)"
  if [ ! -f "$TEAM_BRIEF_FILE" ]; then
    add_finding "team-brief: no brief file for today (social/project_team_brief/briefs/brief_${TODAY}.md) - check com.mbs.team-brief and ~/.mbs_automation/team_brief.log"
  elif [ "$LAST_TEAM_BRIEF" != "$TODAY" ]; then
    add_finding "team-brief: today's brief file exists but the job never stamped success - the EMAIL likely failed after generation; check ~/.mbs_automation/team_brief.log"
  fi
fi

# --- check 12: session-awareness sweep landed (added 2026-08-03) -------------
# Artifact-only, per the watchdog rule: is there a report in the canonical
# folder with an mtime inside the last 35 days. The sweep is a Cowork scheduled
# task (monthly, 1st at 08:39), not launchd, so there is no plist to gate on
# and no stamp file to read - the report IS the only evidence it ran.
#
# Be honest about what this buys: at monthly cadence a dead job stays invisible
# for up to five weeks. This check satisfies the manual's rule that every job
# P depends on gets a watchdog, and nothing more. The real detection is that a
# report either appears on the 1st or it does not. If the 2026-10-01 retirement
# review keeps the job, consider having the sweep write a stamp.
#
# Self-arming: silent until the folder holds at least one report, so it never
# fires on a fresh machine.
SWEEP_DIR="$VAULT/admin/mbs_system/design/session_awareness"
if [ -d "$SWEEP_DIR" ] && ls "$SWEEP_DIR"/report_*.md >/dev/null 2>&1; then
  if [ -z "$(find "$SWEEP_DIR" -name 'report_*.md' -mtime -35 -print -quit 2>/dev/null)" ]; then
    add_finding "session-awareness sweep: no report in admin/mbs_system/design/session_awareness/ modified in the last 35 days - the monthly Cowork task (1st, 08:39) may have stopped running or is writing elsewhere; check Cowork sidebar > Scheduled"
  fi
fi

# --- check 13: the-record has no transcript stuck unprocessed (added 2026-08-07)
# com.mbs.the-record is EVENT-anchored (WatchPaths on the raw/ drop-zone), not
# clock-anchored, so there is no daily artifact to look for and no stamp that
# should read today. Asking "did it produce output today?" would fire every day
# P simply had nothing to capture - which is not a fault, it is the no-cadence
# rule working as designed.
#
# The question that IS answerable without knowing why: has a transcript landed
# in raw/ and NOT been recorded in the job's processed-manifest? That is the
# only state where P is owed output and is not getting it. Artifact-shaped,
# no network, no claude - same contract as every other check here.
#
# 24h of slack (-mmin +1440), deliberately generous: WatchPaths fires within
# seconds, but a transcript dropped while the Mac is asleep waits for RunAtLoad
# at the next login, and heartbeat's own RunAtLoad can win that race. A file
# unprocessed for a full day is unambiguous; anything tighter trades a real
# signal for false alarms, which is how a watchdog gets ignored.
#
# The live-lock guard skips the check mid-run (the job holds the_record.lock
# while claude works), rather than exiting the whole heartbeat the way the
# mbs_daily and team-brief guards do - a busy the-record says nothing about
# the other twelve checks.
#
# Second finding, separate failure mode: the plist's WatchPaths is a hardcoded
# absolute path. The folder was already promoted once (money/verition/the_record
# -> money/project_the_record, 2026-07-21). If it moves again, the trigger dies
# silently and nothing else in the system would ever notice.
#
# Gated on the plist being installed, same self-arming pattern as checks 6/7/11.
# That gate is load-bearing here: runbook.md documents permanent teardown as
# `rm ~/Library/LaunchAgents/com.mbs.the-record.plist`, so when P ends the
# project the watchdog retires itself with it. A `bootout`-only pause leaves the
# plist in place and this check will still speak up, which is why the finding
# names that possibility instead of asserting a failure.
if [ -f "$HOME/Library/LaunchAgents/com.mbs.the-record.plist" ]; then
  RECORD_RAW="$VAULT/money/project_the_record/raw"
  RECORD_MANIFEST="$STATE_DIR/the_record_processed.txt"
  RECORD_LOCK="$STATE_DIR/the_record.lock"
  RECORD_BUSY=0
  if [ -d "$RECORD_LOCK" ]; then
    RECORD_PID="$(cat "$RECORD_LOCK/pid" 2>/dev/null)"
    if [ -n "${RECORD_PID:-}" ] && kill -0 "$RECORD_PID" 2>/dev/null; then
      RECORD_BUSY=1
    fi
  fi
  if [ ! -d "$RECORD_RAW" ]; then
    add_finding "the-record: the raw/ drop-zone is missing ($RECORD_RAW) - the plist's WatchPaths is an absolute path, so a moved or renamed folder kills the trigger silently; check com.mbs.the-record"
  elif [ "$RECORD_BUSY" -eq 0 ]; then
    RECORD_STUCK_COUNT=0
    RECORD_STUCK_FIRST=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      RECORD_BASE="$(basename "$f")"
      if [ ! -f "$RECORD_MANIFEST" ] || ! grep -Fxq "$RECORD_BASE" "$RECORD_MANIFEST"; then
        RECORD_STUCK_COUNT=$((RECORD_STUCK_COUNT + 1))
        [ -z "$RECORD_STUCK_FIRST" ] && RECORD_STUCK_FIRST="$RECORD_BASE"
      fi
    done < <(find "$RECORD_RAW" -maxdepth 1 -type f -name '*.md' -mmin +1440 2>/dev/null | sort)
    if [ "$RECORD_STUCK_COUNT" -gt 0 ]; then
      add_finding "the-record: ${RECORD_STUCK_COUNT} transcript(s) in money/project_the_record/raw/ unprocessed for over 24h (oldest: ${RECORD_STUCK_FIRST}) - the job did not fire, failed, or is booted out; check ~/.mbs_automation/the_record.log and com.mbs.the-record"
    fi
  fi
fi

# --- check 14: oura-watch actually ran (stamp-based, deliberately) -----------
# com.mbs.oura-watch is SILENT BY DESIGN: on P's own 68-night archive it would
# have spoken on 3 nights (4.4%). So "did it produce output today" is the wrong
# question - it would fire on ~95% of healthy days and train P to ignore this
# whole job, which is the exact failure mode the heartbeat exists to prevent.
# The only answerable question for a silent-by-design job is whether it RAN,
# and oura_watch.sh writes its per-day stamp on every success INCLUDING silent
# ones precisely so this check has something to read.
#
# Same family as check 13 (the-record), different mechanism: an event-anchored
# job has no cadence, so 13 diffs unconsumed input against a manifest; this job
# does have a cadence, so a stamp is sufficient. The shared rule: ask the
# question the job's own shape makes answerable.
#
# TODAY-or-YESTERDAY, not stamp==TODAY: oura-watch fires at 10:30 and this
# heartbeat at 11:00, same calendar day, so on a healthy Mac today's stamp is
# normally already there. The yesterday tolerance covers a late wake, where
# launchd runs the 10:30 job after this 11:00 check has already passed.
#
# Gated on plist presence so it self-arms when P installs the job and retires
# itself if he removes the plist.
if [ -f "$HOME/Library/LaunchAgents/com.mbs.oura-watch.plist" ]; then
  OURA_WATCH_STAMP="$STATE_DIR/last_oura_watch_run"
  LAST_OURA_WATCH="$(cat "$OURA_WATCH_STAMP" 2>/dev/null || echo none)"
  OURA_YESTERDAY="$(date -v-1d +%Y-%m-%d)"
  if [ "$LAST_OURA_WATCH" != "$TODAY" ] && [ "$LAST_OURA_WATCH" != "$OURA_YESTERDAY" ]; then
    add_finding "oura-watch has not completed since ${LAST_OURA_WATCH} (expected ${OURA_YESTERDAY} or ${TODAY}, given its 10:30 schedule) - note that this job writing NOTHING is normal, it is the job not RUNNING that this reports; check ~/.mbs_automation/oura_watch.log and com.mbs.oura-watch"
  fi

  # --- check 14b: oura-watch evaluated a RECENT night, not just any night ----
  # Added 2026-08-15. Check 14 above asks only whether the job ran, and that is
  # not the same question as whether its silence means anything. On 2026-08-13
  # and 2026-08-14 oura-watch ran, loaded an archive whose newest night was
  # three days old, wrote "NOTE newest archived night is 3 days old ... the sync
  # may be stuck" into its own log, found no anomalies (of course: it was
  # re-reading a night it had already cleared), stamped success, and check 14
  # reported healthy both mornings. The job knew. The watchdog never asked.
  #
  # oura_watch.py already prints the answer on every run:
  #   oura-watch: target_night=2026-08-11 (newest in archive, 3 day(s) old) ...
  # so this parses its own log rather than recomputing anything. That keeps the
  # watchdog-independence rule intact: still no network, still no `claude`, just
  # a file read.
  #
  # Suppressed when check 5b already fired. An empty archive makes the newest
  # loadable night stale by definition, so both checks would fire on one root
  # cause and P would get the same problem twice in one alert line. When 5b is
  # quiet and this fires, the archive has real data that oura-watch is somehow
  # not reading, which is a genuinely different fault worth its own words.
  #
  # Threshold 2 days, matching check 5's mtime tolerance: Oura's scoring lag
  # makes a 1-day-old newest night normal every single morning.
  OURA_WATCH_LOG="$STATE_DIR/oura_watch.log"
  if [ -z "$OURA_EMPTY_SLUGS" ] && [ -f "$OURA_WATCH_LOG" ]; then
    OURA_WATCH_NIGHT_AGE="$(grep 'newest in archive' "$OURA_WATCH_LOG" 2>/dev/null | tail -1 | sed -n 's/.*newest in archive, \([0-9][0-9]*\) day(s) old.*/\1/p')"
    if [ -n "$OURA_WATCH_NIGHT_AGE" ] && [ "$OURA_WATCH_NIGHT_AGE" -gt 2 ]; then
      add_finding "oura-watch last evaluated a night ${OURA_WATCH_NIGHT_AGE} days old (threshold 2) - it ran and found no anomaly, but it was re-reading stale data, so its silence is not evidence of a healthy night; check ~/.mbs_automation/oura_watch.log"
    fi
  fi
fi

# --- check 15: oura-trends wrote its section into this month's review --------
# Artifact-based, mirroring check 10, because unlike oura-watch this job does
# produce output every period. Two-day grace so a Mac that was off on the 1st
# is not a finding. Gated on plist presence, same self-arming reason as 14.
#
# The missing-note case is reported separately and points at check 10 rather
# than blaming this job: oura-trends deliberately refuses to create the review
# note, because com.mbs.review-monthly owns that note's shape.
if [ -f "$HOME/Library/LaunchAgents/com.mbs.oura-trends.plist" ]; then
  OURA_TRENDS_DOM="$(date +%d)"
  if [ "${OURA_TRENDS_DOM#0}" -ge 3 ]; then
    OURA_TRENDS_PERIOD="$(date +%Y-%m)"
    OURA_TRENDS_NOTE="$VAULT/admin/reviews/review_monthly_${OURA_TRENDS_PERIOD}.md"
    if [ ! -f "$OURA_TRENDS_NOTE" ]; then
      add_finding "oura-trends has no review note to write into for ${OURA_TRENDS_PERIOD} - the upstream problem is com.mbs.review-monthly, which check 10 should also be reporting"
    elif ! grep -q '^## Oura trends' "$OURA_TRENDS_NOTE"; then
      add_finding "oura-trends did not write its section into review_monthly_${OURA_TRENDS_PERIOD}.md - check ~/.mbs_automation/oura_trends.log and com.mbs.oura-trends"
    fi
  fi
fi

# --- check 16: bulk-sync found nothing it refused to classify (2026-08-08) ---
# Companion to check 7. Check 7 asks whether bulk-sync RAN; this asks whether
# it silently SKIPPED something, which a stamp cannot express.
#
# bulk_sync.sh maps each top-level dir of ~/storage_mbs_assets/ to a crypt tier
# (bulk vs sensitive) from a fixed list. A directory it does not recognise is
# deliberately NOT uploaded - guessing a tier could put sensitive material
# under the bulk key, which the automation EC2 box is allowed to hold, so a
# gap is the safer failure. But an un-backed-up pillar that nobody is told
# about is exactly the silent failure this heartbeat exists to end, so the
# script drops a marker file and this check turns it into a nag.
#
# Fix: add the directory to BULK_PILLARS or SENSITIVE_PILLARS in
# ~/dev/mbs_automation/scripts/bulk_sync.sh (and keep it in agreement with
# mbs_aws/scripts/classification-reference.tsv). The marker clears itself on
# the next run once every directory is classified.
if [ -f "$HOME/Library/LaunchAgents/com.mbs.bulk-sync.plist" ]; then
  BULK_SYNC_UNCLASSIFIED="$STATE_DIR/bulk_sync_unclassified"
  if [ -f "$BULK_SYNC_UNCLASSIFIED" ]; then
    add_finding "bulk-sync is NOT backing up unrecognised asset dir(s): $(tr -d '\n' < "$BULK_SYNC_UNCLASSIFIED")- assign each a crypt tier in bulk_sync.sh"
  fi
fi

# --- check 17: the vault itself is being backed up offsite (2026-08-09) ------
# The highest-stakes check in this file, because it guards the thing every
# other check reports INTO. Until 2026-08-09 the vault had no working backup at
# all: no git remote, not in iCloud, and a Time Machine destination that had
# not mounted since 2025-08-18. com.mbs.vault-backup now copies it, encrypted,
# to sensitive:_vault/ four times a day.
#
# Age-based rather than stamp==TODAY, because the job runs four times daily and
# the stamp holds a timestamp, not a date. 30 hours tolerates a Mac that was
# closed overnight plus a missed morning window without crying wolf, while
# still catching a job that has genuinely stopped.
if [ -f "$HOME/Library/LaunchAgents/com.mbs.vault-backup.plist" ]; then
  VB_STAMP="$STATE_DIR/last_vault_backup_run"
  if [ ! -f "$VB_STAMP" ]; then
    add_finding "vault-backup has never completed - the vault has NO offsite copy; check ~/.mbs_automation/vault_backup.log"
  else
    VB_MTIME="$(stat -f %m "$VB_STAMP" 2>/dev/null || echo 0)"
    VB_AGE=$(( ( $(date +%s) - VB_MTIME ) / 3600 ))
    if [ "$VB_MTIME" -eq 0 ]; then
      add_finding "vault-backup stamp at ${VB_STAMP} is unreadable"
    elif [ "$VB_AGE" -gt 30 ]; then
      add_finding "vault-backup last succeeded ${VB_AGE}h ago (threshold 30h) - the vault's offsite copy is going stale; check com.mbs.vault-backup"
    fi
  fi
fi

# --- verdict ----------------------------------------------------------------
if [ "$FINDING_COUNT" -eq 0 ]; then
  echo "$TODAY" > "$STAMP"
  echo "$(ts) - healthy: report present in tasks_${TODAY}.md, daily stamp current, no reauth sentinel. Stamped $TODAY." >> "$LOG"
  exit 0
fi

echo "$(ts) - UNHEALTHY ($FINDING_COUNT finding(s)); no stamp written, will re-check and re-nudge on next trigger:" >> "$LOG"
printf '%s' "$FINDINGS_TEXT" | while IFS= read -r f; do
  [ -n "$f" ] && echo "$(ts) -   * $f" >> "$LOG"
done

# Build the alert body out of the findings themselves.
#
# REWRITTEN 2026-08-15. This line used to read "Heartbeat: today's morning
# report is missing. ${FIRST_FINDING}. ... this line repeats daily until the
# report lands again." That wording is from 2026-07-26, when this script had
# exactly ONE check and "unhealthy" could only ever mean the report was
# missing. Seventeen checks later the sentence is simply false on any day the
# report landed and something else broke: on 2026-08-14 it told P his morning
# report was missing in the very note the morning report had written. Two
# separate defects, both fixed here:
#   1. the hardcoded cause, which made every finding read as a report failure;
#   2. FIRST_FINDING only, which meant findings 2..N never reached the note at
#      all - they existed solely in mbs_heartbeat.log, which is precisely the
#      silence this whole script exists to break.
# Numbering appears only when there is more than one finding, so the common
# single-finding line stays clean. The body is deterministic for a given set of
# findings, which is what alert_tasks_note's exact-text dedupe relies on.
ALERT_BODY=""
if [ "$FINDING_COUNT" -eq 1 ]; then
  ALERT_BODY="$FIRST_FINDING"
else
  ALERT_N=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    ALERT_N=$((ALERT_N + 1))
    ALERT_BODY="${ALERT_BODY}${ALERT_BODY:+ }(${ALERT_N}) ${f}"
  done <<< "$FINDINGS_TEXT"
  ALERT_BODY="${FINDING_COUNT} problems. ${ALERT_BODY}"
fi

# Land the alert where P actually looks. alert_tasks_note dedupes by message
# text, so repeated triggers on the same broken day add one line, not twenty.
alert_tasks_note "Heartbeat: ${ALERT_BODY}. Full detail in ~/.mbs_automation/mbs_heartbeat.log; this line repeats until the finding clears."

# Best-effort macOS notification; never blocks, never fails the script.
/usr/bin/osascript -e "display notification \"$FINDING_COUNT heartbeat finding(s). See today's tasks note.\" with title \"MBS heartbeat\" sound name \"Sosumi\"" 2>/dev/null || true

exit 1
