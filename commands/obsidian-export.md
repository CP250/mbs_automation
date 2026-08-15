---
description: Export a clean structured snapshot of the vault that another tool or agent can consume — flat JSON or markdown index
category: meta
triggers_en: ["export vault", "snapshot vault", "dump vault", "vault export"]
---

Use the mbs_automation skill. Execute `/obsidian-export $ARGUMENTS`:

The optional argument is the format: `json` (default) or `markdown`. This produces a flat, structured snapshot of the vault so an external tool or agent can understand its contents without knowing the pillar layout. It is read-only over the vault — it only writes the one snapshot file.

1. Read `admin/mbs_system/brain/CLAUDE.md`, and `admin/mbs_system/brain/vault_file_tree.md` for the file listing.
2. **Scan the vault exhaustively** (per the search-completeness rule in `references/vault-schema.md` — enumerate every note across the pillars, do not sample). Cover the eight pillars (`admin`, `create`, `culture`, `health`, `money`, `skills`, `social`, `sports`) plus `captured/` and the root files. **Exclude `trash/` entirely** (opaque), and **mark any `_archive/` note as `"archived": true`** so consumers can rank it as historical.
3. For each note, extract:
   - `path` — path relative to the vault root
   - `pillar` — top-level folder
   - `title` — first heading or filename
   - `type` — from frontmatter (`project`, `reference`, `person`, `decision`, `log`, `review`, …)
   - `date`, `status`, `next_action` — from frontmatter where present
   - `summary` — first paragraph or ~200 chars of body
   - `links_to` — outgoing `[[wikilinks]]` (by basename)
   - `tags` — frontmatter tags
   - `archived` — true if under an `_archive/` subfolder
4. Output format:
   - **JSON** (default) — save to `admin/mbs_system/design/export_vault_snapshot_YYYY-MM-DD.json`:
     ```json
     {
       "vault": "storage_mbs",
       "exported": "2026-05-21",
       "total_notes": 0,
       "notes": [
         {
           "path": "money/project_polar/project_polar.md",
           "pillar": "money",
           "title": "Project Polar",
           "type": "project",
           "status": "active",
           "next_action": "…",
           "links_to": ["Madi"],
           "tags": ["project", "money"],
           "archived": false
         }
       ]
     }
     ```
   - **Markdown** — a flat index with every note's metadata + summary grouped by pillar, saved to `admin/mbs_system/design/export_vault_snapshot_YYYY-MM-DD.md`.
5. Append a timestamped line to `admin/mbs_system/design/log.md`: `## [YYYY-MM-DD] export | Vault snapshot exported (<format>, N notes)`. Note it in today's tasks daily note (`## Vault Agent` section). Do not modify any existing note.

The snapshot is the bridge between P's vault and any other tool. They read this one file rather than the folder tree.

---

**Anti-fabrication (hard rule):** report only notes that actually exist, with the metadata they actually carry — never fabricate a note, a `next_action`, or a count. Per search-completeness, enumerate every note rather than sampling: an under-count (missing notes) is the failure to avoid. Use `null`/omit a field rather than inventing a value when frontmatter is absent.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault. No `_export/`/`wiki/` folders (the snapshot lives under `admin/mbs_system/design/`). Read-only over the vault apart from the single snapshot file; existing human notes are never modified. Never read or include `trash/`. Never touch P's own sections of the daily note.
