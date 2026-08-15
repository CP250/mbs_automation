---
description: On-demand work-session shortlist (the Do step): free-text context (location / time / mode) to a ranked cross-pillar list in chat + today's daily note
category: vault
triggers_en: ["work session", "what should I work on", "suggest highest priority items", "what should I do with my time"]
---

Use the mbs_automation skill. Execute `/obsidian-work-session $ARGUMENTS`:

The contract: P wants a 10-20 item, context-filtered, cross-pillar shortlist of his own open tasks, ranked by judgment over signals the vault already carries. On-demand only, stateless, pure suggestion: nothing recurs (no launchd, no heartbeat), nothing is remembered between invocations, and nothing changes anywhere except one bounded subsection of today's daily note. Binding spec and decision list: `admin/mbs_system/design/project_obsidian_work_session.md`; decision record: `adr_2026-08-02_work_session_design.md`. The spec's "Explicitly declined" list is closed: do not re-propose scheduled variants, health reads, new priority or context fields, skip memory, a separate dated note, in-progress markers, or completion counts.

1. Read `admin/mbs_system/brain/CLAUDE.md`, `SOUL.md`, `CRITICAL_FACTS.md`. Use filesystem tools (Read/rg), not the Obsidian MCP (must work with Obsidian closed).

2. **Parse context** from `$ARGUMENTS`, or from the recent conversation if empty: location (New Canaan / Collinsville / Montreal / away / anywhere), time budget, mode or energy. Suggested mode vocabulary, never enforced: physical / desk / calls / errands / creative. Ask ONE follow-up only if something material is missing (usually the time budget). Never read health notes or Oura data: energy is what P typed (decision 2b).

3. **Collect candidates** (mechanical, before any judgment). All unchecked `- [ ]` lines from files passing ALL of: not under any `_archive/` (`trash/` is already rgignored); basename not `ref_*`; frontmatter `type:` not `reference` or `dashboard`; frontmatter `status:` not `someday`, `on_hold`, `completed`, or `reference`. Then ADD today's daily-note capture region (everything above `## Vault Agent` in `daily_notes/tasks/tasks_YYYY-MM-DD.md`): that is the errand pool, ` #keep` lines included. Old daily notes and all agent sections are never candidate sources (reply-loop proposal checkboxes are not P's tasks). Drop regardless of file: `weekly_blocks_*` lines (standing exclusion 2026-07-18) and anything credential-shaped (passwords, keys, account strings: invisible, never surfaced, never mentioned, decision 8 of task-triage carried over). Suggested pipeline:

   ```
   rg -n --no-heading '^\s*- \[ \]' -g '*.md' -g '!**/_archive/**' -g '!**/ref_*.md' -g '!daily_notes/**' -g '!**/_chat_imports/**' -g '!**/pn.md' -g '!trash/**' | grep -v 'weekly_blocks_'
   ```

   then subtract lines in files matching `rg -l '^(type: (reference|dashboard)|status: (someday|on_hold|completed|reference))'` (subtract with awk, not BSD `grep -f`, which is pathologically slow here), then read today's tasks note top region separately. Counts drift daily (~1,100 lines as of 2026-08-02); never hard-code them. The `_chat_imports` and `pn.md` excludes are load-bearing, verified 2026-08-02: chat imports are frozen transcripts (reference by nature), and a broad sweep reached `pn.md` despite `.rgignore`, so the explicit globs stay; since the same-day vault-guard hardening (CLASS 1b in `vault_guard_hook.py`), the hook DENIES any vault-rooted include-glob sweep that lacks both the `pn.md` and `trash/` exclusion globs, so keep all of them. Known residue left to the ranking layer: registry and want-list files not named `ref_*` (a row-per-item list with a 🆔 on every row is a registry, not commitments) rank as reference, and an item whose 🆔 also exists in a second file goes in the prose list only, never the tick strip (a duplicate id renders twice in a query).

4. **Rank** by LLM judgment over existing signals only (no new fields exist; do not invent any). First filter to context fit (mode, location, time budget), then order by: overdue and due-dated items first; unblock leverage (gate items that free downstream work, e.g. the oslo tagging gate pattern); goals-ladder alignment (`rolls_up_to` in the pillar `goals_*` file, toward `goals_long_term`); staleness; budget fit. Compose a mix: one anchor item plus smaller items summing inside the budget, each with an honest time estimate. Lines found in `log_*` or `_HANDOFF_*` files are historical echoes: prefer the project-note copy when duplicated. Target 10-20 items; if fewer than ~10 genuinely fit, return the honest set plus ONE labeled nearest-miss line ("desk items you could do instead: ..."); never pad silently (decision 9).

5. **Deliver, twice, same content:**
   - **Chat:** the ranked numbered list: `[[source note]]`, item text, one-line why, time estimate.
   - **Today's tasks note:** insert the stamped section at the TOP of the note, immediately after the frontmatter and before P's first content line, newest section topmost (P's placement decision 2026-08-02, amending the original end-of-Vault-Agent placement). Head it `### Work session (HH:MM): <context as P gave it>` and END it with a line containing exactly `<!-- /work-session -->`. That terminator is load-bearing: carry-forward and the first-seen recorder in `mbs_daily.sh` use it to bound the block (routing it into the old note's preserved tail, so the section stays in its own day's note and never carries into tomorrow), and the daily triage step skips the same block. Never write a work-session section without it. Read the note before editing. Structure, links never copies:
     1. The same ranked prose list (numbered lines, wikilinks, why, estimate). This is the frozen record; no checkboxes.
     2. A tick strip: ONE `tasks` query block over the picked 🆔 ids, e.g.

        ````
        ```tasks
        not done
        (id includes aaa111) OR (id includes bbb222) OR (id includes ccc333)
        ```
        ````

        Only ids actually picked. Verified supported: installed Tasks is v7.22.0, id filters exist since 6.1.0, boolean OR with parenthesized filters is documented. Skip the block entirely if no picked item carries a 🆔.
     3. Errands from this same note: name them under "From your list below: ..." with no checkboxes and no query; their real lines are already tickable in P's region below the section.
     4. Project items without a 🆔: wikilink only; P ticks at source, one hop.

6. **Multiple invocations per day** insert new stamped sections, newest on top; earlier ones are never edited. Repeat suggestions across sessions are legitimate (stateless); a line stops appearing when P ticks or edits it at source.

**Hard boundaries:** writes touch exactly one file (today's tasks note) and only the command's own `### Work session ... <!-- /work-session -->` block at the top of the note; never edit source notes, never tick, never tag, never stamp ids; never duplicate an existing task line anywhere, ever; credential-shaped lines are invisible; `someday` / `on_hold` / `_archive` items never surface unless P explicitly asks for them; never create or modify calendar events; no state files, no memory. No em-dashes anywhere (comma, colon, parentheses, hyphen instead).

---

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. Tasks plugin, not kanban. The agent writes only its bounded section of the daily note; P's regions are untouchable.
