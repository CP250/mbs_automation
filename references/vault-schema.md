# Vault Schema Reference — mbs_automation

The structure of P's vault. This is the canonical map; commands route by it. It overrides any generic structure assumptions. Companion to `admin/mbs_system/brain/_CLAUDE.md`.

This vault is **hybrid**, not wiki-style: ~4,500 existing human-readable notes organized by life pillars, with new agent-written notes following the amnesia-test conventions below. The agent is not the sole writer — P writes too, and domain Cowork projects write into their folders.

## Structure — life pillars

```
/Users/cpreston/Vaults/storage_mbs/
├── CLAUDE.md              ← vault auto-loader (single root file)
├── admin/mbs_system/brain/ ← brain files (operating manual, identity, catalog)



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
└── trash/                 ← OPAQUE to reads/searches. Agent's only interaction: move files IN (disposal path). Never delete from. See _CLAUDE.md Disposal section.
```

### Pillar boundary rules (P's own definitions)
- **sports** = sports P *plays*. **culture** = the arts. **social** = social activity, *including watching sports with people* (hockey lives in social, not sports or culture).
- Every pillar has (or gets on demand) an `_archive/` subfolder. See below.

## Folder semantics
- **`_archive/`** — every folder's archive for deprecated items, completed projects, conversation transcripts. Standard name everywhere (never `vaults_*`, never `old/`). Created on demand. **The agent suggests archiving but NEVER moves anything to `_archive/` autonomously — P decides when something is complete.**
- **`trash/`** — opaque to reads and searches. The agent never reads, surfaces, or permanently deletes from `trash/`. **The agent's one allowed interaction with `trash/` is to move files INTO it as the disposal path** (per vault `_CLAUDE.md` Disposal section, 2026-06-14). Trash moves do not require permission; the agent never asks "can I delete this?" - the answer is always "move to `trash/` and continue."
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
status: active        # active | planning | on_hold | someday | completed
trigger: "<event that reactivates an on_hold project>"   # on_hold projects only
next_action: "<the single next actionable step>"   # MANDATORY on active; omit on on_hold/someday/planning
people: ["[[Madi]]"]  # wikilink everyone referenced
---
```
`next_action` is non-negotiable on active projects — it's the core of the amnesia test and the missing-next-step duty. `on_hold`/`someday`/`planning` projects don't require one; an `on_hold` project instead carries a `trigger:` naming the (often unrelated) event that should wake it back up.

### Reference note (`ref_*`)
```yaml
---
type: reference
date: 2026-05-20
tags: [reference, <pillar>]
source: "https://..."          # verbatim if from the web
---
```

### Person note (social/people/, or pillar-specific subfolder)
```yaml
---
type: person
date: 2026-05-20
aliases:
  - Full Name
  - Nickname
tags: [person, <relationship-bucket>]
relationship: "<see value set below>"
last_interaction: 2026-05-20
contact: ""
growth_goal: "<optional; see goals_friends.md>"
next_contact: "<optional; see goals_friends.md>"
---
```

**Folder:** default is `social/people/<first_last>.md` (renamed 2026-06-12 from `social/friends/people/`). The folder name avoids "friends" because not everyone in it is already a friend; `relationship:` is the discriminator. People with a dedicated pillar area keep it (Avery in `social/acrp/`, Madi in `social/ftd/`, dogs in `social/dogs/`). Work colleagues live with their work context, not in `social/people/` (Polar interview contacts in `money/project_polar/`, Verition colleagues in `money/verition/`).

**`relationship:` values** (expanded 2026-06-12):
- Family roles: `wife`, `daughter`, `son`, `father`, `mother`, `sibling`
- `friend` - person P enjoys spending time with for its own sake
- `colleague` - direct workplace tie (current or recent)
- `professional_contact` - industry/network tie outside the workplace; includes contacts P is actively cultivating that may evolve into friendship
- `mentor` / `mentee` - explicit mentorship dynamic
- `acquaintance` - light tie worth tracking but not actively cultivated

Custom prose values are permitted when the enum doesn't capture a relationship cleanly (e.g. `ex-wife / co-parent` on [[laura_defranco]], or the prose values on Polar interview contacts). The field is for the dominant current mode; update the value when the dominant mode shifts. Do not move the file.

**Meeting documentation pattern** (canonical 2026-06-12):
- `## Interactions` section at the top: chronological one-line index. Every interaction (text exchange, brief encounter, full meeting) gets a one-liner here.
- `## Meetings` section for substantive writeups: each meeting is a `### YYYY-MM-DD - <one-line title>` subsection covering Setting, the arc of the conversation in named beats, P's takeaways, offers/asks, and action items as Tasks-plugin checkboxes with `#<pillar> 🆔 <id> 📅 <date>` so they flow into Morgen.
- Loose meeting notes at vault root get integrated into the relevant person note via this pattern, then archived. The person note is the single source of truth for the relationship.
- Reference example: [[tom_van_riper#Meetings]].

### Decision note / log entry
```yaml
---
type: decision
date: 2026-05-20
tags: [decision, <pillar>]
project: "[[<project>]]"
---
```

### Pillar goals note (`goals_<thread>.md`)
Most goals notes use `type: reference` and live at `<pillar>/<thread>/goals_<thread>.md` (e.g. `create/ch8/goals_ch8.md`, `sports/golf/goals_golf.md`). They roll up to sections of `admin/betterment/goals_long_term.md` via `rolls_up_to:`. The optional weekly-block fields make a thread participate in the **Morgen drop-zone** workflow (see `_CLAUDE.md` → "Weekly time-blocks → Morgen drop zone" and SETUP.md → "com.mbs.weekly-blocks"):

```yaml
---
type: reference                       # or "goals" for full goals-type notes (e.g. goals_oslo.md)
date: 2026-06-06
tags: [reference, <pillar>, <thread>, goals]
rolls_up_to: "[[goals_long_term#<section>]]"
last_reviewed: 2026-06-06
weekly_minutes: 120                    # OPTIONAL — total minutes/week to time-block. omit or 0 = thread doesn't participate.
default_block_length: 60               # OPTIONAL — largest single block size, default 60. Last block holds the remainder.
---
```

The pair `(weekly_minutes, default_block_length)` is the **single source of truth** for weekly time-block generation. The script `~/dev/mbs_automation/scripts/weekly_blocks.py` reads only the frontmatter — no body parsing — so the goals file body remains free prose. To pause for a week: set `weekly_minutes: 0` or delete the line. To rebalance block lengths: tune `default_block_length`. No code change required for either; next Sunday's launchd run picks up the edit automatically.

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
