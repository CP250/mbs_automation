#!/bin/bash
# oslo_weekly.sh — surface publication-candidate drafts stale > 30 days.
#
# Pairs with mbs_weekly.sh — same launchd pattern (state dir, per-week stamp,
# PATH export, log to ~/.mbs_automation/). The body is bash, not a Claude
# headless call: a frontmatter scan doesn't need an LLM, and bash is cheaper
# and more reliable for this. The IDIOM (how the schedule is invoked, where
# state lives, how idempotency works) matches mbs_weekly.sh exactly.
#
# Triggered by launchd (see scripts/launchd/com.mbs.oslo-weekly.plist):
#   1. StartCalendarInterval Monday 07:15 local (after mbs_weekly's 07:00).
#   2. Wake from sleep — launchd coalesces the missed fire and runs on wake.
#   3. RunAtLoad at login — covers a powered-off Mac.
#
# Per-ISO-week stamp file (last_oslo_weekly_run) — runs at most once per week.
# Stamp is written only on success.
#
# What it does:
#   - Scans create/oslo/works/misc/ and create/oslo/works/collections/ for poems
#     whose frontmatter has both `publication: true` AND `status: draft`, and
#     whose mtime is more than 30 days ago.
#   - Appends findings to today's tasks_YYYY-MM-DD.md under an
#     `## Oslo — Weekly Stale-Drafts` heading, in the Vault Agent reply-loop
#     format (`status:` / `reply:` fields P edits in Obsidian).
#   - Read-only on poems; only writes to today's tasks note + log.
#   - macOS notification (best-effort).

set -uo pipefail

VAULT="/Users/cpreston/Vaults/storage_mbs"
OSLO="$VAULT/create/oslo"
STATE_DIR="$HOME/.mbs_automation"
STAMP="$STATE_DIR/last_oslo_weekly_run"
LOG="$STATE_DIR/oslo_weekly.log"
STALE_DAYS=30

mkdir -p "$STATE_DIR"

THIS_WEEK="$(date +%G-W%V)"
TODAY="$(date +%Y-%m-%d)"
NOW="$(date +%H:%M)"
DAILY_NOTE="$VAULT/daily_notes/tasks/tasks_${TODAY}.md"
HEADING="## Oslo — Weekly Stale-Drafts ($TODAY)"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$THIS_WEEK" ]; then
  echo "$(ts) — already ran for $THIS_WEEK, skipping." >> "$LOG"
  exit 0
fi

echo "$(ts) — starting oslo weekly stale-drafts check for $THIS_WEEK" >> "$LOG"

# Ensure today's daily note exists with minimal frontmatter
if [[ ! -f "$DAILY_NOTE" ]]; then
  mkdir -p "$(dirname "$DAILY_NOTE")"
  cat > "$DAILY_NOTE" <<EOF
---
type: tasks
date: $TODAY
tags: [daily, tasks]
---

# Tasks — $TODAY
EOF
  echo "$(ts) — created daily note: $DAILY_NOTE" >> "$LOG"
fi

# Scan works/misc and works/collections for publication-candidate stale drafts.
# Frontmatter check inspects the first 30 lines only — frontmatter lives at top.
STALE_FOUND=0
TMP_REPORT="$(mktemp)"
trap 'rm -f "$TMP_REPORT"' EXIT

while IFS= read -r poem; do
  if head -n 30 "$poem" | grep -qE '^publication:[[:space:]]*true\b' \
     && head -n 30 "$poem" | grep -qE '^status:[[:space:]]*draft\b'; then
    if [[ -n "$(find "$poem" -mtime +${STALE_DAYS} -print 2>/dev/null)" ]]; then
      basename_no_ext=$(basename "$poem" .md)
      days_old=$(( ( $(date +%s) - $(stat -f %m "$poem") ) / 86400 ))
      last_mod=$(date -r "$poem" +%Y-%m-%d)
      {
        echo "- [ ] [[$basename_no_ext]] — last modified $last_mod (${days_old} days ago)"
        echo "    proposed: run /oslo-finish-review, or revert to status: seed if not actively in progress"
        echo "    status:    "
        echo "    reply:"
      } >> "$TMP_REPORT"
      STALE_FOUND=$((STALE_FOUND + 1))
    fi
  fi
done < <(find "$OSLO/works/misc" "$OSLO/works/collections" -type f -name "*.md" 2>/dev/null)

# Append section to today's daily note
{
  echo ""
  echo "$HEADING"
  echo ""
  if [[ "$STALE_FOUND" -eq 0 ]]; then
    echo "**$NOW** — oslo | weekly stale-drafts check: 0 publication-candidate drafts older than ${STALE_DAYS} days. Nothing to surface."
  else
    echo "**$NOW** — oslo | weekly stale-drafts check: $STALE_FOUND publication-candidate draft(s) older than ${STALE_DAYS} days."
    echo ""
    cat "$TMP_REPORT"
  fi
} >> "$DAILY_NOTE"

echo "$(ts) — appended to $DAILY_NOTE — $STALE_FOUND stale draft(s) surfaced." >> "$LOG"

# macOS notification (silent if not granted; never blocks)
/usr/bin/osascript -e "display notification \"$STALE_FOUND stale publication-candidate draft(s)\" with title \"oslo — weekly stale-drafts\"" 2>/dev/null || true

echo "$THIS_WEEK" > "$STAMP"
echo "$(ts) — completed successfully; stamped $THIS_WEEK" >> "$LOG"
exit 0
