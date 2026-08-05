# Phase 7 test plans — the six adapted-but-untested commands

Manual test plans for the six commands adapted in Phase 7. None of these were executed during authoring (no live Claude Code run was available) — each plan is the exact invocation P should run plus what to verify. Run them against the live vault at `/Users/cpreston/Vaults/storage_mbs/`.

Common acceptance criteria for every command (the "Note rule" contract):
- New notes carry frontmatter (`type`, `date` as `YYYY-MM-DD`, `tags`) and read self-sufficiently (amnesia test).
- No `## For future Claude` preamble and no `ai-first:` flag is ever written.
- No kanban; tasks use the Tasks-plugin line format (`- [ ] … #<pillar> 📅 YYYY-MM-DD`).
- Nothing is deleted, moved, or archived; existing human notes are not rewritten.
- The agent never writes inside P's own sections of the daily note (only the bounded `## Vault Agent` section).
- People/projects/places referenced are `[[wikilinked]]`.

---

## `/obsidian-decide`

**Invocation:** in a session where one or more real decisions were made, run `/obsidian-decide` (and once with a topic arg, e.g. `/obsidian-decide polar pricing`).

**Verify:**
1. Only decisions actually reached are logged — musings and still-open options are NOT upgraded to "decided" (anti-fabrication). If ambiguous, the command asks first.
2. Each decision is appended to the right project note's `## Key Decisions` section using the dated bullet format, with rationale/alternatives and an implied next step.
3. If a decision changed direction, the project's `next_action` frontmatter was refreshed.
4. A standalone decision (not tied to one project) is written as a `type: decision` note with a `project:` wikilink.
5. A multi-project decision is logged in each affected project.
6. Propagation: a `## Vault Agent` mention in today's tasks daily note, a Tasks-plugin line if a next step is implied, and a `admin/mbs_system/design/log.md` line.
7. **Search-completeness (changed in QA):** with the project note present, confirm it is found; the command should not silently create a new note because it failed to locate the existing one. Test the negative path by referencing a project whose note exists under a slightly different name and confirm it greps the candidate pillars before concluding "not found."

---

## `/obsidian-log`

**Invocation:** after a real work/dev/thinking session, run `/obsidian-log`. Test once where the project is obvious and once where it is genuinely ambiguous.

**Verify:**
1. The correct project/pillar is inferred; on ambiguity the command asks rather than guessing.
2. **Search-completeness (changed in QA):** the command greps candidate pillars exhaustively before concluding no matching project note exists — it should not create an orphan log because it under-searched.
3. The log note is saved to a project folder's `_logs/` (`<pillar>/project_<name>/_logs/log_YYYY-MM-DD_<slug>.md`) or pillar `_logs/` location with `type: log` frontmatter and a `project:` wikilink.
4. Body captures only what the session actually produced (anti-fabrication — no inflated outcomes).
5. Propagation: dated line in the project's Recent Activity, `## Vault Agent` mention in today's daily note, refreshed `next_action` + a Tasks line if a concrete next step emerged, and a `admin/mbs_system/design/log.md` line.

---

## `/obsidian-recap`

**Invocation:** `/obsidian-recap today`, `/obsidian-recap week` (default), `/obsidian-recap month`.

**Verify:**
1. Read-only by default — NO note is written unless P explicitly asks; if asked, it lands in `admin/reviews/`.
2. **Search-completeness:** every daily note in the range is enumerated (both `daily_notes/tasks/` and `daily_notes/health/`), not a sampled few. Spot-check by comparing the recap against the actual files in the range.
3. The narrative covers work, decisions, people seen, tasks completed (`✅` lines), and captures — as prose, not a raw dump.
4. A genuinely quiet period is reported honestly as quiet (anti-fabrication — no padded activity).
5. Cited notes are real and in-range.

---

## `/obsidian-ingest`

**Invocation:** `/obsidian-ingest <url>`, then `/obsidian-ingest <local pdf path>`, then `/obsidian-ingest` with pasted text and no arg (should ask). Re-run on a source already ingested to test dedup.

**Verify:**
1. **Search-before-write (changed in QA):** on the re-run, the command finds the existing reference note and updates it rather than creating a duplicate.
2. One `ref_<slug>.md` reference note is created in the right pillar (or `captured/` when the destination is unclear) with `type: reference` frontmatter and the verbatim `source:` URL.
3. Body is a self-contained summary with the source URL inline, recency markers on external claims, and `[[wikilinks]]` only to notes that actually exist (no manufactured links).
4. **Propose, don't rewrite:** if the source contradicts/updates an existing note, the command lists proposed updates for P to approve and does NOT edit that note.
5. Propagation: `## Vault Agent` mention in today's daily note, `admin/mbs_system/design/log.md` line, `index.md` updated for the new note.
6. Heavy tooling (yt-dlp/Whisper/API pulls) is declined with a request to paste text, per the v1 scope note.

---

## `/obsidian-synthesize`

**Invocation:** `/obsidian-synthesize` (whole-vault scan).

**Verify:**
1. The Synthesis Report is presented in-conversation; NO synthesis note is auto-written.
2. Every pattern rests on specific, real, cited notes/dates (anti-fabrication — thin evidence is called out as thin, not forced into a "pattern").
3. `trash/` is excluded; `_archive/` is treated as historical context only.
4. **Search-completeness:** the scan is broad (parallel read subagents), not a sample.
5. Only on P's approval is a note written (to `captured/` or a named project note), following the amnesia test and linking source notes; nothing is auto-linked across human notes.
6. On approval: `admin/mbs_system/design/log.md` line and `## Vault Agent` daily-note mention.

---

## `/obsidian-reconcile`

**Invocation:** `/obsidian-reconcile` (broad), then `/obsidian-reconcile <entity>` (focused, e.g. a person whose role changed).

**Verify:**
1. A reconciliation report is presented; the command NEVER auto-resolves or rewrites (the old auto-rewrite behavior must be absent).
2. Each conflict cites the specific notes and dates on both sides; genuine contradictions are distinguished from evolutions (P changed his mind).
3. Drift against `CRITICAL_FACTS.md` / `SOUL.md` is flagged with those files treated as the source of truth.
4. **Search-completeness:** the scan is thorough before declaring the vault consistent OR inconsistent (anti-fabrication — no invented conflicts, no evolution misread as contradiction).
5. Fixes are applied ONLY after P approves each; on approval, a `admin/mbs_system/design/log.md` line and daily-note mention are added. Nothing is rewritten without a yes.

---

## What changed during this QA pass

- `obsidian-decide.md` — step 4: added the search-completeness requirement so the command greps candidate pillars exhaustively before concluding a project note is absent (was a false-absence risk).
- `obsidian-log.md` — step 2: same search-completeness requirement on project-note inference.
- `obsidian-ingest.md` — step 4: added an explicit search-before-write step (per `write-rules.md`) so a re-ingest updates the existing reference note instead of duplicating it.
- `obsidian-recap.md`, `obsidian-synthesize.md`, `obsidian-reconcile.md` — reviewed, no changes needed; each already cites the search-completeness rule, carries an anti-fabrication rule, and ends with the correct Note rule footer.
