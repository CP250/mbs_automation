---
description: Agent-drafted preparation for the Monthly/Quarterly/Yearly review notes (project_task_triage phase 2)
category: vault
triggers_en: ["review prep", "monthly review prep", "quarterly review prep", "yearly review prep"]
---

Use the mbs_automation skill. This is the unattended review-prep run invoked by `mbs_review_prep.sh` with a cadence (`monthly` | `quarterly` | `yearly`) and a period (e.g. `2026-08`, `2026-Q3`, `2027`) in the prompt.

The contract: P's review ritual is defined in `admin/betterment/operating_system.md`. The reminder job already created the dated note at `admin/reviews/review_<kind>_<period>.md`. Your job is to remove the blank-page cost by drafting the preparation INTO that note. P's judgment stays P's: you prepare, propose, and question; you never decide, never tick his checklist, never archive, never touch the calendar.

1. Read `CLAUDE.md` (vault manual), `SOUL.md`, `CRITICAL_FACTS.md`, `admin/betterment/operating_system.md`, and `goals_long_term`. Use filesystem tools (Read/grep), not the Obsidian MCP: the run may fire with Obsidian closed.
2. Target: `admin/reviews/review_<kind>_<period>.md`. **Read it first** (Edit fails on unread files). Append or refresh a single bounded section headed exactly `## Agent prep` (add ` (drafted YYYY-MM-DD)` after it on the same line). Never modify anything above it, especially P's `## Checklist` and `## Notes`. If a prior `## Agent prep` exists for the same period, refresh it in place.
3. Content by cadence, kept to roughly 60 lines, every vault note wikilinked, recency markers on time-sensitive claims:
   - **monthly**: run the monthly walk from [[operating_system]] as a draft: walk each [[goals_long_term]] domain; list the pillar `goals_*` files pointing at it via `rolls_up_to` (grep the frontmatter); for each, list its `status: active` projects; flag drift ("project no longer serves its pillar goal", "pillar goal no longer serves the domain"), pillar goals with `rolls_up_to: TBD` (unmoored), and active projects with zero unchecked body checkboxes. Close with the three sharpest questions the walk raises for P.
   - **quarterly**: prepare the [[goals_long_term]] refresh: per domain, what materially changed this quarter (scan the quarter's review notes, design log, and pillar logs); the unmoored `rolls_up_to: TBD` list; candidate edits to each domain phrased as proposals for P to accept or strike.
   - **yearly**: assemble the ethos packet: [[SOUL]] and [[goals]] re-read prompts, what this year's monthly/quarterly reviews said that touches the ethos layer, and a draft rotation checklist for `goals_<YYYY>` to `goals_<YYYY+1>`.
4. Propose-only, and the propose surface is the note itself: phrase flags as checkboxes P can tick or strike, not as actions you take. **Phrase every flag so its checkbox text ends with a question mark**: P answers by appending his decision to the end of the line and ticking; when he clears completed items, the daily run's archived-comment sweep (obsidian-daily.md step 3d) picks the decision up automatically the next morning, and the question-mark boundary is what makes his appended answer parse cleanly. No em-dashes anywhere (comma, colon, parentheses, hyphen instead).
5. Append one line to the design ops log (`admin/mbs_system/design/log/YYYY-MM-DD.md`): `**HH:MM** - review-prep | <kind> <period> drafted (N flags)`.

**Hard boundaries:** never delete or archive anything; never tick P's boxes; never create or modify calendar events; never touch any file except the review note and the ops log.
