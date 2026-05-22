---
description: Zero-friction capture — drop a thought into captured/ so the daily triage can route it later
category: vault
triggers_en: ["capture this idea", "save this idea", "quick note", "drop a thought"]
---

Use the mbs_automation skill. Execute `/obsidian-capture $ARGUMENTS`:

The optional argument is the thought/idea text. If not provided, pull the most recent idea from the conversation. The whole point is **zero friction** — get it into `captured/` fast and move on. The morning report's inbox triage (`/obsidian-daily`) proposes a pillar destination later; this command does not need to file it correctly, just capture it without loss.

1. Read `_CLAUDE.md` at the vault root.
2. Take the argument as the thought, or pull it from recent conversation context.
3. Search `captured/` for a closely related existing capture — if there's a clear match, append to it rather than making a near-duplicate. (Don't over-search; this is meant to be fast.)
4. If new, create `captured/<snake_case_title>.md` with minimal frontmatter:
   ```yaml
   ---
   type: capture
   date: <YYYY-MM-DD>
   tags: [capture]
   ---
   ```
5. Write the thought plus any supporting context from the conversation, with verbatim source URLs if any. A capture can be rough. **Wikilink only targets that already exist as notes** (verify before linking) — do NOT link pillar-folder names like `[[sports]]`/`[[health]]` (folders aren't link targets) or invent `[[notes]]` that don't exist. A zero-friction capture must not seed broken links; for anything without a real note, use plain text. The daily triage will add proper links when it files the capture.
6. Add a one-line mention in today's tasks daily note (`daily_notes/tasks/tasks_YYYY-MM-DD.md`) inside the bounded `## Vault Agent` section, so it's visible and the next triage picks it up. Never touch P's own sections.

Do not route the capture into a pillar yourself unless P says where it goes — that's the triage step's job. Keep this command light.

---

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault. `captured/` is an inbox, not a filing destination; its contents are explicitly not treated as filed.
