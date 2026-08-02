# Releasing Daily Auto-Open

This plugin is developed at `mbs_automation/daily-open-plugin/` (a dev mirror) and published from its own repo, `CP250/obsidian-daily-auto-open`, installed via BRAT. Same pattern as `obsidian-mbs-companion`.

All `git` steps are for **P to run by hand** (P uses HTTPS GitHub auth, not SSH).

## First-time split to its own repo

1. Create an empty private repo `CP250/obsidian-daily-auto-open` on GitHub.
2. Copy the plugin out and push over HTTPS:

   ```bash
   cp -R ~/dev/mbs_automation/daily-open-plugin ~/dev/obsidian-daily-auto-open
   cd ~/dev/obsidian-daily-auto-open
   rm -rf node_modules
   git init
   git add .
   git commit -m "Initial import: Daily Auto-Open v0.1.0"
   git branch -M main
   git remote add origin git@github-cp250:CP250/obsidian-daily-auto-open.git   # github-cp250 = CP250 SSH alias (two-identity setup, 2026-08-02)
   git push -u origin main
   ```

## Cutting a release (automated)

The `.github/workflows/release.yml` builds and publishes on any tag push (no `v` prefix — tag must equal the manifest version).

```bash
git tag 0.1.0
git push origin 0.1.0
```

Watch the Actions tab; when green, the release with `main.js` + `manifest.json` appears. Then BRAT: "Check for updates".

For later versions: edit `src/main.ts`, bump `version` in `manifest.json` + add the key to `versions.json`, `npm run build`, commit, then tag + push the new version.
