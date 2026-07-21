#!/bin/bash
# alcohol_stamp.sh — weekly recompute of P's rolling std-drinks/week figure from
# the daily health notes, stamped into CRITICAL_FACTS.md + the baseline profile.
#
# Same launchd idiom as oslo_weekly.sh (state dir, per-ISO-week stamp, PATH
# export, log to ~/.mbs_automation/). Body delegates the compute + file-stamp to
# alcohol_stamp.py (frontmatter arithmetic — mechanical, no LLM). The live daily
# figure is the DataviewJS block in health/dashboard_health.md; this job keeps
# the Claude-readable literal in the two belief docs fresh.
#
# Triggered by launchd (scripts/launchd/com.mbs.alcohol-stamp.plist):
#   Monday 07:30 local (after mbs_weekly 07:00 / oslo-weekly 07:15) + RunAtLoad.
# Per-ISO-week stamp (last_alcohol_stamp_run) — runs at most once per week,
# stamped only on success.

set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

VAULT="/Users/cpreston/Vaults/storage_mbs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HOME/.mbs_automation"
STAMP="$STATE_DIR/last_alcohol_stamp_run"
LOG="$STATE_DIR/alcohol_stamp.log"

mkdir -p "$STATE_DIR"
THIS_WEEK="$(date +%G-W%V)"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$THIS_WEEK" ]; then
  echo "$(ts) — already ran for $THIS_WEEK, skipping." >> "$LOG"
  exit 0
fi

echo "$(ts) — recomputing alcohol figure for $THIS_WEEK" >> "$LOG"

OUT="$(MBS_VAULT_OVERRIDE="$VAULT" python3 "$SCRIPT_DIR/alcohol_stamp.py" 2>&1)"
RC=$?
echo "$OUT" >> "$LOG"

if [ $RC -ne 0 ]; then
  echo "$(ts) — FAILED (rc=$RC); not stamping week." >> "$LOG"
  exit $RC
fi

/usr/bin/osascript -e "display notification \"alcohol figure refreshed\" with title \"mbs — alcohol-stamp\"" 2>/dev/null || true

echo "$THIS_WEEK" > "$STAMP"
echo "$(ts) — completed successfully; stamped $THIS_WEEK" >> "$LOG"
exit 0
