#!/bin/bash
# mbs_review_prep.sh - agent-drafted prep for the Monthly/Quarterly/Yearly
# review notes (project_task_triage phase 2, built 2026-08-01).
#
# Usage: mbs_review_prep.sh {monthly|quarterly|yearly}
#
# Modeled on mbs_daily.sh (the canonical wrapper): per-period stamp, single
# instance lock, explicit PATH, lib_auth sourcing, network pre-flight, retry
# ladder. Flow: (1) review_reminder.sh creates the dated note + notification
# (pure bash, unchanged); (2) claude -p drafts the "## Agent prep" section
# into that note per commands/obsidian-review-prep.md. P decided 2026-08-01:
# prep lands in the same run that creates the note, at 06:00 (moved from the
# legacy 09:00).

set -uo pipefail

VAULT="/Users/cpreston/Vaults/storage_mbs"
STATE_DIR="$HOME/.mbs_automation"
KIND="${1:-}"
LOG="$STATE_DIR/mbs_review_prep.log"

mkdir -p "$STATE_DIR"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

case "$KIND" in
  monthly)   PERIOD="$(date +%Y-%m)" ;;
  quarterly) M=$(( 10#$(date +%m) )); Q=$(( (M - 1) / 3 + 1 )); PERIOD="$(date +%Y)-Q${Q}" ;;
  yearly)    PERIOD="$(date +%Y)" ;;
  *) echo "usage: $0 {monthly|quarterly|yearly}" >&2; exit 1 ;;
esac

STAMP="$STATE_DIR/last_review_prep_${KIND}"
NOTE="$VAULT/admin/reviews/review_${KIND}_${PERIOD}.md"

# shellcheck source=./lib_auth.sh
source "$(dirname "$0")/lib_auth.sh"

if needs_reauth_skip "$LOG"; then
  exit 0
fi

if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$PERIOD" ]; then
  echo "$(ts) - $KIND already prepped for $PERIOD, skipping." >> "$LOG"
  exit 0
fi

LOCK_DIR="$STATE_DIR/mbs_review_prep_${KIND}.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  HOLDER_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -n "${HOLDER_PID:-}" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
    echo "$(ts) - another $KIND instance running (PID $HOLDER_PID), exiting" >> "$LOG"
    exit 0
  fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || { echo "$(ts) - ERROR: cannot claim lock" >> "$LOG"; exit 1; }
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  echo "$(ts) - ERROR: 'claude' not found on PATH" >> "$LOG"
  exit 1
fi

# Step 1: the note + notification (idempotent; skips creation if present).
if ! /bin/bash "$(dirname "$0")/review_reminder.sh" "$KIND"; then
  echo "$(ts) - ERROR: review_reminder.sh $KIND failed; aborting prep" >> "$LOG"
  exit 1
fi
[ -f "$NOTE" ] || { echo "$(ts) - ERROR: $NOTE missing after reminder step" >> "$LOG"; exit 1; }

echo "$(ts) - starting $KIND prep for $PERIOD (claude: $CLAUDE_BIN)" >> "$LOG"
cd "$VAULT" || { echo "$(ts) - ERROR: cannot cd to $VAULT" >> "$LOG"; exit 1; }

PROMPT="Read the file $HOME/.claude/commands/obsidian-review-prep.md and carry out its instructions exactly, using the mbs_automation skill, against the vault at $VAULT. Cadence: ${KIND}. Period: ${PERIOD}. Target note: ${NOTE}. This is the unattended scheduled review-prep run: draft the bounded '## Agent prep' section into the target note via the filesystem and touch nothing else except the ops log."

# Network pre-flight (mbs_daily pattern): the 06:00 fire can beat Wi-Fi/DNS.
wait_for_network() {
  local log="$1" url="https://api.anthropic.com/" max_tries=12 i rc
  for i in $(seq 1 "$max_tries"); do
    curl -sS --max-time 5 -o /dev/null "$url" 2>/dev/null
    rc=$?
    case "$rc" in
      6|7|28|35) echo "$(ts) - network not ready (curl exit $rc); waiting 10s ($i/$max_tries)" >> "$log"; sleep 10 ;;
      *) echo "$(ts) - network reachable (curl exit $rc after $i check(s))" >> "$log"; return 0 ;;
    esac
  done
  echo "$(ts) - network still not ready after $max_tries checks; proceeding anyway" >> "$log"
  return 1
}
wait_for_network "$LOG"

MAX_ATTEMPTS=5
RETRY_DELAYS=(300 600 1800 3600)

rc=1
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  echo "$(ts) - attempt $attempt/$MAX_ATTEMPTS" >> "$LOG"
  run_claude_p "$PROMPT" "$LOG"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    clear_reauth_sentinel
    echo "$PERIOD" > "$STAMP"
    echo "$(ts) - $KIND prep completed for $PERIOD on attempt $attempt; stamped" >> "$LOG"
    exit 0
  fi
  if [ "$rc" -eq 2 ]; then
    mark_reauth_needed "$LOG"
    echo "$(ts) - auth failure; not retrying (next trigger resumes after /login)" >> "$LOG"
    exit 2
  fi
  if [ "$rc" -eq 3 ]; then
    echo "$(ts) - out of usage credits; alert already written by run_claude_p; not retrying" >> "$LOG"
    exit 3
  fi
  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    delay="${RETRY_DELAYS[$((attempt - 1))]}"
    echo "$(ts) - attempt $attempt failed (exit $rc); sleeping ${delay}s" >> "$LOG"
    sleep "$delay"
  fi
done
echo "$(ts) - all $MAX_ATTEMPTS attempts failed (final exit $rc); heartbeat check 10 will nag until the prep lands" >> "$LOG"
alert_tasks_note "Review prep (${KIND} ${PERIOD}) failed after ${MAX_ATTEMPTS} attempts: '## Agent prep' not drafted into ${NOTE##*/}. Detail in ~/.mbs_automation/mbs_review_prep.log; the next launchd trigger retries."
exit "$rc"
