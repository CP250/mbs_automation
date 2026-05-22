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

The "run now" commands shell out to the `claude` binary (path configurable in settings) with `--dangerously-skip-permissions`, in the vault directory. They take a few minutes; you'll get a notice when each finishes.

## Install

### Manual (fastest for now)

Copy the three files into the vault's plugins folder, then enable it:

```bash
mkdir -p ~/Vaults/storage_mbs/.obsidian/plugins/mbs-companion
cp ~/dev/mbs_automation/companion-plugin/{manifest.json,main.js,styles.css} ~/Vaults/storage_mbs/.obsidian/plugins/mbs-companion/
```

Then in Obsidian: Settings → Community plugins → reload → enable **MBS Companion**. (If the folder is open in Obsidian, toggle Community plugins off/on or restart Obsidian to pick it up.)

### BRAT (once pushed to GitHub)

Add the repo in BRAT ("Add beta plugin"). BRAT reads `manifest.json` + `main.js` + `versions.json` from the repo. This plugin currently lives in a subfolder of the skill repo (`companion-plugin/`); for BRAT it should be split into its own repo (e.g. `CP250/obsidian-mbs-companion`) so the manifest is at the repo root.

## Settings

Vault path, commands dir, `claude` binary path, state dir (run-stamps), and the reviews / session-report folders — all default to this machine's layout; change them if anything moves.

## Status / roadmap

- **v0.1.0** — plain JS, no build step (loads directly). Status bar + open/run commands + settings.
- Later: migrate to TypeScript + esbuild (proper plugin toolchain); a richer status panel; inline "reply" affordances for the daily note's `## Vault Agent` items so you can mark done/skip/defer without hand-editing.
