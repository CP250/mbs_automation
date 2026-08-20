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
# Roster as of 2026-08-20: twenty-six checks (5b widened to three oura slugs
# and 14b added; both are sub-checks, not new roster entries). 14 (oura-watch ran) and 15
# (oura-trends artifact) were added alongside the Oura analysis layer; see
# SETUP.md 'Heartbeat update (2026-08-07)'. 16 (bulk-sync refused to classify
# an asset dir) was added when bulk_sync.sh was rewritten onto the encrypted
# S3 estate; 17 (the vault itself has a working offsite backup) was added when
# that gap was found and closed; 18 (the mbs_aws IaC repo has one too) was added
# 2026-08-15 when the same gap was found one layer down. 19 (mychart-sync ran,
# no stuck per-institution reauth) came with that job. 20 (web-watchers is
# actually watching) was added 2026-08-19 after com.mbs.web-watchers was found
# to have died at parse time on 13 consecutive runs with nothing reporting it;
# that job had shipped with no heartbeat check at all. 21 to 24 came out of the
# estate-wide audit the same evening: 21 (the four weekly-cadence jobs ran this
# ISO week), 22 (oslo-monthly ran this month), 23 (vault-index is keeping
# vault_file_tree.md fresh), and 24, the one that generalises all of this: no
# job anywhere wrote to stderr in the last three days. Checks 6, 7, 10, 11,
# 13, 14, 15, 16, 17, 18, 19, 20 and 23 self-arm on plist presence; 21 and 22
# self-arm on the presence of the job's stamp file, because their plists are
# not in this repo and a guessed filename would fail quiet. 25 (the loaded
# launchd roster matches an expected list) closed the last inference gap the
# same evening, and immediately found a duplicate music-discovery job that had
# been double-running for weeks.
#
# 2026-08-20, the completeness pass. A third instance of one failure signature
# turned up that day (see the check_no_shrink comment below), and the audit it
# prompted found that several checks here still asked only whether an artifact
# was RECENT, never whether it was as big as it was. Added: 12b (the newest
# session-awareness report is not a stub), 17b and 18b (neither offsite backup
# destination shrank, reading a size line vault_backup.sh did not previously
# write and aws_repo_backup.sh had always written and nobody had ever read),
# 23b (vault_file_tree.md has a plausible line count, since check 23's `-s`
# passes on a forty-line stub and forty lines does exactly the damage that
# check's own comment fears), and 26, the stdout twin of 24: no job ended its
# most recent run in FAILED. 26 found a live one the hour it was written, a
# mychart-sync auth failure that both of check 19's purpose-built assertions
# were structurally unable to see.
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

# --- the completeness ledger (added 2026-08-20) ------------------------------
# WHY: on 2026-08-20 a third instance of one failure signature turned up in this
# estate. All three answer every yes/no question correctly while carrying less
# than they should:
#   2026-08-01  oura daily_activity archived a fresh, valid, EMPTY file daily
#               for two months (exclusive end_date); check 5 read it as healthy.
#   2026-08-19  two launchd definitions raced behind an flock; the loser exited
#               0, so the log read healthy while coverage silently halved.
#   2026-08-20  api.py never followed Oura's next_token, so 33 of 85 heartrate
#               day-files were archived truncated at exactly 1000 records,
#               starting four days after the archive was created. HTTP 200,
#               valid JSON, correct mtime, 14,072 samples missing.
# A freshness check cannot see any of them. Neither can a stamp. The question
# that catches this family is not "is it recent" but "is it as big as it was".
#
# check_no_shrink NAME VALUE MIN_ABS MAX_DROP_PCT LABEL
#   NAME          ledger key, one small file per metric under completeness/
#   VALUE         the measurement (integer)
#   MIN_ABS       absolute floor; below this is a finding regardless of history
#   MAX_DROP_PCT  tolerated shrink against the last HEALTHY value, in percent
#   LABEL         human phrase, used to build the finding
#
# The ledger holds a HIGH-WATER MARK, and it is updated only when the check
# passes. Two separate decisions, both learned the hard way:
#
#   1. Not updating on a finding is the direct lesson of the 2026-08-19 flock
#      incident: a mitigation that quietly accepts the degraded state as the new
#      normal turns a fault into silence. Keeping the last healthy figure means
#      this nags every day until the artifact recovers, the same reason this
#      whole script refuses to stamp on a finding.
#   2. High-water rather than last-healthy closes a downward ratchet found while
#      testing this helper on 2026-08-20. Storing the last passing value lets an
#      artifact bleed away entirely without ever tripping: 3247 to 2900 is inside
#      a 20% tolerance, and if 2900 becomes the new baseline then 2900 to 2600 is
#      inside it too, and so on to nothing, one legal step at a time. Every metric
#      this helper currently guards only grows in normal operation (the vault
#      gains notes daily and disposal is a move into trash/, which is inside the
#      backup set), so a mark that never falls costs nothing and closes the hole.
#
# The cost is real and deliberate: a legitimate permanent shrink nags until P
# resets the ledger file by hand, which the finding text tells him to do. For a
# watchdog guarding the only offsite copy of the vault, that is the right
# direction to fail in.
#
# Non-numeric input returns quietly rather than firing. A measurement that could
# not be taken is not evidence of shrinkage, and a watchdog that invents a
# finding out of a parse failure is worse than one that stays quiet.
COMPLETENESS_DIR="$STATE_DIR/completeness"
mkdir -p "$COMPLETENESS_DIR"
check_no_shrink() {
  local cns_name="$1" cns_val="$2" cns_min="$3" cns_drop="$4" cns_label="$5"
  local cns_file cns_prev cns_floor
  case "$cns_val" in ''|*[!0-9]*) return 0 ;; esac
  cns_file="$COMPLETENESS_DIR/$cns_name"
  if [ "$cns_val" -lt "$cns_min" ]; then
    add_finding "${cns_label} is ${cns_val}, below the floor of ${cns_min} - the job reported success, so this is the silent-shrink family (fresh artifact, real timestamp, not enough in it), not an outage"
    return 0
  fi
  if [ -f "$cns_file" ]; then
    cns_prev="$(cat "$cns_file" 2>/dev/null || echo 0)"
    case "$cns_prev" in ''|*[!0-9]*) cns_prev=0 ;; esac
    if [ "$cns_prev" -gt 0 ]; then
      cns_floor=$(( cns_prev - (cns_prev * cns_drop / 100) ))
      if [ "$cns_val" -lt "$cns_floor" ]; then
        add_finding "${cns_label} fell from ${cns_prev} to ${cns_val}, past the ${cns_drop}% tolerance - nothing failed, it just got smaller; the high-water figure is kept in ${cns_file} and this will keep nagging until it recovers or you reset that file by hand"
        return 0
      fi
      [ "$cns_prev" -gt "$cns_val" ] && cns_val="$cns_prev"
    fi
  fi
  printf '%s\n' "$cns_val" > "$cns_file"
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

  # --- check 12b: the newest report is a report, not a stub (2026-08-20) -----
  # Floor only, no shrink ledger, and that asymmetry is the point: a new month's
  # report legitimately covers fewer sessions than a busy month before it, so a
  # month-over-month drop is normal here and a ledger would cry wolf every time
  # P had a quiet month. What is never normal is a report of a few hundred bytes.
  # Grounded in the real folder: the fourteen reports on disk run 4,597 to 11,984
  # bytes, so 1,000 sits well clear of the smallest genuine one and still catches
  # a frontmatter-only stub from a sweep that died after creating its file.
  SWEEP_NEWEST="$(ls -t "$SWEEP_DIR"/report_*.md 2>/dev/null | head -1)"
  if [ -n "$SWEEP_NEWEST" ]; then
    SWEEP_BYTES="$(wc -c < "$SWEEP_NEWEST" 2>/dev/null | tr -d ' ')"
    case "${SWEEP_BYTES:-0}" in ''|*[!0-9]*) SWEEP_BYTES=0 ;; esac
    if [ "$SWEEP_BYTES" -lt 1000 ]; then
      add_finding "session-awareness sweep: $(basename "$SWEEP_NEWEST") is only ${SWEEP_BYTES} bytes (real reports run 4,600 to 12,000) - the sweep created its file and died before writing it; check Cowork sidebar > Scheduled"
    fi
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

  # --- check 17b: the destination actually holds the vault (2026-08-20) ------
  # Check 17 above calls itself the highest-stakes check in this file, and until
  # today it verified the only offsite copy of P's second brain with an exit code
  # and a timestamp. vault_backup.sh asked rclone whether it returned 0, then
  # stamped. A copy that wrote nothing, or into an empty or wrong destination,
  # stamps success and reads healthy here for the next 30 hours.
  #
  # vault_backup.sh now runs the same post-copy `rclone size` that
  # aws_repo_backup.sh has run since it shipped, and logs "destination now holds
  # N object(s), M bytes". This reads that line. The network call lives in the
  # backup job, where it belongs; this check is still a file read, so ADR
  # 2026-07-26 watchdog independence holds.
  #
  # 10% tolerance because the vault only ever grows: notes are added daily and
  # disposal is a move into trash/, which is inside the backup set, so even a
  # big cleanup does not shrink the destination. A 10% drop means deletion at the
  # source or a destination that got partially wiped. Floor of 1 catches the
  # empty-destination case if the size line is ever read on a run that predates
  # the FAILED guard in the script.
  #
  # Silent until vault_backup.sh has written at least one size line, so it
  # self-arms on the next run rather than firing once on install.
  VB_LOG="$STATE_DIR/vault_backup.log"
  if [ -f "$VB_LOG" ]; then
    VB_OBJECTS="$(sed -n 's/.*destination now holds \([0-9][0-9]*\) object(s).*/\1/p' "$VB_LOG" 2>/dev/null | tail -1)"
    if [ -n "$VB_OBJECTS" ]; then
      check_no_shrink vault_backup_objects "$VB_OBJECTS" 1 10 "vault-backup: the offsite destination's object count"
    fi
  fi
fi

# --- check 18: the mbs_aws repo is being backed up offsite (2026-08-15) ------
# Sibling of check 17, one layer down. The vault is P's second brain; ~/dev/mbs_aws
# is the infrastructure-as-code for the five-account AWS estate the vault's
# offsite copy LANDS IN. HANDOFF.md section 10b, 2026-08-14: that repo had no
# offsite copy at all - no git remote (18 commits on one disk), touched by
# neither bulk_sync.sh nor vault_backup.sh, and Time Machine still off. Closed
# 2026-08-15 by com.mbs.aws-repo-backup, which copies it encrypted to
# sensitive:_infra/mbs_aws/ daily at 03:45.
#
# Age-based on the stamp's MTIME rather than stamp==TODAY, copied from check 17
# for the same two reasons: the stamp holds a timestamp rather than a date, and
# 30 hours tolerates a Mac closed overnight plus one missed window without
# crying wolf. It is a daily job, not four-times-daily like vault-backup, so 30
# hours is a tighter margin here (one missed fire plus six hours) - deliberately,
# because a single-copy IaC repo going quiet is worth hearing about early.
#
# Artifact-shaped and cause-free, per ADR 2026-07-26: this asks only whether a
# successful run happened recently. It does NOT ask S3 whether the objects are
# there, because that would be a network call the watchdog is forbidden to make,
# and it must not share fate with what it checks. The script's own post-copy
# `rclone size` sanity check is what verifies the destination; the stamp is
# written only when that check passes and only in LIVE mode, so a stale stamp
# here means either the job stopped running or it ran and refused to call itself
# healthy. Both are worth the same nudge.
#
# Self-arming on plist presence, same pattern as checks 6, 7, 10, 11, 13, 14,
# 15, 16 and 17.
if [ -f "$HOME/Library/LaunchAgents/com.mbs.aws-repo-backup.plist" ]; then
  ARB_STAMP="$STATE_DIR/last_aws_repo_backup_run"
  if [ ! -f "$ARB_STAMP" ]; then
    add_finding "aws-repo-backup has never completed - ~/dev/mbs_aws (Terraform state for five live AWS accounts, and it has no git remote) has NO offsite copy; check ~/.mbs_automation/aws_repo_backup.log"
  else
    ARB_MTIME="$(stat -f %m "$ARB_STAMP" 2>/dev/null || echo 0)"
    ARB_AGE=$(( ( $(date +%s) - ARB_MTIME ) / 3600 ))
    if [ "$ARB_MTIME" -eq 0 ]; then
      add_finding "aws-repo-backup stamp at ${ARB_STAMP} is unreadable"
    elif [ "$ARB_AGE" -gt 30 ]; then
      add_finding "aws-repo-backup last succeeded ${ARB_AGE}h ago (threshold 30h) - the mbs_aws repo's offsite copy is going stale; check com.mbs.aws-repo-backup and ~/.mbs_automation/aws_repo_backup.log"
    fi
  fi

  # --- check 18b: that destination did not shrink either (2026-08-20) --------
  # aws_repo_backup.sh has always measured its destination and always logged the
  # number, and nothing has ever read it. The script's own guard is a CEILING,
  # aimed at the .terraform exclusion breaking and pushing 2.6 GB of provider
  # binaries into the sensitive bucket. There was no floor and no comparison, so
  # the opposite failure, a destination quietly losing objects, was invisible.
  #
  # Grounded in the log's own history: 199 objects on 2026-08-15 through 08-19,
  # 217 on 08-20. It only grows. Floor 50 is far below any real value and catches
  # a collapse; 10% catches a partial wipe without firing on normal churn.
  ARB_LOG="$STATE_DIR/aws_repo_backup.log"
  if [ -f "$ARB_LOG" ]; then
    ARB_OBJECTS="$(sed -n 's/.*destination now holds \([0-9][0-9]*\) object(s).*/\1/p' "$ARB_LOG" 2>/dev/null | tail -1)"
    if [ -n "$ARB_OBJECTS" ]; then
      check_no_shrink aws_repo_backup_objects "$ARB_OBJECTS" 50 10 "aws-repo-backup: the offsite destination's object count"
    fi
  fi
fi

# --- check 19: mychart-sync actually ran (stamp-based) + no stuck reauth -----
# com.mbs.mychart-sync (added 2026-08-16) pulls new MSK / Weill Cornell
# encounters into the visits/ ledger daily at 09:00. It is SILENT BY DESIGN on
# a no-new-encounters day (spec section 7), so like check 14 the only
# answerable question is whether it RAN: mychart_sync.sh writes its per-day
# stamp on every success including silent ones. TODAY-or-YESTERDAY tolerance
# for the same 09:00-vs-11:00 wake pattern as check 14.
#
# Second finding: a lingering per-institution reauth sentinel. The job itself
# surfaces a deduped tasks-note line when a grant dies, but a sentinel that
# sits for days means P missed it and one hospital's feed is quietly paused;
# that is exactly the silent-failure family this watchdog exists for. The
# sentinel files are written by src/mychart_sync.py on refresh failures that
# look like auth (revoked/expired grant), and cleared on the next successful
# pull. Fix: cd ~/dev/mbs-mychart-sync && .venv/bin/python \
# scripts/mychart_consent.py --institution <msk|weillcornell> --tls --verify
#
# Self-arming on plist presence, same pattern as checks 6, 7, 10, 11, 13-18.
MCS_STALE_REPORTED=0
if [ -f "$HOME/Library/LaunchAgents/com.mbs.mychart-sync.plist" ]; then
  MCS_STAMP="$STATE_DIR/last_mychart_sync_run"
  LAST_MCS="$(cat "$MCS_STAMP" 2>/dev/null || echo none)"
  MCS_YESTERDAY="$(date -v-1d +%Y-%m-%d)"
  if [ "$LAST_MCS" != "$TODAY" ] && [ "$LAST_MCS" != "$MCS_YESTERDAY" ]; then
    MCS_STALE_REPORTED=1
    add_finding "mychart-sync has not completed since ${LAST_MCS} (expected ${MCS_YESTERDAY} or ${TODAY}, given its 09:00 schedule) - a silent day is normal, a missing stamp is not; check ~/.mbs_automation/mychart_sync.log and com.mbs.mychart-sync"
  fi
  for MCS_INST in msk weillcornell; do
    if [ -f "$STATE_DIR/mychart_needs_reauth_${MCS_INST}" ]; then
      add_finding "mychart-sync: the ${MCS_INST} grant needs re-authorization (sentinel present since $(cat "$STATE_DIR/mychart_needs_reauth_${MCS_INST}" 2>/dev/null | head -1)) - that hospital's encounter feed is paused; run: cd ~/dev/mbs-mychart-sync && .venv/bin/python scripts/mychart_consent.py --institution ${MCS_INST} --tls --verify"
    fi
  done
fi

# --- check 20: web-watchers actually watched something (added 2026-08-19) ----
# WHY: com.mbs.web-watchers died at PARSE time on every run from 2026-08-08 to
# 2026-08-19. A here-document holding an odd number of apostrophes had been
# folded into $( ... ) inside web_watchers.sh's ask_claude(); bash 5 parses that
# file, macOS's /bin/bash 3.2 does not. The script logged "parsed 2 watcher(s)"
# and bash then aborted before the loop, so web_watchers.log looked almost
# normal, the real error went only to web_watchers.err.log, and both watchers
# sat at last_checked 2026-08-07 for twelve days. Nothing reported it, because
# this roster had no web-watchers entry at all: the job shipped without the
# matching check the vault manual requires of every job P depends on.
#
# Three questions, because the job can fail at three different layers:
#   20a  did it run to completion?         (outer stamp)
#   20b  did it actually check the pages?  (state file last_checked)
#   20c  did it die on the way out?        (non-empty, recent stderr log)
# 20b is the load-bearing one: a future failure that still manages to write the
# stamp passes 20a and is caught here. 20c is the one that would have caught
# THIS outage on day one, for free, without knowing anything about its cause.
#
# Pure filesystem reads. No jq, no python, no network, no claude, so the
# watchdog-independence rule (ADR 2026-07-26) still holds.
#
# Self-arming on plist presence, same pattern as checks 6, 7, 10, 11, 13-19.
if [ -f "$HOME/Library/LaunchAgents/com.mbs.web-watchers.plist" ]; then
  WW_YESTERDAY="$(date -v-1d +%Y-%m-%d)"

  # 20a: the outer run stamp, written only on a completed pass.
  WW_STAMP="$STATE_DIR/last_web_watchers_run"
  LAST_WW="$(cat "$WW_STAMP" 2>/dev/null || echo none)"
  if [ "$LAST_WW" != "$TODAY" ] && [ "$LAST_WW" != "$WW_YESTERDAY" ]; then
    add_finding "web-watchers has not completed a run since ${LAST_WW} (expected ${WW_YESTERDAY} or ${TODAY}, given its 08:30 schedule) - the watched pages are not being checked at all; read ~/.mbs_automation/web_watchers.err.log first, not web_watchers.log, then run: bash ~/dev/mbs_automation/scripts/check_syntax.sh"
  fi

  # 20b: the state file is where a check actually lands. A run that stamps
  # success without moving any last_checked has watched nothing.
  WW_STATE="$STATE_DIR/web_watchers_state.json"
  if [ -f "$WW_STATE" ]; then
    WW_NEWEST="$(grep -o '"last_checked": *"[0-9][0-9-]*' "$WW_STATE" 2>/dev/null | sed 's/.*"//' | sort | tail -1)"
    if [ -z "$WW_NEWEST" ]; then
      add_finding "web-watchers state file holds no last_checked for any watcher - no page has ever been checked successfully; see ~/.mbs_automation/web_watchers_state.json"
    elif [ "$WW_NEWEST" != "$TODAY" ] && [ "$WW_NEWEST" != "$WW_YESTERDAY" ]; then
      add_finding "web-watchers last actually reached a page on ${WW_NEWEST} - the newest last_checked in web_watchers_state.json is stale, so however the job is exiting, no watcher is getting through; see ~/.mbs_automation/web_watchers.err.log"
    fi
  fi

  # 20c: stderr. On a healthy day this file stays empty. Anything in it dated
  # today or yesterday means bash itself objected, which no amount of in-script
  # logging can ever report. Truncate the file once the cause is fixed, or this
  # keeps nagging (that is deliberate).
  WW_ERR="$STATE_DIR/web_watchers.err.log"
  if [ -s "$WW_ERR" ]; then
    WW_ERR_DAY="$(stat -f %Sm -t %Y-%m-%d "$WW_ERR" 2>/dev/null || echo unknown)"
    if [ "$WW_ERR_DAY" = "$TODAY" ] || [ "$WW_ERR_DAY" = "$WW_YESTERDAY" ]; then
      add_finding "web-watchers wrote to stderr on ${WW_ERR_DAY}, last line: $(tail -1 "$WW_ERR" 2>/dev/null | cut -c1-140) - the script is failing outside its own logging; fix the cause, then truncate ~/.mbs_automation/web_watchers.err.log to clear this"
    fi
  fi
fi

# --- check 21: the weekly-cadence jobs actually ran this week (2026-08-19) ---
# WHY: on Monday 2026-08-17 mbs_weekly and cars_weekly each timed out on their
# single claude attempt and exited. Both are Weekday=1 launchd jobs, so the next
# scheduled trigger was the FOLLOWING Monday, and RunAtLoad only fires at login.
# Both sat a full week stale on W33 stamps. This roster had no entry for either,
# nor for oslo-weekly or alcohol-stamp, so three days passed with nobody told.
# Those two scripts now carry a four-attempt retry ladder; this check is the
# part that speaks when the ladder still loses.
#
# ARMED BY THE STAMP FILE, not by a plist. Two of these four jobs do not keep
# their plist in ~/dev/mbs_automation/scripts/launchd, so the exact filename
# cannot be verified from here, and a guessed name would fail quiet, which is
# precisely the failure mode this check exists to end. A stamp file is direct
# evidence the job has run at least once. Cost: retiring a job means deleting
# its stamp or this nags. That is the right direction to fail in.
#
# Threshold is the CURRENT ISO week, not a tolerance window. Every job here
# fires Monday morning between 06:00 and 07:45 and this heartbeat runs at 11:00,
# so by the first heartbeat of any week the stamp should already name this week.
# A one-week tolerance would have stayed silent through the whole outage above.
# The only grace is Monday before 10:00, for a RunAtLoad heartbeat that fires on
# an early login before the weekly jobs have had their turn.
WK_THIS="$(date +%G-W%V)"
WK_LAST="$(date -v-7d +%G-W%V)"
WK_HOUR="$(date +%H)"; WK_HOUR="${WK_HOUR#0}"
WK_EARLY=0
if [ "$(date +%u)" = "1" ] && [ "${WK_HOUR:-0}" -lt 10 ]; then WK_EARLY=1; fi
for WK in "mbs-weekly:last_weekly_run:com.mbs.weekly:mbs_weekly.log" \
          "cars-weekly:last_cars_weekly_run:com.mbs.cars-weekly:cars_weekly.log" \
          "oslo-weekly:last_oslo_weekly_run:com.mbs.oslo-weekly:oslo_weekly.log" \
          "alcohol-stamp:last_alcohol_stamp_run:com.mbs.alcohol-stamp:alcohol_stamp.log"; do
  WK_NAME="${WK%%:*}"; WK_R="${WK#*:}"
  WK_FILE="${WK_R%%:*}"; WK_R="${WK_R#*:}"
  WK_JOB="${WK_R%%:*}"; WK_LOGNAME="${WK_R#*:}"
  [ -f "$STATE_DIR/$WK_FILE" ] || continue
  WK_SEEN="$(cat "$STATE_DIR/$WK_FILE" 2>/dev/null || echo none)"
  WK_OK=0
  [ "$WK_SEEN" = "$WK_THIS" ] && WK_OK=1
  [ "$WK_EARLY" -eq 1 ] && [ "$WK_SEEN" = "$WK_LAST" ] && WK_OK=1
  if [ "$WK_OK" -eq 0 ]; then
    add_finding "${WK_NAME} has not completed for ${WK_THIS} (its stamp still says ${WK_SEEN}) - a weekly job that loses its Monday fire does not try again until the NEXT Monday, so this is a lost week unless it is kicked by hand: launchctl kickstart -k gui/\$(id -u)/${WK_JOB} ; check ~/.mbs_automation/${WK_LOGNAME}"
  fi
done

# --- check 22: oslo-monthly ran for this month (added 2026-08-19) ------------
# Same family as check 21, month cadence, fires on the 1st. Three days of grace
# so a Mac that was off over a month boundary is not reported as a failure.
OM_STAMP="$STATE_DIR/last_oslo_monthly_run"
if [ -f "$OM_STAMP" ]; then
  OM_THIS="$(date +%Y-%m)"
  OM_SEEN="$(cat "$OM_STAMP" 2>/dev/null || echo none)"
  OM_DAY="$(date +%d)"; OM_DAY="${OM_DAY#0}"
  if [ "$OM_SEEN" != "$OM_THIS" ] && [ "${OM_DAY:-1}" -ge 4 ]; then
    add_finding "oslo-monthly has not completed for ${OM_THIS} (its stamp still says ${OM_SEEN}) - kick it by hand with launchctl kickstart -k gui/\$(id -u)/com.mbs.oslo-monthly ; check ~/.mbs_automation/oslo_monthly.log"
  fi
fi

# --- check 23: vault-index is keeping vault_file_tree.md fresh (2026-08-19) --
# This one is load-bearing in a way its size hides. vault_file_tree.md is item 5
# of the session-start read order in brain/CLAUDE.md, and the rule there is to
# grep it for existence checks. A stale or missing tree does not fail loudly: it
# makes every session confidently tell P that a file does not exist. Silent
# wrongness, which is worse than silent absence.
#
# Runs 23:30, this heartbeat runs 11:00, so on a healthy Mac the stamp says
# YESTERDAY. TODAY is also fine (a wake-coalesced fire after midnight).
if [ -f "$HOME/Library/LaunchAgents/com.mbs.vault-index.plist" ]; then
  VI_SEEN="$(cat "$STATE_DIR/last_vault_index_run" 2>/dev/null || echo none)"
  VI_YESTERDAY="$(date -v-1d +%Y-%m-%d)"
  if [ "$VI_SEEN" != "$TODAY" ] && [ "$VI_SEEN" != "$VI_YESTERDAY" ]; then
    add_finding "vault-index has not completed since ${VI_SEEN} (expected ${VI_YESTERDAY} or ${TODAY}, given its 23:30 schedule) - vault_file_tree.md is going stale, and sessions grep it to decide whether a file exists, so the failure mode is a session telling you something is not there when it is; check ~/.mbs_automation/vault_index.log and com.mbs.vault-index"
  fi
  VI_TREE="$VAULT/admin/mbs_system/brain/vault_file_tree.md"
  if [ ! -s "$VI_TREE" ]; then
    add_finding "vault_file_tree.md is missing or empty at ${VI_TREE} - every session's existence checks are reading nothing; re-run com.mbs.vault-index"
  else
    # --- check 23b: the tree is a tree, not a stub (2026-08-20) -------------
    # `-s` above only asks whether the file has any bytes at all. Check 23's own
    # comment names the failure mode it fears: "silent wrongness, which is worse
    # than silent absence", because sessions grep this file to decide whether
    # something exists and a truncated tree makes them confidently say no. A
    # one-byte file fails `-s`. A forty-line file does not, and does exactly the
    # damage the comment describes.
    #
    # 3,247 lines on 2026-08-20, and it grows with the vault. Floor 500 is far
    # below any plausible healthy value; 20% tolerance covers a genuine prune
    # (the tree already excludes _corpora/ and oura/raw/) while catching a run
    # that indexed one subtree and stopped.
    VI_LINES="$(wc -l < "$VI_TREE" 2>/dev/null | tr -d ' ')"
    check_no_shrink vault_file_tree_lines "$VI_LINES" 500 20 "vault_file_tree.md's line count"
  fi
fi

# --- check 24: no job is writing to stderr (added 2026-08-19) ----------------
# The generalisation of check 20c to the whole estate, and the single highest
# value check on this roster.
#
# WHY: a script's own logging cannot report a failure that happens outside it. A
# bash parse error, a missing binary, a process killed by a signal: all of these
# land on stderr, which launchd files into the job's StandardErrorPath, and until
# today nothing ever read those files. Two separate multi-day outages were
# sitting in them in plain text. web_watchers.err.log held 13 identical parse
# errors from 2026-08-08 onward. team_brief.err.log held an "unexpected EOF
# while looking for matching quote" from 2026-08-03. Neither was ever surfaced.
#
# This check does not need to know what any job does, or even that it exists. It
# asks one question of every job at once: did bash have something to say that
# the job could not say for itself?
#
# Prerequisite, done the same day: lib_auth.sh's _la_run_with_timeout used to
# leak a benign "NNNN Terminated: 15" line into stderr every time it killed a
# hung claude call, which would have made this check cry wolf on every job that
# had ever timed out. That message is now suppressed at the source.
#
# Three-day window, not one: long enough to survive a weekend of not looking,
# short enough that a fixed-and-truncated log goes quiet. Truncating the file is
# the acknowledgement; that is deliberate.
STDERR_NAMES=""
STDERR_COUNT=0
STDERR_NOW="$(date +%s)"
for EF in "$STATE_DIR"/*.err.log; do
  [ -f "$EF" ] || continue
  [ -s "$EF" ] || continue
  EF_M="$(_la_mtime "$EF")"
  [ "$EF_M" -gt 0 ] || continue
  if [ $((STDERR_NOW - EF_M)) -lt 259200 ]; then
    STDERR_COUNT=$((STDERR_COUNT + 1))
    STDERR_NAMES="${STDERR_NAMES}${STDERR_NAMES:+, }$(basename "$EF")"
  fi
done
if [ "$STDERR_COUNT" -gt 0 ]; then
  add_finding "${STDERR_COUNT} job(s) wrote to stderr in the last 3 days: ${STDERR_NAMES} - stderr is where a failure goes when the job cannot log it itself (bash parse errors, missing binaries, killed processes), so read these files FIRST; after fixing the cause, truncate them to clear this finding"
fi

# --- check 25: the launchd roster is exactly what it should be (2026-08-19) --
# The last inference gap in the estate, closed.
#
# Everything else on this roster asks "did the job produce what it should have".
# None of it can distinguish a job that ran and failed from a job that is no
# longer loaded at all, and the second is invisible in a way the first is not:
# a booted-out job writes no log, no stamp and no stderr, so it leaves exactly
# the same evidence as a Mac that was asleep.
#
# It also catches the opposite, which is what the 2026-08-19 audit actually
# found: com.mbs.music-discovery and com.cp250.mbs-music-discovery were BOTH
# loaded, both running `node index.js` from the same repo at Monday 06:00, both
# appending to the same run.log, both writing the same dispatch file into the
# vault, and both refreshing the same OAuth token. run.log had been recording
# the doubled writes for weeks (two "Wrote N release(s)" lines per run, and on
# one pair two DIFFERENT counts, which is two processes racing on the shared
# cache). Nothing on this roster could have seen that, because the job's output
# existed and looked fine.
#
# Watchdog independence holds: `launchctl list` is a local command with no
# network and no claude. If launchd itself is broken this heartbeat is not
# running either, which is already the design assumption.
#
# DELIBERATELY NOT CHECKED: the exit-status column. mbs-heartbeat exits 1 by
# design whenever it has findings, and mbs-daily exits 2 on an auth failure, so
# non-zero is normal here and would train P to ignore the line. Outcomes are
# what the other twenty-four checks are for. This one is about membership.
#
# KEEPING THIS LIST HONEST: it is a snapshot of what SHOULD be loaded, taken
# 2026-08-19 from `launchctl list`. Adding a job means adding it here. Booting
# one out means removing it here, or this reports it missing forever.
# com.mbs.weekly-blocks is on the list on purpose: it is paused by zeroing
# every thread's weekly_minutes, NOT by being booted out, so it is still loaded
# and still fires Sunday 17:00 (creating nothing). If it is ever really booted
# out, delete it from this list at the same time.
LD_EXPECTED="com.mbs.alcohol-stamp com.mbs.aws-repo-backup com.mbs.bulk-sync com.mbs.cars-weekly com.mbs.daily com.mbs.heartbeat com.mbs.music-discovery com.mbs.mychart-sync com.mbs.oslo-monthly com.mbs.oslo-weekly com.mbs.oura-sync com.mbs.oura-trends com.mbs.oura-watch com.mbs.pointer-check com.mbs.review-monthly com.mbs.review-quarterly com.mbs.review-yearly com.mbs.team-brief com.mbs.the-record com.mbs.vault-backup com.mbs.vault-index com.mbs.web-watchers com.mbs.weekly com.mbs.weekly-blocks"

# Label filter: everything in this estate carries "mbs" somewhere in its label
# (including com.cp250.mbs-music-discovery), and the retired review jobs used
# "cpreston.vaultreview". A stray job named outside both families would still be
# invisible here; that is a known and accepted limit.
LD_LOADED="$(launchctl list 2>/dev/null | awk 'NR>1 {print $3}' | grep -iE 'mbs|vaultreview' | sort)"
if [ -z "$LD_LOADED" ]; then
  add_finding "could not read the launchd roster: 'launchctl list' returned no matching jobs at all. Either launchd is not reachable from this context or every job has been booted out; check by hand with: launchctl list | grep mbs"
else
  LD_MISSING=""
  for LD_J in $LD_EXPECTED; do
    if ! echo "$LD_LOADED" | grep -qx -- "$LD_J"; then
      LD_MISSING="${LD_MISSING}${LD_MISSING:+, }$LD_J"
    fi
  done
  LD_EXTRA=""
  for LD_J in $LD_LOADED; do
    case " $LD_EXPECTED " in
      *" $LD_J "*) ;;
      *) LD_EXTRA="${LD_EXTRA}${LD_EXTRA:+, }$LD_J" ;;
    esac
  done
  if [ -n "$LD_MISSING" ]; then
    add_finding "launchd job(s) expected but NOT loaded: ${LD_MISSING} - a booted-out job leaves no log, no stamp and no stderr, so it looks exactly like a Mac that was asleep; re-bootstrap it (launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/<label>.plist) or remove it from LD_EXPECTED in mbs_heartbeat.sh if it was retired on purpose"
  fi
  if [ -n "$LD_EXTRA" ]; then
    add_finding "launchd job(s) loaded but NOT expected: ${LD_EXTRA} - most often a second copy of a job installed under a different label, which means two processes on the same schedule racing on the same output, log, cache and OAuth token; boot out the duplicate (launchctl bootout gui/\$(id -u)/<label>) or add it to LD_EXPECTED in mbs_heartbeat.sh if it is legitimate"
  fi
fi

# --- check 26: no job's own last word was a failure (added 2026-08-20) -------
# The stdout twin of check 24, and the same move: ask one question of every job
# at once instead of teaching this file about each job in turn.
#
# Check 24 reads stderr, which catches what a job could not say for itself (a
# bash parse error, a missing binary, a killed process). This reads stdout and
# catches the opposite: a job that worked perfectly, knew it had failed, wrote so
# in plain language, and had nobody read it.
#
# That is not hypothetical. It was true when this check was written. At 09:15 on
# 2026-08-20 mychart_sync.log ended "FAILED (rc=1); not stamping day, next
# trigger retries" after four attempts against a dead Weill Cornell keychain
# grant. Check 19 was silent because it tolerates a one-day-old stamp and the
# stamp still read 2026-08-19; check 19's reauth sentinel was silent because the
# job classifies "Keychain is missing credentials" as transient rather than as an
# auth failure. Two purpose-built checks for that exact job, both quiet, while
# the job's own last line said FAILED in English.
#
# The vocabulary is shared estate-wide, which is what makes one rule possible:
# every wrapper here ends a run with "completed successfully; stamped ...",
# "OK (mode=...): ...", or "FAILED ...". Verified 2026-08-20 by reading the last
# terminal line of all 21 non-empty logs in STATE_DIR: twenty ended in a success
# form, one (mychart_sync) in FAILED. So the rule is "the most recent terminal
# line, whichever it is" - a later success supersedes an earlier failure with no
# state to keep and nothing to clear by hand.
#
# EXCLUDES ITS OWN LOG, and that is load-bearing rather than tidy: this script
# writes findings verbatim into mbs_heartbeat.log, findings quote other jobs
# ("mbs_daily has not completed successfully since ..."), so an unfiltered sweep
# would read its own past complaints as fresh evidence and never go quiet.
#
# Three-day window on the line's own date, matching check 24, so a failure that
# has since been superseded or a job that was retired stops nagging on its own.
#
# Suppressed for mychart-sync when check 19 already reported a stale stamp: one
# root cause, one line. Same discipline as 14b's suppression behind 5b.
STDOUT_FAIL_NAMES=""
STDOUT_FAIL_COUNT=0
TC_D1="$TODAY"
TC_D2="$(date -v-1d +%Y-%m-%d)"
TC_D3="$(date -v-2d +%Y-%m-%d)"
for TF in "$STATE_DIR"/*.log; do
  [ -f "$TF" ] || continue
  [ -s "$TF" ] || continue
  TC_BASE="$(basename "$TF")"
  case "$TC_BASE" in
    *.err.log|*.out.log|*manifest*|mbs_heartbeat.log) continue ;;
    mychart_sync.log) [ "$MCS_STALE_REPORTED" -eq 1 ] && continue ;;
  esac
  TC_LINE="$(grep -E 'completed successfully|OK \(mode=|FAILED' "$TF" 2>/dev/null | tail -1)"
  [ -n "$TC_LINE" ] || continue
  case "$TC_LINE" in *FAILED*) ;; *) continue ;; esac
  TC_DAY="${TC_LINE%% *}"
  if [ "$TC_DAY" = "$TC_D1" ] || [ "$TC_DAY" = "$TC_D2" ] || [ "$TC_DAY" = "$TC_D3" ]; then
    STDOUT_FAIL_COUNT=$((STDOUT_FAIL_COUNT + 1))
    STDOUT_FAIL_NAMES="${STDOUT_FAIL_NAMES}${STDOUT_FAIL_NAMES:+, }${TC_BASE} (${TC_DAY})"
  fi
done
if [ "$STDOUT_FAIL_COUNT" -gt 0 ]; then
  add_finding "${STDOUT_FAIL_COUNT} job(s) ended their most recent run in FAILED and said so in their own log: ${STDOUT_FAIL_NAMES} - the job knew; nothing was reading. Open each file in ~/.mbs_automation/ and read its last terminal line; this clears itself as soon as that job's next run succeeds"
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
