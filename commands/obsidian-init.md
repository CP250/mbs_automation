---
description: Refine the vault's _CLAUDE.md against the live structure, and (re)generate index.md + log.md
category: meta
triggers_en: ["init vault", "refresh vault manifest", "update claude md", "scan vault"]
---

Use the mbs_automation skill. Execute `/obsidian-init`:

P's vault already has a hand-authored `_CLAUDE.md`, `SOUL.md`, and `CRITICAL_FACTS.md` at the root. This command **refines, it does not regenerate from scratch.** Never clobber the hand-authored files.

1. Read `_CLAUDE.md`, `SOUL.md`, `CRITICAL_FACTS.md` at the vault root.
2. Map the live vault (`list_files_in_vault()` or filesystem). The structure is the 8 life pillars (admin, create, culture, daily_notes, health, money, skills, social, sports) plus `captured/`, `_archive/` (per folder), `trash/`, `_to_clean/`, `attachments/`. See `references/vault-schema.md`.
3. Spawn parallel subagents to sample for drift:
   - **Pillar-sample agent(s)**: read one or two notes per pillar to confirm naming/frontmatter conventions still match `_CLAUDE.md`.
   - **Convention agent**: check for violations — non-`_archive` archive folders, `vaults_*` leftovers, files at root, redundant pillar prefixes.
4. Compare live structure against what `_CLAUDE.md` describes. Produce a **diff**: new/renamed pillars or subfolders, stale facts, convention drift.
5. **Show the diff and ask before changing `_CLAUDE.md`.** Apply only gap-fills and drift corrections; preserve P's wording and the amnesia-test framing. (Template/shape: `references/claude-md-template.md`.)
6. (Re)generate `index.md` at the vault root — a catalog grouped **by pillar**, one line per note: `- [[Note Name]] — brief description` (from frontmatter or first line). Exclude `trash/`; mark `_archive/` entries as historical. Claude reads this first to navigate.
7. Initialize/update the ops log: root `log.md` is a thin pointer; per-day entries go in `log/YYYY-MM-DD.md` (frontmatter `type: log`, `date`; append-only `**HH:MM** — action | description`). Write today's init entry.
8. Confirm what changed and tell P to restart the Claude session so updates take effect.

If `_CLAUDE.md` does NOT exist (shouldn't happen here): generate it from `references/claude-md-template.md` filled with real pillar values, then ask P to review.

---

**Note rule:** Notes this command writes follow `references/ai-first-rules.md` (the amnesia-test spec): self-contained context, frontmatter (`type`, `date`, `tags`), `next_action` on active projects, recency markers + verbatim sources on external claims, mandatory `[[wikilinks]]`. No `## For future Claude` preamble, no `ai-first:` flag — this vault is hybrid (P reads it; existing notes are left as-is).
