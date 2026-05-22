# Vault Schema Reference — mbs_automation

The structure of P's vault. This is the canonical map; commands route by it. It overrides any generic structure assumptions. Companion to the vault-root `_CLAUDE.md`.

This vault is **hybrid**, not wiki-style: ~4,500 existing human-readable notes organized by life pillars, with new agent-written notes following the amnesia-test conventions below. The agent is not the sole writer — P writes too, and domain Cowork projects write into their folders.

## Structure — life pillars

```
/Users/cpreston/Vaults/storage_mbs/
├── _CLAUDE.md             ← operating manual (read first, every session)
├── SOUL.md                ← who P is, how to work with him
├── CRITICAL_FACTS.md      ← what's true right now (family, health, work, locations)
├── index.md               ← catalog of vault pages (read for navigation)
├── log.md                 ← append-only operation log
│
├── admin/                 ← taxes, cars, citizenships, digital_life, legal, betterment, home, projects
├── create/                ← ch8 (Charlie Hunter 8-string), strings (cello/bass), photography, writing, gear, design
├── culture/               ← the arts: art, listen, play (video games), read, watch
├── daily_notes/           ← two journals: health/ and tasks/ (Journals plugin)
├── health/                ← physical (health_physical), food, drink, grooming
├── money/                 ← employers (tadano=P's holding co, verition), network, project_polar
├── skills/                ← danish, french, backgammon, sewing (non-creative, non-sport learning)
├── social/                ← friends, dogs, mentors, mentees, travel, acrp, ftd, hockey (incl. watching sports)
├── sports/                ← tennis, golf, nordic_skating, nordic_skiing, telemark_skiing, rackets (sports P plays)
│
├── captured/              ← inbox from external tools (MarkDownload, Glasp, Read It Later)
├── _to_clean/             ← legacy backlog P drains manually (NOT the agent's job unless asked)
├── attachments/           ← Obsidian-managed
└── trash/                 ← OPAQUE. Never read, search, or modify.
```

### Pillar boundary rules (P's own definitions)
- **sports** = sports P *plays*. **culture** = the arts. **social** = social activity, *including watching sports with people* (hockey lives in social, not sports or culture).
- Every pillar has (or gets on demand) an `_archive/` subfolder. See below.

## Folder semantics
- **`_archive/`** — every folder's archive for deprecated items, completed projects, conversation transcripts. Standard name everywhere (never `vaults_*`, never `old/`). Created on demand. **The agent suggests archiving but NEVER moves anything to `_archive/` autonomously — P decides when something is complete.**
- **`trash/`** — never searched, never read, never touched. Fully opaque.
- **`captured/`** — inbox; triage source. Don't treat its contents as filed.
- **`_to_clean/`** — P's manual backlog. Leave alone unless asked.

### Search tiers
- `trash/` → never searched.
- `_archive/` → searched, but ranked historical/low-priority; never surfaced as an active next-step.
- Everything else → active, in scope.

### Search completeness (a non-negotiable for every command)
When recalling, auditing, or reconciling, **enumerate exhaustively — do not sample.** List *every* matching file (directory-list a matched folder; grep the full set), not a representative few. **Never assert a note, person, or file is absent without an exhaustive search** — false-absence (under-reporting, or "no note exists" when one does) is the most common observed failure mode, more common than fabrication. Verify presence/absence by listing and grepping, not from memory. When in doubt, over-include and label uncertainty.

## Frontmatter schemas

New notes the agent writes carry frontmatter. Use **simple timestamps — no bi-temporal `timeline:` arrays** (out of scope per VISION). The `_archive/` history + `log.md` provide the audit trail.

### Project note
```yaml
---
type: project
date: 2026-05-20
tags: [project, <pillar>]
status: active        # active | planning | completed | on-hold
next_action: "<the single next actionable step>"   # MANDATORY on active projects
people: ["[[Madi]]"]  # wikilink everyone referenced
---
```
`next_action` is non-negotiable on active projects — it's the core of the amnesia test and the missing-next-step duty.

### Reference note (`ref_*`)
```yaml
---
type: reference
date: 2026-05-20
tags: [reference, <pillar>]
source: "https://..."          # verbatim if from the web
---
```

### Person note (social/)
```yaml
---
type: person
date: 2026-05-20
tags: [person]
relationship: "<wife | daughter | friend | mentee | ...>"
last_interaction: 2026-05-20
contact: ""
---
```

### Decision note / log entry
```yaml
---
type: decision
date: 2026-05-20
tags: [decision, <pillar>]
project: "[[<project>]]"
---
```

### Daily notes (Journals plugin — do not hand-create; the plugin owns these)
- Tasks journal: `daily_notes/tasks/tasks_YYYY-MM-DD.md`
- Health journal: `daily_notes/health/daily/daily_note_health_YYYY-MM-DD.md`
- The agent's morning report appends to the tasks journal inside a bounded `## Vault Agent` section.

## Naming conventions (summary; full detail in `_CLAUDE.md` + the vault's `admin/obsidian_optimize/RENAMING_PLAN.md`)
- Folders: lowercase snake_case, no redundant pillar prefix, singular unless inherently plural.
- Files: lowercase snake_case; type prefixes `project_*`, `ref_*`, `todo_list_*`, `log_YYYY-MM-DD_*`; plain noun when unsure. No spaces. Dates `YYYY-MM-DD`.
- Exception: creative drafts in `create/writing/writing_scraps/` keep natural poetic titles — never normalize those.
- Link format = default "shortest path" → `[[wikilinks]]` resolve by **basename**. Moving files is link-safe; renaming a file risks breaking `[[oldname]]` links — grep inbound links before renaming.

## Task management — Tasks plugin, NOT Kanban
P uses the **Tasks plugin** (`- [ ] description 🆔 <id>`) + **task-archiver**. There are no kanban boards. "Dashboards" are Dataview/Tasks queries, scoped per pillar/project.

```tasks
not done
path includes <pillar>
sort by due
```

## Dataview query patterns (pillar-aware)

### Active projects in a pillar, with their next action
```dataview
TABLE status, next_action FROM "<pillar>"
WHERE type = "project" AND status = "active"
SORT file.mtime DESC
```

### Projects missing a next action (the missing-next-step duty)
```dataview
TABLE file.folder AS pillar FROM ""
WHERE type = "project" AND status = "active" AND (!next_action OR next_action = "")
```

### Stale active projects (no edit in 14+ days)
```dataview
TABLE file.mtime AS "last touched" FROM ""
WHERE type = "project" AND status = "active" AND file.mtime < date(today) - dur(14 days)
SORT file.mtime ASC
```

### People not interacted with recently
```dataview
TABLE last_interaction FROM "social"
WHERE type = "person"
SORT last_interaction ASC
```

Exclude `trash/` always and rank `_archive/` results as historical.
