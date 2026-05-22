---
description: Summarize a time period from the vault — today, week, or month. Read-only narrative
category: vault
triggers_en: ["recap today", "recap the week", "summarize the week", "month recap"]
---

Use the mbs_automation skill. Execute `/obsidian-recap $ARGUMENTS`:

The argument is the period: `today`, `week`, or `month` (default `week`). This is a lighter, read-only cousin of `/obsidian-review` — a quick narrative catch-up, no note written.

1. Read `_CLAUDE.md` at the vault root.
2. Determine the date range.
3. **Read the period's vault activity exhaustively** (per the search-completeness rule in `references/vault-schema.md` — enumerate every daily note in the range, don't sample):
   - Both daily journals: `daily_notes/tasks/` and `daily_notes/health/`.
   - Project notes touched in the range (status changes, new `next_action`s, Key Decisions).
   - Tasks completed (`✅ <date>` lines; task-archiver moves), captures added, logs written.
4. Synthesize a clean narrative summary: what was worked on, decisions made, people seen, tasks completed, ideas captured. Prose, not a raw dump.
5. Read-only by default — don't write a note unless P asks (if asked, save to `admin/reviews/` like `/obsidian-review`). A one-line mention in today's tasks daily note is fine if P wants it tracked.

---

**Anti-fabrication (hard rule):** summarize only what the notes actually show; cite real notes; an honest "quiet week" is correct when that's the truth. Don't pad the recap with invented activity.

**Note rule:** Read-only. Any note it writes follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`: no `## For future Claude` preamble, no `ai-first:` flag, no kanban — hybrid vault.
