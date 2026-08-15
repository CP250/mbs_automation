#!/bin/bash
# the_record.sh - process new "The Record" transcripts as they land.
#
# Part of P's Verition capture-and-synthesis pipeline (money/project_the_record).
# Unlike the calendar-anchored jobs (mbs_daily, weekly_blocks), this one is
# EVENT-ANCHORED by design - it fires when a transcript appears in raw/, not on
# a clock. That matches the project's core rule: capture is event-triggered, and
# P will not drop files on a schedule.
#
# Triggered by launchd (see launchd/com.mbs.the-record.plist):
#   1. WatchPaths on the raw/ folder - fires when a file is added or changed.
#   2. RunAtLoad at login - catches transcripts dropped while logged out.
#
# Idempotence: a processed-manifest ($MANIFEST) records every transcript already
# handled. Each run diffs raw/*.md against it and only processes genuinely new
# files, so repeated WatchPaths fires (e.g. Obsidian Sync writing a file in
# chunks) never double-process. The manifest is appended only on success.
#
# What it does per new transcript, via `claude -p` (headless, in the vault):
#   - extracts candidate lessons into verition_lessons.md
#   - draws parallels to the project_management_arc books
#   - weaves the content into verition_history.md chronologically, flagging
#     inconsistencies against what's already there
#   - appends a "## The Record" section to today's tasks note with
#     inconsistency questions, blind spots, and a recommended next capture

set -uo pipefail

VAULT="/Users/cpreston/Vaults/storage_mbs"
RECORD_DIR="$VAULT/money/project_the_record"
RAW_DIR="$RECORD_DIR/raw"
STATE_DIR="$HOME/.mbs_automation"
MANIFEST="$STATE_DIR/the_record_processed.txt"
LOG="$STATE_DIR/the_record.log"

mkdir -p "$STATE_DIR"
touch "$MANIFEST"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Source auth-failure detection helpers (run_claude_p, needs_reauth_skip, ...).
# shellcheck source=./lib_auth.sh
source "$(dirname "$0")/lib_auth.sh"

# Pre-flight: skip cleanly if Claude Code needs re-auth.
if needs_reauth_skip "$LOG"; then
  exit 0
fi

# Single-instance lock (WatchPaths can fire several times in quick succession).
LOCK_DIR="$STATE_DIR/the_record.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  HOLDER_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -n "${HOLDER_PID:-}" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
    echo "$(ts) - another instance is running (PID $HOLDER_PID), exiting cleanly" >> "$LOG"
    exit 0
  fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || { echo "$(ts) - ERROR: could not claim lock" >> "$LOG"; exit 1; }
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

# Find new transcripts: raw/*.md whose basename is not yet in the manifest.
NEW_FILES=()
while IFS= read -r f; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  if ! grep -Fxq "$base" "$MANIFEST"; then
    NEW_FILES+=("$base")
  fi
done < <(find "$RAW_DIR" -maxdepth 1 -type f -name '*.md' | sort)

if [ "${#NEW_FILES[@]}" -eq 0 ]; then
  echo "$(ts) - no new transcripts, nothing to do." >> "$LOG"
  exit 0
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  echo "$(ts) - ERROR: 'claude' not found on PATH. Aborting." >> "$LOG"
  exit 1
fi

FILE_LIST="$(printf 'raw/%s ' "${NEW_FILES[@]}")"
echo "$(ts) - processing ${#NEW_FILES[@]} new transcript(s): $FILE_LIST (claude: $CLAUDE_BIN)" >> "$LOG"

cd "$VAULT" || { echo "$(ts) - ERROR: cannot cd to $VAULT" >> "$LOG"; exit 1; }

PROMPT="Unattended run of the-record job for the vault at $VAULT. FIRST read admin/mbs_system/brain/CLAUDE.md, then money/project_the_record/_HANDOFF.md and money/project_the_record/rules.md - they govern this work and override defaults. New transcript(s) to process, in money/project_the_record/: $FILE_LIST. For each, do all of the following, writing via the filesystem (NOT the Obsidian MCP): (1) Extract candidate lessons into money/project_the_record/verition_lessons.md under '## Candidate lessons (inbox - unconfirmed)', each as a portable principle plus its Verition origin; do not promote into the confirmed body - that is P's call. (2) For each candidate lesson, name the parallel book(s) in money/project_management_arc/ref_manager_to_executive_arc.md (Leadership Pipeline, What Got You Here, CEO Next Door, High Output Management, The Effective Executive, Pfeffer's Power). (3) Weave the transcript into money/project_the_record/verition_history.md in chronological position, and flag with a 🚩 any inconsistency against what is already there (dates, names, sequence). (4) Append a '## The Record' section to today's daily_notes/tasks/tasks_$(date +%Y-%m-%d).md containing: inconsistency questions, omissions/blind spots, and ONE recommended next person/period/situation to capture; format each as a '- [ ]' task with #money and a short 🆔. Respect discretion (rules.md): this material is private, never referenced in Verition-/Polar-facing work. Do NOT push a cadence, deadline, or target length. Keep edits additive; do not rewrite existing confirmed lessons or prior history prose beyond inserting the new material and its flags."

run_claude_p "$PROMPT" "$LOG"
rc=$?
if [ "$rc" -eq 0 ]; then
  clear_reauth_sentinel
  printf '%s\n' "${NEW_FILES[@]}" >> "$MANIFEST"
  echo "$(ts) - done; recorded ${#NEW_FILES[@]} transcript(s) in manifest." >> "$LOG"
elif [ "$rc" -eq 2 ]; then
  mark_reauth_needed "$LOG"
  echo "$(ts) - blocked on Claude auth; no manifest update. Retries after re-auth." >> "$LOG"
  exit 2
else
  echo "$(ts) - ERROR: run exited $rc; no manifest update, will retry on next trigger." >> "$LOG"
  exit "$rc"
fi
