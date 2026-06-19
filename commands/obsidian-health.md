---
description: Run a vault health audit — duplicates, orphans, broken links, missing next-steps, naming/_archive drift. Report-only.
category: meta
triggers_en: ["vault health", "check vault", "audit vault", "vault diagnostics"]
---

Use the mbs_automation skill. Execute `/obsidian-health`:

1. Read `_CLAUDE.md`, `SOUL.md`, `CRITICAL_FACTS.md` at the vault root.
2. Run: `python3 ~/.claude/skills/mbs_automation/scripts/vault_health.py --path /Users/cpreston/Vaults/storage_mbs --json` (use `python3`, not `python`)
3. Parse the JSON and split into categories. Spawn parallel subagents to verify each:
   - **Links agent**: confirm broken `[[wikilinks]]`; since links resolve by basename, a "broken" link usually means a renamed/missing target. Propose the fix (re-point or create stub).
   - **Duplicates agent**: confirm near-duplicate notes are truly the same thing (name variants for people/projects are the common case), not just similar titles.
   - **Missing-next-step agent** (the headline duty): find active project notes (`status: active`) with no `next_action` (or an empty one). This is the failure state the whole system exists to catch.
   - **Stale-project agent**: active projects with no edit in 14+ days — flag as possibly stalled.
   - **Frontmatter agent**: notes **the agent wrote** (amnesia-test notes) missing required fields. **Do NOT flag the ~4,500 existing human notes** for missing frontmatter — they're exempt by design (hybrid vault).
   - **Convention agent**: naming-convention violations and any non-`_archive` archive folders (stray `vaults_*`, `old/`, `archive/`); files stranded at the vault root.
   - **Orphans agent**: notes with no inbound links and not in `_archive/`. (Note: a note linked only from a daily note is functionally orphaned.)
4. **Exclusions:** never scan `trash/` (opaque). Treat `_archive/` hits as historical/low-priority. `_to_clean/` is P's manual backlog — report its size but don't propose work there unless asked.
5. Group by severity:
   - 🔴 Critical: broken links, active projects missing a next action.
   - 🟡 Warning: duplicates, stale active projects, naming/convention drift, agent-note frontmatter gaps.
   - ⚪ Info: orphans, empty folders, root strays, `_to_clean/` size.
6. **Fixes:** for safe ones (re-point a broken link, fix a naming violation, propose a `next_action`), offer to apply. For **archiving** to `_archive/` - list it and require explicit P approval (archiving signals "completed work P wants to keep"; that judgment is P's). For **disposal of junk / true duplicates / accidents** - move to `trash/` at the vault root, no permission needed (per `_CLAUDE.md` Disposal section, 2026-06-14). **Never permanently delete; never auto-archive.** If about to ask "can I delete this?", the answer is: move to `trash/` and continue. Trash is reversible; the move IS the disposal.
7. Append to the operation log: `**HH:MM** — health | X critical, Y warning, Z info`.

---

**Note rule:** Notes this command writes follow `references/ai-first-rules.md` (amnesia test): frontmatter, `next_action` on active projects, recency markers + verbatim sources, mandatory `[[wikilinks]]`. No `## For future Claude` preamble, no `ai-first:` flag. Existing human notes are left as-is.
