---
description: Generate a structured weekly or monthly review note from vault history — accomplishments, decisions, people, next-step gaps
category: thinking
triggers_en: ["weekly review", "monthly review", "review my week", "review my month"]
---

Use the mbs_automation skill. Execute `/obsidian-review $ARGUMENTS`:

The optional argument is `weekly` or `monthly` (ask if unclear). This is the reflective counterpart to the daily safety net: zoom out, see the arc, name what to carry forward.

1. Read `_CLAUDE.md`, `SOUL.md`, `CRITICAL_FACTS.md`.
2. Determine the period (weekly or monthly) and its date range.
3. **Read the period's vault history** (shell-grep + reads):
   - Both daily journals: `daily_notes/tasks/` and `daily_notes/health/` for the range.
   - Active project notes — status changes, new `next_action`s, Key Decisions added in the range.
   - Tasks completed in the range (Tasks-plugin `✅ <date>` lines; task-archiver moves, not kanban).
   - New captures in `captured/`.
4. **Draft the review note** with these sections:
   - **What happened** — accomplishments and movement, grounded in cited notes.
   - **Key decisions** — with the project they belong to (`[[wikilinks]]`).
   - **People** — who P worked with / saw (link `social/` notes).
   - **What I learned / what to carry forward.**
   - **Open next steps** — active projects still missing a `next_action`, and the most important thing for the coming period. (This ties the review back to the headline duty.)
   - Where SOUL.md's honest-mirror role applies, name a blind spot or a pattern worth P's attention — directly, not flattering.
5. Frontmatter:
   ```yaml
   ---
   type: review
   date: <YYYY-MM-DD>
   period_start: <YYYY-MM-DD>
   period_end: <YYYY-MM-DD>
   tags: [review]
   ---
   ```
6. Save to `admin/reviews/review_<weekly|monthly>_<YYYY-MM-DD>.md` (create `admin/reviews/` on demand). Link it from the last daily note of the period. Append to `admin/mbs_system/design/log.md`.

---

**Anti-fabrication (hard rule):** the review reflects what the notes actually show. Cite real notes for accomplishments and decisions; do not invent progress, inflate outcomes, or attribute decisions that weren't made. An honest "little moved this week" is correct when that's the truth.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag, no kanban — hybrid vault, Tasks plugin.
