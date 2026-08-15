#!/usr/bin/env python3
"""
move_binaries.py - Migrate vault binary files to ~/storage_mbs_assets/

Usage:
  python3 /Users/cpreston/Vaults/storage_mbs/admin/mbs_system/move_binaries.py            # live run
  python3 /Users/cpreston/Vaults/storage_mbs/admin/mbs_system/move_binaries.py --dry-run  # preview only

What it does:
  1. Finds every binary file (pdf, png, jpg, jpeg, gif, svg, webp, mp3,
     mp4, wav, mov, avi, zip, docx, xlsx, pptx, sketch, fig, epub,
     html, ics) in the vault.
  2. Moves each file to a mirrored path under ~/storage_mbs_assets/,
     preserving the full directory structure.
  3. Updates all .md files in the vault:
       - ![[image.ext]]         → ![](file:///path/to/image.ext)
       - ![alt](relative.ext)  → ![alt](file:///path/to/image.ext)
       - [[binary.ext]]        → [binary.ext](file:///path/to/binary.ext)
  4. Adds  asset_path: <dir>  to frontmatter of project_*.md / goals_*.md
     files whose adjacent binaries were moved - only if those notes already
     have a frontmatter block.
  5. Writes a full migration log to:
       admin/mbs_system/brain/log_binary_migration.md
"""

import os
import re
import shutil
import sys
import datetime
from pathlib import Path
from collections import defaultdict

# ── Config ────────────────────────────────────────────────────────────────────

VAULT  = Path("/Users/cpreston/Vaults/storage_mbs")
ASSETS = Path("/Users/cpreston/storage_mbs_assets")
LOG    = VAULT / "admin/mbs_system/brain/log_binary_migration.md"

BINARY_EXTS = frozenset({
    ".pdf", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp",
    ".mp3", ".mp4", ".wav", ".mov", ".avi", ".zip",
    ".docx", ".xlsx", ".pptx", ".sketch", ".fig",
    ".epub", ".html", ".ics",
})

SKIP_DIRS = {".obsidian", ".git"}

DRY_RUN = "--dry-run" in sys.argv

# ── State ─────────────────────────────────────────────────────────────────────

moved:  dict[Path, Path] = {}  # vault_src → assets_target
errors: list[str]        = []

# ── Step 1: Move binaries ─────────────────────────────────────────────────────

def collect_binaries() -> list[Path]:
    result = []
    for root, dirs, files in os.walk(VAULT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            p = Path(root) / f
            if p.suffix.lower() in BINARY_EXTS:
                result.append(p)
    return sorted(result)


def move_file(src: Path) -> Path | None:
    rel    = src.relative_to(VAULT)
    target = ASSETS / rel
    if DRY_RUN:
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.move(str(src), str(target))
        return target
    except Exception as e:
        errors.append(f"MOVE FAILED {rel}: {e}")
        return None

# ── Step 2: Lookup index ──────────────────────────────────────────────────────

def build_index() -> dict[str, list[tuple[Path, Path]]]:
    """basename (lowercase) → [(vault_src, assets_target), ...]"""
    idx: dict[str, list[tuple[Path, Path]]] = defaultdict(list)
    for src, tgt in moved.items():
        idx[src.name.lower()].append((src, tgt))
    return idx


def resolve(basename: str, note_dir: Path, idx: dict) -> Path | None:
    """Return the assets target most likely referenced by this basename."""
    cands = idx.get(basename.lower(), [])
    if not cands:
        return None
    if len(cands) == 1:
        return cands[0][1]
    # Prefer candidate whose source was in the same dir as the note
    for src, tgt in cands:
        if src.parent == note_dir:
            return tgt
    # Prefer candidate whose source was in a subdir of the note's dir
    for src, tgt in cands:
        try:
            src.relative_to(note_dir)
            return tgt
        except ValueError:
            pass
    # Fall back to first
    return cands[0][1]

# ── Step 3: Update markdown references ────────────────────────────────────────

RE_WIKIEMBED = re.compile(r'!\[\[([^\]]+?)\]\]')
RE_MDIMAGE   = re.compile(r'!\[([^\]]*)\]\(([^)\n]+?)\)')
RE_WIKILINK  = re.compile(r'(?<!!)\[\[([^\]]+?)\]\]')


def furl(p: Path) -> str:
    return f"file://{p}"


def process_md(path: Path, idx: dict) -> bool:
    """Update binary references in a markdown file. Returns True if changed."""
    try:
        text = path.read_text(encoding="utf-8")
    except Exception as e:
        errors.append(f"READ {path.relative_to(VAULT)}: {e}")
        return False

    note_dir = path.parent
    original = text

    # 1. ![[image.ext]] or ![[image.ext|alt]]
    def sub_wikiembed(m):
        inner    = m.group(1).split("|")[0].strip()
        basename = Path(inner).name
        if Path(basename).suffix.lower() not in BINARY_EXTS:
            return m.group(0)
        tgt = resolve(basename, note_dir, idx)
        return f"![]({furl(tgt)})" if tgt else m.group(0)

    text = RE_WIKIEMBED.sub(sub_wikiembed, text)

    # 2. ![alt](relative/path.ext)
    def sub_mdimage(m):
        alt  = m.group(1)
        href = m.group(2).strip()
        if href.startswith(("http", "file://")):
            return m.group(0)
        # Try absolute resolution via relative path from note location
        try:
            abs_src = (note_dir / href).resolve()
            if abs_src in moved:
                return f"![{alt}]({furl(moved[abs_src])})"
        except Exception:
            pass
        # Fallback: basename match
        basename = Path(href).name
        if Path(basename).suffix.lower() not in BINARY_EXTS:
            return m.group(0)
        tgt = resolve(basename, note_dir, idx)
        return f"![{alt}]({furl(tgt)})" if tgt else m.group(0)

    text = RE_MDIMAGE.sub(sub_mdimage, text)

    # 3. [[binary.ext]] plain wikilinks (non-embed) → markdown links
    def sub_wikilink(m):
        parts    = m.group(1).split("|")
        inner    = parts[0].strip()
        label    = parts[-1].strip()
        basename = Path(inner).name
        if Path(basename).suffix.lower() not in BINARY_EXTS:
            return m.group(0)
        tgt = resolve(basename, note_dir, idx)
        return f"[{label}]({furl(tgt)})" if tgt else m.group(0)

    text = RE_WIKILINK.sub(sub_wikilink, text)

    if text == original:
        return False

    if not DRY_RUN:
        try:
            path.write_text(text, encoding="utf-8")
        except Exception as e:
            errors.append(f"WRITE {path.relative_to(VAULT)}: {e}")
            return False

    return True

# ── Step 4: asset_path frontmatter ────────────────────────────────────────────

def maybe_add_asset_path(path: Path):
    name = path.name
    if not (name.startswith("project_") or name.startswith("goals_")):
        return

    note_dir = path.parent
    asset_dirs: set[Path] = set()

    for src, tgt in moved.items():
        try:
            rel = src.relative_to(note_dir)
            # Binary was directly in same dir, or one level under attachments/assets/
            if len(rel.parts) == 1:
                asset_dirs.add(ASSETS / note_dir.relative_to(VAULT))
            elif len(rel.parts) == 2:
                asset_dirs.add(ASSETS / note_dir.relative_to(VAULT) / rel.parts[0])
        except ValueError:
            pass

    if not asset_dirs:
        return

    try:
        content = path.read_text(encoding="utf-8")
    except Exception:
        return

    if not content.startswith("---"):
        return  # no frontmatter block - skip

    end = content.find("\n---", 3)
    if end == -1:
        return

    if "asset_path:" in content[:end]:
        return  # already has it

    primary    = sorted(str(d) for d in asset_dirs)[0]
    new_content = content[:end] + f"\nasset_path: {primary}" + content[end:]

    if not DRY_RUN:
        try:
            path.write_text(new_content, encoding="utf-8")
        except Exception as e:
            errors.append(f"FM WRITE {path.relative_to(VAULT)}: {e}")
            return

    print(f"  [frontmatter] {path.relative_to(VAULT)}")

# ── Step 5: Write log ─────────────────────────────────────────────────────────

def write_log():
    date  = datetime.date.today().isoformat()
    lines = [
        "# Binary Migration Log\n\n",
        f"- **Date:** {date}\n",
        f"- **Mode:** {'dry-run (no changes made)' if DRY_RUN else 'live'}\n",
        f"- **Files moved:** {len(moved)}\n",
        f"- **Errors:** {len(errors)}\n\n",
        "## Moved Files\n\n",
    ]
    for src in sorted(moved):
        lines.append(f"- `{src.relative_to(VAULT)}` → `{moved[src]}`\n")
    if errors:
        lines += ["\n## Errors\n\n"] + [f"- {e}\n" for e in errors]
    if not DRY_RUN:
        LOG.write_text("".join(lines), encoding="utf-8")
        print(f"  Log written → {LOG}")
    else:
        print("  (dry run: log not written to disk)")

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    print(f"Vault : {VAULT}")
    print(f"Assets: {ASSETS}")
    print(f"Mode  : {'DRY RUN - no files will be changed' if DRY_RUN else 'LIVE'}")
    print()

    # 1. Move
    print("── Step 1: Moving binary files ──────────────────────────────────")
    if not DRY_RUN:
        ASSETS.mkdir(parents=True, exist_ok=True)
    binaries = collect_binaries()
    print(f"  Found {len(binaries)} binary files")
    for src in binaries:
        tgt = move_file(src)
        if tgt is not None:
            moved[src] = tgt
    print(f"  Moved {len(moved)}, errors so far: {len(errors)}")
    print()

    # 2. Index
    idx = build_index()

    # 3. Update links
    print("── Step 3: Updating markdown references ─────────────────────────")
    updated = 0
    for root, dirs, files in os.walk(VAULT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if f.endswith(".md"):
                p = Path(root) / f
                if process_md(p, idx):
                    updated += 1
                    print(f"  [links] {p.relative_to(VAULT)}")
    print(f"  Updated {updated} markdown files")
    print()

    # 4. Frontmatter
    print("── Step 4: Adding asset_path: frontmatter ───────────────────────")
    for root, dirs, files in os.walk(VAULT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if f.endswith(".md"):
                maybe_add_asset_path(Path(root) / f)
    print()

    # 5. Log
    print("── Step 5: Writing migration log ────────────────────────────────")
    write_log()
    print()

    print(f"{'DRY RUN complete.' if DRY_RUN else 'Migration complete.'}")
    if errors:
        print(f"\n⚠ ERRORS ({len(errors)}):")
        for e in errors:
            print(f"  {e}")
    else:
        print("✓ No errors.")


if __name__ == "__main__":
    main()
