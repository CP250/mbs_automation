#!/bin/bash
# cars_weekly.sh - weekly LHD collectible-car listing sweep.
#
# Pairs with mbs_weekly.sh / oslo_weekly.sh - same launchd pattern (state dir,
# per-week stamp, PATH export, log to ~/.mbs_automation/). The body is a Claude
# headless call (`claude -p`) because the work needs web search, dedupe against
# existing car notes, and structured note writing - not something bash can do.
#
# Triggered by launchd (see scripts/launchd/com.mbs.cars-weekly.plist):
#   1. StartCalendarInterval Monday 07:30 local (after mbs_weekly 07:00, oslo 07:15).
#   2. Wake from sleep - launchd coalesces the missed fire and runs on wake.
#   3. RunAtLoad at login - covers a powered-off Mac.
#
# Per-ISO-week stamp file (last_cars_weekly_run) makes every trigger idempotent:
# at most one run per week, and only if this week hasn't already succeeded.
# Stamp is written only on success.
#
# What it does: sweeps the major auction/dealer platforms for new LHD listings
# of the four candidate models, dedupes against the registry by chassis, files
# hits into the Obsidian registry under admin/transportation/cars/luxury/, and
# appends a summary to today's tasks daily note. Asset (image) capture is NOT
# done unattended - it is on-demand and may need a browser session.

set -uo pipefail

VAULT="/Users/cpreston/Vaults/storage_mbs"
STATE_DIR="$HOME/.mbs_automation"
STAMP="$STATE_DIR/last_cars_weekly_run"
LOG="$STATE_DIR/cars_weekly.log"

mkdir -p "$STATE_DIR"

THIS_WEEK="$(date +%G-W%V)"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$THIS_WEEK" ]; then
  echo "$(ts) - already ran for $THIS_WEEK, skipping." >> "$LOG"
  exit 0
fi

# Source auth-failure detection helpers.
# shellcheck source=./lib_auth.sh
source "$(dirname "$0")/lib_auth.sh"

# Pre-flight: skip cleanly if Claude Code needs re-auth.
if needs_reauth_skip "$LOG"; then
  exit 0
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  echo "$(ts) - ERROR: 'claude' not found on PATH. Edit PATH in this script. Aborting." >> "$LOG"
  exit 1
fi

echo "$(ts) - starting cars weekly sweep for $THIS_WEEK (claude: $CLAUDE_BIN)" >> "$LOG"

cd "$VAULT" || { echo "$(ts) - ERROR: cannot cd to $VAULT" >> "$LOG"; exit 1; }

# Daily-note sync-conflict guard (SETUP.md, "Phone-Mac sync conflict guard").
# This job appends to TODAY's tasks note, so it follows pattern (b): Mac owns
# creation; phone Journals `tasks.autoCreate` is disabled. mbs_daily's 06:00
# pre-flight normally creates this file before this 07:30 job runs, but guard
# against a failed/skipped daily run by ensuring it exists here too, using the
# same minimal frontmatter mbs_daily writes.
TODAY="$(date +%Y-%m-%d)"
TODAYS_TASKS="$VAULT/daily_notes/tasks/tasks_${TODAY}.md"
if [ ! -f "$TODAYS_TASKS" ]; then
  mkdir -p "$(dirname "$TODAYS_TASKS")"
  cat > "$TODAYS_TASKS" <<EOF2
---
journal: tasks
journal-date: ${TODAY}
---

EOF2
  echo "$(ts) - pre-flight: created minimal $TODAYS_TASKS" >> "$LOG"
fi

read -r -d '' PROMPT <<'EOF'
This is the unattended weekly LHD collectible-car listing sweep for P's vault at /Users/cpreston/Vaults/storage_mbs, using the mbs_automation skill. Write via the filesystem, not the Obsidian MCP.

First read these for conventions and the per-car schema:
- admin/transportation/cars/luxury/ref_lhd_registry_method.md
- the four project notes: admin/transportation/cars/luxury/<slug>/project_*.md
Slugs: aston_martin_virage, aston_martin_v8_zagato, lagonda_series_iv, bristol_blenheim.

SCOPE - LHD cars only (P is US-Eastern; alert geography = US, Canada, continental Europe; UK listings are mostly RHD and usually not relevant). The four models:
1. Aston Martin Virage / V8 Coupe / V8 Vantage (1988-2000)
2. Aston Martin V8 Zagato coupe + Volante (1986-1990)
3. Aston Martin Lagonda Series IV / Series 4 (1987-1990)
4. Bristol Blenheim car (1994-2009) - scope queries to "car" or "saloon" to avoid the WWII aircraft.

CITATION RULE (mandatory, non-negotiable): every car, price, sale, sighting, or factual claim you report MUST carry the verbatim source URL it came from, inline in the same bullet, as a markdown link. A claim with no URL may NOT be presented as fact. If something appears only in a search-result summary and you do not have a specific retrievable page URL, you must EITHER (a) fetch the page and get the real URL, or (b) write it as "UNVERIFIED - no source URL (search query: <the exact query you ran>)" and never state it as though confirmed. When a source actually resolves a fact (e.g. a VIN that turns out to be RHD), report the resolved fact with its link rather than leaving it "unconfirmed." Prefer three sourced items over ten unsourced ones. A report containing any unsourced, un-tagged claim is a failed run.

DO each run:
1. Search the web (and fetch server-rendered sites such as classic.com, bonhams.com, rmsothebys.com) for listings posted or updated in roughly the last 7-10 days, across Bring a Trailer, Collecting Cars, Car and Classic, The Market, Bonhams, RM Sotheby's, classic.com, Classic Driver. Prefer LHD; skip obvious RHD-only UK cars unless notable.
2. Capture per hit, each with its source URL: model, chassis or VIN if shown, year, drive, exterior and interior colour, asking or sold price with date, platform, listing URL. For any car whose drive is unclear, try to resolve it from the source (VIN drive code, the listing's own LHD/RHD field) before reporting; report the resolved answer with the link.
3. Dedupe against existing notes in each model's cars/ folder by chassis number. If the chassis already has a note, append a dated line to its "## Ownership and sales timeline" with the new sighting and URL. If the chassis is new and the car is LHD or likely LHD, create cars/<chassis>.md using the schema in the method note, provenance lead - including the source URL in its "## Source" section.
4. Append every new hit as a dated bullet to the "## New listings to triage" section of the matching index_<slug>.md note - each bullet MUST contain at least one markdown link to its source (or the explicit UNVERIFIED tag from the citation rule).
5. Do NOT scrape or download images unattended - only record URLs. Asset capture is on-demand. If a listing page is JavaScript-rendered and you cannot retrieve its content, say so explicitly and give the URL anyway so P can open it.

OUTPUT: append a concise summary to today's daily note at daily_notes/tasks/tasks_YYYY-MM-DD.md under a "## Vault Agent - car sweep" heading: new hits per model, any standout LHD cars, anything needing P's attention. Every factual line in the summary carries its source link per the citation rule. If zero new LHD listings across all four, say so in one line.
EOF

run_claude_p "$PROMPT" "$LOG"
rc=$?
if [ "$rc" -eq 0 ]; then
  clear_reauth_sentinel
  echo "$THIS_WEEK" > "$STAMP"
  echo "$(ts) - completed successfully; stamped $THIS_WEEK" >> "$LOG"
  /usr/bin/osascript -e "display notification \"car listing sweep complete\" with title \"mbs - cars weekly\"" 2>/dev/null || true
elif [ "$rc" -eq 2 ]; then
  mark_reauth_needed "$LOG"
  echo "$(ts) - cars weekly sweep blocked on Claude Code auth; no stamp written. Next trigger after re-auth will retry." >> "$LOG"
  exit 2
else
  echo "$(ts) - ERROR: cars weekly sweep exited $rc; will retry on next trigger" >> "$LOG"
  exit "$rc"
fi
