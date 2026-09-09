#!/bin/bash
# check_syntax.sh - parse-gate every launchd-fired script with the SAME bash
# that actually runs them.
#
# WHY THIS EXISTS (2026-08-19): macOS ships /bin/bash 3.2. Homebrew installs
# bash 5 and puts it first on PATH, so `bash -n` in a dev shell parses with 5
# and cannot see a 3.2-only parse failure. On 2026-08-07 a here-document
# holding an odd number of apostrophes was folded into $( ... ) inside
# web_watchers.sh's ask_claude(). bash 5 parses that file; bash 3.2 does not,
# because its command-substitution parser does not exempt here-document bodies
# from quote matching. com.mbs.web-watchers then died at parse time on all 13
# runs between 2026-08-08 and 2026-08-19, logging only to web_watchers.err.log,
# and no watcher checked anything for 12 days.
#
# Usage:
#   bash scripts/check_syntax.sh
#   CHECK_BASH=/path/to/bash bash scripts/check_syntax.sh   (test another bash)
#
# Also wired as .git/hooks/pre-commit.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYSTEM_BASH="${CHECK_BASH:-/bin/bash}"

if [ ! -x "$SYSTEM_BASH" ]; then
  echo "check_syntax: $SYSTEM_BASH is not executable; falling back to $(command -v bash)" >&2
  SYSTEM_BASH="$(command -v bash)"
fi

version="$("$SYSTEM_BASH" -c 'echo "$BASH_VERSION"')"
echo "check_syntax: parsing with $SYSTEM_BASH ($version)"
case "$version" in
  3.2*) : ;;
  *)
    echo "check_syntax: WARNING - this is bash $version, not 3.2. On macOS the" >&2
    echo "  launchd jobs run under /bin/bash 3.2, so a pass here does NOT prove" >&2
    echo "  they parse there. Point CHECK_BASH at a real 3.2 to be sure." >&2
    ;;
esac

# Scheduled jobs live in more repos than this one. The launchd estate spans
# ~/dev/oslo, ~/dev/mbs-oura-sync and ~/dev/mbs-mychart-sync as well, and a
# 3.2-only parse error is no less fatal there (added 2026-08-19, after the
# estate audit found that only this repo was ever being checked). Missing
# directories are skipped silently so this still works on a machine that does
# not have them all checked out.
EXTRA_DIRS="$HOME/dev/oslo/scripts $HOME/dev/mbs-oura-sync/scripts $HOME/dev/mbs-mychart-sync/scripts $HOME/dev/mbs-music-discovery/scripts"

fail=0
checked=0
skipped_dirs=""
for d in $EXTRA_DIRS; do
  [ -d "$d" ] || skipped_dirs="${skipped_dirs}${skipped_dirs:+ }${d}"
done
[ -n "$skipped_dirs" ] && echo "check_syntax: note, not present on this machine, skipped: $skipped_dirs"

for f in "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/hooks/*.sh $(for d in $EXTRA_DIRS; do [ -d "$d" ] && echo "$d"/*.sh; done); do
  [ -f "$f" ] || continue
  checked=$((checked + 1))
  out="$("$SYSTEM_BASH" -n "$f" 2>&1)"
  if [ -n "$out" ]; then
    echo "FAIL ${f#$HOME/}"
    echo "$out" | sed 's/^/       /'
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "check_syntax: $checked file(s) checked, at least one does NOT parse under bash $version." >&2
  echo "  Fix before committing. Do not work around it by testing with a newer bash." >&2
  exit 1
fi

echo "check_syntax: $checked file(s) checked, all parse clean under bash $version."
exit 0
