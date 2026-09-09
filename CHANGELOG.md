# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`claude -p` supervision in `lib_auth.sh` (2026-09-09): idle watchdog, per-attempt trace, forensic log line.** `run_claude_p` now runs claude with `--output-format stream-json --verbose` into a per-attempt trace file under `~/.mbs_automation/claude_traces/` (14-day rotation), extracts the final result text into the job log exactly where text-mode output used to land, and kills an attempt on either of two named conditions: the hard cap (`CLAUDE_TIMEOUT_SECONDS`, estate default still 1500s) or `CLAUDE_IDLE_SECONDS` (default 600s) with no growth of the trace. On a kill the log gets the reason, the elapsed time, the tool-call count, the last three tool calls, and whether the last one ever returned, so a hung MCP call is named rather than inferred. Auth and credit detection read only the verdict text (result event plus stderr), never the whole trace, since the trace contains every file the agent read, including `mbs_daily.log` and its old 401 lines. Why: on 2026-09-09 attempts 1, 2 and 3 of the daily run were killed at 1500s with the network up and left zero bytes of evidence; the same signature on 2026-08-17 (five kills, all jobs) was recorded as a no-network morning on the strength of the banner text alone. Same contract for every caller (`mbs_daily`, `mbs_weekly`, `cars_weekly`, `the_record`, `weekly_blocks`, `mbs_review_prep`); `team_brief.sh` still carries its own loop and is outside this change.
- **Completion marker for the morning report** (`commands/obsidian-daily.md` step 8): the agent ends `## Vault Agent` with one `<!-- vault-agent-status: complete | ... -->` or `<!-- vault-agent-status: partial | skipped=... | reason=... -->` line. `mbs_daily.sh` reads it after a zero exit: `partial` is a failed attempt (exit 5, no stamp, the ladder continues and the next attempt refreshes the section in place); a missing marker is logged as a WARNING and stamped. A zero exit with no real `## Vault Agent` section at all is also exit 5 now. Heartbeat **check 2c** reports a `partial` or missing marker. Why: attempt 4 on 2026-09-09 wrote a deliberately partial section with a minute left before the kill, exited 0, was stamped, and checks 2 and 9 both passed on it.
- **CLI debug log per attempt and startup latency in the accounting line** (`lib_auth.sh`, same day, later): `run_claude_p` adds `--debug-file <trace dir>/<job>_<stamp>.debug.log` when `claude --help` advertises the flag (probed once per process; an older CLI runs without it), records `first output after Ns` in the log line, and on a kill with zero events quotes the debug log's last lines. Why: P's transcript listing showed the three killed attempts had no session transcript at all, so the stall was in CLI startup, where the stream trace is empty by construction.
- **`run_claude_p` optional `$3` (result file) and `$4` (stdin file)**, and `team_brief.sh`'s `generate_brief` now delegates to it instead of carrying its own hard-cap-only supervisor copy since 2026-08-03. The brief body goes to the result file, stderr to the log, the data pack on stdin; the loop's own auth and credit checks stay as a second layer, with the duplicate credit alert removed since `run_claude_p` already writes it.
- **`## Vault Agent (skipped, timed out)` and `(skipped, no report written)` banners** in `mbs_daily.sh`, chosen by the ladder's final exit code. The old block called every all-attempts failure "no network".

### Changed

- **`mbs_daily.sh` per-attempt hard cap is 3600s** (was the 1500s estate default), set by exporting `CLAUDE_TIMEOUT_SECONDS` before `lib_auth.sh` is sourced; a hung attempt is now caught by the idle watchdog instead, so the higher cap costs nothing on a hang. The prompt tells the agent its budget and the marker contract. Measured 2026-08-18 to 09-08: healthy runs take 6 to 12 minutes; 09-04 attempt 1 (killed at 1500s while executing approvals) and 09-09 attempt 4 (24m47s) are the two runs the old cap threw away or nearly did.

- **`open_tasks` frontmatter property on the tasks daily note:** `mbs_daily.sh` now counts every unchecked `- [ ]` checkbox in the vault (excluding `trash/`, `admin/pn.md`, all `_archive/` and `_logs/`, and all of `daily_notes/`) and stamps it into today's note as `open_tasks: <n>`, directly after `journal-date`. Two new bash functions, `count_open_tasks` and `ensure_open_tasks_field`, both bash-3.2 and BSD safe. Deliberately a morning snapshot: written once at creation, never refreshed, never overwritten if already present. `mbs_heartbeat.sh` gained a matching presence check (check 2b) per the watchdog rule.
- **SessionStart hook (`hooks/load_vault_context.py`):** injects `_CLAUDE.md` into context once per session when the session starts inside the vault. Eliminates the per-command re-read of `_CLAUDE.md` that burned tokens on every invocation. Wired automatically by `scripts/setup.sh`.
- **`scripts/setup.sh` updated:** wires the new SessionStart hook (`hooks/load_vault_context.py`) in addition to the existing PostCompact background agent.
- **Per-day operation logs:** `/obsidian-init` now creates a `Logs/` folder with per-day files (`Logs/YYYY-MM-DD.md`) instead of a monolithic `log.md`. Root `log.md` becomes a pointer file only. Cheaper to read, faster to query.
- **`scripts/vault_stats.py`:** computes vault stats (notes by type, project/task counts by status, people by strength) and rewrites the `<!-- BEGIN STATS -->`/`<!-- END STATS -->` markers in `index.md`. Idempotent and re-runnable.
- **`scripts/migrate_log.py`:** splits an existing monolithic `log.md` (with `## YYYY-MM-DD` section headers) into per-day files under `Logs/`. Idempotent — skips days that already exist. Replaces root `log.md` with a pointer file after migration.

- **`clear_skip_banner()` in `mbs_daily.sh`:** strikes a stale `## Vault Agent (skipped)` / `## Vault Agent (skipped, no network)` banner out of today's tasks note at the start of each run. Required by the 30-minute grid below: with more than one ladder possible per day, a later success would otherwise append a real report directly underneath a banner announcing that no report was generated. Runs after carry-forward (yesterday's note keeps its own banner as accurate history) and before the claude ladder (the claude step never sees a `(skipped` heading it might refresh instead of appending a clean one). Same self-healing principle as `lib_auth.sh`'s `unalert_tasks_note`. bash 3.2 and BSD safe; best-effort, with a line-delta sanity check that discards any implausible rewrite rather than committing it.

### Changed

- **`com.mbs.daily` now fires on a 30-minute `StartCalendarInterval` grid, 06:00 through 21:30 (32 entries), instead of a single 06:00 fire.** P decision 2026-08-22. 06:00 is still the on-time fire and the morning is unchanged; the rest of the grid exists so a day that fails early is retried later rather than lost. The direct cause: on 2026-08-21 the 06:14 ladder hit a DNS wall, burned all five attempts, died at 12:00, and nothing triggered again that day.

  **A calendar array, deliberately not `StartInterval`.** `launchd.plist(5)` says a `StartInterval` firing that lands while the system is asleep "will be missed due to shortcomings in kqueue(3)", and one that lands while the job is already running is missed too, which the ~1.75 hr retry ladder would trip constantly. `StartCalendarInterval` has the opposite behavior: "launchd will start the job the next time the computer wakes up. If multiple intervals transpire before the computer is woken, those events will be coalesced into one event upon wake from sleep." That coalescing is the run-on-wake behavior being asked for: a Mac asleep 09:00 to 14:20 produces one fire on wake, not eleven.

  **Firing this often is free** because the per-day stamp check is the third thing `mbs_daily.sh` does, before the lock and before the vault scan, so every later fire on a successful day exits in milliseconds; fires that land mid-ladder hit the live PID lock and exit cleanly. This is a deliberate exception to the one-job-per-slot stagger convention: the grid overlaps every other job's slot by design, and the stamp is why that is harmless.

- **Skip-banner texts in `mbs_daily.sh`** now describe the grid cadence and say the banner is struck automatically if a later attempt that day succeeds, instead of pointing at "next wake event or tomorrow's 06:00".

### Fixed

- **Stale lock could silently eat an entire day (`mbs_daily.sh` + `mbs_heartbeat.sh`).** Two correct-looking safety mechanisms combined into silent data loss. `mbs_daily.sh`'s retry sleeps use CLOCK_MONOTONIC and pause while the Mac sleeps, so the 2026-08-23 ladder started at 06:10 and did not fire attempt 5 until 20:12 the following day. For the whole of 08-24, (a) launchd would not start a second copy of the already-running job, so none of that day's triggers fired, and (b) `mbs_heartbeat.sh` deferred on the live PID as "still running, not late yet" and exited without stamping or reporting. 08-24 got no carry-forward, no report, and no banner explaining the absence. Corroborating detail: the lock's "another instance is running" branch has never been reached once in the life of the log, because launchd never gives it the chance.

  **`mbs_daily.sh` is now day-bound:** before each attempt, if the date no longer matches the `$TODAY` the run started for, the ladder is abandoned, a `## Vault Agent (skipped, run abandoned)` banner is written into that day's note, and the script exits 4 (0/1/2/3 and `run_claude_p`'s 124 were taken). The lock directory now also carries a `day` file recording what it was claimed for.

  **`mbs_heartbeat.sh` defers only on a lock claimed today:** new `lock_claimed_day()` reads that `day` file and falls back to the lock directory's mtime for locks that write none, shape-checking every source as `YYYY-MM-DD` and returning empty (which makes callers defer, the old conservative behavior) for anything unparseable. A live PID from an earlier day is now finding "check 0", deliberately the first emitted. The same guard was applied to the team-brief lock.

  The generalizable lesson, recorded in SETUP.md: a "be patient, it is still working" guard and a "one instance at a time" guard are each correct alone and jointly lose days in silence. **A patience guard needs a bound**: ask not just whether the holder is alive, but whether it is still working on the thing being waited for.

- **`check 0` finding text executed shell commands (caught pre-ship).** The first version escaped backticks such that bash resolved them as live command substitution, so building the finding string ran `ps` and `tail`. Backticks removed from the message.

- **`lock_claimed_day()` trusted unvalidated `stat` output (caught pre-ship).** GNU stat accepts BSD's `-f` as "filesystem status" and answers with block counts at exit 0, so on a non-macOS host the fallback chain never advanced and the caller would have compared a date against a block count. Every source is now shape-checked before it is accepted. Production is macOS-only so this could not have bitten there, but an unvalidated date is how a guard silently inverts.

- **`clear_skip_banner` section boundary (caught pre-ship).** The first version bounded the banner section at the next `## ` heading. Run against the real `tasks_2026-08-21.md`, that swallowed the entire `### Pointer check` section `com.mbs.pointer-check` had appended below the banner. The function's line-delta sanity check refused the rewrite rather than committing it, which would have made it a silent no-op in precisely the case it exists for. Boundary is now the next heading at any level, and the seam repair only re-inserts a blank line where lines were actually dropped. Verified on the real note: 33 lines to 28, banner gone, pointer-check intact, idempotent on re-run, no blank-line ratchet across five write-then-strike cycles.

## [0.8.0] — 2026-05-15

### Added

- **`/notebooklm` command rewritten end to end — no browser, one HTTP call.** Replaces the prior bundle-and-paste workflow (which required opening notebooklm.google.com manually and pasting the response back into the terminal) with a single-phase command that calls Google's Gemini File Search API directly. Same architectural shape as `/research-deep`: one HTTP call, no manual step. Under the hood: scans the vault for the top 12 relevant notes (Research/NotebookLM/ excluded so the synthesis doesn't self-reference its own bundle), uploads them to an ephemeral Gemini File Search store, asks Gemini (default `gemini-2.5-flash`, free-tier friendly) for a citation-style synthesis grounded only against those sources, writes the AI-first synthesis to `Research/NotebookLM/YYYY-MM-DD - <slug>.md`, deletes the store, and emits a propagation payload for `/obsidian-save`. Requires `GEMINI_API_KEY` from https://aistudio.google.com/apikey (free tier covers it). Cost: roughly $0.004 per run on Flash, $0.06 per run on Pro (override via `NOTEBOOKLM_MODEL` env). Filenames written by this command use ASCII separators (`2026-05-15 - <slug>.md`) instead of em-dashes; existing `/research-deep` filenames untouched. The two research tracks (open-web via `/research-deep`, vault-grounded via `/notebooklm`) are designed to run in parallel for high-stakes topics. Contradictions across the two tracks are where the insight is.

### Fixed

- **`/notebooklm` self-reference bug.** Previous implementation re-scanned the vault during the save phase, which scored the bundle file (written during the start phase) as a top hit. The synthesis linked to its own input bundle as a vault baseline. Fix: `vault_scan` now excludes anything under `Research/NotebookLM/`.
- **`/notebooklm` em-dash filenames blew up the Gemini SDK upload.** Vault filenames in `Research/Deep/` and `wiki/logs/` often contain em-dashes (from the prior `/research-deep` convention). The Gemini SDK puts the basename in a Content-Disposition header, and httpx rejects non-ASCII headers. Fix: copy each source to a temp path with an ASCII-safe name before upload; preserve the original path as the human-readable `display_name`.
- **`/notebooklm` em-dashes baked into vault output.** The synthesis H1 used `topic — NotebookLM synthesis (date)` and the preamble had mid-sentence em-dashes. The voice rule says no em-dashes anywhere. Both now use a colon and a period-restructure respectively.

## [0.7.0] — 2026-05-13

### Added

- **`bootstrap_vault.py --preset` and `--mode` flags:** wires the preset/mode interface that `SKILL.md` documented but the script never implemented (running `--preset researcher` errored with `unrecognized arguments: --preset researcher --mode personal`). Five presets land at once, matching the existing SKILL.md description verbatim: `default` (preserves existing Life-OS layout — no change in behavior when no flag is passed), `executive` (Decisions/People/Meetings/OKRs · Boards: OKRs/Quarterly/Weekly), `builder` (Projects/Dev Logs/Architecture/Debugging · Boards: Backlog/Sprint/In Progress/Done), `creator` (Content/Ideas/Audience/Publishing · Boards: Ideas/Drafts/Scheduled/Published), `researcher` (Sources/Literature/Hypotheses/Methodology/Synthesis · Boards: Reading/Processing/Synthesized/Done). Each preset declares its folder list, kanban columns, `_CLAUDE.md` folder map, Home dashboard nav, and template extras via a single `PRESETS` dict at the top of the file — adding a new preset is one dict entry plus optional template lines in `write_preset_extras()`. Two modes: `personal` (default — owner-style `_CLAUDE.md`) and `assistant` (uses the `references/claude-md-assistant-template.md` schema, requires `--subject "Name"` and renders the operator/subject distinction). Fully backwards-compatible: `--path`, `--name`, `--jobs`, `--no-sidebiz` keep their meaning under the default preset; `--no-sidebiz` is silently ignored on non-default presets. The vault-not-empty check now ignores `.obsidian/` so re-running on a vault that only has Obsidian config no longer prompts.
- **`/create-command` interview flow (Phase 5):** new meta command that scaffolds a new `commands/<name>.md` through a 9-phase conversation — zero markdown editing. Asks intent, name, category, triggers, behavior steps, AI-first compliance, and external API needs, then writes a fully-formed command file (frontmatter + body + AI-first footer where applicable) using the Write tool. The new file flows automatically into every platform via the existing adapters — no extra build steps. Lowers the contribution bar so anyone can extend the skill, and every command added through this flow lands AI-first-compliant by construction. Listed under `meta` category; total command count is now 32 (was 31).
- **Write-time AI-first validator (Phase 4):** new `hooks/validate-ai-first.sh` runs as a Claude Code `PostToolUse` hook after every `Write` or `Edit` on a markdown file inside `OBSIDIAN_VAULT_PATH`. Warns (non-blocking) when the file fails the AI-first rule: missing frontmatter delimiters, missing required fields (`date`, `type`, `tags`, `ai-first: true`), tabs in YAML, or missing `## For future Claude` preamble. Surfaces specific warnings on stderr so Claude can repair the note in the same turn. Skips `raw/`, `templates/`, `_export/`, `.obsidian/`, `.git/`, `.trash/` and anything outside the vault. Platform-neutral spec at `hooks/validate-ai-first.hook.yaml`. Setup instructions in `SKILL.md` under "Write-Time AI-First Validator (PostToolUse Hook)". This is the **write-time cleanup primitive** that the Second Brain for Companies thesis depends on — humans write inconsistent input, the validator enforces AI-first discipline automatically.
- **Multilingual trigger phrases (Phase 3):** every command now declares `triggers_<lang>:` lines in its frontmatter. English (`triggers_en:`) is populated for all 31 commands; the schema is extensible to any language via `triggers_es:`, `triggers_it:`, `triggers_fr:`, `triggers_de:`, `triggers_pt:`, `triggers_ru:`, `triggers_ja:` (community contributions welcome). The non-Claude dispatchers (`AGENTS.md`, `GEMINI.md`) now include a `## Trigger phrases` section grouped by language then by category, so AI agents on those platforms can match natural-language requests without seeing the slash form. Adapters auto-detect which languages are populated; empty languages do not appear in the output. Documented in `CONTRIBUTING.md` under "Translating trigger phrases (multilingual support)".
- **Command categorization (Phase 2):** each command in `commands/` now declares a `category:` (vault, thinking, research, meta). Non-Claude dispatcher tables in `AGENTS.md` / `GEMINI.md` are now emitted as four grouped sections instead of one 31-row blob. Adapters use the shared `emit_routing_table_grouped` helper in `adapters/lib.sh`, so the categorization carries through automatically when a new command is added. No breaking changes — Claude Code build is still a byte-exact identity copy.
- **Multi-platform adapter pattern (Phase 1):** one source, four platforms.
  - `scripts/build.sh` orchestrator + `scripts/lib.sh` utility helpers
  - `adapters/lib.sh` shared parsing, path rewriting, tool-name neutralization
  - `adapters/claude-code/adapter.sh` — identity copy (Claude Code is the canonical platform)
  - `adapters/codex-cli/adapter.sh` — emits `AGENTS.md` + `.codex/commands/`
  - `adapters/gemini-cli/adapter.sh` — emits `GEMINI.md` + `.gemini/commands/`
  - `adapters/opencode/adapter.sh` — emits `AGENTS.md` + `.opencode/commands/`
  - Auto-generated routing tables (parses each command's `description:` frontmatter)
  - Tool-name neutralization for non-Claude platforms (`Read tool` → `read files`, etc.)
  - Per-platform `exclude:` frontmatter field for opt-outs
  - Build output goes to `dist/<platform>/` (gitignored)
- `CODE_OF_CONDUCT.md` (Contributor Covenant v2.1)
- `CONTRIBUTING.md` with full contributor guide
- `CLAUDE.md` at repo root for contributor-facing operating instructions
- `CHANGELOG.md` (this file)
- `.github/` community files: issue templates, PR template, FUNDING.yml
- `CITATION.cff` for Google Scholar / Zenodo / OpenSSF
- `llms.txt` at repo root for AI crawlers (ChatGPT, Claude, Perplexity)
- FAQ section in README to boost AI-search citation rate
- GitHub Pages site with Cayman theme + jekyll-seo-tag + jekyll-sitemap
- Banner image and polished author hero in README
- `examples/sample-vault/` showing 6 AI-first compliant note types (daily, person, project, idea, devlog, plus `_CLAUDE.md` template)
- `SECURITY.md` — vulnerability reporting policy and coordinated disclosure timeline
- Schema.org JSON-LD `SoftwareApplication` block on the Pages site (`_includes/head_custom.html`) for rich-result eligibility and AI-search citation
- 3 new FAQ entries targeting "Obsidian plugin vs Claude Code skill" search intent

### Changed

- GitHub About description rewritten to lead with "Claude Code skill for Obsidian"
- README banner alt text now contains the full search-intent phrasing
- GitHub topics: swapped `markdown` and `pkm` for `obsidian-skill` and `claude-code-skill`

### Fixed

- **`bootstrap_vault.py` `UnicodeEncodeError` on Windows `cp1252` consoles.** The script's emoji print statements (`🧠 Bootstrapping vault: ...`, `📁 Folders created`, `✅ Vault bootstrapped at: ...`) crashed on Windows before doing any work because the default Python `sys.stdout` encoding on Windows PowerShell / cmd is `cp1252`, which has no codepoints for those characters. `sys.stdout` and `sys.stderr` are now reconfigured to UTF-8 at script start, wrapped in `try/except (AttributeError, ValueError)` so non-text streams or environments without `.reconfigure()` fall back gracefully.
- **Removed dead `--minimal` flag from `bootstrap_vault.py`.** `argparse` accepted `--minimal` but the value was never passed into `bootstrap()` — the flag had no effect for any user since v0.1.0. Removing it changes no behavior.
- `pyproject.toml` version was `0.1.0`, now matches the v0.6.0 release tag.

## [0.6.0] — 2026-04-26

### Added

- `references/ai-first-rules.md` — canonical spec for vault writes (the 7 rules, frontmatter schemas per note type, preamble templates, anti-patterns, audit checklist).

### Changed

- All 31 commands now explicitly reference the AI-first rule. Surgical cross-reference per command file, no body rewrites. Closes the gap where two Claude sessions on the same conversation could produce inconsistently structured notes.
- `references/write-rules.md` now points to `ai-first-rules.md` as the foundation.
- `SKILL.md` — new "AI-first vault rule" section under Core Operating Principles.

### Notes

- 29 files changed, +406 lines, 0 breaking changes. Additive only.

## [0.5.0] — 2026-04-26

### Added

- **Research Toolkit** — five new commands that turn the vault into a live research workspace.
  - `/x-read [url]` — verbatim X post + thread + TL;DR + key claims + reply sentiment (Grok-4 + x_search).
  - `/x-pulse [topic]` — what's hot on X, gaps, working hooks, post ideas (Grok-4.20-reasoning + x_search).
  - `/research [topic]` — web research dossier with citations, recency markers, contrarian views, open questions (Perplexity Sonar Pro).
  - `/research-deep [topic]` — vault-first: scans vault, identifies gaps, fills only those, synthesizes a delta report, propagates updates via `/obsidian-save` (Perplexity sonar-reasoning-pro + Grok + vault scan).
  - `/youtube [url]` — transcript + metadata + top comments, summarized AI-first (youtube-transcript-api + YouTube Data API v3 + Grok-4).
- Section 0 of `_CLAUDE.md` template — first version of the AI-first vault rule, applied to all 5 research commands from day one.
- API key handling at `~/.config/obsidian-second-brain/.env` (Mac-local, never synced).
- `pyproject.toml` + `uv.lock` for Python dependency management.
- Auto-open behavior: every research save pops Obsidian to the new note via `obsidian://open?...`.

### Notes

- Command count went 26 → 31. Same install, same `_CLAUDE.md`.
- Without API keys, the original 26 commands still work — research toolkit degrades gracefully.

[Unreleased]: https://github.com/eugeniughelbur/obsidian-second-brain/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/eugeniughelbur/obsidian-second-brain/releases/tag/v0.6.0
[0.5.0]: https://github.com/eugeniughelbur/obsidian-second-brain/releases/tag/v0.5.0
