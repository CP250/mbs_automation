# Write Rules

How the agent writes, links, formats, and updates notes in P's vault.

> **Read `references/ai-first-rules.md` (the amnesia-test spec) first.** New notes the agent writes must pass the amnesia test: self-contained, frontmatter, `next_action` on projects, recency markers, verbatim sources, mandatory wikilinks. Existing human notes are left alone. The rules below are operational details on top of that.

## The propagation rule

**Never create a note in isolation.** Trace forward — what else needs to know?

```
New project created
  → add a task to the relevant pillar's todo (Tasks plugin) if there's a next action
  → link from today's daily note (daily_notes/tasks/)
  → if a person is involved, link from their note in social/

Task completed
  → mark done in the Tasks-plugin line (task-archiver handles archiving)
  → update the project note (Recent Activity / next_action)
  → note it in today's daily note

Person interaction
  → log in today's daily note
  → update their note in social/ (last_interaction)

Work/dev session
  → log to the relevant pillar (e.g. money/<employer>/ or the project folder)
  → link from today's daily note

Decision made
  → append to the project note's Key Decisions section
  → note in today's daily note
```

Always append to `log.md` (timestamped) when a structural change happens, and update `index.md` when a note is created or deleted.

## Internal linking
Use `[[Note Name]]` — Obsidian resolves by basename (default "shortest path" setting). Always link people, projects, places, recurring concepts. Never hardcode full paths in links. If the target doesn't exist, create a stub (below).

**Rename safety:** moving a file is link-safe (basename unchanged). Renaming a file can break `[[oldname]]` links — grep for inbound links before renaming, and fix them.

## Date formatting
| Context | Format | Example |
|---|---|---|
| Frontmatter `date` / `due` | `YYYY-MM-DD` | `2026-05-20` |
| Tasks-plugin due date | `📅 YYYY-MM-DD` | `📅 2026-05-28` |
| Body text | human | `May 20` |
| Dated filenames | `YYYY-MM-DD` prefix | `log_2026-05-20_*.md` |

## Tasks — Tasks plugin, NOT kanban
P uses the **Tasks plugin** + **task-archiver**. There are no kanban boards.

Task line format:
```markdown
- [ ] Description #<pillar> 🔼 📅 2026-05-28
```
- Status: `[ ]` todo, `[/]` in progress, `[x]` done (P's configured statuses).
- Priority (optional): Tasks-plugin emoji (`🔺` highest … `🔽` lowest) — use sparingly.
- Due: `📅 YYYY-MM-DD`. Completed tasks get `✅ YYYY-MM-DD` (the plugin adds this).
- "Dashboards" are `tasks` or `dataview` query blocks scoped per pillar/project — not boards.

Never delete completed tasks — `task-archiver` moves them to the pillar's archive on P's cadence.

## Status values
- **Projects:** `active` | `planning` | `completed` | `on-hold`
- **Tasks:** todo `[ ]` | in-progress `[/]` | done `[x]`
- **Notes (drafts):** `stub` | `draft` | `done` (optional `status:` for incomplete-note detection)

## Writing-style calibration
Before writing in a folder you haven't written in: read 1–2 existing notes there and match heading structure, frontmatter fields, tone, list style. **Extend what's there; don't introduce new patterns.** Special case: `create/writing/writing_scraps/` uses natural poetic titles — never normalize those.

## Archiving — `_archive/`, suggest-only
- Archive = **move the note into that folder's `_archive/` subfolder** (not a filename prefix). Create `_archive/` on demand if absent.
- **The agent NEVER archives autonomously.** It may flag "this looks complete — archive it?" and waits for P. P decides when something is done.
- **Never permanently delete.** The agent's disposal path for junk / true duplicates / accidents is a **move to `trash/` at the vault root, no permission required** (per vault `_CLAUDE.md` Disposal section, 2026-06-14). `trash/` is opaque to reads and searches: the agent never reads from it, never surfaces its contents, and never permanently deletes from it. The agent's only interaction with `trash/` is to move files INTO it.

## Template usage
When creating from a Templater template, strip all `<% ... %>` syntax and fill real values. Never leave template placeholders in a saved note.

## Stub notes
When a `[[link]]` target doesn't exist, create a minimal stub:
```yaml
---
type: <person | project | reference>
date: YYYY-MM-DD
tags: [<type>, <pillar>]
---

# <Name>

<!-- stub — expand when more info is available -->
```

## Section injection (updating existing notes)
1. Read the full file. 2. Find the target heading. 3. Append below the last item in that section (before the next `##`). 4. Write back. For the daily note, the agent's content goes inside a bounded `## Vault Agent` section in `daily_notes/tasks/tasks_YYYY-MM-DD.md`.

## Search before write
Before creating any note, search for an existing one (filename + content). If the same concept exists → update it, don't duplicate. If similar name, different concept → proceed but pick a distinct name. Duplicate prevention matters most for people (name variants) and projects (working-title variants). Exclude `trash/`; treat `_archive/` hits as historical.
