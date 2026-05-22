# Releasing MBS Companion

This plugin currently lives inside the `mbs_automation` skill repo at
`companion-plugin/`. BRAT and the Obsidian community-plugin ecosystem expect
`manifest.json` + `main.js` + `versions.json` at the **root** of a dedicated
repo, so before publishing it has to be split out to its own repo
(`CP250/obsidian-mbs-companion`). This file is the runbook for that.

All `git` steps below are for **P to run by hand** — Claude does not run git in
this project.

## What ships in the standalone repo

These files (the contents of `companion-plugin/`) become the root of the new repo:

- `manifest.json` — id `mbs-companion`, version `0.2.0`, `isDesktopOnly: true`
- `main.js` — the build OUTPUT (Obsidian + BRAT load this directly)
- `versions.json` — minAppVersion map (`0.1.0` and `0.2.0` both -> `1.4.0`)
- `styles.css`
- `src/main.ts` — the TypeScript source
- `package.json`, `tsconfig.json`, `esbuild.config.mjs` — the build toolchain
- `.gitignore`, `README.md`, `RELEASING.md`

`node_modules/` is gitignored and is never committed.

## Option A — fresh repo (simplest, recommended for a clean start)

1. Create an empty repo `CP250/obsidian-mbs-companion` on GitHub (no README, so
   history is clean).
2. From the skill checkout, copy the plugin folder out to a new location and
   init it:

   ```bash
   cp -R ~/dev/mbs_automation/companion-plugin ~/dev/obsidian-mbs-companion
   cd ~/dev/obsidian-mbs-companion
   rm -rf node_modules        # belt-and-suspenders; .gitignore already excludes it
   git init
   git add .
   git commit -m "Initial import: MBS Companion v0.2.0 (split from mbs_automation)"
   git branch -M main
   git remote add origin git@github.com:CP250/obsidian-mbs-companion.git
   git push -u origin main
   ```

3. Confirm `main.js` is committed (BRAT needs it) and that a fresh
   `npm install && npm run build` reproduces it.

## Option B — git subtree split (preserves history)

If you want the plugin's git history carried over from the skill repo:

```bash
cd ~/dev/mbs_automation
# Produce a branch whose root is companion-plugin/ with full history:
git subtree split --prefix=companion-plugin -b mbs-companion-split

# Push that branch to the new (empty) GitHub repo as main:
git push git@github.com:CP250/obsidian-mbs-companion.git mbs-companion-split:main

# Optional: delete the temp branch
git branch -D mbs-companion-split
```

Then clone the new repo somewhere fresh to work on it going forward. Note:
subtree split carries whatever was committed historically — if `main.js` or
`node_modules` were ever committed under `companion-plugin/`, scrub them in the
new repo after splitting.

## Cutting a release (in the standalone repo)

1. Make sure `manifest.json` `version` and the matching key in `versions.json`
   are both set (currently `0.2.0`).
2. Build and verify:

   ```bash
   npm install
   npm run build
   node --check main.js     # must pass
   ```

3. Commit the rebuilt `main.js` if it changed.
4. Tag the release. **The git tag must equal the manifest version with NO `v`
   prefix** (Obsidian/BRAT convention):

   ```bash
   git tag 0.2.0
   git push origin 0.2.0
   ```

5. Create a GitHub Release on that tag and attach `manifest.json`, `main.js`,
   and `styles.css` as release binaries (BRAT can read either the tag or the
   release assets; attaching them is the most robust).

## Installing via BRAT

In Obsidian: BRAT -> "Add beta plugin" -> enter `CP250/obsidian-mbs-companion`.
BRAT pulls `manifest.json` + `main.js` + `versions.json` from the latest release
(or the repo root) and installs it. Enable **MBS Companion** under Community
plugins. To update later, BRAT -> "Check for updates".

## After the split

The copy under `mbs_automation/companion-plugin/` can stay as the development
source, or be removed once the standalone repo is the source of truth. If you
keep both, only edit one of them to avoid drift.
