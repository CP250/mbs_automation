#!/bin/bash
# pointer_check.sh - nightly pointer-integrity sweep of the vault.
#
# Fires at 23:45 (com.mbs.pointer-check), 15 min after com.mbs.vault-index
# (23:30) so the freshly regenerated vault_file_tree.md reflects the day's
# writes before this runs. Idempotent: per-day stamp, written on success only
# (house pattern - see vault_index.sh, the closest sibling: pure bash, no
# claude, no network, TZ pinned to America/New_York).
#
# WHAT THIS CHECKS (both pure-local, no network, no claude):
#
#   (a) Broken [[wikilinks]] - WRAPPED, not reimplemented. vault_health.py
#       already has a mature check_broken_links() (alias-aware, archive-aware,
#       attachment-aware). This script shells out to
#       `vault_health.py --json`, keeps only the "broken_link" issues, and
#       drops any whose SOURCE file lives under create/oslo/_corpora/ or
#       health/health_physical/oura/raw/ (both excluded per this job's spec -
#       5,323 poetry-corpus .md files and the Oura raw archive are noise for
#       a pointer-hygiene sweep, not signal). vault_health.py's own
#       EXCLUDE_DIRS is untouched; this script only filters ITS OWN output.
#
#   (b) Broken literal vault-relative paths in _CLAUDE.md, CLAUDE.md, and
#       goals_*.md files - NOT covered by vault_health.py at this scope.
#       vault_health.py's check_doc_path_drift() is deliberately narrow (a
#       curated allowlist of ~8 global docs - SETUP.md, VISION.md, the
#       brain files, ...) because per-folder _CLAUDE.md files legitimately
#       use paths relative to their OWN folder, and checking those against
#       the vault root would be wall-to-wall false positives (see that
#       function's docstring). This check is genuinely additive: it scans
#       EVERY _CLAUDE.md / CLAUDE.md / goals_*.md in the vault (140 + 42 + 1
#       as of 2026-07-30), but ONLY flags a backtick-quoted candidate when it
#       unambiguously LOOKS vault-relative - starts with a known top-level
#       pillar name (admin/, create/, ... - same allowlist vault_health.py
#       uses for the same reason). Scope is deliberately "vault-relative"
#       ONLY, per the spec: a bare "~/..." candidate (home-relative, e.g.
#       ~/dev/mbs_automation/... or ~/storage_mbs_assets/...) is a real and
#       common style in these docs but points OUTSIDE the vault, is often
#       written with doc-shorthand this script can't safely interpret (e.g.
#       "com.mbs.oslo-{weekly,monthly}.plist" brace-expansion prose), and
#       ~/storage_mbs_assets/ subfolders are explicitly "created on demand,
#       never pre-mirrored" per SETUP.md - so a missing one there is not a
#       broken pointer, it's normal. Confirmed empirically 2026-07-30: adding
#       "~/" resolution produced exactly these false positives; dropped
#       rather than special-cased further. Anything else (bare filenames,
#       slash-commands, URLs, template placeholders like <slug> or
#       YYYY-MM-DD) is deliberately left alone too - that is vault_health.py's
#       documented lesson, carried over here rather than relearned.
#
#       For a candidate that DOES match a known pillar prefix, two bases are
#       tried before flagging: vault-root (the doc is describing an absolute
#       vault path) and the referencing file's OWN containing folder (the doc
#       is using a path relative to itself, the same per-folder convention
#       vault_health.py's docstring names as its reason for NOT scanning
#       ordinary _CLAUDE.md files at all). Only flagged if NEITHER resolves.
#
# HARD-RULE COMPLIANCE: trash/ and admin/pn.md are opaque per the vault's
# hard rules (never read/list/search). This script never scans INTO trash/
# (excluded from both the wikilink wrap and the doc-scan find), and any
# candidate literal path that merely MENTIONS trash/ or admin/pn.md is
# skipped outright - not existence-tested, not flagged either way. That is a
# deliberately conservative reading: a single `[ -e ... ]` stat call on a
# named path is arguably not "reading/listing/searching" trash's contents,
# but there is no upside to relying on that distinction, so this script just
# never touches those paths at all.
#
# OUTPUT: a bounded "### Pointer check" block (~20 lines max) appended to
# today's daily_notes/tasks/tasks_YYYY-MM-DD.md. Appended at end-of-file,
# which - per the file's own established convention (P's own notes carried
# above; "## Vault Agent" is always the LAST heading mbs_daily.sh writes; any
# same-day sibling agent append, e.g. lib_auth.sh's "## Automation alerts",
# also just lands after it) - reads as nested under "## Vault Agent" whenever
# that heading is present, which by the time this runs at 23:45 (long after
# the 06:00 daily report and the 11:00 heartbeat) it almost always is. If no
# "## Vault Agent" heading exists at all yet (rare: e.g. the daily job is
# still mid-retry past 23:45), the exact same "### Pointer check" block is
# still appended standalone - see report for why a fabricated "## Vault
# Agent" wrapper was deliberately NOT synthesized (risk of confusing the
# heartbeat's own "## Vault Agent" presence check on a future read).

set -uo pipefail

VAULT="/Users/cpreston/Vaults/storage_mbs"
STATE_DIR="$HOME/.mbs_automation"
STAMP="$STATE_DIR/last_pointer_check_run"
LOG="$STATE_DIR/pointer_check.log"
SCRIPT_DIR="$(dirname "$0")"

mkdir -p "$STATE_DIR"

# Always use Eastern time - P's timezone (matches vault_index.sh).
TODAY="$(TZ=America/New_York date +%Y-%m-%d)"
ts() { TZ=America/New_York date '+%Y-%m-%d %H:%M:%S'; }

# Already ran today? Stop (dedupe - never post twice in one day).
if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$TODAY" ]; then
  echo "$(ts) - already ran for $TODAY, skipping." >> "$LOG"
  exit 0
fi

echo "$(ts) - starting pointer check run" >> "$LOG"

# launchd starts jobs with a minimal PATH; this script depends on python3
# (vault_health.py) and jq, both commonly homebrew-installed at
# /opt/homebrew/bin, which is NOT on that minimal PATH. Same fix as
# mbs_daily.sh (there for `claude`); per SETUP.md's job-authoring checklist,
# pure-bash jobs that only use find/grep/awk/stat/osascript don't strictly
# need this, but this one calls out to python3/jq so it does.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

if [ ! -d "$VAULT" ]; then
  echo "$(ts) - ERROR: vault not found at $VAULT" >> "$LOG"
  exit 1
fi

require_bin() {
  local name="$1" hint="$2"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "$(ts) - ERROR: '$name' not found on PATH. Install with: $hint" >> "$LOG"
    exit 1
  fi
}
require_bin "python3" "brew install python3"
require_bin "jq" "brew install jq"

TMP_DIR="$(mktemp -d "${STATE_DIR}/.pointer_check.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# ── (a) broken wikilinks - wrap vault_health.py, don't reimplement ─────────
VH_JSON="$TMP_DIR/vault_health.json"
if ! python3 "$SCRIPT_DIR/vault_health.py" --path "$VAULT" --json > "$VH_JSON" 2>>"$LOG"; then
  echo "$(ts) - WARNING: vault_health.py exited non-zero; broken-link count may be incomplete" >> "$LOG"
fi

TOTAL_NOTES="$(jq -r '.total_notes // "?"' "$VH_JSON" 2>/dev/null || echo "?")"

FILTERED_LINKS="$TMP_DIR/broken_links_filtered.txt"
jq -r '.issues[]? | select(.type=="broken_link") | .files[0]' "$VH_JSON" 2>/dev/null \
  | grep -vE '^(create/oslo/_corpora/|health/health_physical/oura/raw/)' \
  > "$FILTERED_LINKS" || true

BROKEN_LINK_COUNT="$(wc -l < "$FILTERED_LINKS" | tr -d ' ')"
BROKEN_LINK_TOP="$(sort "$FILTERED_LINKS" | uniq -c | sort -rn | head -5 \
  | awk '{n=$1; $1=""; sub(/^ /,""); printf "  - %d broken link(s) in `%s`\n", n, $0}')"

echo "$(ts) - vault_health.py: $TOTAL_NOTES notes scanned, $BROKEN_LINK_COUNT broken wikilink(s) after excluding _corpora/oura-raw" >> "$LOG"

# ── (b) broken literal vault-relative paths in _CLAUDE.md/CLAUDE.md/goals_*.md
POINTER_FILES="$TMP_DIR/pointer_scope_files.txt"
find "$VAULT" \( -name "_CLAUDE.md" -o -name "CLAUDE.md" -o -name "goals_*.md" \) -type f \
  ! -path "*/trash/*" \
  ! -path "*/.obsidian/*" \
  ! -path "*/create/oslo/_corpora/*" \
  ! -path "*/health/health_physical/oura/raw/*" \
  2>/dev/null | sort > "$POINTER_FILES"

SCOPE_COUNT="$(wc -l < "$POINTER_FILES" | tr -d ' ')"

BROKEN_PATH_LIST="$TMP_DIR/broken_paths.txt"
: > "$BROKEN_PATH_LIST"

while IFS= read -r f; do
  [ -z "$f" ] && continue
  rel_f="${f#"$VAULT"/}"
  case "$rel_f" in
    */*) doc_dir_rel="${rel_f%/*}" ;;
    *)   doc_dir_rel="" ;;   # file sits at vault root (e.g. CLAUDE.md)
  esac
  grep -oE '`[^`]+`' "$f" 2>/dev/null | tr -d '`' | while IFS= read -r cand; do
    cand="$(printf '%s' "$cand" | sed -E 's/[.,;:)]+$//')"
    case "$cand" in
      */*) : ;;
      *) continue ;;
    esac
    case "$cand" in
      *'<'*|*'{'*|*'*'*|*YYYY*|http://*|https://*|mailto:*) continue ;;
    esac
    case "$cand" in
      trash/*|*/trash/*|admin/pn.md|*/pn.md) continue ;;  # opaque - never test, never flag
    esac
    # Strip all trailing slashes, then require an INTERNAL slash beyond that.
    # A bare single-segment mention like `_archive/` or `trash/` illustrates
    # the PER-FOLDER convention ("every folder gets its own _archive/"), not
    # one specific vault-root instance - vault_health.py's
    # _looks_like_real_path() filters the identical case for the identical
    # reason ("too generic to check"); mirrored here rather than relearned.
    rstripped="$cand"
    while [ "${rstripped%/}" != "$rstripped" ]; do rstripped="${rstripped%/}"; done
    case "$rstripped" in
      */*) : ;;
      *) continue ;;
    esac
    case "$cand" in
      admin/*|create/*|culture/*|daily_notes/*|health/*|money/*|skills/*|social/*|sports/*|captured/*|attachments/*|_archive/*)
        # Try TWO bases before flagging: vault-root (the doc IS describing an
        # absolute vault path), then the referencing file's OWN folder (the
        # doc is using a path relative to itself - the exact convention
        # vault_health.py's check_doc_path_drift() docstring calls out as why
        # it does not scan ordinary per-folder _CLAUDE.md files: "per-folder
        # _CLAUDE.md files legitimately use paths relative to their OWN
        # folder". Confirmed empirically 2026-07-30: money/network/resume/
        # _CLAUDE.md's `_archive/20260321_verition_resume_section.md` only
        # resolves under the second base, not the first.
        [ -e "$VAULT/$cand" ] && continue
        if [ -n "$doc_dir_rel" ] && [ -e "$VAULT/$doc_dir_rel/$cand" ]; then continue; fi
        ;;
      *)
        continue  # not unambiguously vault-relative - skip (avoid vault_health.py's documented false-positive trap)
        ;;
    esac
    printf '%s\t%s\n' "$cand" "$rel_f" >> "$BROKEN_PATH_LIST"
  done
done < "$POINTER_FILES"

# Dedupe identical (path, file) pairs - the same backtick candidate can
# legitimately appear more than once in one doc (e.g. repeated in separate
# bullets), and should count as one finding, not one per mention.
BROKEN_PATH_DEDUPED="$TMP_DIR/broken_paths_deduped.txt"
sort -u "$BROKEN_PATH_LIST" > "$BROKEN_PATH_DEDUPED"

BROKEN_PATH_COUNT="$(wc -l < "$BROKEN_PATH_DEDUPED" | tr -d ' ')"
BROKEN_PATH_TOP="$(head -5 "$BROKEN_PATH_DEDUPED" \
  | awk -F'\t' '{printf "  - `%s` in `%s`\n", $1, $2}')"

echo "$(ts) - doc scan: $SCOPE_COUNT files (_CLAUDE.md/CLAUDE.md/goals_*.md), $BROKEN_PATH_COUNT broken literal path(s)" >> "$LOG"

# ── build the bounded block ─────────────────────────────────────────────────
if [ "$BROKEN_LINK_COUNT" -eq 0 ] && [ "$BROKEN_PATH_COUNT" -eq 0 ]; then
  BLOCK="Clean: 0 broken wikilinks, 0 broken literal paths ($SCOPE_COUNT _CLAUDE.md/CLAUDE.md/goals_*.md files scanned; vault_health.py scanned $TOTAL_NOTES notes). Log: \`~/.mbs_automation/pointer_check.log\`"
else
  BLOCK="**Broken wikilinks:** ${BROKEN_LINK_COUNT} (via vault_health.py, excluding _corpora/oura-raw)"
  if [ -n "$BROKEN_LINK_TOP" ]; then
    BLOCK="${BLOCK}
${BROKEN_LINK_TOP}"
  fi
  BLOCK="${BLOCK}

**Broken literal paths** in _CLAUDE.md/CLAUDE.md/goals_*.md (${SCOPE_COUNT} files scanned): ${BROKEN_PATH_COUNT}"
  if [ -n "$BROKEN_PATH_TOP" ]; then
    BLOCK="${BLOCK}
${BROKEN_PATH_TOP}"
  fi
  BLOCK="${BLOCK}

Full detail: \`~/.mbs_automation/pointer_check.log\`"
fi

# ── append to today's tasks note ────────────────────────────────────────────
TASKS_NOTE="$VAULT/daily_notes/tasks/tasks_${TODAY}.md"
if [ ! -f "$TASKS_NOTE" ]; then
  mkdir -p "$(dirname "$TASKS_NOTE")"
  cat > "$TASKS_NOTE" <<EOF
---
journal: tasks
journal-date: ${TODAY}
---



EOF
  echo "$(ts) - pre-flight: created minimal $TASKS_NOTE" >> "$LOG"
fi

if grep -qE '^## Vault Agent' "$TASKS_NOTE" 2>/dev/null; then
  echo "$(ts) - ## Vault Agent section present; appending Pointer check after it" >> "$LOG"
else
  echo "$(ts) - no ## Vault Agent heading found; appending Pointer check as a standalone section" >> "$LOG"
fi

{
  echo ""
  echo "### Pointer check"
  echo ""
  echo "$BLOCK"
} >> "$TASKS_NOTE"

echo "$TODAY" > "$STAMP"
echo "$(ts) - appended Pointer check block to $TASKS_NOTE; stamped $TODAY" >> "$LOG"
exit 0
