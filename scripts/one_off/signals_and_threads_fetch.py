#!/usr/bin/env python3
"""Archive Signals and Threads episode transcripts into the vault.

Signals and Threads (https://signalsandthreads.com/) publishes a full
transcript on every episode page, inside a `div` whose class list contains
`tab-view` and `transcript`. Structure within that div, verified against
the "What is an Operating System?" episode on 2026-08-30:

    <h2>00:00:04</h2>   timestamp
    <h1>Ron</h1>        speaker
    <p>...</p>          one or more paragraphs of speech

This script walks the index page, finds every episode link, pulls the
transcript out of each, and writes one markdown file per episode into the
target folder using that folder's convention: title on line 1, source URL
on line 2, blank line, then `Transcript:` and the body.

Why a script and not hand-copying: 28 episodes at roughly 18,000 words each
is about half a million words. Anything that routes that through a chat
context truncates, garbles, or silently drops episodes. Fetch and write in
one process, then verify with counts.

Verification (the run fails loudly rather than writing plausible junk):
  - every episode file must clear MIN_WORDS
  - the run must find at least MIN_EPISODES episode links
  - a summary table of per-file word counts is printed at the end

Usage:
    python3 scripts/one_off/signals_and_threads_fetch.py --list
    python3 scripts/one_off/signals_and_threads_fetch.py
    python3 scripts/one_off/signals_and_threads_fetch.py --force
    python3 scripts/one_off/signals_and_threads_fetch.py --out /some/other/dir

Stdlib only, matching scripts/html_to_text.py. No dependencies.
"""
from __future__ import annotations

import argparse
import html
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

INDEX_URL = "https://signalsandthreads.com/"
DEFAULT_OUT = Path(
    "/Users/cpreston/Vaults/storage_mbs/money/project_management_arc"
    "/reference/yaron_minsky_transcripts"
)
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) personal-archive/1.0"
MIN_WORDS = 2000
MIN_EPISODES = 28
SLEEP_BETWEEN = 1.5

NON_EPISODE_PATHS = {
    "", "about", "about-us", "contact", "feed", "rss", "subscribe",
    "episodes", "index", "privacy", "terms", "search",
}


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = resp.read()
    return raw.decode("utf-8", errors="replace")


class LinkFinder(HTMLParser):
    """Collect every href on the index page."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.hrefs: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag != "a":
            return
        for key, value in attrs:
            if key == "href" and value:
                self.hrefs.append(value)


class TranscriptParser(HTMLParser):
    """Pull the transcript block, plus the page title, out of an episode page.

    Enters capture mode on a div whose class contains both `tab-view` and
    `transcript`, tracks nesting depth so it exits on the matching close tag,
    and routes h2 to timestamp, h1 to speaker, p to speech.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.depth = 0
        self.capturing = False
        self.current: str | None = None
        self.buf: list[str] = []
        self.timestamp: str | None = None
        self.speaker: str | None = None
        self.blocks: list[str] = []
        self.found_transcript_div = False
        self.in_title = False
        self.title_parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attrd = {k: (v or "") for k, v in attrs}
        if tag == "title" and not self.title_parts:
            self.in_title = True
            return
        if self.capturing:
            if tag == "div":
                self.depth += 1
            if tag in ("h1", "h2", "p"):
                self._flush()
                self.current = tag
            return
        if tag == "div":
            classes = attrd.get("class", "").split()
            if "transcript" in classes and "tab-view" in classes:
                self.capturing = True
                self.found_transcript_div = True
                self.depth = 1

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self.in_title = False
            return
        if not self.capturing:
            return
        if tag in ("h1", "h2", "p"):
            self._flush()
            return
        if tag == "div":
            self.depth -= 1
            if self.depth <= 0:
                self._flush()
                self.capturing = False

    def handle_data(self, data: str) -> None:
        if self.in_title:
            self.title_parts.append(data)
        elif self.capturing and self.current:
            self.buf.append(data)

    def _flush(self) -> None:
        if not self.current:
            return
        text = html.unescape("".join(self.buf)).strip()
        text = re.sub(r"\s+", " ", text)
        tag, self.current, self.buf = self.current, None, []
        if not text:
            return
        if tag == "h2":
            self.timestamp = text
        elif tag == "h1":
            self.speaker = text
        elif tag == "p":
            stamp = f"({self.timestamp}) " if self.timestamp else ""
            who = f"{self.speaker}: " if self.speaker else ""
            self.blocks.append(f"{stamp}{who}{text}")
            self.timestamp = None

    @property
    def title(self) -> str:
        raw = html.unescape("".join(self.title_parts)).strip()
        return re.sub(r"\s+", " ", raw)

    @property
    def transcript(self) -> str:
        return "\n\n".join(self.blocks)


def slugify(url: str) -> str:
    path = urllib.parse.urlparse(url).path.strip("/")
    slug = path.split("/")[-1] if path else "index"
    slug = re.sub(r"[^a-z0-9]+", "_", slug.lower()).strip("_")
    return f"ref_{slug}.md"


def discover_episodes(index_html: str) -> list[str]:
    finder = LinkFinder()
    finder.feed(index_html)
    seen: list[str] = []
    for href in finder.hrefs:
        absolute = urllib.parse.urljoin(INDEX_URL, href)
        parts = urllib.parse.urlparse(absolute)
        if parts.netloc != urllib.parse.urlparse(INDEX_URL).netloc:
            continue
        path = parts.path.strip("/")
        if not path or "/" in path:
            continue
        if path.lower() in NON_EPISODE_PATHS:
            continue
        canonical = f"{parts.scheme}://{parts.netloc}/{path}/"
        if canonical not in seen:
            seen.append(canonical)
    return seen


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--force", action="store_true", help="rewrite files that already exist")
    ap.add_argument("--list", action="store_true", help="list discovered episodes and stop")
    ap.add_argument("--limit", type=int, default=0, help="stop after N episodes (for a smoke test)")
    args = ap.parse_args()

    print(f"index: {INDEX_URL}")
    try:
        index_html = fetch(INDEX_URL)
    except (urllib.error.URLError, TimeoutError) as exc:
        print(f"FAILED to fetch index: {exc}", file=sys.stderr)
        return 2

    episodes = discover_episodes(index_html)
    print(f"discovered {len(episodes)} episode links")
    if args.list:
        for url in episodes:
            print(f"  {url}  ->  {slugify(url)}")
        return 0

    if len(episodes) < MIN_EPISODES:
        print(
            f"FAILED: found {len(episodes)} episode links, expected at least {MIN_EPISODES}. "
            "The index markup probably changed. Not writing anything.",
            file=sys.stderr,
        )
        return 2

    args.out.mkdir(parents=True, exist_ok=True)
    if args.limit:
        episodes = episodes[: args.limit]

    written: list[tuple[str, int]] = []
    skipped: list[str] = []
    not_episodes: list[str] = []
    failed: list[tuple[str, str]] = []

    for i, url in enumerate(episodes, 1):
        target = args.out / slugify(url)
        if target.exists() and not args.force:
            skipped.append(target.name)
            print(f"[{i}/{len(episodes)}] skip (exists) {target.name}")
            continue
        try:
            page = fetch(url)
        except (urllib.error.URLError, TimeoutError) as exc:
            failed.append((url, f"fetch: {exc}"))
            print(f"[{i}/{len(episodes)}] FAIL fetch {url}: {exc}", file=sys.stderr)
            continue

        parser = TranscriptParser()
        parser.feed(page)
        body = parser.transcript
        words = len(body.split())
        if not parser.found_transcript_div:
            # No transcript container at all. The index also links a couple of
            # site announcements ("Introducing Signals and Threads", "More
            # Signals and Threads coming soon") which are pages, not episodes.
            # Those are expected and must not be reported as failures, or the
            # run's exit code stops meaning anything.
            not_episodes.append(url)
            print(f"[{i}/{len(episodes)}] not an episode (no transcript block): {url}")
            time.sleep(SLEEP_BETWEEN)
            continue
        if words < MIN_WORDS:
            # Transcript container present but nearly empty. That IS a real
            # regression: the markup changed under us. Fail loudly.
            failed.append((url, f"transcript block present but only {words} words extracted"))
            print(
                f"[{i}/{len(episodes)}] FAIL extract {url}: transcript block found but "
                f"only {words} words (floor {MIN_WORDS}). Not written.",
                file=sys.stderr,
            )
            continue

        title = parser.title or url
        target.write_text(f"{title}\n{url}\n\nTranscript:\n\n{body}\n", encoding="utf-8")
        written.append((target.name, words))
        print(f"[{i}/{len(episodes)}] wrote {target.name} ({words:,} words)")
        time.sleep(SLEEP_BETWEEN)

    print("\n=== summary ===")
    print(
        f"written: {len(written)}   skipped (already present): {len(skipped)}   "
        f"not episodes: {len(not_episodes)}   failed: {len(failed)}"
    )
    for name, words in written:
        print(f"  {words:>7,}  {name}")
    for url in not_episodes:
        print(f"  not an episode  {url}")
    for url, why in failed:
        print(f"  FAILED  {url}  ({why})")
    if written:
        counts = [w for _, w in written]
        print(f"word counts: min {min(counts):,} / median {sorted(counts)[len(counts)//2]:,} / max {max(counts):,}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
