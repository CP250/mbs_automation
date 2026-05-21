---
description: Extract decisions actually made in this conversation and log them to the right project notes
category: thinking
triggers_en: ["extract decisions", "log decisions", "what did we decide"]
---

Use the mbs_automation skill. Execute `/obsidian-decide $ARGUMENTS`:

Capture decisions so the reasoning doesn't evaporate when the session closes. The optional argument narrows to a specific topic.

1. Read `_CLAUDE.md` at the vault root.
2. Scan the conversation for decisions **actually made** — conclusions reached, choices committed to, directions changed. If a topic argument is given, focus there.
3. For each decision, capture: the decision itself, the date (`YYYY-MM-DD`), the reasoning/alternatives considered, and any follow-on action it implies.
4. **Find the relevant project note** (shell-grep the vault). Append each decision to that note's `## Key Decisions` section:
   ```markdown
   - **<YYYY-MM-DD>** — <decision>. Rationale: <why; alternatives weighed>. → <implied next step, if any>
   ```
   If the decision changes the project's direction, also update its `next_action` frontmatter.
5. If a decision is substantial and standalone (not tied to one project), write a decision note with frontmatter:
   ```yaml
   ---
   type: decision
   date: <YYYY-MM-DD>
   tags: [decision, <pillar>]
   project: "[[<project>]]"
   ---
   ```
6. If a decision affects multiple projects, log it in each.
7. **Propagate:** note the decision in today's tasks daily note (bounded `## Vault Agent` section); if it implies a next step, add a `- [ ] … #<pillar>` task. Append to `log.md`.

---

**Anti-fabrication (hard rule):** log only decisions that were genuinely made in the conversation. Do not upgrade a musing or an option-on-the-table into a "decision," and do not invent rationale P didn't give. If it's ambiguous whether something was decided, ask before logging it.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault. Never touch P's own sections of the daily note.
