#!/usr/bin/env python3
"""
music_dedup.py - Music library dedup + format audit

TASK 1 (cross-library duplicates)
    Finds albums in both /Volumes/music/redacted and /Volumes/music/what that
    contain the identical set of audio files (matched by SHA-256 checksum,
    regardless of filename or folder name). In dry-run mode (default) it just
    reports. With --move it physically moves the 'what' copy to !!delete/.

TASK 2 (MP3 inventory)
    Lists every album folder that contains MP3 files, flagging any that also
    have a FLAC counterpart in either library (matched by artist+album tags).
    No files are moved; this is a report for manual review.

PERFORMANCE
    Checksums are cached in .music_dedup_cache.json next to this script.
    Re-runs skip files whose mtime and size haven't changed, so the full scan
    only happens once per file.

USAGE
    pip install mutagen                    # one-time
    python3 music_dedup.py                 # dry run
    python3 music_dedup.py --move          # move confirmed dupes from what/ to !!delete/
    python3 music_dedup.py --clear-cache   # wipe checksum cache and rescan everything
    python3 music_dedup.py --task 1        # run only the duplicate scan
    python3 music_dedup.py --task 2        # run only the MP3 inventory

REQUIREMENTS
    Python 3.10+, mutagen
"""

import argparse
import hashlib
import json
import os
import shutil
import sys
import time
from collections import defaultdict
from pathlib import Path

try:
    from mutagen import File as MFile
except ImportError:
    sys.exit("ERROR: mutagen is not installed. Run: pip3 install mutagen")

# ── configuration ─────────────────────────────────────────────────────────────

REDACTED = Path("/Volumes/music/redacted")
WHAT     = Path("/Volumes/music/what")
DELETE   = Path("/Volumes/music/!!delete")

AUDIO_EXT = {".flac", ".mp3", ".wav", ".aif", ".aiff", ".m4a",
             ".ogg", ".opus", ".ape", ".wv", ".alac"}

SCRIPT_DIR  = Path(__file__).parent
CACHE_FILE  = SCRIPT_DIR / ".music_dedup_cache.json"
REPORT_FILE = SCRIPT_DIR / "music_dedup_report.json"

# ── checksum cache ────────────────────────────────────────────────────────────

def load_cache() -> dict:
    if CACHE_FILE.exists():
        try:
            return json.loads(CACHE_FILE.read_text())
        except Exception:
            pass
    return {}

def save_cache(cache: dict) -> None:
    CACHE_FILE.write_text(json.dumps(cache, indent=2))

def sha256_cached(path: Path, cache: dict) -> str:
    """Return SHA-256 hex for path, using/updating cache keyed by (path, mtime, size)."""
    stat = path.stat()
    key  = f"{path}|{stat.st_mtime}|{stat.st_size}"
    if key not in cache:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            while chunk := f.read(1 << 20):   # 1 MB chunks
                h.update(chunk)
        cache[key] = h.hexdigest()
    return cache[key]

# ── filesystem helpers ────────────────────────────────────────────────────────

def audio_files_in(folder: Path) -> list[Path]:
    """All audio files directly inside folder (non-recursive)."""
    return sorted(
        f for f in folder.iterdir()
        if f.is_file() and f.suffix.lower() in AUDIO_EXT
    )

def find_album_dirs(root: Path, max_depth: int = 2) -> list[Path]:
    """
    Return directories (never root itself) that directly contain audio files,
    searching up to max_depth levels below root. Handles both flat
    (root/album/) and nested (root/artist/album/) layouts.
    """
    results = []
    # Always start from root's children (depth 1) - never treat root as an album
    try:
        initial = [(d, 1) for d in sorted(root.iterdir()) if d.is_dir()]
    except PermissionError:
        return []
    stack = initial
    while stack:
        current, depth = stack.pop()
        try:
            entries = list(current.iterdir())
        except PermissionError:
            continue
        subdirs   = [e for e in entries if e.is_dir()]
        has_audio = any(e.is_file() and e.suffix.lower() in AUDIO_EXT for e in entries)
        if has_audio:
            results.append(current)
        elif depth < max_depth:
            stack.extend((d, depth + 1) for d in subdirs)
    return sorted(results)

def album_fingerprint(folder: Path, cache: dict, total: list) -> frozenset | None:
    """
    SHA-256 fingerprint = frozenset of checksums of all audio files in folder.
    Returns None if folder has no audio files.
    Mutates total[0] (a counter) for progress display.
    """
    files = audio_files_in(folder)
    if not files:
        return None
    hashes = set()
    for f in files:
        hashes.add(sha256_cached(f, cache))
        total[0] += 1
        print(f"\r  files hashed: {total[0]}", end="", flush=True)
    return frozenset(hashes)

# ── tag helpers ───────────────────────────────────────────────────────────────

def _read_tag(path: Path, keys: list[str]) -> str:
    try:
        m = MFile(path, easy=True)
        if m:
            for k in keys:
                if k in m and m[k]:
                    return str(m[k][0]).strip().lower()
    except Exception:
        pass
    return ""

def album_identity(folder: Path) -> tuple[str, str] | None:
    """
    Read artist + album tags from the first audio file with usable metadata.
    Returns (artist, album) normalised to lowercase, or None.
    """
    for f in audio_files_in(folder):
        artist = _read_tag(f, ["albumartist", "artist"])
        album  = _read_tag(f, ["album"])
        if artist and album:
            return (artist, album)
    return None

def dominant_format(folder: Path) -> str:
    """'flac' | 'mp3' | 'mixed' | 'unknown'"""
    exts = {f.suffix.lower() for f in audio_files_in(folder)}
    if not exts:
        return "unknown"
    if exts <= {".flac"}:
        return "flac"
    if exts <= {".mp3"}:
        return "mp3"
    return "mixed"

# ── task 1: cross-library duplicates ─────────────────────────────────────────

def task1_cross_library_dupes(cache: dict, do_move: bool) -> list[dict]:
    """
    Find albums that exist in both redacted/ and what/ with identical audio
    content. Returns list of dupe records for the report.
    """
    print("\n══ TASK 1: Cross-library duplicate scan ══\n")

    redacted_dirs = find_album_dirs(REDACTED)
    what_dirs     = find_album_dirs(WHAT)
    print(f"  redacted/ albums found : {len(redacted_dirs)}")
    print(f"  what/     albums found : {len(what_dirs)}\n")

    total = [0]

    # Index redacted by fingerprint
    print("Hashing redacted/ …")
    redacted_index: dict[frozenset, Path] = {}
    for folder in redacted_dirs:
        fp = album_fingerprint(folder, cache, total)
        if fp:
            redacted_index[fp] = folder
    print(f"\n  Done. {len(redacted_index)} albums indexed.\n")

    # Match against what/
    print("Hashing what/ and matching …")
    dupes = []
    for folder in what_dirs:
        fp = album_fingerprint(folder, cache, total)
        if fp and fp in redacted_index:
            dupes.append({
                "what_path":     str(folder),
                "redacted_path": str(redacted_index[fp]),
            })
    print(f"\n  Total files hashed: {total[0]}")
    print(f"  Duplicates found  : {len(dupes)}\n")

    # Report + optional move
    if not dupes:
        print("  ✓ No cross-library duplicates.\n")
        return dupes

    action_word = "MOVING" if do_move else "WOULD MOVE"
    if do_move:
        DELETE.mkdir(parents=True, exist_ok=True)

    print(f"  {'─'*66}")
    for d in dupes:
        what_path     = Path(d["what_path"])
        redacted_path = Path(d["redacted_path"])
        print(f"\n  {action_word}: what/{what_path.name}")
        print(f"    ↳ matches redacted/{redacted_path.name}")
        if do_move:
            dest = DELETE / what_path.name
            if dest.exists():
                dest = DELETE / (what_path.name + "__dupe_" + str(int(time.time())))
            shutil.move(str(what_path), str(dest))
            d["moved_to"] = str(dest)
            print(f"    ✓ Moved → !!delete/{dest.name}")

    return dupes

# ── task 2: mp3 inventory ─────────────────────────────────────────────────────

def task2_mp3_inventory() -> dict:
    """
    Scan both libraries for album folders containing MP3 files.
    Group by (artist, album) identity tags to surface FLAC+MP3 pairs.
    Returns report dict.
    """
    print("\n══ TASK 2: MP3 format inventory ══\n")

    all_dirs = (
        [(d, "redacted") for d in find_album_dirs(REDACTED)] +
        [(d, "what")     for d in find_album_dirs(WHAT)]
    )
    print(f"  Scanning {len(all_dirs)} album folders for tags …\n")

    by_identity: dict[tuple, list] = defaultdict(list)
    untagged_mp3s = []

    for i, (folder, lib) in enumerate(all_dirs, 1):
        print(f"\r  {i}/{len(all_dirs)}", end="", flush=True)
        fmt = dominant_format(folder)
        if fmt == "unknown":
            continue
        identity = album_identity(folder)
        entry = {
            "path":    str(folder),
            "name":    folder.name,
            "library": lib,
            "format":  fmt,
        }
        if identity:
            by_identity[identity].append(entry)
        elif fmt in ("mp3", "mixed"):
            untagged_mp3s.append(entry)

    print(f"\n  Tag scan complete.\n")

    # Build MP3 report
    mp3_pairs = []   # albums with both FLAC and MP3
    mp3_only  = []   # albums with MP3 only (no FLAC counterpart found)

    for (artist, album), entries in sorted(by_identity.items()):
        formats  = {e["format"] for e in entries}
        has_flac = "flac" in formats
        has_mp3  = any(f in ("mp3", "mixed") for f in formats)
        if not has_mp3:
            continue
        record = {
            "artist":           artist,
            "album":            album,
            "has_flac_version": has_flac,
            "entries":          entries,
        }
        if has_flac:
            mp3_pairs.append(record)
        else:
            mp3_only.append(record)

    # Print results
    def _print_records(records: list, label: str) -> None:
        print(f"  {label} ({len(records)}):")
        if not records:
            print("    (none)\n")
            return
        for r in records:
            print(f"\n    {r['artist']} / {r['album']}")
            for e in r["entries"]:
                print(f"      [{e['format'].upper():5s}] [{e['library']:8s}] {e['name']}")
        print()

    print(f"  {'─'*66}")
    _print_records(mp3_pairs, "Albums with BOTH FLAC and MP3  ← safe to delete MP3")
    _print_records(mp3_only,  "Albums with MP3 only (no FLAC found)")

    if untagged_mp3s:
        print(f"  MP3 folders with no readable tags ({len(untagged_mp3s)}):")
        for e in untagged_mp3s:
            print(f"    [{e['library']:8s}] {e['name']}")
        print()

    return {
        "mp3_with_flac_counterpart": mp3_pairs,
        "mp3_only":                  mp3_only,
        "untagged_mp3_folders":      untagged_mp3s,
    }

# ── entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Music library dedup + MP3 audit",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--move", action="store_true",
        help="Actually move cross-library dupes from what/ to !!delete/ "
             "(default: dry-run, report only)",
    )
    parser.add_argument(
        "--clear-cache", action="store_true",
        help="Delete the checksum cache and rehash everything from scratch",
    )
    parser.add_argument(
        "--task", choices=["1", "2", "both"], default="both",
        help="Run only task 1 (dupes), only task 2 (MP3 inventory), or both (default)",
    )
    args = parser.parse_args()

    for path, name in [(REDACTED, "redacted/"), (WHAT, "what/")]:
        if not path.exists():
            sys.exit(f"ERROR: {name} not found at {path}")

    if args.move:
        print("⚠  --move is active. Cross-library dupes WILL be moved to !!delete/.\n")
    else:
        print("DRY RUN - pass --move to actually move files\n")

    if args.clear_cache and CACHE_FILE.exists():
        CACHE_FILE.unlink()
        print(f"Cache cleared: {CACHE_FILE}\n")

    start  = time.time()
    cache  = load_cache()
    report = {"dry_run": not args.move}

    try:
        if args.task in ("1", "both"):
            report["task1_cross_library_dupes"] = task1_cross_library_dupes(cache, args.move)

        if args.task in ("2", "both"):
            report["task2_mp3_inventory"] = task2_mp3_inventory()

    finally:
        save_cache(cache)
        print(f"Checksum cache saved → {CACHE_FILE}")

    REPORT_FILE.write_text(json.dumps(report, indent=2, default=str))
    elapsed = time.time() - start
    print(f"Full JSON report     → {REPORT_FILE}")
    print(f"Total time           : {elapsed:.0f}s\n")


if __name__ == "__main__":
    main()
