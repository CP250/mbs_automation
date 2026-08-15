#!/usr/bin/env python3
"""alcohol_stamp.py - recompute P's rolling weekly standard-drinks figure from
the daily health notes and stamp it into the two canonical belief docs.

Source of truth: `drinks_home_std` + `drinks_social_std` frontmatter in
daily_notes/health/daily/. Live daily view lives in health/dashboard_health.md
(DataviewJS); this stamps a Claude-readable literal into CRITICAL_FACTS.md and
the baseline profile, between <!--alc--> ... <!--/alc--> markers.

Vault path: $MBS_VAULT_OVERRIDE if set (used for testing against the Cowork
mount), else the real macOS path. Exits non-zero on any failure so the wrapper
does not write the success stamp.
"""
import os, re, glob, datetime, sys

VAULT = os.environ.get("MBS_VAULT_OVERRIDE", "/Users/cpreston/Vaults/storage_mbs")
DAILY = os.path.join(VAULT, "daily_notes/health/daily")
TARGETS = [
    os.path.join(VAULT, "admin/mbs_system/brain/CRITICAL_FACTS.md"),
    os.path.join(VAULT, "health/health_physical/meta/2026-05-15_baseline_health_profile.md"),
]

def num(txt, key):
    m = re.search(rf"^{key}:\s*([0-9]+(?:\.[0-9]+)?)\s*$", txt, re.M)
    return float(m.group(1)) if m else None

def collect():
    rows = []
    for f in glob.glob(os.path.join(DAILY, "daily_note_health_*.md")):
        m = re.search(r"(\d{4}-\d{2}-\d{2})", os.path.basename(f))
        if not m:
            continue
        t = open(f, encoding="utf-8").read()
        h, s = num(t, "drinks_home_std"), num(t, "drinks_social_std")
        if h is None and s is None:
            continue
        rows.append((datetime.date.fromisoformat(m.group(1)), (h or 0) + (s or 0)))
    rows.sort()
    return rows

def main():
    rows = collect()
    if not rows:
        print("no daily drink data found - aborting", file=sys.stderr)
        return 1
    today = datetime.date.today()
    total = sum(v for _, v in rows)
    wk_all = round(total / len(rows) * 7)
    lo = today - datetime.timedelta(days=27)
    win = [v for d, v in rows if lo <= d <= today]
    wk_28 = round(sum(win) / len(win) * 7) if win else wk_all
    span = f"**~{wk_all} std/wk** all-tracked, ~{wk_28} std/wk trailing-4-week (as of {today.isoformat()})"

    ok = True
    for path in TARGETS:
        try:
            t = open(path, encoding="utf-8").read()
        except FileNotFoundError:
            print(f"missing target: {path}", file=sys.stderr); ok = False; continue
        new, n = re.subn(r"<!--alc-->.*?<!--/alc-->",
                         f"<!--alc-->{span}<!--/alc-->", t, flags=re.S)
        if n < 1:
            print(f"no <!--alc--> marker in {path}", file=sys.stderr); ok = False; continue
        if new != t:
            open(path, "w", encoding="utf-8").write(new)
        print(f"stamped {n}x: {os.path.basename(path)}")
    print(f"VALUES all-tracked={wk_all}/wk trailing-28d={wk_28}/wk days={len(rows)}")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
