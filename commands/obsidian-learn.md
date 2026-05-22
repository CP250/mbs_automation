---
description: Review the lessons accumulated in the vault, surface the ones still live, and flag stale or superseded ones — suggest-only
category: thinking
triggers_en: ["review learnings", "what have I learned", "show lessons", "prune learnings"]
---

Use the mbs_automation skill. Execute `/obsidian-learn $ARGUMENTS`:

The optional argument is a scope: `recent` (last ~90 days, default), `all` (whole vault), or a topic. This reviews the lessons P's vault has accumulated so they compound instead of expiring. It **proposes** — it never auto-prunes, auto-archives, or rewrites `_CLAUDE.md` on its own.

1. Read `_CLAUDE.md`, `SOUL.md` at the vault root, and `index.md` + the last ~20 lines of `log.md` for context.
2. Gather learnings (shell-grep + reads; parallel read subagents for breadth; per the search-completeness rule in `references/vault-schema.md`, scan exhaustively rather than sampling). **Exclude `trash/`; treat `_archive/` hits as historical.** Look for:
   - **Lessons in daily notes** — both journals (`daily_notes/tasks/`, `daily_notes/health/`): "lesson learned", "what didn't work", "next time", review insights.
   - **Decisions** — structural ADRs in `admin/obsidian_optimize/` and project `## Key Decisions` sections (their rationale and how they turned out).
   - **Mistakes and wins** — logs and daily notes showing what wasted time vs. what worked, across pillars.
3. For each learning, classify and **cite the real source note(s) and dates** on both the original and any reinforcement:
   - **Active** — reinforced recently; still applies.
   - **Stale** — old, no recent reinforcement; a candidate to revisit (not to delete).
   - **Superseded** — explicitly replaced by a newer decision; cite both.
   - **Promotion candidate** — appeared 3+ times across contexts; strong enough that P might want it as a standing rule.
4. Present a **Learnings Report** in the conversation (no note written by default):
   - **Active learnings** — what still applies, with the original + most recent citation.
   - **Stale learnings** — with no recent reinforcement; suggest *keep / revisit*, never auto-archive.
   - **Superseded learnings** — old position → new position, both cited.
   - **Promotion candidates** — with proposed exact wording, framed as a suggestion for P to accept or reject.
   - **Top lessons of the period** — ranked by frequency × recency × consequence.
5. **Suggest, don't dispose.** Only on P's explicit approval: write the report (to `admin/reviews/` like `/obsidian-review`, or a relevant project note), propose a `_CLAUDE.md` / `references/` edit (propose the exact diff — never silently rewrite the operating manual), or flag a stale note for archiving (P moves it; the agent never does). If P approves writing, the note follows the amnesia test and links its source notes. Append to `log.md`; note in today's tasks daily note.

Lessons that aren't reviewed don't compound. This turns scattered notes into a living, but P-governed, rulebook.

---

**Anti-fabrication (hard rule):** every learning must rest on specific, real, cited notes — do not manufacture a "lesson", invent a reinforcement count, or inflate one mention into a recurring pattern. If the evidence for "active" or "promotion candidate" is thin, say so rather than forcing the classification. Distinguish what the notes actually say from your inference.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag, no `wiki/concepts/`/`auto_generated:` machinery — hybrid vault, suggest-don't-dispose. Never auto-archive, never silently edit `_CLAUDE.md`. Never touch P's own sections of the daily note.
