# MBS Companion (Obsidian plugin)

A small companion plugin for the [`mbs_automation`](https://github.com/CP250/mbs_automation) second-brain skill. It surfaces the scheduled agents inside Obsidian so you don't have to live in the terminal or tail a log file.

Desktop-only (it uses Node's `fs` and `child_process`).

## What it does

**Status bar** — shows whether today's `mbs-daily` and this week's `mbs-weekly` have run, by reading the launchd run-stamps in `~/.mbs_automation/` (`🧠 daily ✓ · wk ✓`). Hover for the exact last-run dates; click to open today's note.

**Commands** (Command Palette, `Cmd-P`):

- **Open today's daily note** — `daily_notes/tasks/tasks_YYYY-MM-DD.md`
- **Open latest weekly review** — newest note in `admin/reviews/`
- **Open latest session-awareness report** — newest note in `admin/obsidian_optimize/session_awareness/`
- **Run daily report now** — runs `/obsidian-daily` headless via `claude -p` (refreshes today's `## Vault Agent` section regardless of the run-stamp)
- **Run health audit now** — runs `/obsidian-health` report-only
- **Refresh agent status** — re-read the stamps now
- **Cycle Vault Agent item status (done | skip | defer)** — with the cursor on a list item (or its `status:`/`reply:` lines) inside today's `## Vault Agent` section, cycles that item's `status:` field through `done -> skip -> defer`. Only operates inside a `## Vault Agent` block; it never touches P's own sections.
- **Open status panel** — opens a modal with last-run times for daily/weekly (stamps + log tails), the latest session-awareness report's leak count, and quick links to the daily note / latest review / latest session report.

The "run now" commands shell out to the `claude` binary (path configurable in settings) with `--dangerously-skip-permissions`, in the vault directory. They take a few minutes; you'll get a notice when each finishes.

**Push settings on quit (v0.3.1)** — when Obsidian quits, the plugin commits and pushes the `.obsidian` settings repo (the multi-machine settings repo). It runs as a *detached background process* and is never awaited, so it cannot block or delay shutdown (that was a v0.3.0 bug — a hanging push wedged the app). It no-ops when there's nothing to commit, refuses to auto-commit a new untracked file that looks like a credential (`token`/`secret`/`key`/`.pem`), and runs git with `GIT_TERMINAL_PROMPT=0` so it fails fast instead of hanging on auth. The commit is local, so a failed push persists and goes out on the next quit. Toggle and git-binary path are in settings; this only touches the `.obsidian` repo, never your notes.

## Building from source

As of v0.2.0 the plugin is written in TypeScript and bundled to `main.js` with esbuild. The committed `main.js` is the build output Obsidian loads — do not edit it by hand. To rebuild after changing anything under `src/`:

```bash
cd ~/dev/obsidian-mbs-companion
npm install      # one time, pulls esbuild + typescript + obsidian types (~17 packages)
npm run build    # type-checks with tsc, then bundles src/main.ts -> main.js
npm run dev      # optional: rebuild-on-save watch mode
```

`npm run build` does `tsc -noEmit` (type-check only) followed by the esbuild bundle. `node_modules/` is gitignored; `main.js`, `manifest.json`, `versions.json`, and `styles.css` are committed so Obsidian and BRAT can load the plugin without a build step. You don't copy files into the vault by hand anymore — tagging a release publishes it and BRAT updates the install (see [RELEASING.md](RELEASING.md)).

## Install

### BRAT (current)

The plugin lives in its own repo, `CP250/obsidian-mbs-companion`, and is installed via BRAT. In Obsidian: command palette → **"BRAT: Add a beta plugin"** → enter `CP250/obsidian-mbs-companion`. BRAT reads `manifest.json` + `main.js` + `versions.json` from the latest GitHub release and installs into `.obsidian/plugins/mbs-companion/`. Enable **MBS Companion** under Community plugins. Updates: **"BRAT: Check for updates"** (or automatically on next launch). This mirrors how `obsidian-ch8-tab` is hosted.

Releases are automated: a GitHub Actions workflow (`.github/workflows/release.yml`) builds the plugin and publishes the release with all three assets on any tag push. See [RELEASING.md](RELEASING.md).

### Manual (fallback)

If you ever need to sideload without BRAT, copy the three files into the vault's plugins folder, then enable it:

```bash
mkdir -p ~/Vaults/storage_mbs/.obsidian/plugins/mbs-companion
cp ~/dev/obsidian-mbs-companion/{manifest.json,main.js,styles.css} ~/Vaults/storage_mbs/.obsidian/plugins/mbs-companion/
```

Then in Obsidian: Settings → Community plugins → reload → enable **MBS Companion**. Don't keep both a manual copy and a BRAT install of the same plugin — pick one to avoid conflicts.

## Settings

Vault path, commands dir, `claude` binary path, state dir (run-stamps), and the reviews / session-report folders — all default to this machine's layout; change them if anything moves.

## Status / roadmap

- **v0.1.0** — plain JS, no build step (loads directly). Status bar + open/run commands + settings.
- **v0.2.0** — migrated to TypeScript + esbuild (`src/main.ts` -> `main.js`). Added an inline "Cycle Vault Agent item status" editor command for marking daily-note items done/skip/defer, and an "Open status panel" modal (last-run times from stamps + logs, latest session-report leak count, quick links). `isDesktopOnly` unchanged. First release published to its own repo (`CP250/obsidian-mbs-companion`) and installed via BRAT (2026-05-22).
- **v0.3.0** — push the `.obsidian` settings repo on Obsidian quit (commit + push, with a credential-file guard). Adds settings: "Push settings on quit" toggle and "Git binary" path. (Superseded by 0.3.1 — the awaited push could hang shutdown.)
- **v0.3.1** — fix: the on-quit push now runs detached and is never awaited, so it can't block or delay Obsidian shutdown; git runs non-interactively (`GIT_TERMINAL_PROMPT=0`) so it fails fast instead of hanging on auth. (Superseded by 0.3.2 — fully-detached produced no commit.)
- **v0.3.2** — fix: commit the settings repo synchronously on quit (fast local op, can't hang shutdown) and detach only the push, so the commit reliably lands even if the background push dies during teardown. Each quit appends a line to `<stateDir>/settings_push.log` for debugging.
- **v0.3.3** — robustness: before committing, the hook removes a *stale* `index.lock` (older than 60s, i.e. left by an interrupted git op) so a leftover lock can't silently block the auto-push; a fresh lock (<60s, possibly a real concurrent git process) is left untouched.
- Later: a reading-view post-processor that renders done/skip/defer as buttons; a persistent side-panel view instead of a modal.
