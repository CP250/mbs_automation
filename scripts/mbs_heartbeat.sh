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
