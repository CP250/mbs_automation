---
description: Generate or refresh a per-pillar dashboard note — active projects + next actions, projects missing a next step, due/overdue tasks, stale projects
category: vault
triggers_en: ["pillar dashboard", "refresh dashboard", "make a dashboard", "dashboard for"]
---

Use the mbs_automation skill. Execute `/obsidian-dashboard $ARGUMENTS`:

The argument is a pillar name (`admin`, `create`, `culture`, `health`, `money`, `skills`, `social`, `sports`); `all` (default) refreshes every pillar. A dashboard is a live `dataview`/`tasks` query note — not a kanban board and not a hand-maintained list. Its job is to surface the system's core duty: every active project should carry a `next_action`, and any that don't are the failure the whole vault exists to catch.

1. Read `_CLAUDE.md` at the vault root and `references/vault-schema.md` (the canonical query patterns live there).
2. Resolve the pillar(s). If a single pillar, confirm it is one of the eight; if `all`, iterate over all eight.
3. For each pillar, generate (or refresh) the dashboard note at `<pillar>/dashboard_<pillar>.md`. **Search first** (per `references/write-rules.md`): if it already exists, refresh the query blocks in place rather than duplicating, and do not disturb any notes P added below them. Frontmatter:
   ```yaml
   ---
   type: dashboard
   date: <YYYY-MM-DD>
   tags: [dashboard, <pillar>]
   ---
   ```
4. The body is **query blocks only** — Dataview and Tasks plugins render them live, so the dashboard never goes stale and never needs the agent to fabricate state. Use exactly these patterns (scoped to the pillar), per `references/vault-schema.md`:
   - **Active projects + their next action**
     ```dataview
     TABLE status, next_action FROM "<pillar>"
     WHERE type = "project" AND status = "active"
     SORT file.mtime DESC
     ```
   - **Active projects MISSING a next action** (the missing-next-step duty — the most important block)
     ```dataview
     TABLE file.link AS project FROM "<pillar>"
     WHERE type = "project" AND status = "active" AND (!next_action OR next_action = "")
     ```
   - **Due / overdue tasks in the pillar** (Tasks plugin)
     ```tasks
     not done
     path includes <pillar>
     (due before tomorrow) OR (is overdue)
     sort by due
     ```
   - **Stale active projects** (no edit in 14+ days)
     ```dataview
     TABLE file.mtime AS "last touched" FROM "<pillar>"
     WHERE type = "project" AND status = "active" AND file.mtime < date(today) - dur(14 days)
     SORT file.mtime ASC
     ```
   Lead the note with one plain sentence naming the pillar and what the dashboard shows (amnesia test — a future reader should understand it cold). Add a short heading above each block. Note that `_archive/` items rank as historical and `trash/` is excluded by these `FROM "<pillar>"` scopes.
5. **Propagate** (per `references/write-rules.md`): append a timestamped line to `log.md`; add the new dashboard(s) to `index.md`; note it in today's tasks daily note (`## Vault Agent` section). Optionally link the pillar dashboards from `index.md` so they are one click away.

---

**Anti-fabrication (hard rule):** the dashboard contains query blocks, not hand-written results — never paste a static list of "active projects" or "overdue tasks" into the note, because that snapshot rots and invites invented entries. Let Dataview/Tasks compute the live state. Do not invent a `next_action` to make the "missing next action" block look empty; an active project with no next step is exactly what this dashboard must reveal.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault. No kanban boards (Tasks plugin + Dataview). Dashboards are additive new notes; existing human notes are left as-is, and the agent never archives. Never touch P's own sections of the daily note.
