---
description: Promote an idea/capture into a full project spec — pillar-routed, amnesia-test, with a real next_action and Tasks-plugin steps
category: thinking
triggers_en: ["promote idea", "graduate this to project", "make a project from this", "elevate idea"]
---

Use the mbs_automation skill. Execute `/obsidian-graduate $ARGUMENTS`:

This is the co-creative project-decomposition duty: take a rough fragment and turn it into a real, actionable project. The output is only worth anything if it ends with a concrete next step P can actually take.

The optional argument is the idea title/keyword. If not given, scan `captured/` and recent daily notes (last ~14 days) for candidate fragments and ask P which one.

1. Read `_CLAUDE.md`, `SOUL.md`, `CRITICAL_FACTS.md`.
2. **Find and read the source fragment** (a `captured/` note, a daily-note line, a stray thought) and any notes it links to.
3. **Research the vault before designing** (shell-grep, not assumption): existing projects that overlap (don't duplicate), people involved, past decisions that bear on it, and prior similar ideas that were tried — surface those so the spec doesn't reinvent or repeat a known dead end.
4. **Decompose with P, don't dictate.** Propose the structure, but where a goal, scope, or next step genuinely depends on information you don't have, ask — do not invent it. (See anti-fabrication below.)
5. **Create the project note** the same way `/obsidian-project` does: route to the right pillar as `<pillar>/project_<snake_case_name>.md` (or a `project_<name>/` folder if it will grow), with amnesia-test frontmatter:
   ```yaml
   ---
   type: project
   date: <YYYY-MM-DD>
   tags: [project, <pillar>]
   status: planning            # planning until the first step is underway; then active
   people: ["[[Name]]"]
   ---
   ```
   Body (amnesia-self-sufficient): **description** (what this is and why it matters), **goals** (3–5 concrete outcomes), **plan** (phased steps), **open questions** (what still needs answering), **related** (wikilinks to everything found in step 3). External claims get recency markers + verbatim source URLs.
6. **Turn the plan into tasks** (Tasks-plugin, not boards): write the first actionable steps as `- [ ] … #<pillar> 🆔 <6-char-id> 📅 <due?>` lines on the project note, under a `## Next action` heading. **There is no `next_action:` frontmatter field** — it was retired 2026-06-06 and the first unchecked body checkbox IS the next action, so nothing needs mirroring. A `status: active` project whose body has zero unchecked checkboxes is the failure state the whole system exists to catch.
7. **The fragment evolves, it doesn't die.** Leave the original capture in place and add a link to the new project note ("graduated to [[project_…]]"). Don't delete or archive it.
8. **Propagate:** link the project from today's tasks daily note (bounded `## Vault Agent` section), link involved people from `social/`, append to `admin/mbs_system/design/log.md`, update `index.md`.
9. **Report** what was created, what was linked, and what still needs P's input.

---

**Anti-fabrication (hard rule):** never invent goals, people, dates, or facts to fill out the spec. If something is unknown, write `TBD` and ask P. A plausible-sounding invented detail in a project plan is worse than an honest gap.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag, no kanban — hybrid vault, Tasks plugin. Existing human notes left as-is unless P asks.
