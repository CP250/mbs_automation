---
description: Record a decision about the vault's own structure or conventions — so the vault knows why it is shaped the way it is
category: thinking
triggers_en: ["log this decision", "ADR", "record decision", "decision record"]
---

Use the mbs_automation skill. Execute `/obsidian-adr $ARGUMENTS`:

The optional argument is the decision topic; if absent, infer it from recent conversation. This records a **structural** decision — a choice about the vault itself (a new convention, a folder reorganization, a renaming rule, a pillar boundary, a schema change), not a decision inside a life project. For project-level decisions use `/obsidian-decide` instead.

1. Read `admin/mbs_system/brain/_CLAUDE.md` (and `references/vault-schema.md` for the pillar map).
2. Identify the structural decision — from the argument or from recent conversation (e.g. a convention was adopted, a folder was reorganized, a naming rule changed, a pillar boundary was clarified). Confirm in one sentence what you understood before writing.
3. **Search before writing** (per `references/write-rules.md`, exhaustively per the search-completeness rule in `references/vault-schema.md`): check `admin/mbs_system/design/` and the vault root for an existing record on this same decision so you update rather than duplicate.
4. Write the decision record to `admin/mbs_system/design/adr_YYYY-MM-DD_<snake_case_title>.md` (this is vault-meta, which lives under `admin/`). Frontmatter:
   ```yaml
   ---
   type: decision
   date: <YYYY-MM-DD>
   tags: [decision, admin]
   scope: vault-structure
   status: accepted        # accepted | superseded | proposed
   ---
   ```
   Body — amnesia-test self-sufficient (a future reader with zero context should understand it):
   - **Decision** — one line: what was decided.
   - **Context** — the problem or trigger that prompted it.
   - **Options considered** — the 2-3 alternatives weighed.
   - **Rationale** — why this option over the others.
   - **Consequences** — what changes as a result: which conventions, folders, or notes are affected. List affected notes as `[[wikilinks]]`.
   - **Related** — links to affected notes, prior ADRs it supersedes, or `references/` specs.
5. **Propagate** (per `references/write-rules.md`): if the decision changes a documented convention, flag the `references/` spec or `_CLAUDE.md` line that should be updated and propose the exact edit — do not silently rewrite the operating manual. Append a timestamped line to `admin/mbs_system/design/log.md`; note it in today's tasks daily note (`## Vault Agent` section).
6. This command can also be offered by other commands when a structural change happens (a folder reorg, a convention adopted during `/obsidian-reconcile`, a schema change). In those cases offer to create an ADR — never force it.

---

**Anti-fabrication (hard rule):** record only a decision that was genuinely made. Do not invent options that were never weighed, a rationale P did not give, or consequences that did not occur. If it is unclear whether something was actually decided (vs. discussed), ask before recording it. Per search-completeness, confirm no prior record exists before claiming this is a new decision.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault, P reads his own notes. No kanban boards, no `Knowledge/`/`wiki/` folders (vault-meta lives in `admin/`). Never silently rewrite `_CLAUDE.md` or a `references/` spec — propose the change. Never touch P's own sections of the daily note.
