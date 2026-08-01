#!/bin/bash
# mbs_heartbeat.sh — verify that the morning report actually landed.
#
# WHY THIS EXISTS (2026-07-26)
# ----------------------------
# Every automation failure in this system so far was found by P noticing, not
# by the system reporting:
#   2026-07-05  connection/DNS failure at wake — silent
#   2026-07-06  API 401 — caught, because lib_auth.sh knew that wording
#   2026-07-24  out of usage credits (Fable) — caught, same reason
#   2026-07-25  OAuth session expired — SILENT for two days, because the
#               wording did not match lib_auth.sh's patterns
#
# Each fix widened the detector by one string. That approach can only ever
# catch failures whose wording was anticipated. This job takes the opposite
# approach: it does not care WHY the report is missing, only WHETHER it is
# there. It asks one question — "does today's tasks note contain a real
# ## Vault Agent section?" — and shouts if the answer is no.
#
# THE DESIGN RULE: this script must not share fate with what it checks.
# It therefore calls NO network service and NO `claude` binary. Pure bash,
# filesystem only. If it cannot run, the Mac is off, and nothing else ran
# either. Do not add a Claude call to this script — that would recreate the
# exact coupling it exists to break.
#
# Triggered by launchd (scripts/launchd/com.mbs.heartbeat.plist):
#   1. StartCalendarInterval at 11:00 local — well after mbs_daily's 06:00
#      fire plus its full five-attempt retry ladder (~1.75 hr of awake time).
#   2. RunAtLoad at login — so a Mac powered off all morning still gets checked.
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
  echo "$(ts) — already verified healthy for $TODAY, skipping." >> "$LOG"
  exit 0
fi

# If mbs_daily is still working (live PID in its lock), it is not late yet.
# Exit without stamping so the next trigger checks again.
DAILY_LOCK="$STATE_DIR/mbs_daily.lock"
if [ -d "$DAILY_LOCK" ]; then
  HOLDER_PID="$(cat "$DAILY_LOCK/pid" 2>/dev/null)"
  if [ -n "${HOLDER_PID:-}" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
    echo "$(ts) — mbs_daily still running (PID $HOLDER_PID); not late yet, will re-check on next trigger." >> "$LOG"
    exit 0
  fi
fi

TASKS_NOTE="$VAULT/daily_notes/tasks/tasks_${TODAY}.md"

# Findings are accumulated as a counter + newline-joined string rather than a
# bash array. Reason: launchd runs this with /bin/bash, which on macOS is still
# 3.2, and there `${#arr[@]}` on an EMPTY array under `set -u` aborts with
# "unbound variable" — so a perfectly healthy day would crash the watchdog.
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
  # land, so it counts as a finding — with the cause already named in the note.
  if grep -qE '^## Vault Agent \(skipped' "$TASKS_NOTE"; then
    add_finding "the daily report was skipped and said so in today's note — see the '## Vault Agent (skipped' banner there for the reason"
  elif ! grep -qE '^## Vault Agent' "$TASKS_NOTE"; then
    add_finding "today's tasks note has no ## Vault Agent section — the morning report did not land"
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
  add_finding "Claude CLI needs re-auth (first detected ${FIRST_SEEN}) — run \`claude\` then \`/login\` in Terminal"
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
# 2 days of slack tolerates one missed sync (the sync job's own --lookback 3
# self-heals a gap on the next successful run).
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
  OURA_CONTENT_CHECK_FILES="$(find "$OURA_CANARY_DIR" -maxdepth 1 -name '*.json' ! -name "${TODAY}.json" 2>/dev/null | sort -r | head -2)"
  OURA_CONTENT_FILE_COUNT="$(printf '%s\n' "$OURA_CONTENT_CHECK_FILES" | grep -c . || true)"
  if [ "$OURA_CONTENT_FILE_COUNT" -ge 2 ]; then
    OURA_ALL_EMPTY=1
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      grep -qF '"data": []' "$f" 2>/dev/null || OURA_ALL_EMPTY=0
    done <<< "$OURA_CONTENT_CHECK_FILES"
    if [ "$OURA_ALL_EMPTY" -eq 1 ]; then
      add_finding "oura sync: the 2 most recent daily_activity archive files are both empty (\"data\": []) - files are fresh but content looks broken, check the oura-sync launchd job and api.py's query params"
    fi
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
  fi
fi

# --- verdict ----------------------------------------------------------------
if [ "$FINDING_COUNT" -eq 0 ]; then
  echo "$TODAY" > "$STAMP"
  echo "$(ts) — healthy: report present in tasks_${TODAY}.md, daily stamp current, no reauth sentinel. Stamped $TODAY." >> "$LOG"
  exit 0
fi

echo "$(ts) — UNHEALTHY ($FINDING_COUNT finding(s)); no stamp written, will re-check and re-nudge on next trigger:" >> "$LOG"
printf '%s' "$FINDINGS_TEXT" | while IFS= read -r f; do
  [ -n "$f" ] && echo "$(ts) —   • $f" >> "$LOG"
done

# Land the alert where P actually looks. alert_tasks_note dedupes by message
# text, so repeated triggers on the same broken day add one line, not twenty.
alert_tasks_note "Heartbeat: today's morning report is missing. ${FIRST_FINDING}. Full detail in ~/.mbs_automation/mbs_heartbeat.log; this line repeats daily until the report lands again."

# Best-effort macOS notification; never blocks, never fails the script.
/usr/bin/osascript -e "display notification \"$FINDING_COUNT problem(s) — today's morning report is missing. See today's tasks note.\" with title \"MBS heartbeat\" sound name \"Sosumi\"" 2>/dev/null || true

exit 1
