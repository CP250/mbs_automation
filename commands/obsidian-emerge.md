---
description: Surface unnamed patterns from recent notes — recurring themes, energy patterns, and conclusions the vault implies but you haven't stated
category: thinking
triggers_en: ["find patterns", "what is emerging", "surface themes", "unnamed patterns"]
---

Use the mbs_automation skill. Execute `/obsidian-emerge $ARGUMENTS`:

The optional argument is a timeframe (e.g. "2 weeks", "this month"); default last 30 days. The goal is insight P cannot easily see himself — surface what the notes imply but never name.

1. Read `CLAUDE.md`, `SOUL.md`.
2. Determine the date range.
3. Read the period's vault content (shell-grep + reads; spawn parallel read subagents if the range is large). Exclude `trash/`; treat `_archive/` as historical context only:
   - Both daily journals (`daily_notes/tasks/`, `daily_notes/health/`) — recurring topics, complaints, observations, energy.
   - Project notes — Key Decisions and `next_action` churn for directional trends.
   - `captured/` — thematic clusters in recent captures.
   - Pillar/work logs for repeated blockers or themes.
4. Identify and name:
   - **Recurring themes** — topics that appear 3+ times without being named as a priority.
   - **Energy patterns** — what energizes vs. drains (cross-check against SOUL.md's existing read; note shifts).
   - **Unnamed conclusions** — what the notes imply but never state ("you've raised X across four contexts — it's systemic, not local").
   - **Emerging directions** — where the vault suggests P is heading.
5. Present a **Pattern Report**: each pattern gets its evidence (cited real notes/dates), the interpretation, and a suggested action. Do not restate what P already knows.
6. Offer to save the report to `captured/` or a relevant project note. Log a brief summary in today's tasks daily note (`## Vault Agent` section).

---

**Anti-fabrication (hard rule):** every pattern must be backed by specific, real notes you cite. Do not manufacture a theme, invent a quote, or inflate two mentions into "a pattern." If the period is thin, say there's little to surface rather than forcing insight.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault. Never touch P's own sections of the daily note.
