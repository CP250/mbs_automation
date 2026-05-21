---
description: Reconcile the vault against your calendar — flag deadlines and commitments implied by notes that aren't on the calendar. Flag only, never adds events
category: vault
triggers_en: ["calendar check", "reconcile calendar", "what's not on my calendar", "calendar reconciliation"]
---

Use the mbs_automation skill. Execute `/obsidian-calendar $ARGUMENTS`:

This is vision duty #2: catch the gap between what the vault knows you need to do and what's actually scheduled. The optional argument is a window (`today`, `this week`, `this month`); default to this week.

1. Read `_CLAUDE.md`, `CRITICAL_FACTS.md`.
2. **Pull the calendar** for the window from Google Calendar (and Morgen if available) via the calendar MCP. List events with times.
3. **Gather what the vault implies** for the same window (shell-grep, not assumption):
   - Active project `next_action`s and any dated deadlines in project notes.
   - Tasks-plugin lines due in the window (`📅` dates, `not done`).
   - Commitments mentioned in recent daily notes / captures (appointments, calls, travel, someone's birthday, a filing deadline).
   - Known fixed dates from `CRITICAL_FACTS.md` (e.g. family birthdays) falling in the window.
4. **Reconcile and report**, in two directions:
   - **Vault-implied, not on the calendar** — the headline output. For each, state the item, its source note, and the date/urgency. These are the gaps worth P's attention.
   - **On the calendar, no vault context** (optional, lighter) — events that might warrant a prep note or project link.
5. **Flag only — never add, move, or change calendar events.** This is a hard boundary. For each gap, propose what P could do ("add a hold?", "this needs a prep note?") but do not act on the calendar.
6. Offer to record the reconciliation in today's tasks daily note (bounded `## Vault Agent` section) so the gaps are tracked; if P wants, add `- [ ] … 📅 <date>` tasks for the items he intends to act on.

---

**Anti-fabrication (hard rule):** only flag commitments that actually appear in the vault or calendar. Do not invent a deadline, an appointment, or a "should be scheduled" item that isn't grounded in a note. If timing is unclear, say so rather than asserting a date.

**Note rule:** Read-only with respect to the calendar (flag, never write events). Any vault note it writes follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`: no `## For future Claude` preamble, no `ai-first:` flag, hybrid vault. Never touch P's own sections of the daily note.
