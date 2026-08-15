---
description: Add a task in Tasks-plugin syntax — routed to the right project or pillar todo list, linked from today's note
category: vault
triggers_en: ["add task", "new todo", "track this", "remind me"]
---

Use the mbs_automation skill. Execute `/obsidian-task $ARGUMENTS`:

Add a task using P's **Tasks plugin** model. There are no kanban boards — tasks are checkbox lines that live on a project note or a pillar todo list, and "dashboards" are Tasks/Dataview queries.

1. Read `admin/mbs_system/brain/CLAUDE.md`.
2. Parse the task from the argument, or pull it from recent conversation context if no argument is given.
3. Infer: pillar (`admin`/`create`/`culture`/`health`/`money`/`skills`/`social`/`sports`), linked project (search for it), linked person, due date, and whether a priority is warranted. Don't over-tag — priority and due are optional.
4. **Write the task line** in Tasks-plugin syntax (per `references/write-rules.md`):
   ```markdown
   - [ ] <description> #<pillar> <priority?> 📅 <YYYY-MM-DD if due>
   ```
   - Status markers: `[ ]` todo, `[/]` in progress, `[x]` done (P's configured statuses).
   - Priority is optional and sparing: Tasks-plugin emoji (`🔺` highest … `🔽` lowest).
   - Due date format is `📅 YYYY-MM-DD`. Don't fabricate a due date — omit it if unknown.
5. **Route it:**
   - If the task belongs to a known project → append the line to that project note (under its tasks/next-steps section). If it is the project's single most important next step, also set/refresh the project's `next_action` frontmatter to match.
   - Otherwise → append to the pillar's todo list (`<pillar>/todo_list_<pillar>.md`); create that list with minimal frontmatter (`type: reference`, `tags: [<pillar>]`) if it doesn't exist.
6. **Propagate:** mention the task in today's tasks daily note (`daily_notes/tasks/tasks_YYYY-MM-DD.md`) so it surfaces in the morning report. Link the relevant project/person with `[[wikilinks]]`. If the target project or person note doesn't exist, create a stub (see `references/write-rules.md` § Stub Notes).
7. Never delete completed tasks — `task-archiver` moves them out on P's cadence. Marking `[x]` is enough.

If the task is substantial (multi-step, needs context), suggest promoting it to a project via `/obsidian-project` rather than burying detail in a one-line task.

---

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. Tasks plugin, not kanban. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault. Never touch P's own sections of the daily note; the agent writes only its bounded `## Vault Agent` section there.
