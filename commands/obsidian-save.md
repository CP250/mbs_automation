---
description: Save everything worth keeping from this conversation to the vault
category: vault
triggers_en: ["save this", "save the conversation", "save to vault", "obsidian save"]
---

Use the mbs_automation skill. Execute `/obsidian-save`:

1. Read `_CLAUDE.md`, `SOUL.md`, `CRITICAL_FACTS.md` at the vault root.
2. Scan the conversation and identify vault-worthy items: decisions, tasks, people mentioned, projects started, ideas, learnings.
3. Group by type and route to the right **pillar** (admin/create/culture/health/money/skills/social/sports — see `vault-schema.md`). Spawn parallel subagents, one per group:
   - **People agent**: search `social/` for each person; create or update their note; log the interaction.
   - **Projects agent**: search for each project; create or update in the right pillar; ensure active projects have a `next_action`.
   - **Tasks agent**: parse tasks; add Tasks-plugin lines (`- [ ] ... 📅 YYYY-MM-DD`) to the relevant pillar's todo. (No kanban.)
   - **Decisions agent**: find the relevant project note; append to its Key Decisions section.
   - **Ideas agent**: search for related notes; create or append in the right pillar (or `captured/` if unsorted).
4. After agents complete: append links to everything saved into today's daily note (`daily_notes/tasks/tasks_YYYY-MM-DD.md`) and add a `log` entry.
5. Report back: a clean list of what was saved and where.

Search before creating — duplicates are vault rot. Propagate every write (daily note, linked notes, log). Never create an orphaned note. **Never auto-archive; never move files without approval.**

---

**Note rule:** Notes follow `references/ai-first-rules.md` (amnesia test): self-contained, frontmatter (`type`/`date`/`tags`), `next_action` on active projects, recency markers + verbatim sources, mandatory `[[wikilinks]]`. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault; existing human notes left as-is.
