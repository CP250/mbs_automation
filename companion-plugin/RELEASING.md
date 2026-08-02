# Releasing MBS Companion

**Status (2026-05-22): the split is done.** The plugin now lives in its own
GitHub repo, `CP250/obsidian-mbs-companion`, and is installed and auto-updated
via BRAT. Releases are automated by a GitHub Actions workflow. This file is the
runbook for cutting future releases and, for reference, how the split was done.

The `mbs_automation/companion-plugin/` folder is a development mirror. The
standalone repo `~/dev/obsidian-mbs-companion` is the source of truth — edit one
copy only, to avoid drift.

All `git` steps are for **P to run by hand** — Claude does not run git in this
project.

## What ships in the standalone repo

These files are at the root of the repo:

- `manifest.json` — id `mbs-companion`, version `0.2.0`, `isDesktopOnly: true`
- `main.js` — the build OUTPUT (Obsidian + BRAT load this directly)
- `versions.json` — minAppVersion map (`0.1.0` and `0.2.0` both -> `1.4.0`)
- `styles.css`
- `src/main.ts` — the TypeScript source
- `package.json`, `tsconfig.json`, `esbuild.config.mjs` — the build toolchain
- `.github/workflows/release.yml` — the release automation (see below)
- `.gitignore`, `README.md`, `RELEASING.md`

`node_modules/` is gitignored and is never committed.

## Cutting a release (the normal path — automated)

Releases are published by `.github/workflows/release.yml`. On any **tag push**
it checks out the repo, runs `npm install && npm run build`, verifies `main.js`,
then creates the GitHub Release and attaches `main.js`, `manifest.json`, and
`styles.css` automatically. You never touch the Releases UI.

1. Make the change in `src/main.ts`, then build and verify locally:

   ```bash
   cd ~/dev/obsidian-mbs-companion
   npm install
   npm run build
   node --check main.js     # must pass
   ```

2. Bump the version in **both** `manifest.json` (`version`) and `versions.json`
   (add a `"0.X.0": "1.4.0"` key). Commit the rebuilt `main.js` and the bumps:

   ```bash
   git add -A
   git commit -m "Release 0.X.0"
   git push
   ```

3. Tag and push. **The tag must equal the manifest version with NO `v` prefix**
   (Obsidian/BRAT convention). Tag the commit that contains the version bump:

   ```bash
   git tag 0.X.0
   git push origin 0.X.0
   ```

4. Watch the **Actions** tab. The "Release Obsidian plugin" run goes green in
   ~1 min and the release appears under Releases with all three assets attached.

   If you ever need to re-point a tag (e.g. it was created on the wrong commit):

   ```bash
   git tag -d 0.X.0
   git push origin :refs/tags/0.X.0
   git tag 0.X.0
   git push origin 0.X.0
   ```

That's it — BRAT picks up the new release on next Obsidian launch (or via
"BRAT: Check for updates").

## Installing / updating via BRAT (done; for reference)

In Obsidian: command palette -> "BRAT: Add a beta plugin" -> enter
`CP250/obsidian-mbs-companion`. BRAT pulls `manifest.json` + `main.js` +
`versions.json` from the latest release and installs into
`.obsidian/plugins/mbs-companion/`. Enable **MBS Companion** under Community
plugins. To update later: "BRAT: Check for updates".

Note: if a hand-copied install of the plugin already exists in the vault,
disable it and `rm -rf` the `.obsidian/plugins/mbs-companion/` folder before the
BRAT add, so BRAT does a clean install and owns the folder.

## How the split was done (history, 2026-05-22)

Fresh repo, copied the dev folder out and pushed over HTTPS (P's GitHub auth is
HTTPS, not SSH):

```bash
cp -R ~/dev/mbs_automation/companion-plugin ~/dev/obsidian-mbs-companion
cd ~/dev/obsidian-mbs-companion
rm -rf node_modules
git init
git add .
git commit -m "Initial import: MBS Companion v0.2.0 (split from mbs_automation)"
git branch -M main
git remote add origin git@github-cp250:CP250/obsidian-mbs-companion.git   # github-cp250 = CP250 SSH alias (two-identity setup, 2026-08-02)
git push -u origin main
```

The release workflow was added in a follow-up commit; the first `0.2.0` tag had
been created on the pre-workflow commit, so it was deleted and re-tagged on the
workflow commit to make the Action fire (see the re-point snippet above).

If you ever want the plugin's prior git history carried over instead of a fresh
import, use `git subtree split --prefix=companion-plugin` from the skill repo.
