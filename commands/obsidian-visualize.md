---
description: Generate a JSON Canvas map of the vault or a slice of it — see the shape of the pillars and how notes connect
category: meta
triggers_en: ["visualize vault", "vault map", "canvas of vault", "show me the vault shape"]
---

Use the mbs_automation skill. Execute `/obsidian-visualize $ARGUMENTS`:

The optional argument is a scope: a pillar name (`money`, `social`, …), a project or person name, a topic, or `full` for the whole vault (default `full`). Full-vault on a ~4,500-note vault is large — if the scope is `full`, confirm with P or suggest narrowing to a pillar first.

1. Read `_CLAUDE.md` at the vault root, and `index.md` for the catalog.
2. Build the graph (per the search-completeness rule in `references/vault-schema.md` — enumerate the in-scope notes exhaustively, do not sample):
   - **Scoped to a pillar/project/person/topic:** start from the matching note(s), follow outgoing `[[wikilinks]]` two hops, and include inbound links found by grepping for the basename.
   - **Full:** map every note and the links between them. **Exclude `trash/`.** Include `_archive/` notes but mark them historical (see colour below).
3. Generate a JSON Canvas file (the native Obsidian `.canvas` format — JSON with `nodes` and `edges` arrays):
   ```json
   {
     "nodes": [
       {"id": "1", "type": "file", "file": "money/project_polar/project_polar.md", "x": 0, "y": 0, "width": 250, "height": 60}
     ],
     "edges": [
       {"id": "e1", "fromNode": "1", "toNode": "2"}
     ]
   }
   ```
   Layout and styling rules:
   - **Hub nodes** (most links) toward the centre, larger.
   - **Cluster by pillar** — group each pillar's notes into a region; keep cross-pillar links as the long edges (those are the interesting connections).
   - **Colour by pillar** using Canvas colour slots ("1"–"6"); reuse a consistent mapping and state it in the text summary. Mark `_archive/` notes with a muted/grey colour so historical notes are visually distinct.
   - **Orphan nodes** (no links) placed at the edge so they are easy to spot.
4. Save to `admin/obsidian_optimize/atlas.canvas` for full scope, or `admin/obsidian_optimize/atlas_<scope>.canvas` when scoped. If a file of that name exists, confirm before overwriting (do not clobber a prior map silently).
5. Also print a short text summary: total nodes/edges, top 5 hub notes, orphans found, and any bridge notes that connect two otherwise-separate pillars. **Surface orphaned active projects** as something to act on, not just a stat.
6. Append a timestamped line to `admin/mbs_system/design/log.md`: `## [YYYY-MM-DD] visualize | Canvas generated — N nodes, M edges, K orphans (scope)`. Note it in today's tasks daily note (`## Vault Agent` section). Do not modify any existing note.

P opens the `.canvas` file in Obsidian to explore the graph visually.

---

**Anti-fabrication (hard rule):** every node and edge must correspond to a real note and a real `[[wikilink]]` that resolves — never invent a connection to make the graph look richer, and never list an orphan or hub that the link data does not support. Per search-completeness, an edge missing because you sampled is a real defect; enumerate the in-scope links fully.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault. The `.canvas` output lives under `admin/obsidian_optimize/`, not the vault root or a `wiki/` folder. Read-only over the vault apart from the canvas file; existing human notes are never modified. Never read `trash/`. Never touch P's own sections of the daily note.
