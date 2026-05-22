---
description: Bring legacy project notes up to amnesia-test schema — propose frontmatter additions per-note, never bulk-rewrite
category: meta
triggers_en: ["normalize projects", "true up schema", "fix project frontmatter", "upgrade project notes"]
---

Use the mbs_automation skill. Execute `/obsidian-normalize $ARGUMENTS`:

The argument is a pillar name (`admin`, `create`, `culture`, `health`, `money`, `skills`, `social`, `sports`) or `all`. This command finds `project_*` notes missing amnesia-test frontmatter and proposes additions one note at a time — it is the engine for schema true-up without touching human content.

1. Read `_CLAUDE.md`, `references/vault-schema.md`, and `references/ai-first-rules.md` at the vault root.
2. **Scope.** Accept the pillar argument (or `all`). Enumerate every `project_*` file in the target pillar(s), excluding `trash/` and `_archive/`. Report the total count before proceeding.
3. **Audit each note's frontmatter.** For each project note, read its frontmatter and flag what is missing against the project schema: `type`, `date`, `tags`, `status`, `next_action`, `people`. Notes that already have all required fields are skipped silently.
4. **Infer safe fields from content.** `type: project` is certain (filename convention). `tags` can be inferred from the pillar path. `status` can be inferred from keywords, recency of edits, and content tone (e.g. "completed," "on hold," recent activity → `active`). `date` defaults to the file's creation date if not present. `people` can be inferred from `[[wikilinks]]` in the body.
5. **Ask for what can't be safely inferred.** For `next_action` on notes inferred as `active`, and for `status` when the content is genuinely ambiguous, ask P one note at a time — show the note title, a brief content summary, and the proposed inference so far, then ask for the missing field(s). Never invent a `next_action`.
6. **Present a per-note diff and wait for approval.** Show the proposed frontmatter additions (what will be added or changed) as a before/after diff. Wait for P's explicit approval before writing each note. If P says "skip," move to the next note without writing.
7. **After all notes are processed,** report a summary: how many notes were updated, how many skipped, how many still need attention (e.g. active projects where P deferred `next_action`). Append a timestamped line to `log.md`.

This matters because ~4,500 legacy notes can't be bulk-migrated safely — the only reliable path is note-by-note inference + human confirmation, and this command turns that into a repeatable, interruptible workflow.

---

**Anti-fabrication (hard rule):** infer only what the note's content and file metadata actually support. Never invent a `next_action`, `status`, person, date, or any claim not present in the note or conversation. When a field can't be inferred, ask — don't guess. Per the search-completeness rule in `references/vault-schema.md`, never assert a note is absent without an exhaustive search.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault, P reads his own notes. No kanban boards (Tasks plugin + task-archiver). Existing human notes are left as-is unless P asks; the agent suggests archiving but never moves anything to `_archive/` itself. Never touch P's own sections of the daily note.
