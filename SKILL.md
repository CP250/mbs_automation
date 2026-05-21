---
name: mbs_automation
description: >
  Operate P's Obsidian vault (life organized by pillars: admin, create, culture,
  daily_notes, health, money, skills, social, sports) as a living second brain that
  holds his life and recalls any part on demand. Use whenever P asks Claude to read,
  write, update, search, or manage the vault — saving notes from conversation, creating
  or appending to daily notes, managing tasks (Tasks plugin, not kanban), logging work,
  managing people notes, capturing decisions, surfacing the next step, reconciling the
  calendar, or maintaining vault structure. Core duties: missing-next-step detection,
  calendar reconciliation, note normalization, and project-decomposition partnership.
  New notes follow the amnesia test (self-contained, frontmatter, next_action on projects,
  recency markers, mandatory wikilinks); existing human notes are left as-is. The agent
  suggests archiving but never archives autonomously. Out of scope: research toolkit,
  bi-temporal facts.
---

# mbs_automation

> Claude operates P's Obsidian vault as his external memory — it holds his life so he doesn't have to, and recalls any part of it on demand. The standard is the **amnesia test**: if P woke up remembering nothing, the vault tells him what things are, where they are, and what to do next. The failure mode it defends against: stress + distraction making him lose the next step.
> Read `_CLAUDE.md`, `SOUL.md`, `CRITICAL_FACTS.md` at the vault root first, every session.

---

## Quick Start

### 0. Choose vault access method (in order of preference)

Try these methods in order. Use the first one available:

**Method 0 — SessionStart hook (if configured):**
If `hooks/load_vault_context.py` is wired as a SessionStart hook in `~/.claude/settings.json`, `_CLAUDE.md` is injected into context automatically at session start. Skip step 1 below.
To wire it: `bash scripts/setup.sh "/path/to/vault"` or run `/obsidian-setup`.

**Method A — iansinnott Claude Code MCP plugin (preferred):**
P runs the "Claude Code MCP" Obsidian plugin (live workspace link via websocket). Connect with `/ide` → select Obsidian. This gives the active file + vault structure and is the intended access path.

**Method B — Direct filesystem (fallback, always works):**
Standard file tools (Read, Write, Edit, Glob) against `/Users/cpreston/Vaults/storage_mbs/`. The vault is plain markdown — everything works this way too.

### 1. First time in a vault → read `_CLAUDE.md`

Before doing anything in a vault, check if `_CLAUDE.md` exists at the vault root:

```
get_file_contents("_CLAUDE.md")
```

If it exists: follow its rules exactly — they override the defaults in this skill. Where `_CLAUDE.md` is silent, fall back to the defaults below.
If it doesn't exist: use the defaults in this skill, then offer to create one.

If the SessionStart hook is active, `_CLAUDE.md` is already in context — skip this step.

### 2. First time with a new user → run discovery

```
list_files_in_vault()
```

Scan the structure to understand: folder names, template locations, naming conventions, frontmatter patterns. Then read 2–3 existing notes with `get_file_contents(path)` to calibrate writing style before creating anything new.

### 3. No bootstrap — the vault already exists

P has a mature, ~4,500-note vault organized by life pillars. **Do not run `bootstrap_vault.py`, do not apply presets, do not impose a wiki structure.** The structure, conventions, and foundation files (`_CLAUDE.md`, `SOUL.md`, `CRITICAL_FACTS.md`) already exist. Use `/obsidian-init` only to *refine* `_CLAUDE.md` against the live structure (diff-and-ask), never to regenerate.

See `references/vault-schema.md` for the pillar structure.

---

## Core Operating Principles

### Note rule — the amnesia test (applies to notes the agent writes)
This vault is **hybrid**, not future-Claude-only: P reads it, and ~4,500 existing human notes stay as-is. New notes the agent writes must pass the **amnesia test** (canonical spec: `references/ai-first-rules.md`):

1. **Self-contained context** — the note explains itself; it may be retrieved in isolation.
2. **Frontmatter** — `type`, `date`, `tags` (type-specific fields per `ai-first-rules.md`).
3. **`next_action` on active project notes** — mandatory; the structural core of the whole system.
4. **Recency markers + verbatim source URLs** on external claims.
5. **Cross-links mandatory** — every person/project/place/concept uses `[[wikilinks]]` (basename resolution).

**Not required:** the `## For future Claude` preamble, the `ai-first:` flag, mandatory confidence levels, bi-temporal timelines. And **never bulk-rewrite existing human notes** — upgrade only when P asks or when actively editing.

### Never create in isolation
Every write operation must ask: *where else does this belong?*

| You create/update... | Also update... |
|---|---|
| A new project note | today's daily note (link it); if it has a next action, a Tasks-plugin line in the pillar's todo |
| A task completed | mark the Tasks-plugin line done (`task-archiver` handles archiving); the project note; daily note |
| A person note | daily note (interaction); the `social/` pillar |
| A work/dev session | the relevant pillar/project folder; daily note |
| A decision made | the project note's Key Decisions section; daily note |
| Any vault write | the operation log (timestamped entry); `index.md` (if a note was created/deleted) |

Always propagate. Never create a single orphaned note. (No kanban — P uses the Tasks plugin. No `Mentions`/`Side Biz`/`social-media` folders unless they actually exist.)

### CRITICAL_FACTS.md — always loaded
A tiny file (~120 tokens) loaded alongside `SOUL.md` at L0 in every session. Contains facts needed in every conversation:
- Timezone
- Current manager
- Current location
- Current company and role
- Any other fact that's true RIGHT NOW and relevant to every interaction

Update this file whenever a critical fact changes. Keep it under 150 tokens.

### Archives and trash
This vault has no `raw/` folder. Original sources and clippings live in the relevant pillar (or `captured/` as inbox). History is preserved via each folder's `_archive/` subfolder. **`_archive/` is suggest-only — the agent never moves anything there autonomously; P decides when something is complete.** `trash/` is fully opaque — never read, search, or modify it.

### Maintain `index.md` and `log.md`
Two structural files that keep the vault navigable and auditable:

- **`index.md`** — A catalog of all vault pages organized by category. Claude reads this FIRST when navigating the vault instead of searching — faster and cheaper on tokens. Update it whenever a new note is created or deleted. Format: `- [[Note Name]] — brief description` grouped under folder headings.

- **`log.md`** — An append-only chronological log of every vault operation. Every save, ingest, health check, and structural change gets a timestamped entry. Never delete or rewrite entries — only append. Format: `## [YYYY-MM-DD] action | Description`

### Per-day operation logs (modernized vaults)
Vaults initialized with `/obsidian-init` (v0.9+) use a split log structure instead of a monolithic `log.md`:

- **`Logs/YYYY-MM-DD.md`** — one file per day, append-only. Format: `**HH:MM** — action | description`
- **`log.md` at vault root** — pointer file only. Never write entries here; it explains the per-day structure and ships the entry template.

To migrate an existing monolithic `log.md`: run `python3 scripts/migrate_log.py --vault <path>`.
To refresh the stats block in `index.md` after bulk writes: run `python3 scripts/vault_stats.py --vault <path>`.

When writing operation log entries, check whether the vault uses the old (`log.md`) or new (`Logs/YYYY-MM-DD.md`) structure and write to the correct location.

### The vault is a living system
The vault is not a filing cabinet. It is a living knowledge base that rewrites itself with every input. When new information enters:
- Existing pages get REWRITTEN with new context, not just appended to
- Contradictions between old and new claims get resolved or explicitly documented
- New patterns across multiple sources trigger automatic synthesis pages
- Stale claims get replaced with current information, with history preserved

The vault after an ingest should be DIFFERENT — not just bigger. If pages that existed before aren't smarter, more connected, and more current, the ingest wasn't deep enough.

### Two-Output Rule
Every interaction that produces insight must generate two outputs:
1. **The answer** — what the user sees in the conversation
2. **A vault update** — the insight filed back into the relevant note(s)

This applies to all thinking tools and any query where Claude synthesizes information from the vault.

### Synthesis Hook
When Claude notices a pattern during any operation (ingest, query, challenge, emerge), it should automatically create a synthesis page in `wiki/concepts/`. Patterns include:
- The same concept appearing in 3+ unrelated sources
- A claim being reinforced by multiple independent sources
- A trend emerging across time-sequenced notes
- Two entities sharing unexpected connections

Synthesis pages are the vault thinking for itself — connecting dots the user hasn't connected yet.

### Reconciliation
The vault should never contain two pages that disagree without knowing they disagree. When contradictions are found (during ingest, health checks, or queries), either:
- Resolve them: rewrite the outdated page, preserve history
- Document them: create an explicit conflict page marked as an open question

Use `/obsidian-reconcile` for vault-wide truth maintenance.

### Proactive save reminders
Unsaved conversations are lost knowledge. Claude should proactively remind the user to save:
- After 10+ exchanges: suggest "Want me to run /obsidian-save before we continue?"
- When the user signals wrap-up (e.g., "ok", "thanks", "done", "bye", "that's it"): suggest "Before you go — want me to /obsidian-save this conversation?"
- When a logical work block completes (feature shipped, decision made, problem solved): suggest saving
- Never skip the reminder. This is especially critical on Claude Desktop where there's no background agent.

### Search before creating
Before creating any new note, search for an existing one:
```
search(query="keyword from title")
```
Duplicate notes are vault rot. Merge or update instead of creating new.

### Match the vault's voice
Read existing notes in the same folder before writing new ones.
Match: frontmatter schema, heading style, list formatting, tone, emoji usage (or lack of it).
Never introduce new conventions — extend what's already there.

### Frontmatter is mandatory
Every note gets frontmatter. At minimum:
```yaml
---
date: 2026-03-24
tags:
  - <note-type>
---
```
See `references/vault-schema.md` for full frontmatter specs by note type.

---

## Write Rules

See `references/write-rules.md` for the complete guide. Summary:

- **Links**: Use `[[Note Name]]` for internal links. Always link to people, projects, and jobs mentioned in a note.
- **Dates**: ISO format (`YYYY-MM-DD`) in frontmatter. Human format (`March 24`) in body text.
- **Naming**: `YYYY-MM-DD — Title.md` for dated notes. `Title.md` for evergreen notes. No special characters except `—` (em dash).
- **Status values**: `active` / `planning` / `completed` / `archived` / `on-hold` for projects. `in-progress` / `done` / `waiting` for tasks.
- **Kanban**: Items follow the format `- [ ] 🔴 **Title** · @{YYYY-MM-DD}\n\tDescription [[Link]]`

---

## The `_CLAUDE.md` File

This is the most important concept in this skill.

`_CLAUDE.md` lives at the vault root and persists Claude's operating rules across every session and every surface (Claude Desktop, Claude Code, VS Code, terminal). Without it, Claude has to re-learn your vault conventions every conversation.

**Precedence rule:** `_CLAUDE.md` wins on all vault-specific rules (folder names, naming conventions, frontmatter fields, auto-save behavior, private folders). The defaults in this skill file apply only where `_CLAUDE.md` is silent. Never let skill defaults override an explicit `_CLAUDE.md` rule.

**What it contains:**
- Your vault's folder map and what each folder is for
- Frontmatter schemas for your specific note types
- Naming conventions you use
- What to auto-save vs. what to ask first
- People and projects that need special handling
- Links to key files (boards, dashboard, templates)

To generate a `_CLAUDE.md` for an existing vault, run vault discovery then use the template in `references/claude-md-template.md`.

To install it: write the file to the vault root. Every Claude session that starts in that vault should read it first.

---

## Common Operations

### Save info from conversation
When a conversation produces something vault-worthy:
1. Identify the note type (decision → project note, person met → People/, task → board + Tasks/, etc.)
2. Check if a relevant note already exists
3. Write or update — always frontmatter-first
4. Propagate to boards, daily note, linked notes

### Create today's daily note
```
date = today in YYYY-MM-DD format
path = Daily/{date}.md
```
Read `Templates/Daily Note.md`, fill in the date fields, create the file.
Then scan recent conversation for anything worth logging in today's sections.

### Log a dev session
Read `Templates/Dev Log.md`. Fill: date, project name, what was worked on, problems solved, decisions made, next steps.
Save to `Dev Logs/YYYY-MM-DD — Project Name.md`.
Link from project note's Recent Activity section and today's daily note.

### Update a kanban board
Boards use the `kanban-plugin: board` frontmatter.
Columns are `## Column Name` headers.
Items are `- [ ] **Title** · @{due-date}\n\tDescription [[Links]]`
Completed items move to the `## ✅ Done` column with a strikethrough: `- [x] ~~**Title**~~ ✅ Date`

### Run vault health check
```bash
python3 scripts/vault_health.py --path ~/path/to/vault
```
Reports: duplicate notes, orphaned files (no incoming links), stale tasks (overdue), empty folders, broken links, notes missing frontmatter.

Proactively suggest running this when the user says the vault feels messy, notes are hard to find, they mention duplicates, or they haven't mentioned a health check in a long time. Offer: *"Want me to run a vault health check?"*

---

## Commands

These slash commands can be used in any Claude surface. Each one is smart — it reads context, searches before writing, and propagates everywhere changes belong.

**Name matching:** If a name argument has a typo or is approximate, search the vault for the closest match, show what was found, and confirm with the user before proceeding. Never silently create a note with a misspelled name.

---

### `/obsidian-save`

**The master save command.** Reads the entire conversation and extracts everything worth preserving.

Steps:
1. Scan the conversation and identify all vault-worthy items: decisions, tasks, people mentioned, projects started, ideas, learnings, deals, mentions/shoutouts
2. Group items by type: people, projects, tasks, decisions, ideas, deals
3. Spawn parallel subagents — one per group — so all note types are handled simultaneously:
   - **People agent**: search for each person, create or update notes, log interactions
   - **Projects agent**: search for each project, create or update notes
   - **Tasks agent**: parse tasks, add to the right kanban columns
   - **Decisions agent**: find relevant project notes, append to Key Decisions sections
   - **Ideas agent**: search Ideas/ for related notes, create or append
4. After all agents complete: update today's daily note with links to everything saved
5. Report back: a clean list of what was saved and where

Do not ask for guidance on where to save things — infer it. Only ask if something is genuinely ambiguous (e.g. a person mentioned with no context on who they are).

---

### `/obsidian-daily`

**Creates or updates today's daily note.**

Steps:
1. Check if `Daily/YYYY-MM-DD.md` exists for today
2. If not: read `Templates/Daily Note.md`, fill in date fields, create the file
3. Scan the current conversation for anything relevant to today: tasks in progress, people mentioned, decisions made, what's being worked on
4. Pre-fill or update the note's sections with that context
5. If the note already exists, inject new content into the right sections rather than overwriting

Return the path of the daily note when done.

---

### `/obsidian-log`

**Logs a work or dev session to the vault.**

Steps:
1. Infer the project from conversation context — search the vault if needed to find the right project note
2. Read `Templates/Dev Log.md` (or `Templates/Work Log.md` if it exists)
3. Fill in: date, project, what was worked on, problems encountered, decisions made, next steps — all inferred from the conversation
4. Save to `Dev Logs/YYYY-MM-DD — Project Name.md`
5. Inject a link into the project note's Recent Activity section
6. Inject a link into today's daily note Work section

---

### `/obsidian-task [description]`

**Adds a task to the vault and the right kanban board.**

Steps:
1. Parse the task from the argument or from recent conversation context if no argument given
2. Infer: priority (🔴/🟡/🟢), due date, linked project, linked person
3. Search for the right kanban board — use `_CLAUDE.md` board list or search `Boards/`
4. Add the task card to the correct column (`📋 This Week` or `📥 Backlog` depending on due date)
5. Create a task note in `Tasks/` if the task is substantial (more than a one-liner)
6. Link the task from the relevant project note and today's daily note

---

### `/obsidian-person [name]`

**Creates or updates a person note.**

Steps:
1. Search the vault for an existing note matching the name (fuzzy — handle typos and partial names)
2. If found: confirm with user, then update with new info from conversation
3. If not found: create `People/Full Name.md` with full frontmatter schema
4. Fill in everything inferable from the conversation: role, company, context, relationship strength, last interaction date
5. Log the interaction in today's daily note
6. If a People index file exists, add or update the entry there

---

### `/obsidian-decide [optional: topic]`

**Extracts and logs decisions from the conversation.**

Steps:
1. Scan the conversation for decisions made — look for conclusions, choices, commitments, direction changes
2. If a topic argument is given, focus on decisions related to that topic
3. Find the relevant project note(s) — search if needed
4. Append each decision to the project note's `## Key Decisions` section with date
5. Log a summary in today's daily note
6. If a decision affects multiple projects, log it in all of them

---

### `/obsidian-capture [optional: idea text]`

**Quick idea capture with zero friction.**

Steps:
1. Take the argument as the idea, or pull the most recent idea/thought from the conversation
2. Search `Ideas/` for a related existing note — if found, append to it
3. If new: create `Ideas/Title.md` with minimal frontmatter (`date`, `tags: [idea]`)
4. Write the idea with any supporting context from the conversation
5. Add a brief mention in today's daily note under an Ideas or Captures section

---

### `/obsidian-find [query]`

**Smart vault search.**

Steps:
1. Run `search(query="...")` with the provided query
2. Also try variations if results are sparse (synonyms, related terms)
3. Return results with context: note title, folder, a relevant excerpt, and what type of note it is
4. If results are ambiguous, group them by type (people, projects, tasks, etc.)
5. Offer to open, update, or link any of the found notes

Do not just return filenames — return enough context for the user to act.

---

### `/obsidian-recap [today|week|month]`

**Summarizes a time period from the vault.**

Steps:
1. Determine the date range from the argument (default: `week` if not specified)
2. List all daily notes in the range with `list_files_in_dir("Daily/")`
3. Spawn parallel subagents — one per daily note — to read and extract key points from each simultaneously
4. Also spawn parallel agents to read dev logs and completed kanban tasks from the same period
5. Synthesize all agent results: what was worked on, decisions made, people interacted with, tasks completed, ideas captured
6. Present as a clean narrative summary — not a raw dump of note content

---

### `/obsidian-review`

**Generates a structured weekly or monthly review note.**

Steps:
1. Ask: weekly or monthly? (or infer from context)
2. Read daily notes and dev logs for the period
3. Read active projects and check for status changes
4. Read completed tasks from kanban boards
5. Draft a review note using `Templates/Review.md` if it exists, otherwise use a standard structure:
   - What I accomplished
   - Key decisions made
   - People I worked with
   - What I learned
   - What to carry forward
6. Save to `Reviews/YYYY-MM-DD — Weekly Review.md` (or Monthly)
7. Link from the last daily note of the period

---

### `/obsidian-board [optional: board name]`

**Shows or updates a kanban board.**

Steps:
1. If a board name is given, search `Boards/` for it (fuzzy match)
2. If no name given, list available boards and ask which one
3. Read and display the current board state: columns, item counts, overdue items (past `@{date}`)
4. Ask if the user wants to make updates — if yes, infer changes from conversation context
5. Move completed items to ✅ Done with strikethrough, add new items in the right column
6. Flag any items that are overdue or have been in the same column for more than a week

---

### `/obsidian-project [name]`

**Creates or updates a project note.**

Steps:
1. Search the vault for an existing project matching the name (fuzzy — handle typos)
2. If found: show what was found, confirm, then update with new info from conversation
3. If not found: create `Projects/Project Name.md` with full frontmatter schema (`date`, `tags: [project]`, `status: active`, `job`)
4. Fill in everything inferable from the conversation: description, goals, key people, current status
5. Add a card to the relevant kanban board in the `📥 Backlog` or `🔨 In Progress` column
6. Link from today's daily note

---

### `/obsidian-health`

**Runs a vault health check and summarizes findings.**

Steps:
1. Run: `python3 scripts/vault_health.py --path ~/path/to/vault --json`
2. Parse the JSON output and split findings into categories
3. Spawn parallel subagents to handle each category simultaneously:
   - **Links agent**: verify broken links, attempt to resolve them
   - **Duplicates agent**: confirm duplicates are truly the same concept, not just similar names
   - **Frontmatter agent**: identify notes missing required fields by type
   - **Staleness agent**: check overdue tasks and unfilled template syntax
   - **Orphans agent**: check orphaned notes and empty folders
   - **Contradictions agent**: scan Key Decisions and Knowledge/ for claims that conflict or are superseded
   - **Concept gaps agent**: find terms mentioned 3+ times without a dedicated page
   - **Stale claims agent**: flag Knowledge/ notes older than 6 months on fast-moving topics
4. Merge agent results and group by severity:
   - 🔴 Critical: broken links, unfilled template syntax, contradictions
   - 🟡 Warning: duplicates, stale tasks, missing frontmatter, stale claims, concept gaps
   - ⚪ Info: orphaned notes, empty folders
5. Present a clean summary with counts per category
6. For safe fixes (missing frontmatter, obvious duplicates, creating pages for concept gaps), offer to fix them automatically
7. For destructive fixes (archiving, merging, resolving contradictions), list them and ask for explicit confirmation before touching anything
8. Append to `log.md` with severity counts

---

### `/obsidian-reconcile`

**Finds and resolves contradictions across the vault.**

Steps:
1. Read `index.md` to understand the full vault landscape
2. Spawn parallel subagents to find contradictions:
   - **Claims agent**: scan `wiki/concepts/` and `wiki/projects/` for conflicting factual claims
   - **Entity agent**: scan `wiki/entities/` for outdated roles, companies, or descriptions
   - **Decisions agent**: scan `wiki/decisions/` for reversed or superseded decisions never updated
   - **Source freshness agent**: compare `raw/` dates against `wiki/` pages for stale references
3. For each contradiction, evaluate: which is newer, which is more authoritative, is it a genuine conflict or an evolution
4. Resolve:
   - **Clear winner**: rewrite the outdated page, add a History section noting what changed
   - **Ambiguous**: create `wiki/decisions/Conflict — Topic.md` with both sides, mark `status: open`
   - **Evolution**: update the page to current state with historical context
5. Rebuild affected `index.md` sections, append to `log.md`, update daily note

---

### `/obsidian-synthesize`

**Automatic synthesis — the vault thinks for itself.**

Can run manually or as a scheduled agent. Scans the vault for patterns nobody asked about.

Steps:
1. Read `index.md` and `log.md` (last 20 entries) for recent activity
2. Spawn parallel subagents:
   - **Cross-source agent**: find concepts appearing in 2+ unrelated sources from the last 7 days
   - **Entity convergence agent**: find people who appear together in multiple contexts but have no connection page
   - **Concept evolution agent**: find concepts updated 3+ times and document how thinking changed
   - **Orphan rescue agent**: find unlinked notes that should be connected to existing pages
3. For each pattern: create `wiki/concepts/Synthesis — Title.md` with evidence, interpretation, and suggested action
4. Link synthesis pages FROM all source notes they reference
5. Update `index.md`, `log.md`, and today's daily note

---

### `/obsidian-export`

**Export a clean snapshot any agent or tool can consume.**

Steps:
1. Scan all notes in `wiki/` and extract: path, title, type, date, status, summary, links, tags, frontmatter
2. Output as JSON (default) to `_export/vault-snapshot.json` or markdown to `_export/vault-snapshot.md`
3. The snapshot is a flat, structured representation of the vault — no folder structure knowledge needed
4. Any AI tool, automation, or agent can read this file and understand the vault
5. Append to `log.md`

---

### `/obsidian-init`

**Bootstraps `_CLAUDE.md` for the vault — the operating manual.**

Steps:
1. Call `list_files_in_vault()` to map the full structure
2. Spawn parallel subagents to discover vault context simultaneously:
   - **Dashboard agent**: read `Home.md` or equivalent dashboard
   - **Templates agent**: read all files in `Templates/`
   - **Boards agent**: read all files in `Boards/`
   - **Samples agent**: read one existing note per major folder to capture naming conventions and frontmatter patterns
3. Merge all agent results into a complete picture of the vault
4. Generate a complete `_CLAUDE.md` using the template in `references/claude-md-template.md`, filled with real values from the vault
5. Write it to `_CLAUDE.md` at the vault root via `append_content("_CLAUDE.md", content)`
6. Confirm what was written and tell the user to restart their Claude session so the new file takes effect

If `_CLAUDE.md` already exists: show a diff of what would change and ask before overwriting.

---

### `/obsidian-ingest`

**Ingests a source into the vault — one source touches many pages.**

Steps:
1. Accept a URL, file path, or pasted text as the source
2. Classify the source type before full read: article, PDF, transcript, video, or raw text
3. Read or fetch the full source content
4. Extract: entities (people, companies, tools), concepts, claims, action items, notable quotes
5. Save the raw source to `Knowledge/YYYY-MM-DD — Source Title.md` with full summary and source link
6. Spawn parallel subagents to distribute knowledge across the vault:
   - **People agent**: create or update People/ notes for each person mentioned
   - **Projects agent**: update existing project notes with new findings
   - **Ideas agent**: create or append to Ideas/ for new concepts
   - **Knowledge agent**: create or update Knowledge/ notes for factual claims and frameworks
7. Update `index.md` with all newly created notes
8. Append to `log.md`: `## [YYYY-MM-DD] ingest | Source Title (type) — X created, Y updated`
9. Update today's daily note with an ingest summary

A single ingest should touch 5-15 files. Compile knowledge once, distribute everywhere.

---

## Thinking Tools

These commands use the vault as a thinking partner — not just storage. They surface insights, challenge assumptions, and generate connections that the user cannot see on their own.

---

### `/obsidian-challenge`

**Red-teams your current idea against your own vault history.**

Steps:
1. Identify the user's current claim, plan, or assumption — from the argument or conversation context
2. Extract the key premises behind that position
3. Spawn parallel subagents to search for counter-evidence:
   - **Decisions agent**: search Key Decisions sections for past decisions that contradicted similar thinking
   - **Failures agent**: search dev logs, daily notes, and archives for past failures or lessons related to this topic
   - **Contradictions agent**: search for notes where the user held the opposite position or flagged risks
4. Synthesize a structured "Red Team" analysis:
   - **Your position**: restate the claim
   - **Counter-evidence from your vault**: cite specific notes, dates, and quotes
   - **Blind spots**: what the user might be ignoring based on their own history
   - **Verdict**: consistent with past experience, or does the vault suggest caution?
5. Log the challenge in today's daily note under a Thinking section

Do not be agreeable. The entire point is to pressure-test. Cite specific vault files.

---

### `/obsidian-emerge`

**Surfaces unnamed patterns from recent notes — recurring themes and conclusions you haven't explicitly stated.**

Steps:
1. Determine the date range from the argument (default: last 30 days)
2. Spawn parallel subagents to scan vault content:
   - **Daily notes agent**: extract recurring topics, complaints, observations, energy patterns
   - **Dev logs agent**: extract repeated blockers, tools, architectural patterns
   - **Decisions agent**: look for directional trends across project notes
   - **Ideas agent**: look for thematic clusters in Ideas/ notes
3. Identify:
   - **Recurring themes**: topics that appeared 3+ times without being named as a priority
   - **Emotional patterns**: what energizes vs. drains (based on language)
   - **Unnamed conclusions**: things the notes imply but never state outright
   - **Emerging directions**: where the vault suggests the user is heading
4. Present a "Pattern Report" — each pattern with evidence (cited notes), interpretation, and suggested action
5. Offer to save the report to `Ideas/` or a relevant project note
6. Log a summary in today's daily note

The goal is insight the user cannot see themselves. Surface what they haven't named yet.

---

### `/obsidian-connect [topic A] [topic B]`

**Bridges two unrelated domains using the vault's link graph to spark new ideas.**

Steps:
1. Parse two domains from arguments (e.g., `/obsidian-connect "distributed systems" "cooking"`)
2. For each domain, search the vault: find all related notes, map backlinks and outgoing links to build a local cluster
3. Find the bridge:
   - Shared links, tags, or people between the two clusters
   - If a direct path exists in the link graph, trace it and explain each hop
   - If no direct path, find the closest semantic overlap
4. Generate creative connections:
   - **Structural analogy**: how a pattern in A maps to B
   - **Transfer opportunities**: what works in A that could apply to B
   - **Collision ideas**: new concepts that only exist at the intersection
5. Present 3-5 specific, actionable connections — not vague analogies but concrete ideas
6. Offer to save the best connections to `Ideas/` with links to both source domains
7. Log the connection exercise in today's daily note

The value is in unexpected links. If the connection is obvious, dig deeper.

---

### `/obsidian-graduate`

**Promotes an idea fragment into a full project spec with tasks, board entries, and structure.**

Steps:
1. If argument given: search `Ideas/`, daily notes, and captures for a matching idea (fuzzy)
2. If no argument: list recent ideas (last 14 days) and ask the user to pick one
3. Read the full idea note and any linked notes for context
4. Research the vault for related content: overlapping projects, related people, past decisions, similar ideas explored before
5. Generate a full project spec:
   - **Project note** in `Projects/` with complete frontmatter (status: planning, linked idea)
   - **Goals**: 3-5 concrete outcomes
   - **Key tasks**: broken into phases with priorities
   - **Open questions**: what still needs answering
   - **Related notes**: links to everything relevant
6. Add cards to the relevant kanban board
7. Update the original idea note: add `status: graduated` and link to the new project
8. Link the new project from today's daily note

The idea doesn't die — it evolves. The original note stays as the origin story.

---

## Context Engine

### `/obsidian-world`

**Loads your identity, values, priorities, and current state in one shot — with progressive context levels.**

Uses token budgets to avoid loading the entire vault. Start light, go deeper only as needed.

Steps:
1. **L0 — Identity (~200 tokens)**: read `SOUL.md`/`About Me.md` and `CORE_VALUES.md`/`Values.md`
2. **L1 — Navigation (~1-2K tokens)**: read `index.md` (vault catalog) and `log.md` (last 10 entries)
3. **L2 — Current State (~2-5K tokens)**: read `Home.md`/`Dashboard.md`, today's daily note, last 3 daily notes, active kanban boards, previous session digests
4. **L3 — Deep Context (on demand, ~5-20K tokens)**: only load if needed — active project notes, full Knowledge/ articles, recently mentioned people

Present a brief status after L0-L2 (do NOT load L3 unless needed):
- **Who I am to you**: persona and communication style
- **Your current priorities**: top 3-5 active threads (from index.md + boards)
- **Open threads from last session**: anything unfinished (from log.md + daily notes)
- **Overdue / needs attention**: stale tasks or projects
- **Today so far**: what's already logged

Keep output concise — this is a boot-up sequence, not a report.

If identity files don't exist, offer to create them by asking 5-7 quick questions about the user's role, values, and preferences.
If `index.md` doesn't exist, offer to run `/obsidian-init` to generate it.

---

### `/obsidian-adr`

**Generates a decision record when the vault structure changes.**

Steps:
1. Identify the structural decision from the argument or conversation context
2. Create `Knowledge/ADR-YYYY-MM-DD — Title.md` with:
   - **Decision**: one-line summary
   - **Context**: what prompted this
   - **Options Considered**: 2-3 alternatives evaluated
   - **Rationale**: why this option won
   - **Consequences**: what changed — notes created, moved, or restructured
   - **Related**: links to affected notes
3. Update the relevant project note's Key Decisions section with a link to the ADR
4. Update `index.md` and append to `log.md`
5. Link from today's daily note

The vault knows why it's structured the way it is. When a future session asks "why?" — the ADR has the answer.

Can also be triggered automatically by `/obsidian-graduate`, `/obsidian-health` structural fixes, or folder reorganizations. In those cases, offer to create an ADR — don't force it.

---

## Scheduled Agents

Two autonomous agents run on a schedule, no user intervention. Conservative by default: they never delete, never auto-archive, never move files without approval, never ask questions mid-run (they propose; P decides). Set up via the `/schedule` skill in Claude Code.

---

### `mbs-daily` — every morning (e.g. 6:00 AM)

**The daily safety net — P's #1 need: stress/distraction make him lose the next step.**

Prompt to schedule:
```
Read _CLAUDE.md, SOUL.md, CRITICAL_FACTS.md.
Append a `## Vault Agent` section to today's tasks daily note (daily_notes/tasks/tasks_YYYY-MM-DD.md):
- Overdue + due-today tasks (Tasks plugin) across pillars.
- Active projects with NO next_action — flag each and propose a next step.
- Calendar reconciliation: things implied by the vault that are not on the calendar (google-calendar / Morgen) — flag them, do NOT add.
- Note normalization: up to ~5 convention violations to fix (naming, missing frontmatter, non-_archive archive folders).
- New captured/ items to triage, each with a proposed destination.
Keep it a short, checkable list with inline skip/defer reply fields. Do not auto-archive. Do not move files without approval. Append a log entry. Save and stop.
```
Setup: `/schedule mbs-daily — daily 6:00 AM`

---

### `mbs-weekly` — Friday evening (e.g. 6:00 PM)

**Weekly review + full vault health audit.**

Prompt to schedule:
```
Read _CLAUDE.md.
1. Weekly review note (Get Clear / Get Current / Get Creative): what got done, decisions made, people interacted with, what's still open, what to carry forward. Save as a review note (type: review) dated this week; link from the last daily note.
2. Run: python3 scripts/vault_health.py --path /Users/cpreston/Vaults/storage_mbs --json
   Summarize by severity (critical / warning / info): duplicates, orphans, broken links, missing frontmatter, stale active projects, naming/_archive drift. Report only — fix nothing autonomously.
Do not ask questions. Save and stop.
```
Setup: `/schedule mbs-weekly — every Friday 6:00 PM`

---

### Setting up scheduled agents

```
/schedule
```
Then name the agents and times. To list or remove: `/schedule list` · `/schedule remove mbs-daily`.


## Background Agent (PostCompact Hook)

> **DEFERRED — not enabled in v1.** This hook spawns a headless `claude --dangerously-skip-permissions -p` subprocess that writes to the vault unattended after every context compaction. Given the vault holds taxes, legal, and health data, this is trust-gated: revisit once the foundation is proven. `install.sh` does NOT wire it. Mechanics kept below for when we choose to enable it — and even then it must respect the suggest-never-auto-archive boundary and never bulk-write.

A background agent that fires automatically whenever Claude compacts the conversation context. It reads the session summary and propagates everything worth preserving to the vault — no user action required.

**What it does:** After each compaction, a headless `claude -p` subprocess wakes up, reads `_CLAUDE.md`, scans the summary for vault-worthy items (people, projects, decisions, tasks, dev work, ideas), and writes updates everywhere they belong — people notes, project notes, dev logs, kanban boards, and today's daily note.

**How it works:**
1. `PostCompact` hook fires in Claude Code after context compaction
2. Hook script reads the JSON summary from stdin
3. Spawns a headless `claude --dangerously-skip-permissions -p` subprocess in the vault directory
4. Agent runs silently, propagates updates, and exits — user sees nothing

**Setup:**

1. Make the hook script executable (one-time):
   ```bash
   chmod +x ~/.claude/skills/mbs_automation/hooks/obsidian-bg-agent.sh
   ```

2. Set `OBSIDIAN_VAULT_PATH` in `~/.claude/settings.json`:
   ```json
   {
     "env": {
       "OBSIDIAN_VAULT_PATH": "/path/to/your/vault"
     }
   }
   ```

3. Add the `PostCompact` hook to `~/.claude/settings.json`:
   ```json
   {
     "hooks": {
       "PostCompact": [
         {
           "matcher": "",
           "hooks": [
             {
               "type": "command",
               "command": "/Users/you/.claude/skills/mbs_automation/hooks/obsidian-bg-agent.sh",
               "timeout": 10,
               "async": true
             }
           ]
         }
       ]
     }
   }
   ```

**Debugging:** The agent logs to `/tmp/obsidian-bg-agent.log`. Check there if updates aren't appearing.

**Safety:** The agent never deletes, archives, or merges anything. It only adds or updates. If the summary has nothing vault-worthy, it exits without touching the vault.

---

## Write-Time Validator (PostToolUse Hook)

> **REFRAMED + dormant in v1.** Original behavior validated every write against the strict AI-first rule (mandatory `## For future Claude` preamble, `ai-first: true`). That's wrong for this hybrid vault — P writes notes too, and it would fire on every human edit. `install.sh` does NOT wire it. If enabled later, it should validate only against the **amnesia test** (frontmatter present, `next_action` on active project notes) and only on agent-written notes, never on P's own edits. No preamble/flag checks.

A non-blocking validator that fires after a `Write` or `Edit` on a markdown file inside the vault. If enabled, it warns when an agent-written note misses the amnesia-test essentials (frontmatter, `next_action` on active projects, broken YAML) and surfaces the warning on stderr so the agent can repair in the same turn.

**What it checks:**
1. The file has frontmatter delimiters (`--- ... ---`)
2. No tabs in frontmatter (YAML requires spaces)
3. Required AI-first fields present: `date:`, `type:`, `tags:`, `ai-first: true`
4. The body contains a `## For future Claude` preamble (rule #2 of [`references/ai-first-rules.md`](references/ai-first-rules.md))

**What it skips:**
- Files outside `OBSIDIAN_VAULT_PATH`
- Files under `raw/`, `templates/`, `_export/`, `.obsidian/`, `.git/`, `.trash/`

**Setup:**

1. Make the script executable (one-time):
   ```bash
   chmod +x ~/.claude/skills/mbs_automation/hooks/validate-ai-first.sh
   ```

2. `OBSIDIAN_VAULT_PATH` must already be set in `~/.claude/settings.json` (the background agent setup above covers this).

3. Add the `PostToolUse` hook to `~/.claude/settings.json`:
   ```json
   {
     "hooks": {
       "PostToolUse": [
         {
           "matcher": "Write|Edit",
           "hooks": [
             {
               "type": "command",
               "command": "bash ~/.claude/skills/mbs_automation/hooks/validate-ai-first.sh"
             }
           ]
         }
       ]
     }
   }
   ```

**Behavior:** Non-blocking. If a write fails the AI-first rule, Claude sees the warning text on stderr (with one line per missing requirement) and can re-write the file in the same conversation turn to fix it. The original write is NOT reverted.

**Other platforms (Codex CLI / Gemini CLI / OpenCode):** The hook script ships in `dist/<platform>/hooks/` for all four platform builds, but each platform's hook system differs. Wiring it up beyond Claude Code is left to the platform's own configuration. See [`hooks/validate-ai-first.hook.yaml`](hooks/validate-ai-first.hook.yaml) for the platform-neutral spec.

---

## Reference Files

- `references/vault-schema.md` — Complete folder structure + frontmatter specs for all note types
- `references/write-rules.md` — Detailed writing, linking, and formatting rules
- `references/claude-md-template.md` — Template for generating a vault's `_CLAUDE.md`

## Scripts

- `scripts/setup.sh` — One-command installer (wires hook + env var + MCP)
- `scripts/bootstrap_vault.py` — Bootstrap a complete vault from scratch
- `scripts/vault_health.py` — Audit a vault for structural issues
