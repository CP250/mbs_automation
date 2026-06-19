#!/usr/bin/env python3
"""weekly_blocks.py - generate the weekly time-block plan.

Walks the vault for goals_*.md files, reads `weekly_minutes` (and optional
`default_block_length`) from their frontmatter, and emits TWO artifacts:

1. **Events JSON** at `~/.mbs_automation/weekly_blocks_<plan_week>_events.json`.
   Consumed by `weekly_blocks.sh` which calls `claude -p` to invoke
   `mcp__google-calendar__create-event` for each event. This is the C-lite
   pathway adopted 2026-06-16 after the previous Morgen-drop-zone approach
   (markdown -> Tasks-plugin pin -> drag) failed: P could not drag the
   all-day pins to time slots and side-panel drag was too high-friction.

2. **Audit-log markdown** at `admin/mbs_system/weekly/weekly_blocks_<plan_week>.md`.
   Kept as a record of what was scheduled (chassis-of-truth for debugging,
   not consumed by any tool). The previous "Morgen drop zone" framing is gone.

P now sees real calendar events appear in his calendar on Sunday evening
(default placement: Monday of plan-week starting 18:00 EST, stacked
sequentially). He drags them around in whatever calendar app he prefers
(Morgen, Google Calendar, Apple Calendar). No bidirectional sync; the script
writes once per plan-week.

Source-of-truth file: each `goals_<thread>.md`. To add a thread to the weekly
schedule, add `weekly_minutes: <int>` to its frontmatter. To pause for a week
set it to 0 (or delete the line).

Triggered by `weekly_blocks.sh` via launchd Sunday 17:00. Idempotent within a
plan-week via the stamp file - re-running regenerates the same audit log and
the same JSON (but if the stamp is deleted manually, the second run WILL
create duplicate calendar events; trust the stamp).

Pure stdlib; no external deps.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sys
from dataclasses import dataclass
from math import ceil
from pathlib import Path

VAULT_DEFAULT = Path("/Users/cpreston/Vaults/storage_mbs")
WEEKLY_SUBDIR = Path("admin/mbs_system/weekly")
STATE_DIR_DEFAULT = Path.home() / ".mbs_automation"

# Calendar event placement defaults (v1 - same time/day for all blocks; P drags).
DEFAULT_PLACEMENT_HOUR = 18  # 6 PM
DEFAULT_PLACEMENT_MINUTE = 0
DEFAULT_TIMEZONE = "America/New_York"
# Folder substrings whose goals files we skip.
SKIP_DIR_PARTS = {"_archive", "_deprecated", "trash"}
# Pillars derived from the top-level folder name. Anything outside this set is
# treated as pillar = top-level folder verbatim (lets new pillars participate
# without code changes), but we still log it.
KNOWN_PILLARS = {
    "admin", "create", "culture", "health", "money", "skills", "social", "sports",
}

FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---", re.DOTALL)
INT_FIELD_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(-?\d+)\s*$", re.MULTILINE)

ID_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"


@dataclass
class Thread:
    """A single get-better thread that has weekly_minutes set."""
    name: str            # 'ch8', 'rackets', 'golf'
    pillar: str          # 'create', 'sports'
    goals_path: Path     # vault-relative path to goals_<thread>.md
    weekly_minutes: int
    default_block_length: int  # default 60 if not set


def parse_int_frontmatter(text: str) -> dict[str, int]:
    """Pull every `<key>: <int>` line out of the frontmatter block.

    Robust for the simple schemas we care about. Anything more complex (lists,
    quoted strings, multi-line values) is ignored - by design.
    """
    m = FRONTMATTER_RE.match(text)
    if not m:
        return {}
    return {k: int(v) for k, v in INT_FIELD_RE.findall(m.group(1))}


def pillar_from_path(rel: Path) -> str:
    """Top-level folder of a vault-relative path."""
    if rel.parts:
        return rel.parts[0]
    return "unknown"


def discover_threads(vault: Path) -> list[Thread]:
    threads: list[Thread] = []
    for path in sorted(vault.rglob("goals_*.md")):
        rel = path.relative_to(vault)
        if any(part in SKIP_DIR_PARTS for part in rel.parts):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        fields = parse_int_frontmatter(text)
        wm = fields.get("weekly_minutes", 0)
        if wm <= 0:
            continue
        block_len = fields.get("default_block_length", 60)
        if block_len <= 0:
            block_len = 60
        name = path.stem.removeprefix("goals_")
        threads.append(Thread(
            name=name,
            pillar=pillar_from_path(rel),
            goals_path=rel,
            weekly_minutes=wm,
            default_block_length=block_len,
        ))
    return threads


def plan_week(today: dt.date | None = None) -> tuple[dt.date, str]:
    """Return (Monday-of-plan-week, ISO-week-tag) for today.

    If today is Sunday, plan for the upcoming week (Monday = today + 1).
    Otherwise plan for the current ISO week (Monday = today - weekday-1).
    """
    today = today or dt.date.today()
    if today.isoweekday() == 7:  # Sunday
        monday = today + dt.timedelta(days=1)
    else:
        monday = today - dt.timedelta(days=today.isoweekday() - 1)
    iso_year, iso_week, _ = monday.isocalendar()
    return monday, f"{iso_year}-W{iso_week:02d}"


def stable_id(thread: str, plan_week_tag: str, block_idx: int) -> str:
    """Deterministic 6-char Tasks-plugin ID per (thread, plan-week, block).

    Re-running within the same plan-week regenerates the same IDs, so Morgen
    doesn't see "new" tasks if the source file is overwritten.
    """
    s = f"{thread}|{plan_week_tag}|{block_idx}"
    digest = hashlib.sha256(s.encode("utf-8")).digest()
    n = int.from_bytes(digest[:6], "big")
    out = []
    for _ in range(6):
        out.append(ID_ALPHABET[n % 62])
        n //= 62
    return "".join(out)


def blocks_for(thread: Thread) -> list[int]:
    """List of block-minute lengths for a thread.

    weekly_minutes=180 default_block_length=60 -> [60, 60, 60]
    weekly_minutes=90  default_block_length=60 -> [60, 30]
    weekly_minutes=30  default_block_length=30 -> [30]
    """
    full = thread.weekly_minutes // thread.default_block_length
    rem = thread.weekly_minutes - full * thread.default_block_length
    blocks = [thread.default_block_length] * full
    if rem > 0:
        blocks.append(rem)
    if not blocks:
        blocks = [thread.weekly_minutes]
    return blocks


def render_task_line(thread: Thread, block_idx: int, total: int,
                     minutes: int, plan_week_tag: str, due_date: dt.date) -> str:
    """Audit-log line. Tasks-plugin format kept for grep-ability; no longer
    consumed by Morgen as a drop zone (the C-lite switch makes calendar events
    the primary artifact). The #weekly-block tag remains useful if P wants to
    filter the audit log by Dataview later."""
    tid = stable_id(thread.name, plan_week_tag, block_idx)
    return (
        f"- [ ] {thread.name} block {block_idx}/{total} ({minutes} min) "
        f"#{thread.pillar} #weekly-block \U0001F194 {tid} \U0001F4C5 {due_date.isoformat()}"
    )


def event_payloads(threads: list[Thread], plan_week_tag: str,
                   monday: dt.date) -> list[dict]:
    """Build Google Calendar event payloads for all blocks.

    v1 placement: all events start Monday of plan-week at
    DEFAULT_PLACEMENT_HOUR:DEFAULT_PLACEMENT_MINUTE, stacked back-to-back in
    pillar-then-thread alphabetical order. P drags each to its real slot in
    his calendar app of choice.

    Naive datetimes are emitted as ISO 8601 strings; the timezone is carried
    in a separate `timezone` field so the consumer (claude -p calling
    mcp__google-calendar__create-event) can pass {dateTime, timeZone}.
    """
    sources = sorted(threads, key=lambda t: (t.pillar, t.name))
    cursor = dt.datetime.combine(
        monday,
        dt.time(DEFAULT_PLACEMENT_HOUR, DEFAULT_PLACEMENT_MINUTE),
    )
    events: list[dict] = []
    for thread in sources:
        block_minutes = blocks_for(thread)
        total = len(block_minutes)
        for i, minutes in enumerate(block_minutes, start=1):
            tid = stable_id(thread.name, plan_week_tag, i)
            end = cursor + dt.timedelta(minutes=minutes)
            events.append({
                "stable_id": tid,
                "thread": thread.name,
                "pillar": thread.pillar,
                "block_idx": i,
                "block_total": total,
                "minutes": minutes,
                "summary": f"{thread.name} block {i}/{total} ({minutes} min)",
                "description": (
                    "Auto-generated weekly time-block.\n"
                    f"ID: {tid}\n"
                    f"Thread: {thread.name} ({thread.pillar})\n"
                    f"Source: {thread.goals_path.as_posix()}\n"
                    f"Plan week: {plan_week_tag}\n"
                    "Drag this event to your preferred time slot."
                ),
                "start": cursor.isoformat(timespec="seconds"),
                "end": end.isoformat(timespec="seconds"),
                "timezone": DEFAULT_TIMEZONE,
            })
            cursor = end
    return events


def render_file(threads: list[Thread], plan_week_tag: str, monday: dt.date,
                generated_at: dt.datetime) -> str:
    sources = sorted(threads, key=lambda t: (t.pillar, t.name))
    lines: list[str] = []
    lines.append("---")
    lines.append("type: weekly_blocks")
    lines.append(f"date: {monday.isoformat()}")
    lines.append(f"plan_week: \"{plan_week_tag}\"")
    lines.append(f"plan_week_start: {monday.isoformat()}")
    lines.append("tags: [weekly, blocks, generated, ai-first]")
    lines.append("ai-first: true")
    lines.append(f"generated_at: \"{generated_at.isoformat(timespec='seconds')}\"")
    lines.append("generated_by: scripts/weekly_blocks.py")
    lines.append("---")
    lines.append("")
    lines.append("## For future Claude")
    lines.append(
        "**Audit log** of the weekly time-block plan written into P's Google Calendar by "
        f"`weekly_blocks.py` + `weekly_blocks.sh` on Sunday 17:00 (run for plan-week {plan_week_tag}). "
        "Switched from the previous Morgen-drop-zone approach to direct Google Calendar event "
        "creation on 2026-06-16 (the C-lite pathway) after Morgen's drag-from-all-day-pin "
        "workflow turned out to be unworkable. **This markdown file is no longer the primary "
        "artifact** - it is kept for debugging and historical record. The primary artifact is the "
        f"set of Google Calendar events created at default placement (Monday {monday.isoformat()} "
        f"starting {DEFAULT_PLACEMENT_HOUR:02d}:{DEFAULT_PLACEMENT_MINUTE:02d} {DEFAULT_TIMEZONE}, "
        "stacked sequentially). P drags each event to its real time slot in whatever calendar "
        "app he prefers; no bidirectional sync."
    )
    lines.append("")
    lines.append(
        "Source of truth: `weekly_minutes:` (and optional `default_block_length:`) on each "
        "`goals_<thread>.md` in the vault. To add a thread, add `weekly_minutes: <n>` to its "
        "goals file. To pause a thread for a week, set `weekly_minutes: 0` (the next Sunday "
        "run will skip it). Event-creation IDs are deterministic per (thread, plan_week, "
        "block_idx); the launchd stamp file at `~/.mbs_automation/last_weekly_blocks_run` "
        "prevents accidental duplicate creation within a plan-week. Deleting the stamp "
        "manually and re-running WILL create duplicate events; trust the stamp."
    )
    lines.append("")
    lines.append("## Tasks")

    if not sources:
        lines.append("")
        lines.append("_No threads with `weekly_minutes:` set. Add it to a `goals_<thread>.md` to populate._")
    else:
        # Group by pillar > thread.
        current_pillar: str | None = None
        for thread in sources:
            if thread.pillar != current_pillar:
                lines.append("")
                lines.append(f"### {thread.pillar}")
                current_pillar = thread.pillar
            block_minutes = blocks_for(thread)
            total = len(block_minutes)
            lines.append("")
            lines.append(
                f"**{thread.name}** ({thread.weekly_minutes} min "
                f"= {total} × ≤{thread.default_block_length} min, from "
                f"[[{thread.goals_path.with_suffix('').as_posix()}|goals_{thread.name}]])"
            )
            for i, minutes in enumerate(block_minutes, start=1):
                lines.append(render_task_line(thread, i, total, minutes, plan_week_tag, monday))

    lines.append("")
    lines.append("## How it works (C-lite)")
    lines.append(f"1. Sunday 17:00 launchd fires `weekly_blocks.sh`, which runs this Python script.")
    lines.append(f"2. The script reads goals frontmatter, generates this audit-log markdown, AND writes a JSON of event payloads at `~/.mbs_automation/weekly_blocks_{plan_week_tag}_events.json`.")
    lines.append(f"3. The shell wrapper then invokes `claude -p` to call `mcp__google-calendar__create-event` for each event, placing them on Monday {monday.isoformat()} starting {DEFAULT_PLACEMENT_HOUR:02d}:{DEFAULT_PLACEMENT_MINUTE:02d} stacked sequentially.")
    lines.append("4. P drags each event to its real time slot in his calendar app. No bidirectional sync; the script writes once per plan-week.")
    lines.append("5. Completion tracking: not via these events. Use the daily growth log in `daily_notes/health/` or whatever surface P chooses; the events themselves are placement-only.")
    lines.append("")
    lines.append("## Source threads")
    if sources:
        for thread in sources:
            lines.append(
                f"- [[{thread.goals_path.with_suffix('').as_posix()}|goals_{thread.name}]] - "
                f"`weekly_minutes: {thread.weekly_minutes}`, `default_block_length: {thread.default_block_length}`"
            )
    else:
        lines.append("_(none yet)_")
    lines.append("")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault", type=Path, default=VAULT_DEFAULT, help="Vault root.")
    parser.add_argument(
        "--state-dir", type=Path, default=STATE_DIR_DEFAULT,
        help="State directory for the events JSON (default ~/.mbs_automation/).",
    )
    parser.add_argument(
        "--today", type=str, default=None,
        help="Override today's date as YYYY-MM-DD (testing only).",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print rendered audit log + events JSON to stdout; write nothing.",
    )
    args = parser.parse_args(argv)

    today: dt.date | None = None
    if args.today:
        today = dt.date.fromisoformat(args.today)
    monday, plan_week_tag = plan_week(today)
    generated_at = dt.datetime.now(dt.timezone.utc).astimezone()

    if not args.vault.is_dir():
        print(f"ERROR: vault not found at {args.vault}", file=sys.stderr)
        return 2

    threads = discover_threads(args.vault)
    audit_content = render_file(threads, plan_week_tag, monday, generated_at)
    events = event_payloads(threads, plan_week_tag, monday)
    events_doc = {
        "plan_week": plan_week_tag,
        "monday": monday.isoformat(),
        "generated_at": generated_at.isoformat(timespec="seconds"),
        "default_timezone": DEFAULT_TIMEZONE,
        "default_placement": f"Monday {DEFAULT_PLACEMENT_HOUR:02d}:{DEFAULT_PLACEMENT_MINUTE:02d}, stacked sequentially",
        "total_blocks": len(events),
        "events": events,
    }

    audit_path = args.vault / WEEKLY_SUBDIR / f"weekly_blocks_{plan_week_tag}.md"
    events_path = args.state_dir / f"weekly_blocks_{plan_week_tag}_events.json"

    if args.dry_run:
        print(f"# DRY RUN - would write audit log to {audit_path}")
        print(f"# DRY RUN - would write events JSON to {events_path}")
        print(f"# {len(threads)} thread(s) with weekly_minutes set, {len(events)} event(s) total")
        print("--- events JSON ---")
        print(json.dumps(events_doc, indent=2))
        print("--- audit log markdown ---")
        print(audit_content)
        return 0

    audit_path.parent.mkdir(parents=True, exist_ok=True)
    audit_path.write_text(audit_content, encoding="utf-8")
    args.state_dir.mkdir(parents=True, exist_ok=True)
    events_path.write_text(json.dumps(events_doc, indent=2), encoding="utf-8")
    print(
        f"Wrote audit log {audit_path} and events JSON {events_path} "
        f"({len(threads)} thread(s), {len(events)} event(s), plan_week={plan_week_tag})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
