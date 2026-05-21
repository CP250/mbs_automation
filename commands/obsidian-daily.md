---
description: The morning report — append a bounded Vault Agent section to today's tasks note (next steps, overdue, calendar, triage)
category: vault
triggers_en: ["morning report", "daily report", "what's on today", "vault agent report"]
---

Use the mbs_automation skill. Execute `/obsidian-daily`:

This is P's daily safety net — the defense against stress/distraction making him lose the next step. The **Journals plugin already creates** today's daily note; this command **appends a bounded `## Vault Agent` section**, it does not create the note.

1. Read `_CLAUDE.md`, `SOUL.md`, `CRITICAL_FACTS.md`.
2. Target file: `daily_notes/tasks/tasks_YYYY-MM-DD.md` (today, US Eastern).
   - **Read the file first.** It already exists (the Journals plugin creates it on open, usually just frontmatter). Claude Code's Edit/Write refuse to modify an existing file that has not been read in this session — so always `Read` the note before appending, or the write fails with a generic error that looks like a permission block but is not.
   - If the Journals plugin genuinely has not created it yet (Read returns not-found), create it minimally with the `journal: tasks` / `journal-date:` frontmatter, then append.
   - Append the `## Vault Agent` section with an Edit that inserts after the frontmatter / existing content. Do not overwrite P's own content.
3. Build the report. Append (or refresh) a single `## Vault Agent` section containing, in order, kept to a short and checkable list:
   - **Overdue + due-today tasks** — a Tasks-plugin/Dataview query across pillars (`not done`, due ≤ today). Most urgent first.
   - **Projects missing a next step** — active project notes with no `next_action`. For each, propose one concrete next step. (The headline duty.)
   - **Calendar reconciliation** — pull today/this-week from Google Calendar / Morgen; flag anything implied by the vault that isn't on the calendar. **Flag only — never add calendar events.**
   - **Inbox triage** — new items in `captured/` since last run, each with a proposed destination pillar.
   - **Normalization** — up to ~5 convention/`_archive` violations worth fixing.
4. Each suggestion gets inline reply fields so P can respond in the note:
   ```
   - [ ] <suggestion> — proposed: <action>
       status:        (done | skip | defer)
       reply:
   ```
5. On the next run, read yesterday's `## Vault Agent` section: learn what P did / skipped / deferred, and don't re-suggest things marked `skip`. Persist recurring skips to `_CLAUDE.md`'s notes or a `vault_agent/decisions.md` if one exists.
6. **Hard boundaries:** never auto-archive, never move files without approval, never delete. Propose; P disposes.
7. Append to the operation log: `**HH:MM** — daily | report appended (N overdue, M missing-next-step)`.

This command IS the logic the scheduled `mbs-daily` agent runs each morning. Run it manually anytime to test or refresh.

---

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test). No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault. The `## Vault Agent` section is bounded and clearly the agent's; never touch P's own sections of the daily note.
