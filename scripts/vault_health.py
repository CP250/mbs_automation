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
    allowed_root = {"_CLAUDE.md", "SOUL.md", "CRITICAL_FACTS.md", "index.md", "log.md", "PINNED.md"}
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
SKIP_LINK_DOCS = {"_CLAUDE.md", "SOUL.md", "CRITICAL_FACTS.md"}
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
