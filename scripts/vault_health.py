#!/usr/bin/env python3
"""
vault_health.py — mbs_automation vault health check (pillar-aware, hybrid vault)

Audits P's Obsidian vault for ACTIONABLE structural issues, tuned to the hybrid model:
existing human notes are left alone; the agent only flags things worth fixing.

Checks:
- Missing next-step    : active project notes (type: project, status: active) with no next_action  [headline duty]
- Duplicates           : same concept, multiple files
- Broken links         : [[wikilinks]] that don't resolve (basename) to any note
- Orphans (agent notes): notes WITH frontmatter (agent-written) that have no incoming links
- Stale active projects: type: project + status: active not edited in 14+ days
- Naming/convention    : non-_archive archive folders (vaults_*, old/, archive/), files at vault root
- Empty folders
- Template leftovers    : unfilled <% %> Templater syntax outside template dirs
- Doc path drift       : literal `backtick paths` in system/reference docs (_CLAUDE.md,
                          SETUP.md, VISION.md, ROADMAP.md, RENAMING_PLAN.md,
                          PROJECT_BOOTSTRAP.md, ref_*.md) that don't resolve on disk —
                          date/placeholder segments (YYYY-MM-DD, <slug>, etc.) are
                          treated as wildcards, so a whole pattern is flagged only if
                          NOTHING on disk matches it. Added 2026-07-21 after SETUP.md
                          was found to document a `session_awareness` report path that
                          had silently moved (design/ → obsidian_optimize/).
- Ambiguous bare refs  : a bare `filename.md` (no path) mentioned in one of those same
                          docs that resolves to more than one file in the vault by
                          basename — the exact shape of the bug that let SETUP.md's bare
                          `log.md` reference get taken literally and produce a duplicate
                          log file at the vault root (2026-06-29 → found & fixed 2026-07-21).

Deliberately NOT checked (hybrid vault):
- Missing frontmatter on human notes — that's the norm, not a problem.
- Orphans among non-frontmatter human notes — most aren't linked, by design.

Excluded from scanning: trash/, _to_clean/, .obsidian, .git, attachments.
_archive/ notes are indexed (so links resolve) but never themselves flagged.

Usage:
    python vault_health.py --path /Users/cpreston/Vaults/storage_mbs
    python vault_health.py --path /Users/cpreston/Vaults/storage_mbs --json
"""

import argparse
import json
import re
from collections import defaultdict
from datetime import date, datetime
from pathlib import Path

TODAY = date.today()
STALE_DAYS = 14

EXCLUDE_DIRS = {".obsidian", ".git", "trash", ".trash", "_trash", "_to_clean", "attachments"}
TEMPLATE_HINTS = ("templater", "templates", "/template")  # paths where <% %> is legitimate

FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---", re.DOTALL)
LINK_RE = re.compile(r"\[\[([^\]|#]+)(?:[|#][^\]]*)?\]\]")
TEMPLATE_RE = re.compile(r"<%.*?%>")
TYPE_RE = re.compile(r"^type:\s*(.+)$", re.MULTILINE)
STATUS_RE = re.compile(r"^status:\s*(.+)$", re.MULTILINE)
NEXTACTION_RE = re.compile(r"^next_action:\s*(.*)$", re.MULTILINE)
ALIAS_RE = re.compile(r"^aliases:\s*\n((?:\s+-\s+.+\n?)+)", re.MULTILINE)
ALIAS_ITEM_RE = re.compile(r"^\s+-\s+(.+)$", re.MULTILINE)


def _clean(v: str) -> str:
    return v.strip().strip('"').strip("'")


def parse_aliases(frontmatter: str) -> list:
    block = ALIAS_RE.search(frontmatter)
    if not block:
        return []
    return [m.strip().strip('"\'').lower() for m in ALIAS_ITEM_RE.findall(block.group(1))]


def load_vault(vault: Path) -> dict:
    notes = {}
    for md in vault.rglob("*.md"):
        parts = md.relative_to(vault).parts
        if any(p in EXCLUDE_DIRS for p in parts):
            continue
        rel = str(md.relative_to(vault))
        content = md.read_text(encoding="utf-8", errors="replace")
        fm_match = FRONTMATTER_RE.match(content)
        frontmatter = fm_match.group(1) if fm_match else ""
        type_m = TYPE_RE.search(frontmatter)
        status_m = STATUS_RE.search(frontmatter)
        na_m = NEXTACTION_RE.search(frontmatter)
        try:
            mtime = datetime.fromtimestamp(md.stat().st_mtime).date()
        except OSError:
            mtime = TODAY
        notes[rel] = {
            "path": md,
            "rel": rel,
            "stem": md.stem,
            "content": content,
            "frontmatter": frontmatter,
            "has_frontmatter": bool(fm_match),
            "links": [l.strip().rstrip("\\") for l in LINK_RE.findall(content)],
            "aliases": parse_aliases(frontmatter),
            "type": _clean(type_m.group(1)) if type_m else None,
            "status": _clean(status_m.group(1)).lower() if status_m else None,
            "next_action": _clean(na_m.group(1)) if na_m else "",
            "in_archive": "_archive" in parts,
            "top": parts[0] if len(parts) > 1 else "",
            "mtime": mtime,
            "size": len(content),
        }
    return notes


def check_missing_next_step(notes: dict) -> list:
    """Headline duty: active project notes with no next_action."""
    issues = []
    for rel, n in notes.items():
        if n["in_archive"]:
            continue
        if n["type"] == "project" and n["status"] == "active" and not n["next_action"]:
            issues.append({
                "type": "missing_next_step", "severity": "critical",
                "message": f"Active project with no next_action: {rel}", "files": [rel],
            })
    return issues


STRUCTURAL_STEMS = {
    "index", "readme", "_readme", "untitled", "tasks", "archive", "_archive",
    "daily note health", "goals", "notes", "todo", "", "1", "2", "3",
}


def check_duplicates(notes: dict) -> list:
    issues, stems = [], defaultdict(list)
    for rel, n in notes.items():
        if n["in_archive"] or n["top"] == "daily_notes":
            continue
        norm = re.sub(r"\d{4}-\d{2}-\d{2}", "", n["stem"]).lower()
        norm = re.sub(r"[^a-z0-9 ]", " ", norm).strip()
        norm = re.sub(r"\s+", " ", norm)
        if norm and norm not in STRUCTURAL_STEMS and len(norm) > 3:
            stems[norm].append(rel)
    for norm, files in stems.items():
        if len(files) > 1:
            issues.append({
                "type": "duplicate", "severity": "warning",
                "message": f"Possible duplicates: {norm!r}", "files": files,
            })
    return issues


def check_orphans(notes: dict) -> list:
    """Only flag AGENT-written notes (with frontmatter). Human notes are exempt by design."""
    all_links = set()
    for n in notes.values():
        for link in n["links"]:
            all_links.add(link.lower())
            all_links.add(link.lower().replace(" ", "-"))
    skip_top = {"daily_notes", "captured"}
    issues = []
    for rel, n in notes.items():
        if n["in_archive"] or n["top"] in skip_top or not n["has_frontmatter"]:
            continue
        # folder-readmes and saved reference assets aren't meant to be linked
        if n["stem"].lower() in ("_readme", "readme") or "/assets/" in rel or "_chat_imports/" in rel:
            continue
        stem_lower = n["stem"].lower()
        stem_norm = stem_lower.replace("-", " ").replace("_", " ")
        linked = (stem_lower in all_links or stem_norm in all_links
                  or any(stem_lower in lk for lk in all_links)
                  or any(a in all_links for a in n["aliases"]))
        if not linked:
            issues.append({
                "type": "orphan", "severity": "info",
                "message": f"Agent note with no incoming links: {rel}", "files": [rel],
            })
    return issues


def check_stale_projects(notes: dict) -> list:
    issues = []
    for rel, n in notes.items():
        if n["in_archive"]:
            continue
        if n["type"] == "project" and n["status"] == "active":
            age = (TODAY - n["mtime"]).days
            if age >= STALE_DAYS:
                issues.append({
                    "type": "stale_project", "severity": "warning",
                    "message": f"Active project untouched {age}d: {rel}", "files": [rel],
                })
    return issues


def check_conventions(notes: dict, vault: Path) -> list:
    """Non-_archive archive folders, and stray files at the vault root."""
    issues = []
    bad_archive = re.compile(r"(^|/)(vaults?_[^/]+|old|archive)/", re.IGNORECASE)
    seen = set()
    for rel, n in notes.items():
        m = bad_archive.search("/" + rel)
        if m:
            folder = rel[:rel.rfind("/")] if "/" in rel else rel
            if folder not in seen:
                seen.add(folder)
                issues.append({
                    "type": "naming_drift", "severity": "warning",
                    "message": f"Non-standard archive folder (should be _archive/): {folder}/",
                    "files": [folder],
                })
    allowed_root = {"CLAUDE.md"}  # brain files moved to admin/mbs_system/brain/
    for rel, n in notes.items():
        if "/" not in rel and rel not in allowed_root:
            issues.append({
                "type": "root_stray", "severity": "info",
                "message": f"Loose file at vault root: {rel}", "files": [rel],
            })
    return issues


def check_empty_folders(vault: Path) -> list:
    issues = []
    for folder in vault.rglob("*"):
        if not folder.is_dir():
            continue
        parts = folder.relative_to(vault).parts
        if any(p in EXCLUDE_DIRS for p in parts):
            continue
        if not any(folder.iterdir()):
            issues.append({
                "type": "empty_folder", "severity": "info",
                "message": f"Empty folder: {folder.relative_to(vault)}/", "files": [],
            })
    return issues


# Foundation/meta docs contain illustrative [[link]] syntax and folder navigation;
# don't flag their links as broken.
SKIP_LINK_DOCS = {
    "admin/mbs_system/brain/_CLAUDE.md",
    "admin/mbs_system/brain/SOUL.md",
    "admin/mbs_system/brain/CRITICAL_FACTS.md",
    "admin/mbs_system/brain/IDENTITY_FIREWALL.md",
}
# Embedded attachments ([[image.png]] etc.) point to files, not notes — don't flag.
ATTACHMENT_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".pdf", ".canvas",
                   ".excalidraw", ".mp4", ".mov", ".mp3", ".m4a", ".heic", ".tif", ".tiff", ".html"}


def check_broken_links(notes: dict, vault: Path) -> list:
    all_stems = {n["stem"].lower(): rel for rel, n in notes.items()}
    all_aliases = {a.lower(): rel for rel, n in notes.items() for a in n["aliases"]}
    date_link = re.compile(r"^\d{4}-\d{2}-\d{2}")
    issues = []
    for rel, n in notes.items():
        if n["in_archive"] or rel in SKIP_LINK_DOCS or rel.startswith("admin/obsidian_optimize/"):
            continue
        if n["top"] == "daily_notes" or "_chat_imports/" in rel:   # transient/pasted-conversation links
            continue
        for link in n["links"]:
            t = link.strip()
            if t.endswith("/") or date_link.match(t) or "{{" in t:   # folder, date ref, or template placeholder
                continue
            if Path(t).suffix.lower() in ATTACHMENT_EXTS:   # embedded attachment, not a note
                continue
            if t.lower().endswith(".md"):
                t = t[:-3]
            link_stem = Path(t).stem.lower() if "/" in t else t.lower()
            link_norm = link_stem.replace("-", " ").replace("_", " ")
            resolved = (link_stem in all_stems or link_norm in all_stems
                        or link_stem in all_aliases or link_norm in all_aliases)
            if not resolved and not (vault / link).is_dir():
                issues.append({
                    "type": "broken_link", "severity": "critical",
                    "message": f"Broken link [[{link}]] in {rel}", "files": [rel],
                })
    return issues


def check_template_leftovers(notes: dict) -> list:
    issues = []
    for rel, n in notes.items():
        if any(h in rel.lower() for h in TEMPLATE_HINTS) or n["in_archive"]:
            continue
        if TEMPLATE_RE.search(n["content"]):
            issues.append({
                "type": "template_leftover", "severity": "critical",
                "message": f"Unfilled template syntax in: {rel}", "files": [rel],
            })
    return issues


# ── Doc path drift + ambiguous bare refs ────────────────────────────────────
# Scope is an EXACT allowlist, not a basename match. Per-folder `_CLAUDE.md` files
# legitimately use paths relative to their OWN folder (that's the convention, not a
# bug) — checking those against the vault root produces wall-to-wall false positives.
# The real risk is concentrated in the handful of global/foundation docs that every
# session reads and that describe vault-root-relative or home-relative paths as if
# absolute: the same list `check_broken_links` already treats as foundation/meta
# (SKIP_LINK_DOCS) plus the sibling design docs in the same folder as SETUP.md.
DOC_SCOPE = SKIP_LINK_DOCS | {
    "admin/mbs_system/design/SETUP.md",
    "admin/mbs_system/design/VISION.md",
    "admin/mbs_system/design/ROADMAP.md",
    "admin/mbs_system/design/PROJECT_BOOTSTRAP.md",
    # RENAMING_PLAN.md deliberately excluded: it's a current-name -> proposed-name table,
    # so its "Current" column is SUPPOSED to contain names that no longer exist post-rename.
    # Flagging those would be flagging the document for doing its job.
}
BACKTICK_RE = re.compile(r"`([^`\s]+)`")
PLACEHOLDER_TOKEN_RE = re.compile(r"<[^>/\\]+>|YYYY(?:-MM(?:-DD)?)?|\bMM\b|\bDD\b|\bWW\b")
# after placeholder substitution, a real path/glob pattern only ever contains these
SAFE_PATTERN_RE = re.compile(r"^[A-Za-z0-9_./~*-]+$")
KNOWN_TOP_LEVEL = {
    "admin", "create", "culture", "daily_notes", "health", "money",
    "skills", "social", "sports", "captured", "trash", "_archive", "attachments",
}
PATH_EXTENSIONS = {
    ".md", ".py", ".sh", ".json", ".plist", ".log", ".txt", ".yml", ".yaml",
    ".canvas", ".html", ".js", ".ts", ".css",
}
# secondary roots to try for a bare relative candidate before calling it drift — SETUP.md
# in particular writes elliptically ("Wrapper: `~/dev/mbs_automation/scripts/x.sh`. Job:
# `launchd/y.plist`") where later paths are implicitly relative to the script repo, not
# the vault. Try vault root first (the common case), then these, before flagging.
SECONDARY_ROOTS = ("dev/mbs_automation", "dev/mbs_automation/scripts")


def _looks_like_real_path(candidate: str) -> bool:
    """Filter out slash-bearing tokens that aren't actually filesystem paths: Claude Code
    slash-commands (`/obsidian-init`), GitHub owner/repo shorthand (`CP250/mbs_automation`),
    and bare single-segment directory mentions (`_archive/`, `trash/`) that are almost always
    illustrating a CONVENTION ("every folder gets an `_archive/`"), not pointing at one
    specific instance — those top-level names are foundational enough that drift here is
    vanishingly unlikely, and the false-positive rate isn't worth the marginal coverage."""
    if candidate.startswith("/"):
        return candidate.count("/") >= 2  # a bare "/word" with no second segment is a slash-command
    if candidate.startswith("~/"):
        return True
    if candidate.rstrip("/").count("/") == 0:
        return False  # single bare segment ("_archive/", "trash/", "cars/") — too generic to check
    first = candidate.split("/", 1)[0]
    return first in KNOWN_TOP_LEVEL or Path(candidate).suffix.lower() in PATH_EXTENSIONS


def check_doc_path_drift(notes: dict, vault: Path) -> list:
    """Backtick literal paths in scoped foundation docs that don't resolve on disk.
    Placeholder segments (<slug>, YYYY-MM-DD, ...) become glob wildcards first, so a
    pattern is only flagged if NOTHING matches it anywhere it could plausibly live
    (vault-relative, home-relative/absolute, or — as a fallback for bare relative
    paths — the mbs_automation script repo) — not just the literal placeholder string."""
    issues, seen = [], set()
    for rel, n in notes.items():
        if rel not in DOC_SCOPE:
            continue
        for raw in BACKTICK_RE.findall(n["content"]):
            candidate = raw.rstrip(",.;:)]}")
            if "/" not in candidate or candidate.startswith(("http://", "https://", "mailto:")):
                continue
            if not _looks_like_real_path(candidate):
                continue
            key = (rel, candidate)
            if key in seen:
                continue
            seen.add(key)

            pattern = PLACEHOLDER_TOKEN_RE.sub("*", candidate)
            if not SAFE_PATTERN_RE.match(pattern):
                continue  # not a real path/glob token (HTML comment marker, prose w/ slash, etc.)
            has_wildcard = "*" in pattern

            if pattern.startswith("~/"):
                bases = [(Path.home(), pattern[2:])]
            elif pattern.startswith("/"):
                bases = [(Path("/"), pattern.lstrip("/"))]
            else:
                rest = pattern.rstrip("/")
                bases = [(vault, rest)] + [(Path.home() / r, rest) for r in SECONDARY_ROOTS]

            def _hit(base, rest):
                try:
                    return any(base.glob(rest)) if has_wildcard else (base / rest).exists()
                except (OSError, ValueError):
                    return True  # unparseable — don't flag what we can't evaluate

            if not any(_hit(b, r) for b, r in bases):
                issues.append({
                    "type": "doc_path_drift", "severity": "warning",
                    "message": f"Path `{candidate}` referenced in {rel} does not resolve to anything on disk",
                    "files": [rel],
                })
    return issues


# Filenames the vault deliberately repeats in every/many folders by convention
# (_CLAUDE.md and _HANDOFF.md per admin/mbs_system/brain/_CLAUDE.md itself; README.md
# and its variants per STRUCTURAL_STEMS above). Many matches for these is the intended
# design, not a collision — excluded so the check stays about SURPRISING ambiguity.
KNOWN_REPEATED_BASENAMES = {"_claude.md", "_handoff.md", "readme.md", "_readme.md"}
MAX_SUSPICIOUS_MATCHES = 5  # more than this looks like an intentional repeated pattern, not an accident


def check_ambiguous_bare_refs(notes: dict) -> list:
    """A bare `filename.md` (no directory) referenced in a scoped foundation doc that
    resolves to a SMALL number (2-5) of files in the vault by basename — enough to be a
    surprising collision, not a known one-per-folder convention. This is the exact shape
    of the bug that let SETUP.md's bare `log.md` mention get taken literally and produce
    a duplicate log file at the vault root (2026-06-29 sweep; found & fixed 2026-07-21,
    where the count was exactly 2)."""
    by_name = defaultdict(list)
    for rel in notes:
        by_name[rel.rsplit("/", 1)[-1]].append(rel)
    issues, seen = [], set()
    for rel, n in notes.items():
        if rel not in DOC_SCOPE:
            continue
        for raw in BACKTICK_RE.findall(n["content"]):
            candidate = raw.rstrip(",.;:)]}")
            if "/" in candidate or not re.match(r"^[A-Za-z0-9_.-]+\.md$", candidate):
                continue
            if candidate.lower() in KNOWN_REPEATED_BASENAMES:
                continue
            key = (rel, candidate)
            if key in seen:
                continue
            seen.add(key)
            matches = by_name.get(candidate, [])
            if 1 < len(matches) <= MAX_SUSPICIOUS_MATCHES:
                issues.append({
                    "type": "ambiguous_bare_ref", "severity": "warning",
                    "message": f"Bare `{candidate}` in {rel} resolves to {len(matches)} files: {', '.join(sorted(matches))}",
                    "files": [rel],
                })
    return issues


def run_health_check(vault: Path) -> dict:
    notes = load_vault(vault)
    checks = [
        ("Missing next-step", check_missing_next_step(notes)),
        ("Broken links", check_broken_links(notes, vault)),
        ("Template leftovers", check_template_leftovers(notes)),
        ("Duplicates", check_duplicates(notes)),
        ("Stale active projects", check_stale_projects(notes)),
        ("Naming/convention", check_conventions(notes, vault)),
        ("Orphans (agent notes)", check_orphans(notes)),
        ("Empty folders", check_empty_folders(vault)),
        ("Doc path drift", check_doc_path_drift(notes, vault)),
        ("Ambiguous bare refs", check_ambiguous_bare_refs(notes)),
    ]
    all_issues, counts = [], {}
    for label, issues in checks:
        counts[label] = len(issues)
        all_issues.extend(issues)
    return {
        "vault": str(vault), "scanned": TODAY.isoformat(),
        "total_notes": len(notes), "total_issues": len(all_issues),
        "counts": counts, "issues": all_issues,
    }


def print_report(result: dict):
    print("=" * 60)
    print(f"  VAULT HEALTH — {result['scanned']}  ({result['total_notes']} notes)")
    print("=" * 60)
    if result["total_issues"] == 0:
        print("✅ No actionable issues found.")
        return
    icon = {"critical": "🔴", "warning": "🟡", "info": "⚪"}
    for label, count in result["counts"].items():
        if count:
            print(f"  {label}: {count}")
    by_type = defaultdict(list)
    for i in result["issues"]:
        by_type[i["type"]].append(i)
    for t, issues in by_type.items():
        print(f"\n{icon.get(issues[0]['severity'], '⚪')} {t.replace('_',' ').title()} ({len(issues)})")
        for i in issues[:10]:
            print(f"  {i['message']}")
        if len(issues) > 10:
            print(f"  ... and {len(issues)-10} more")


def main():
    parser = argparse.ArgumentParser(description="mbs_automation vault health check")
    parser.add_argument("--path", required=True)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    vault = Path(args.path).expanduser().resolve()
    if not vault.exists():
        print(f"❌ Vault not found: {vault}")
        return 1
    result = run_health_check(vault)
    print(json.dumps(result, indent=2, default=str) if args.json else "", end="")
    if not args.json:
        print_report(result)


if __name__ == "__main__":
    main()
