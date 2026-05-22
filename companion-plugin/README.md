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

## Building from source

As of v0.2.0 the plugin is written in TypeScript and bundled to `main.js` with esbuild. The committed `main.js` is the build output Obsidian loads — do not edit it by hand. To rebuild after changing anything under `src/`:

```bash
cd ~/dev/mbs_automation/companion-plugin
npm install      # one time, pulls esbuild + typescript + obsidian types (~17 packages)
npm run build    # type-checks with tsc, then bundles src/main.ts -> main.js
npm run dev      # optional: rebuild-on-save watch mode
```

`npm run build` does `tsc -noEmit` (type-check only) followed by the esbuild bundle. `node_modules/` is gitignored; `main.js`, `manifest.json`, `versions.json`, and `styles.css` are committed so Obsidian and BRAT can load the plugin without a build step. After building, copy `main.js` (and `manifest.json`/`styles.css` if they changed) into the vault's plugin folder, or reload via BRAT.

## Install

### Manual (fastest for now)

Copy the three files into the vault's plugins folder, then enable it:

```bash
mkdir -p ~/Vaults/storage_mbs/.obsidian/plugins/mbs-companion
cp ~/dev/mbs_automation/companion-plugin/{manifest.json,main.js,styles.css} ~/Vaults/storage_mbs/.obsidian/plugins/mbs-companion/
```

Then in Obsidian: Settings → Community plugins → reload → enable **MBS Companion**. (If the folder is open in Obsidian, toggle Community plugins off/on or restart Obsidian to pick it up.)

### BRAT (once pushed to GitHub)

Add the repo in BRAT ("Add beta plugin"). BRAT reads `manifest.json` + `main.js` + `versions.json` from the repo root. This plugin currently lives in a subfolder of the skill repo (`companion-plugin/`); for BRAT it must be split into its own repo (e.g. `CP250/obsidian-mbs-companion`) so the manifest is at the repo root. See [RELEASING.md](RELEASING.md) for the exact split / tag / BRAT steps.

## Settings

Vault path, commands dir, `claude` binary path, state dir (run-stamps), and the reviews / session-report folders — all default to this machine's layout; change them if anything moves.

## Status / roadmap

- **v0.1.0** — plain JS, no build step (loads directly). Status bar + open/run commands + settings.
- **v0.2.0** — migrated to TypeScript + esbuild (`src/main.ts` -> `main.js`). Added an inline "Cycle Vault Agent item status" editor command for marking daily-note items done/skip/defer, and an "Open status panel" modal (last-run times from stamps + logs, latest session-report leak count, quick links). `isDesktopOnly` unchanged.
- Later: a reading-view post-processor that renders done/skip/defer as buttons; a persistent side-panel view instead of a modal.
