---
description: Create or update a project note — pillar-routed, amnesia-test frontmatter, mandatory body checkbox for next step, linked from today's note
category: vault
triggers_en: ["new project", "create project note", "project setup", "start a project"]
---

Use the mbs_automation skill. Execute `/obsidian-project $ARGUMENTS`:

The argument is a project name (handle typos and partial matches). This command creates or updates a project note that passes the amnesia test — its single most important job is that every active project carries at least one unchecked `- [ ]` body checkbox naming the next concrete step, because an active project with no next step is the exact failure this whole system exists to catch. (The vault used to encode this as a frontmatter `next_action:` field; that field was retired on 2026-06-06 in favor of the body checklist as the single source of truth.)

1. Read `_CLAUDE.md`, `SOUL.md`, `CRITICAL_FACTS.md` at the vault root.
2. **Search before writing.** Search the vault (filename + content, fuzzy) for an existing project — including working-title variants, which are the common duplicate source. Exclude `trash/`; treat `_archive/` hits as historical. If a typo or approximate name, show what was found and confirm before proceeding. Never silently create a note with a misspelled or near-duplicate name.
3. **If found:** show it, confirm, then update with new info from the conversation — add/tick body checkboxes as appropriate, append to Recent Activity / Key Decisions, update `status` if it changed.
4. **If not found:** determine the pillar (`admin`, `create`, `culture`, `health`, `money`, `skills`, `social`, `sports`) from context per `references/vault-schema.md`; if genuinely ambiguous, ask. Create the note as `<pillar>/project_<snake_case_name>.md`. If the project will accumulate sub-notes or attachments, use a folder: `<pillar>/project_<name>/project_<name>.md`. Match the pattern of existing projects in that pillar (read 1–2 first).
5. **Binary assets — ask, don't assume.** Per `references/asset-storage.md`, large binaries (PDFs, scans, images, audio, video, datasets) live outside the vault in a mirrored tree at `~/<vault-name>_assets/` (P's vault: `~/storage_mbs_assets/`). Ask P: *"Does this project need a binary asset folder for PDFs, scans, or other large files?"* If yes, create the mirrored folder (`~/<vault-name>_assets/<same-path-as-vault>/<slug>/` where `<slug>` is the project name without the `project_` prefix) and add `asset_path: "~/<vault-name>_assets/<...>/"` to the project's frontmatter (see step 6). If no, omit `asset_path:` — the convention is on-demand, never pre-created. If the answer is "maybe later," omit it now; the field can be added when the need arises.
6. **Frontmatter (mandatory schema)** per `references/ai-first-rules.md`:
   ```yaml
   ---
   type: project
   date: <YYYY-MM-DD>
   tags: [project, <pillar>]
   status: active                       # active | planning | completed | on-hold
   people: ["[[Name]]"]                 # wikilink everyone referenced
   asset_path: "~/<vault-name>_assets/<...>/"   # ONLY if step 5 said yes; omit otherwise
   ---
   ```
   **NO `next_action:` field.** The next step lives in the body as a `- [ ] ...` checkbox (see step 7). If `status: active`, the body MUST contain at least one unchecked checkbox or the project is in the "needs next step" failure state and the missing-next-step dashboard block will flag it.
   **Anti-fabrication (hard rule):** when asking P for the next step or any missing fact, ask neutrally. NEVER populate the question, its options, or the note with invented people, hand-offs, dates, signings, or status claims that are not present in the vault or this conversation. Inventing a name or a relationship (e.g. "X has the letter drafted") is a fabrication and is forbidden — it corrupts the amnesia-test vault. Mark unknowns as `TBD` and ask an open question instead.
7. **Body — amnesia-test self-sufficient + at least one unchecked checkbox:**
   - Lead with a sentence or two of plain context (what this is, why it exists, when it started).
   - Add a `## Next action` section (or `## Immediate next steps` if multiple) containing **at least one** `- [ ] <action> #<pillar> 🆔 <6-char-id>` line. This is the tickable next step. If `status: active` and you cannot infer a real next step, do not invent one — ask P. Never leave the section empty on an active project.
   - Fill in everything else inferable: description, goal, key people (as `[[wikilinks]]`), current status, relevant locations/account IDs/paths ("where things are"), and any external claims with recency markers and verbatim source URLs.
   - If `asset_path:` is set, reference specific binaries via `file://` absolute links (not Obsidian wikilinks — those only resolve inside the vault).
8. **Propagate** (per `references/write-rules.md` — never create a note in isolation):
   - The body checkbox added in step 7 IS the propagation to the Tasks plugin — the Tasks-plugin queries in the pillar dashboard and in `daily_notes/tasks/...` will find it via `path includes <pillar>` filters. Do not separately duplicate it into a per-pillar todo file unless P asks.
   - Link the project from today's tasks daily note (`daily_notes/tasks/tasks_YYYY-MM-DD.md`, inside the bounded `## Vault Agent` section or a one-line mention — never touch P's own sections).
   - If a person is involved, link the project from their note in `social/` (create a stub if absent).
   - Append a timestamped line to `admin/mbs_system/design/log.md`; update `index.md` for the new note.

---

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test), `references/write-rules.md`, and `references/asset-storage.md` (binaries outside the vault). No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault, P reads his own notes. No kanban boards (P uses the Tasks plugin + task-archiver). Existing human notes are left as-is unless P asks to upgrade one.
