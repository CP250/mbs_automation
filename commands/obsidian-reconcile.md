---
description: Find contradictions in the vault and propose fixes — flag-and-propose only, never auto-resolves or rewrites
category: thinking
triggers_en: ["find contradictions", "reconcile vault", "fix conflicts", "vault contradictions"]
---

Use the mbs_automation skill. Execute `/obsidian-reconcile $ARGUMENTS`:

The optional argument is a topic/entity to focus on; otherwise scan broadly. This finds notes that disagree with each other. **It never auto-resolves or rewrites** (the old "rewrite the outdated page" behavior is removed — it violates the propose-don't-dispose and never-auto-rewrite boundaries). It surfaces conflicts and proposes fixes; P decides.

1. Read `admin/mbs_system/brain/_CLAUDE.md`, `CRITICAL_FACTS.md`.
2. Find contradictions (shell-grep + reads; parallel read subagents for breadth). Exclude `trash/`. Look for:
   - Conflicting factual claims across notes (dates, numbers, names, statuses).
   - Outdated entity info (a role/company/relationship that a newer note contradicts).
   - Reversed or superseded decisions never updated in the project note.
   - Foundation drift: anything contradicting `CRITICAL_FACTS.md` / `SOUL.md` (these are the source of truth — flag the stale copy).
3. For each, judge: which is newer? Is it a genuine contradiction or just an **evolution** (P changed his mind — that's growth, not a conflict)? Cite the specific notes and dates on each side.
4. **Present a reconciliation report** — never act on it autonomously:
   - **Clear stale fact** → propose the exact fix (e.g. "update `[[note_x]]` line N from A to B"), and apply it **only after P approves**.
   - **Genuinely ambiguous** → list both sides with evidence; P decides.
   - **Evolution** → note the current state vs. the historical one; propose recording the change, don't erase the history.
5. On approval only: apply the agreed fixes, append to `admin/mbs_system/design/log.md`, note in today's tasks daily note. Nothing is rewritten without a yes.

---

**Anti-fabrication (hard rule):** only flag real contradictions backed by cited notes — do not invent a conflict or misread an evolution as a contradiction. Per search-completeness, scan thoroughly before declaring the vault consistent (or inconsistent). Distinguish what the notes actually say from your inference, and label which is which.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag, no `wiki/`/bi-temporal structure, no autonomous rewrites — hybrid vault, suggest-don't-dispose. Never touch P's own sections of the daily note.
