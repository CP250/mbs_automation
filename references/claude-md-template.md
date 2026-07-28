# `_CLAUDE.md` Template

`_CLAUDE.md` lives at `admin/mbs_system/brain/` and is the first thing every Claude surface reads. **P's vault already has a hand-authored `_CLAUDE.md`** (written with full project context). So `/obsidian-init`'s job here is to **refine, not regenerate**.

## How `/obsidian-init` should behave

1. Check for an existing `admin/mbs_system/brain/_CLAUDE.md`. **It exists.** Read it.
2. Map the live vault (`list_files_in_vault` or filesystem) and compare against what `_CLAUDE.md` describes.
3. Propose a **diff** — folders/conventions that drifted, new pillars/subfolders, stale facts — and **ask before overwriting.** Never clobber the hand-authored file.
4. Only fill gaps and correct drift. Preserve P's wording, the amnesia-test framing, and the rules below.

If you ever did need to regenerate from scratch, match this shape (it mirrors the existing file):

## The shape (reference)

```markdown
# _CLAUDE.md
Operating manual for any Claude session in this vault. Read first, every session. Overrides default skill behavior.

## What this vault is
The amnesia-test framing: hold P's life, recall it on demand, defend against stress/distraction losing the next step. Vault at /Users/cpreston/Vaults/storage_mbs/.

## Structure — life pillars
[8-pillar table: admin, create, culture, daily_notes, health, money, skills, social, sports]
[Pillar boundary rules: sports=play, culture=arts, social=watching-with-people]
[Top-level: captured/ (inbox), _archive/ (per folder), trash/ (opaque), _to_clean/ (P's manual backlog), attachments/]

## Folder & file conventions
[lowercase snake_case, no redundant pillar prefix, type prefixes project_/ref_/todo_list_/log_, dates YYYY-MM-DD, writing_scraps exception]

## The _archive convention
[standard name everywhere; on-demand; agent SUGGESTS, never auto-archives — P decides completion]

## Search tiers
[trash never searched; _archive historical/low-priority; everything else active]

## Note style — hybrid
[new agent notes = amnesia-test compliant; existing ~4,500 notes left as-is]

## Tasks & daily notes
[Tasks plugin not Kanban; Journals plugin two journals: health + tasks; morning report appends to daily_notes/tasks/ in a ## Vault Agent section]

## The agent's job (the four duties)
[1 missing-next-step, 2 calendar reconciliation, 3 note normalization, 4 project-decomposition partnership; plus recall, decisions, people, creative, weekly reflection, cross-domain, pattern surfacing]
[Out of scope: research toolkit, bi-temporal facts]

## Cowork integration
[name=folder convention; agent is librarian/dispatcher not domain expert; reads other sessions' transcripts; suggests renames, can't rename sessions]

## Key files (read order)
[admin/mbs_system/brain/_CLAUDE.md, SOUL.md, CRITICAL_FACTS.md, LEARNINGS_DIGEST.md, vault_file_tree.md; LEARNINGS.md and design/log.md on demand]

## Installed plugins worth knowing
[Tasks+archiver, Journals, Templater, Dataview, Git, Terminal, google-calendar+Morgen, Glasp+Read It Later, custom obsidian-ch8-tab, BRAT; basename link resolution]
```

## Keeping it fresh
Update `_CLAUDE.md` when a convention changes, a pillar is added, or a structural fact drifts. Trigger: "update my _CLAUDE.md." Always diff-and-ask; never silently overwrite the hand-authored file.

## Assistant-mode template
For operating a vault on behalf of someone else, see `references/claude-md-assistant-template.md`. Not applicable to P's own vault.
