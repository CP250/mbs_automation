#!/bin/bash
# oslo_monthly.sh - monthly nudge for the oslo journal-corpus refresh.
#
# Pairs with mbs_weekly.sh / mbs_daily.sh - same launchd idiom (state dir,
# per-month stamp, PATH export, log to ~/.mbs_automation/). Body is bash: the
# script counts per-journal notes in create/oslo/reference/journals/ and
# appends a reminder section to today's tasks note. The actual corpus refresh
# (fetching new issues, parsing, attributing, saving poems) is intelligence
# work done interactively in Claude Code - this script just makes sure the
# nudge surfaces on the 1st.
#
# Triggered by launchd (see scripts/launchd/com.mbs.oslo-monthly.plist):
#   1. StartCalendarInterval Day 1 at 08:00 local.
#   2. Wake from sleep - launchd coalesces missed fires.
#   3. RunAtLoad at login - covers a powered-off Mac.
#
# Per-month stamp (YYYY-MM) - runs at most once per month.

set -uo pipefail

VAULT="/Users/cpreston/Vaults/storage_mbs"
OSLO="$VAULT/create/oslo"
STATE_DIR="$HOME/.mbs_automation"
STAMP="$STATE_DIR/last_oslo_monthly_run"
LOG="$STATE_DIR/oslo_monthly.log"
JOURNALS_DIR="$OSLO/reference/journals"

mkdir -p "$STATE_DIR"

THIS_MONTH="$(date +%Y-%m)"
TODAY="$(date +%Y-%m-%d)"
NOW="$(date +%H:%M)"
DAILY_NOTE="$VAULT/daily_notes/tasks/tasks_${TODAY}.md"
HEADING="## Oslo - Monthly Corpus Refresh ($TODAY)"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$THIS_MONTH" ]; then
  echo "$(ts) - already ran for $THIS_MONTH, skipping." >> "$LOG"
  exit 0
fi

echo "$(ts) - starting oslo monthly corpus-refresh nudge for $THIS_MONTH" >> "$LOG"

# Ensure today's daily note exists
if [[ ! -f "$DAILY_NOTE" ]]; then
  mkdir -p "$(dirname "$DAILY_NOTE")"
  cat > "$DAILY_NOTE" <<EOF
---
type: tasks
date: $TODAY
tags: [daily, tasks]
---

# Tasks - $TODAY
EOF
  echo "$(ts) - created daily note: $DAILY_NOTE" >> "$LOG"
fi

# Count configured journals: every .md file in reference/journals/ except README.md
# represents one configured journal (slug = basename without .md).
JOURNAL_COUNT=0
if [[ -d "$JOURNALS_DIR" ]]; then
  JOURNAL_COUNT=$(find "$JOURNALS_DIR" -maxdepth 1 -type f -name "*.md" -not -name "README.md" 2>/dev/null | wc -l | tr -d ' ')
fi

{
  echo ""
  echo "$HEADING"
  echo ""
  if [[ "$JOURNAL_COUNT" -eq 0 ]]; then
    echo "**$NOW** - oslo | monthly corpus refresh: no journals configured in \`create/oslo/reference/journals/\` yet. Skipping."
    echo ""
    echo "- [ ] When you pick your top 3-5 target journals (see [[ref_north_american_poetry_journals]]), create a note per journal at \`create/oslo/reference/journals/<slug>.md\` (frontmatter schema in that folder's README) and the next monthly run will start refreshing."
    echo "    proposed: pick targets and create per-journal notes"
    echo "    status:    "
    echo "    reply:"
  else
    echo "**$NOW** - oslo | monthly corpus refresh due: $JOURNAL_COUNT journal(s) configured."
    echo ""
    echo "- [ ] Open Claude Code from the vault root and refresh each configured journal corpus: pull recent issues' tables of contents, save representative poems to \`create/oslo/_corpora/journals/<slug>/\`, update each manifest. Paywalled journals need manual handling - note them in the reply."
    echo "    proposed: per-journal ingestion in Claude Code"
    echo "    status:    "
    echo "    reply:"
  fi
} >> "$DAILY_NOTE"

echo "$(ts) - appended to $DAILY_NOTE - $JOURNAL_COUNT journal(s) configured." >> "$LOG"

/usr/bin/osascript -e "display notification \"$JOURNAL_COUNT journal(s) configured\" with title \"oslo - monthly corpus refresh\"" 2>/dev/null || true

echo "$THIS_MONTH" > "$STAMP"
echo "$(ts) - completed successfully; stamped $THIS_MONTH" >> "$LOG"
exit 0
