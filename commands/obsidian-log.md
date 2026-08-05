---
description: Log this work or session to the vault — routed to the relevant pillar/project, linked from today's note
category: vault
triggers_en: ["log this work", "log this session", "log this dev session", "obsidian log"]
---

Use the mbs_automation skill. Execute `/obsidian-log`:

Capture what a work or thinking session produced so it isn't lost when the session closes.

1. Read `admin/mbs_system/brain/CLAUDE.md`.
2. Infer the project/pillar from the conversation (shell-grep to find the right project note — search exhaustively per the search-completeness rule in `references/vault-schema.md`; never conclude "no matching project note exists" without listing and grepping the candidate pillars). If genuinely ambiguous, ask.
3. Build the log from the conversation: what was worked on, problems hit, decisions made, next steps. Capture only what actually happened — do not invent progress (see anti-fabrication).
4. Save as a log note in the relevant location's `_logs/` (create it if absent): a project folder (`<pillar>/project_<name>/_logs/log_YYYY-MM-DD_<slug>.md`) or the pillar (e.g. `money/<employer>/_logs/log_YYYY-MM-DD_<slug>.md`). Frontmatter:
   ```yaml
   ---
   type: log
   date: <YYYY-MM-DD>
   tags: [log, <pillar>]
   project: "[[<project>]]"
   ---
   ```
5. **Propagate** (per `references/write-rules.md`): add a dated line to the project note's Recent Activity section; mention it in today's tasks daily note (`## Vault Agent` section); if the session produced a concrete next step, set/refresh the project's `next_action` and add a `- [ ] … #<pillar>` task. Append to `admin/mbs_system/design/log.md`.

---

**Anti-fabrication (hard rule):** log only what the session actually produced. Don't inflate outcomes, invent decisions, or attribute work that wasn't done.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag, no kanban, no `Dev Logs/` folder — hybrid vault, Tasks plugin. Never touch P's own sections of the daily note.
