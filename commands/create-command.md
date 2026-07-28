---
description: Create a new obsidian-second-brain command via interview — zero markdown editing required
category: meta
triggers_en: ["create command", "new command", "add a command", "scaffold a command"]
---

Use the mbs_automation skill. Execute `/create-command $ARGUMENTS`:

This command runs a short interview, then writes a new `commands/<name>.md` file that the build pipeline picks up automatically. The user never touches frontmatter, never edits a template, and never copies an existing command file.

**Hard rule:** You MUST use the AskUserQuestion tool for every question in this flow. ONE question per call. Wait for the answer before the next question. Do not batch.

Before scaffolding, read `references/ai-first-rules.md` (the amnesia-test note spec), `references/vault-schema.md` (the pillar map), and `references/write-rules.md` (suggest-don't-dispose, Tasks plugin not kanban) so the generated command lands consistent with the rest of the skill. Also read 1-2 existing commands (e.g. `commands/obsidian-project.md`, `commands/obsidian-log.md`) to match their shape.

The optional argument is a free-text seed describing what the command should do (e.g., `summarize my notion pages and save to vault`). If given, use it to pre-fill suggestions in the interview. If empty, the first question opens with "what problem do you want to solve?".

---

## Phase 1 — Intent

Ask ONE question via AskUserQuestion:

> "What problem do you want this new command to solve?" (free text)

Read the answer. Confirm understanding back in one sentence before proceeding.

---

## Phase 2 — Naming

From the intent, propose 3 candidate kebab-case names. Names should be lowercase, hyphenated, and start with `obsidian-` (vault-management commands) OR a topic prefix (research toolkit uses `research-*`, social uses `x-*`/`brand-*`) OR just a verb (`create-*`, `import-*`).

Use AskUserQuestion (single-select) with 3 options plus "Other" implicit:

> "Which name should I use?"
> - `<candidate-1>`
> - `<candidate-2>`
> - `<candidate-3>`

After the user picks, validate:
1. Check that `commands/<name>.md` does NOT already exist (use Read; if it succeeds, the name is taken — go back and re-ask)
2. Confirm the name passes the regex `^[a-z][a-z0-9-]*$`

---

## Phase 3 — Category

Ask via AskUserQuestion (single-select, 4 options):

> "Which category does this command belong to?"
> - `vault` — daily writing, capture, find (note creation, retrieval, tasks via the Tasks plugin)
> - `thinking` — synthesis, decisions, learning, reviews
> - `research` — bring external sources into the vault
> - `meta` — vault setup, health, structure, tooling

---

## Phase 4 — Trigger phrases

Generate 3-5 natural-language trigger phrases the user might say to invoke this command (not slash-form). Examples from existing commands: `"save this"`, `"deep research"`, `"weekly review"`. Avoid duplicating triggers already used by other commands (read all `commands/*.md` frontmatter `triggers_en:` once and warn on collisions).

Ask via AskUserQuestion (free text, default to your suggested set):

> "Trigger phrases the user might say to fire this command, comma-separated:"
> Default: `<suggestion-1>, <suggestion-2>, <suggestion-3>`

---

## Phase 5 — Behavior outline

Ask via AskUserQuestion (free text):

> "Describe what the command does in 3-5 numbered steps. Plain English, no code."

Use the answer as the spine of the command body.

---

## Phase 6 — Vault writes? (amnesia-test compliance gate)

Ask via AskUserQuestion (single-select):

> "Does this command write notes to P's Obsidian vault?"
> - `yes` — output must pass the amnesia test (frontmatter, `next_action` on active projects, mandatory wikilinks, recency markers, verbatim sources) and route to the right pillar
> - `no` — read-only, informational, or external-write only

If `yes`: the generated command body MUST include an **anti-fabrication** rule and end with the **Note rule** footer (see Phase 8). If the command writes to projects, the body must enforce `next_action` on active projects. If it could change existing notes, it must follow suggest-don't-dispose (propose edits, never auto-rewrite or auto-archive existing human notes).

---

## Phase 7 — External APIs?

Ask via AskUserQuestion (multi-select):

> "Does this command call any external APIs?"
> - Perplexity Sonar (web research)
> - xAI Grok (X posts, Live Search)
> - YouTube Data API
> - Other (free text)
> - None — purely operates on the vault and conversation

If any are selected, the generated body should include a setup line referencing `~/.config/obsidian-second-brain/.env` and the relevant key (e.g., `PERPLEXITY_API_KEY`).

---

## Phase 8 — Generate the file

Build the new command file. The exact format MUST be:

```
---
description: <one-line, sentence-case, ends without period>
category: <vault | thinking | research | meta>
triggers_en: ["<trigger 1>", "<trigger 2>", "<trigger 3>"]
---

Use the mbs_automation skill. Execute `/<name> $ARGUMENTS`:

<one-sentence framing tying P's intent (Phase 1) to the action>

1. Read `admin/mbs_system/brain/_CLAUDE.md` (and `references/vault-schema.md` if it routes by pillar).
2. <step from Phase 5, step 1>
3. <step from Phase 5, step 2>
4. <step from Phase 5, step 3>
5. <step from Phase 5, step 4 if present>
6. <step from Phase 5, step 5 if present>

<closing one-liner explaining why this matters>

---

<anti-fabrication + Note rule footer ONLY if Phase 6 = yes>
**Anti-fabrication (hard rule):** <one-line, tailored to this command — write/assert only what the conversation, source, or vault supports; never invent people, dates, hand-offs, or status claims; mark unknowns as `TBD`; per the search-completeness rule in `references/vault-schema.md`, never assert a note is absent without an exhaustive search>.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault, P reads his own notes. No kanban boards (Tasks plugin + task-archiver). Existing human notes are left as-is unless P asks; the agent suggests archiving but never moves anything to `_archive/` itself. Never touch P's own sections of the daily note.
```

Write the file to `commands/<name>.md` using the Write tool.

---

## Phase 9 — Confirm + next steps

Show the user the absolute path of the file you just wrote. Then surface the three follow-up actions:

1. **Build** — `bash scripts/build.sh` will recompile every platform (`dist/claude-code/commands/<name>.md`, plus the auto-generated routing tables and trigger reference in `AGENTS.md` / `GEMINI.md`)
2. **Install** — for Claude Code users who symlink, the new command appears automatically on next session. For other platforms, copy `dist/<platform>/` into the vault.
3. **Iterate** — open the file, refine steps, commit. Or rerun `/create-command` to add a sibling command.

If the new command writes to the vault, remind P that new notes must pass the amnesia test (frontmatter, `next_action` on active projects, mandatory wikilinks) and route to the correct pillar — the command's own logic carries that, per the Note rule footer.

---

**Why this matters:** Most "no-code" frameworks fail because they make the user fill out a form. This command treats the conversation itself as the form. A handful of questions, one file, zero markdown editing. Lowers the contribution bar so the skill can grow — and every command added through this flow lands amnesia-test-compliant and consistent with the pillar/Tasks/suggest-don't-dispose conventions by construction.

---

**Anti-fabrication (hard rule):** scaffold only what the interview answers support. Do not invent steps, triggers, or behavior P did not describe; if an answer is vague, ask a follow-up rather than filling the gap with assumptions.

**Note rule:** This is a command that creates commands. Do not run it recursively on itself. Do not rewrite this file when invoked — write a NEW `commands/<name>.md` based on the interview. The file it writes follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`; no `## For future Claude` preamble, no `ai-first:` flag, no kanban.
