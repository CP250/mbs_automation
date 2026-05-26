# Daily Auto-Open (Obsidian plugin)

Opens today's daily notes automatically when Obsidian launches — on **desktop and mobile**. Built because the Journals plugin's `openOnStartup` only opens *one* journal, and P runs two (a health journal and a tasks journal).

## What it does

On app launch (after a short delay so the Journals plugin can auto-create today's notes), it opens each configured daily note for today. Options:

- **Open on startup** — open today's notes when Obsidian launches (default on).
- **Pin as tabs** — pin the opened notes so they persist as tabs on desktop / stay open on mobile (default on).
- **Rotate stale tabs** — on open, close *previous days'* daily-note tabs so only today's stay open (default on). Without this, pinned tabs would accumulate one per day.
- **Startup delay (ms)** — how long to wait after launch before opening (default 1200), so the Journals plugin creates today's notes first.
- **Notes opened each day** — a list of `{ folder, filename ({{date}}), dateFormat }`. Defaults match the vault's two journals:
  - `daily_notes/health/daily/daily_note_health_{{date}}`
  - `daily_notes/tasks/tasks_{{date}}`

It only opens notes that **already exist** — it never creates an untemplated note (the Journals plugin owns creation). If a note isn't there yet, it shows a notice and leaves it.

Cross-platform: uses only the Obsidian workspace API (no Node), so it is **not** desktop-only and runs on iPhone.

## Commands

- **Open today's daily notes** — run the open/rotate manually any time.

## Building from source

```bash
cd ~/dev/obsidian-daily-auto-open
npm install
npm run build   # tsc type-check + esbuild bundle -> main.js
```

`main.js` is committed (Obsidian + BRAT load it). Releases are automated by `.github/workflows/release.yml` on tag push. See RELEASING.md.

## Install (BRAT)

Command palette → "BRAT: Add a beta plugin" → `CP250/obsidian-daily-auto-open`. Enable **Daily Auto-Open** under Community plugins.
