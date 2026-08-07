#!/usr/bin/env python3
"""Strip an HTML page down to its visible text. Stdlib only, no dependencies.

web_watchers.sh feeds fetched pages to `claude -p` for deterministic fact
extraction. Raw HTML (Squarespace-style pages run 100-150KB, mostly config
JSON, <script>/<style> blocks, and markup) buries the handful of visible
facts the watcher actually cares about, which measurably increases both
self-correction chatter and outright misreads in the model's output (see
admin/mbs_system/_logs/log_2026-08-07_web_watchers_fix.md, round 2). This
strips tags and non-visible content so the model sees only what a human
would see on the page.

Usage:
    python3 scripts/html_to_text.py path/to/page.html > page.txt
    curl ... | python3 scripts/html_to_text.py > page.txt
"""
from __future__ import annotations

import sys
from html.parser import HTMLParser

BLOCK_TAGS = {
    "p", "div", "li", "tr", "br", "h1", "h2", "h3", "h4", "h5", "h6",
    "section", "article", "header", "footer", "ul", "ol", "table", "hr",
}
SKIP_TAGS = {"script", "style", "noscript", "template", "svg"}


class TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.chunks: list[str] = []
        self.skip_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in SKIP_TAGS:
            self.skip_depth += 1
        elif tag in BLOCK_TAGS:
            self.chunks.append("\n")

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in BLOCK_TAGS:
            self.chunks.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in SKIP_TAGS:
            self.skip_depth = max(0, self.skip_depth - 1)
        elif tag in BLOCK_TAGS:
            self.chunks.append("\n")

    def handle_data(self, data: str) -> None:
        if self.skip_depth == 0:
            self.chunks.append(data)


def html_to_text(html: str) -> str:
    parser = TextExtractor()
    parser.feed(html)
    parser.close()
    lines = [line.strip() for line in "".join(parser.chunks).splitlines()]
    return "\n".join(line for line in lines if line)


def main() -> None:
    if len(sys.argv) > 1:
        with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
            html = f.read()
    else:
        html = sys.stdin.read()
    print(html_to_text(html))


if __name__ == "__main__":
    main()
