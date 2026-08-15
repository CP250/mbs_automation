---
description: Smart vault recall — returns results with context and pillar, ranks _archive as historical, never touches trash
category: vault
triggers_en: ["find in vault", "search my notes", "where is", "what did I write about"]
---

Use the mbs_automation skill. Execute `/obsidian-find $ARGUMENTS`:

The argument is the search query. This is the recall capability — the "recall any part of it back to me on demand" half of the amnesia test. It is read-only.

1. Read `admin/mbs_system/brain/CLAUDE.md`.
2. Search the vault by filename and content for the query. If results are sparse, try variations (synonyms, related terms, working-title variants for projects, name variants for people).
   **Be exhaustive, not illustrative.** Recall's whole job is completeness, and the main failure mode is under-reporting. When a topic maps to a folder (a project, an `_archive/`), **directory-list it and report every matching file** — never a representative sample. If you write "archived files: …", that list must be complete; confirm it by listing the folder, not from memory. Do not claim a note is absent without an exhaustive search.
3. **Apply the search tiers** (per `references/vault-schema.md`):
   - **Never** search or surface `trash/` — it is opaque.
   - `_archive/` results are included but ranked **historical / low-priority**, and never presented as an active next step. Label them as archived.
   - Everything else is active and in scope.
4. Return results with enough context to act on — never bare filenames. For each: note title, pillar/folder, note type (project, person, reference, log, capture, ...), and a relevant excerpt. For a project, surface its `status` and `next_action` if present.
5. If results are ambiguous or numerous, group them by type (projects, people, references, daily notes, ...) and by pillar.
6. Offer to open, update, or link any result. If P asks to update or link one, that write follows `references/write-rules.md` (search-before-write, wikilinks, propagation, log/index update).

Do not just return filenames — return enough that P can act without opening each note.

---

**Note rule:** This command is read-only by default. Any edit it offers (update, link, stub) follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`: no `## For future Claude` preamble, no `ai-first:` flag, hybrid vault, existing human notes left as-is unless P asks.
