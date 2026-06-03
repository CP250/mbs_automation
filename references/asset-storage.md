# Asset Storage — Binaries Outside the Vault

Canonical convention for storing large binary files (PDFs, scans, images, audio, video, datasets) that support vault notes. Authored 2026-06-02 in response to a real binary need (P's backgammon library, 538 MB before dedupe, 272 MB after).

## The premise

The vault is **markdown-only**. Binaries don't belong in it.

- Obsidian Sync has per-file size limits and bandwidth quotas; large binaries chew through both.
- Vault startup and indexing slow with binary bloat.
- A git-tracked vault becomes unwieldy at scale with binaries.
- Mobile Obsidian downloading multi-MB PDFs over cellular is a bad user experience.

Binaries live in a parallel asset folder that mirrors the vault's directory structure. The vault note describes the thing; the asset folder holds the bytes.

## The asset folder

**Location:** `~/<vault-name>_assets/` — a sibling of the vault, NOT inside it.

For P's `storage_mbs` vault, this is `~/storage_mbs_assets/`. The folder is local-only by intent; Time Machine or equivalent must cover it. No iCloud, no Obsidian Sync.

**Never symlink the asset folder into the vault.** Obsidian indexes the contents of any symlinked folder it sees, which recreates the exact problem this convention avoids.

## Mirror rule

Vault note path → asset folder path is one-to-one:

| Vault note | Asset folder |
|---|---|
| `skills/backgammon/project_backgammon_plan.md` | `~/storage_mbs_assets/skills/backgammon/` |
| `<pillar>/project_<slug>/project_<slug>.md` | `~/storage_mbs_assets/<pillar>/<slug>/` |
| `<pillar>/<sub>/project_<slug>.md` | `~/storage_mbs_assets/<pillar>/<sub>/<slug>/` |
| `social/friends/people/<name>.md` (with scans) | `~/storage_mbs_assets/social/friends/people/<name>/` |
| `culture/read/ref_<slug>.md` (with photos) | `~/storage_mbs_assets/culture/read/<slug>/` |

Slug derivation for project notes: drop the `project_` prefix, drop the `.md` extension. For non-project notes, the slug is the basename without extension.

## On-demand creation

**Do not pre-mirror the entire vault.** Most vault notes never need binary backing. Create the asset subfolder only the first time a vault note actually needs binaries.

This keeps the tree honest: anything present in `~/storage_mbs_assets/<path>/` has real files in it.

## Filename convention inside asset folders

`<author_lastname>_<title_in_lowercase_underscores>.<ext>`

Examples:
- `magriel_backgammon.pdf`
- `robertie_501_problems.pdf`
- `lamford_improve_your_backgammon.pdf`

Sortable by author. No z-library/site suffixes, no leading `!`, no ISBN-only filenames, no spaces, no decorative punctuation.

If no clear author (cookbooks, scanned receipts, photos), use a descriptive snake_case name. For dated documents (statements, correspondence, contracts), prepend `YYYY-MM-DD_`: `2026-q3_polar_statement.pdf`, `2025-08-17_lease_amendment.pdf`.

## Vault frontmatter pointer

The vault note records its asset path in frontmatter:

```yaml
asset_path: "~/storage_mbs_assets/skills/backgammon/"
```

This makes the link explicit and discoverable — future-Claude searching the note finds the path without having to derive it from the vault location. Adding `asset_path:` is the structural signal that "this note has binary backing."

## Inline references from vault notes

Markdown link, absolute path:

```markdown
See [Magriel's foundations](file:///Users/cpreston/storage_mbs_assets/skills/backgammon/magriel_backgammon.pdf).
```

Obsidian won't preview the PDF and that's intended — a 50 MB PDF inline is wrong. If you need a quick visual, drop a thumbnail or screenshot inside the vault's `attachments/` and place it next to the `file://` link.

Don't use Obsidian wikilink syntax (`![[file.pdf]]`) for external assets — it only resolves for in-vault files.

## Cowork mount

When a Cowork session needs the binaries, mount `~/storage_mbs_assets/` as a folder alongside the vault and `mbs_automation`. Always mount the whole tree; per-session subtree mounting isn't worth the friction. Cowork agents are scoped by prompt, not by mount.

## Cleanup pattern: !delete/ subfolder

For staged removal during dedupe or cleanup, move losing files to a `!delete/` subfolder within the asset folder. The leading `!` ensures it sorts to the top in Finder. This preserves an audit trail before permanent deletion — P or future-Claude reviews `!delete/` contents and removes them when confident.

## Anti-patterns

| Don't | Why |
|---|---|
| Put binaries in the vault | Sync bloat, indexing slow, git unworkable |
| Symlink the asset folder into the vault | Same effect as putting them inside |
| Pre-create empty mirror folders | Cruft; misleads future-Claude into thinking the convention applies where it doesn't |
| Use Obsidian wikilinks for external assets | Only resolves for in-vault paths |
| ISBN-only or hash-only filenames | Unreadable; defeats the convention |
| Skip the `asset_path:` frontmatter | The binary backing becomes invisible to vault-side search |
| Trust iCloud or Obsidian Sync for backup | The asset folder is local-only; backup is the user's responsibility |
