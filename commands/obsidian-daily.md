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
   - Append the `## Vault Agent` section with an Edit that inserts after the frontmatter / existing content. **Leave three blank lines above `## Vault Agent`** so P has space for his own content above the agent's section. Do not overwrite P's own content. If a `## Vault Agent` section already exists from an earlier run today, refresh it in place rather than adding a second one.
   - **Write via the filesystem Edit/Write tools, not the Obsidian MCP.** The scheduled `mbs-daily` agent may run when Obsidian (and therefore the MCP) is down, so the filesystem is the reliable path and the MCP is only a fallback. If an Edit/Write to the daily note fails, do NOT silently switch to the MCP and do NOT guess at the cause: surface the exact error text verbatim and stop, so the real cause (permission mode, sandbox write config, or read-first guard) can be diagnosed. The OS-level directory has been verified writable (`cpreston` owns it; shell append succeeds), so a Claude Code write failure is a Claude Code permission/sandbox-layer issue, not an OS one.
3. Build the report. Append (or refresh) a single `## Vault Agent` section containing, in order, kept to a short and checkable list:
   - **Overdue + due-today tasks** - find unticked `- [ ]` lines with `📅 <YYYY-MM-DD>` due dates at or before today, across all pillars except `trash/` and `_archive/`. **Use filesystem grep (Bash tool with ripgrep/grep), not the Obsidian MCP's `search_vault`.** Obsidian MCP tools are deferred-loaded in headless runs and require a ToolSearch step before invocation; filesystem grep is the reliable path for the unattended morning job. Most urgent first.
   - **Projects missing a next step** — active project notes with no `next_action`. For each, propose one concrete next step. (The headline duty.)
   - **Calendar reconciliation** - pull today's events and the next 6 days from Google Calendar by calling `mcp__google-calendar__list-events` **directly** with `calendarId='primary'`, `timeMin` set to today's start in ISO 8601 format, and `timeMax` set to 7 days out. **Do NOT call any loading / ToolSearch / schema-discovery step first.** In `claude -p` (the headless run this command lives in), MCP tools whose server is connected are directly callable by their full name; there is no separate deferred-loading dance. Verified 2026-06-15 against P's actual CLI run: direct invocation returned 24 events across the next 7 days without any preamble step. If `mcp__google-calendar__list-events` itself errors, fall through to `mcp__claude_ai_Google_Calendar__list_events` (same direct-invocation pattern, different MCP server). **If BOTH calendar MCPs error**, capture the verbatim error string from each in the report (which MCP, what error) and carry forward yesterday's calendar with an explicit "stale, MCP unreachable" flag - never silently degrade. Flag any vault-implied events that are not on the calendar. **Flag only - never create, modify, or respond to calendar events from this command.**
   - **Inbox triage** — new items in `captured/` since last run, each with a proposed destination pillar.
   - **Normalization** — up to ~5 convention/`_archive` violations worth fixing.
3b. **Wikilink every vault note mentioned, everywhere in the report.** Any note name that appears in any section (overdue table File column, projects-missing-next-step rows, calendar-vault-implied items, inbox triage, normalization items, the "yesterday's responses" recap) must be a `[[basename]]` wikilink, not a plain backtick-wrapped file path. The vault uses "shortest path" link resolution, so `[[tom_van_riper]]` resolves to `social/people/tom_van_riper.md` from anywhere - no need to spell the full path. Anti-pattern to avoid: `` `social/people/tom_van_riper.md` `` (plain backticks; not clickable in Obsidian). Correct pattern: `[[tom_van_riper]]` (renders as a clickable link in reading view and live preview). This applies even when the path appears as data inside a rename suggestion - prefer `[[old_basename]] → [[new_basename]]` over backticked paths whenever both files have clean snake_case names. For rename items where the source filename has spaces or special chars (broken basename), keep backticks for the source and wikilink the target.

4. Each suggestion gets inline reply fields so P can respond in the note:
   ```
   - [ ] <suggestion> - proposed: <action>
       status:        (done | skip | defer)
       reply:
   ```

   **CRITICAL: the checkbox MUST be at the START of the line.** Do NOT wrap suggestions in a numbered list. The bad pattern `1. - [ ] <suggestion>` is INVALID markdown for an Obsidian checkbox: CommonMark parses `1. - [ ]` as "numbered list item with inline content `- [ ]`", not as a clickable checkbox, so the result renders as literal `[ ]` brackets that P cannot click. This regression occurred from 2026-06-09 to 2026-06-12 in the Normalization section and broke the daily-tasks workflow. If the section needs ordering, use bare `- [ ]` bullets and let the natural list order speak; never combine `N. ` numbering with `- [ ]` on the same line. Sub-items belonging to a suggestion (the `status:` / `reply:` lines, or additional context) get indented under the bullet, no other change.
5. On the next run, read yesterday's `## Vault Agent` section: learn what P did / skipped / deferred, and don't re-suggest things marked `skip`. Persist recurring skips to `_CLAUDE.md`'s notes or a `vault_agent/decisions.md` if one exists.
6. **Hard boundaries:** never permanently delete anything; never auto-archive (archiving signals "completed work P wants to keep" and is P's call). Disposal of junk / true duplicates / accidents is via **move to `trash/` at the vault root, no permission needed** (recorded 2026-06-14 in vault `_CLAUDE.md` Disposal section). If about to ask "can I delete this?", the answer is: just move it to `trash/` and continue. Moves between active folders (re-organization, not disposal) still require P approval.
7. Append to the operation log: `**HH:MM** — daily | report appended (N overdue, M missing-next-step)`.

This command IS the logic the scheduled `mbs-daily` agent runs each morning. Run it manually anytime to test or refresh.

---

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test). No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault. The `## Vault Agent` section is bounded and clearly the agent's; never touch P's own sections of the daily note.
