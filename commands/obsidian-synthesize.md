---
description: Scan the whole vault for unnamed cross-domain patterns and propose synthesis notes — suggest-only, never auto-files
category: thinking
triggers_en: ["synthesize", "find unnamed patterns", "make synthesis notes", "cross-vault patterns"]
---

Use the mbs_automation skill. Execute `/obsidian-synthesize`:

The whole-vault cousin of `/obsidian-emerge` (which looks at a recent window). This scans broadly for patterns that span domains and time, and **proposes** synthesis — it does not autonomously write synthesis pages (the old "writes synthesis pages without being asked / on its own schedule" behavior is removed; it violates propose-don't-dispose).

1. Read `_CLAUDE.md`, `SOUL.md`, `index.md`, and the last ~20 lines of `log.md`.
2. Scan for synthesis opportunities (shell-grep + reads; parallel read subagents for breadth). Exclude `trash/`; `_archive/` is historical context. Look for:
   - **Cross-domain recurrence** — the same idea/tension appearing in unrelated pillars (e.g. a "breadth vs. conviction" theme in both sports and money).
   - **Entity convergence** — people/projects that co-occur across contexts but aren't linked.
   - **Concept evolution** — how P's thinking on something has shifted over time (cite the dated notes that show the shift).
   - **Functional orphans** — substantive notes with no inbound links that clearly belong to an existing project/theme.
3. Present a **Synthesis Report**: each pattern with its evidence (cited real notes/dates), the interpretation, and a proposed action or proposed link.
4. **Suggest, don't file.** Only write a synthesis note (to `captured/` for triage, or a named project note) **when P approves**. Never auto-create `auto_generated` pages, never auto-link across human notes without approval.
5. If P approves writing, the synthesis note follows the amnesia test and links back to its source notes. Append to `log.md`; mention in today's tasks daily note.

---

**Anti-fabrication (hard rule):** every pattern must rest on specific, real, cited notes. Do not manufacture a theme, invent a quote, or inflate a couple of mentions into "a pattern." Per the search-completeness rule, scan broadly rather than sampling — but if the evidence is thin, say so instead of forcing a synthesis.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:`/`auto_generated:` flag, no `wiki/` structure, no autonomous writing — hybrid vault, suggest-don't-dispose. Never touch P's own sections of the daily note.
