#!/bin/bash
# review_reminder.sh - vault review-cadence reminder, driven by launchd.
# Creates a dated review note in the vault (if not already present) and fires
# a macOS notification. Complements the in-vault recurring Tasks-plugin tasks
# in admin/betterment/operating_system.md (those nudge when Obsidian is open;
# this fires even when it's closed).
#
# Usage: review_reminder.sh {monthly|quarterly|yearly}
set -euo pipefail

VAULT="/Users/cpreston/Vaults/storage_mbs"
REVIEWS="$VAULT/admin/reviews"
KIND="${1:-monthly}"
DATE_TAG="$(date +%Y-%m-%d)"

case "$KIND" in
  monthly)
    PERIOD="$(date +%Y-%m)"
    TITLE="Monthly review"
    PROMPT="Go over ALL projects and ALL goals - does each project still further its goal outcome?"
    ;;
  quarterly)
    M=$(( 10#$(date +%m) ))           # 10# avoids octal parsing of e.g. 08/09
    Q=$(( (M - 1) / 3 + 1 ))
    PERIOD="$(date +%Y)-Q${Q}"
    TITLE="Quarterly review"
    PROMPT="Define the outcome one level above each project (e.g. define what 'AGMR' means)."
    ;;
  yearly)
    PERIOD="$(date +%Y)"
    TITLE="Yearly review"
    PROMPT="Revisit the ethos (see SOUL.md)."
    ;;
  *)
    echo "usage: $0 {monthly|quarterly|yearly}" >&2
    exit 1
    ;;
esac

NOTE="$REVIEWS/review_${KIND}_${PERIOD}.md"
mkdir -p "$REVIEWS"

if [ ! -f "$NOTE" ]; then
  cat > "$NOTE" <<NOTE_EOF
---
type: review
date: ${DATE_TAG}
tags: [admin, review, ${KIND}]
---

# ${TITLE} - ${PERIOD}

> ${PROMPT}

Cadence defined in [[operating_system]]. Auto-created by review_reminder.sh.

## Checklist
- [ ] Go over all active projects; flag any without a next_action
- [ ] Re-check each goal: does every project still serve it?
- [ ] Archive what's done; park what's stalled (status: on_hold + trigger)
- [ ] Capture decisions and carry-forwards

## Notes

NOTE_EOF
fi

# macOS notification (best-effort; first run may prompt for notification permission)
/usr/bin/osascript -e "display notification \"${PROMPT}\" with title \"${TITLE} due\" subtitle \"${PERIOD}\" sound name \"Glass\"" || true

echo "$(date '+%Y-%m-%d %H:%M:%S')  ${KIND}  ${NOTE}" >> "$HOME/.mbs_automation/review_reminder.log"
