---
description: Refine the vault's CLAUDE.md against the live structure, and maintain the ops log
category: meta
triggers_en: ["init vault", "refresh vault manifest", "update claude md", "scan vault"]
---

Use the mbs_automation skill. Execute `/obsidian-init`:

P's vault already has a hand-authored files in `admin/mbs_system/brain/`. This command **refines, it does not regenerate from scratch.** Never clobber the hand-authored files.

1. Read `admin/mbs_system/brain/CLAUDE.md`, `SOUL.md`, `CRITICAL_FACTS.md`.
2. Map the live vault (`list_files_in_vault()` or filesystem). The structure is the 8 life pillars (admin, create, culture, daily_notes, health, money, skills, social, sports) plus `captured/`, `_archive/` (per folder), `trash/`, `_to_clean/`, `attachments/`. See `references/vault-schema.md`.
3. Spawn parallel subagents to sample for drift:
   - **Pillar-sample agent(s)**: read one or two notes per pillar to confirm naming/frontmatter conventions still match `CLAUDE.md`.
   - **Convention agent**: check for violations — non-`_archive` archive folders, `vaults_*` leftovers, files at root, redundant pillar prefixes.
4. Compare live structure against what `CLAUDE.md` describes. Produce a **diff**: new/renamed pillars or subfolders, stale facts, convention drift.
5. **Show the diff and ask before changing `CLAUDE.md`.** Apply only gap-fills and drift corrections; preserve P's wording and the amnesia-test framing. (Template/shape: `references/claude-md-template.md`.)
6. `index.md` was retired 2026-07-28 (redundant with the nightly `vault_file_tree.md` and per-folder `CLAUDE.md` files). Do not generate or recreate it.
7. Initialize/update the ops log: the `admin/mbs_system/design/log.md` file is a thin pointer; per-day entries go in `admin/mbs_system/design/log/YYYY-MM-DD.md` (frontmatter `type: log`, `date`; append-only `**HH:MM** — action | description`). Write today's init entry.
8. Confirm what changed and tell P to restart the Claude session so updates take effect.

If `CLAUDE.md` does NOT exist (shouldn't happen here): generate it from `references/claude-md-template.md` filled with real pillar values, then ask P to review.

---

**Note rule:** Notes this command writes follow `references/ai-first-rules.md` (the amnesia-test spec): self-contained context, frontmatter (`type`, `date`, `tags`), `next_action` on active projects, recency markers + verbatim sources on external claims, mandatory `[[wikilinks]]`. No `## For future Claude` preamble, no `ai-first:` flag — this vault is hybrid (P reads it; existing notes are left as-is).
