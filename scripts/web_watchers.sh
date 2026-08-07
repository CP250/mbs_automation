#!/bin/bash
# web_watchers.sh — daily web-page change-watcher driven by admin/web_watchers.md.
#
# Reads the YAML list embedded in admin/web_watchers.md, iterates active watchers,
# applies per-watcher frequency stamps, fetches each due URL, asks Claude (via
# `claude -p`) the watcher's `what_to_watch` question, compares against the
# last-known answer in the state file, and fires a notification when the answer
# changes.
#
# Pairs with mbs_daily.sh / mbs_weekly.sh / oslo_weekly.sh — same launchd idiom
# (state dir, per-period stamp, PATH export, log to ~/.mbs_automation/).
#
# Triggered by launchd (see scripts/launchd/com.mbs.web-watchers.plist):
#   1. StartCalendarInterval daily 08:30 local.
#   2. Wake from sleep — launchd coalesces the missed fire and runs on wake.
#   3. RunAtLoad at login — covers a powered-off Mac.
#
# Two stamp layers:
#   - Outer: ~/.mbs_automation/last_web_watchers_run — once-per-day idempotency
#     for the JOB itself. If the job has already run today, exit 0.
#   - Inner: ~/.mbs_automation/last_web_watchers_<slug>_run — per-watcher
#     idempotency based on its declared frequency (daily | weekly | monthly).
#     A `weekly` watcher checked yesterday will skip today.
#
# State file:
#   - ~/.mbs_automation/web_watchers_state.json — one entry per slug with the
#     last-known Claude answer plus a timestamp. Lives outside the vault so
#     repeated checks don't generate vault git commits.
#
# Notifications:
#   - `notification: email` — uses lib_email.sh (sourced). Subject prefixed with
#     "web_watchers:". Body = the change description Claude produced.
#   - `notification: daily_note` — appends a `## Web Watchers — <date>` section
#     to today's tasks note in the Vault Agent reply-loop format.
#
# Failure handling:
#   - curl failure (network, 404, timeout): logged, watcher's per-slug error
#     counter incremented in state. Three consecutive errors fires a daily-note
#     nudge per watcher ("watcher <slug> has failed 3 consecutive fires").
#   - claude -p failure: same model — counted, not propagated as a job failure.
#   - YAML parse failure (yq fails): job ABORTS with non-zero, no stamp written,
#     so next launchd trigger retries. The watch-list file is the spec.

set -uo pipefail

# ----------------------------------------------------------------------------
# Constants and paths
# ----------------------------------------------------------------------------

VAULT="/Users/cpreston/Vaults/storage_mbs"
WATCH_LIST="$VAULT/admin/web_watchers.md"
STATE_DIR="$HOME/.mbs_automation"
STATE_FILE="$STATE_DIR/web_watchers_state.json"
STAMP="$STATE_DIR/last_web_watchers_run"
LOG="$STATE_DIR/web_watchers.log"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ERROR_THRESHOLD=3

mkdir -p "$STATE_DIR"

TODAY="$(date +%Y-%m-%d)"
NOW="$(date +%H:%M)"
DAILY_NOTE="$VAULT/daily_notes/tasks/tasks_${TODAY}.md"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# ----------------------------------------------------------------------------
# Outer once-per-day stamp
# ----------------------------------------------------------------------------

if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$TODAY" ]; then
  echo "$(ts) — already ran for $TODAY, skipping." >> "$LOG"
  exit 0
fi

# ----------------------------------------------------------------------------
# Auth-failure pre-flight (lib_auth.sh)
# ----------------------------------------------------------------------------

# shellcheck source=./lib_auth.sh
source "$LIB_DIR/lib_auth.sh"

if needs_reauth_skip "$LOG"; then
  exit 0
fi

# ----------------------------------------------------------------------------
# PATH and prerequisites
# ----------------------------------------------------------------------------

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

require_bin() {
  local name="$1"
  local install_hint="$2"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "$(ts) — ERROR: '$name' not found on PATH. Install with: $install_hint" >> "$LOG"
    exit 1
  fi
}

require_bin "yq" "brew install yq"
require_bin "jq" "brew install jq"
require_bin "curl" "(comes with macOS)"
require_bin "claude" "see ~/.claude/ install docs"

# Source the email helper. lib_email.sh exposes send_email().
# shellcheck source=./lib_email.sh
source "$LIB_DIR/lib_email.sh"

# ----------------------------------------------------------------------------
# Pre-flight network gate (2026-07-07 hardening, ported from mbs_daily.sh):
# the 08:30 fire (or a wake-coalesced fire) can land in a dark-wake window
# before Wi-Fi/DNS has reconnected, so every curl in the loop would burn on a
# could-not-resolve failure that has nothing to do with the watched URLs. This
# is what produced the analogue_3d_firmware 5-consecutive-failures false alarm
# of 2026-07-03..07. Poll a known-good host for up to ~2 min before starting;
# proceed regardless once reachable or the budget is exhausted (the per-fetch
# retry loop below still covers a genuine outage). On a healthy morning the
# first probe returns immediately, so this adds no meaningful delay.
# ----------------------------------------------------------------------------

NETWORK_PROBE_URL="https://api.anthropic.com/"

# One-shot probe: is the network up right now? curl exit 0 or any HTTP-level
# response = reachable; exit 6 (DNS), 7 (refused), 28 (timeout), 35 (TLS) = not.
network_up() {
  curl -sS --max-time 5 -o /dev/null "$NETWORK_PROBE_URL" 2>/dev/null
  case "$?" in
    6|7|28|35) return 1 ;;
    *)         return 0 ;;
  esac
}

wait_for_network() {
  local max_tries=12 i
  for i in $(seq 1 "$max_tries"); do
    if network_up; then
      echo "$(ts) — network reachable after $i check(s)" >> "$LOG"
      return 0
    fi
    echo "$(ts) — network not ready; waiting 10s ($i/$max_tries)" >> "$LOG"
    sleep 10
  done
  echo "$(ts) — network still not ready after $max_tries checks; proceeding anyway" >> "$LOG"
  return 1
}

wait_for_network

echo "$(ts) — starting web-watchers run for $TODAY" >> "$LOG"

# ----------------------------------------------------------------------------
# Ensure state file exists with at least an empty object
# ----------------------------------------------------------------------------

if [ ! -f "$STATE_FILE" ]; then
  echo '{}' > "$STATE_FILE"
  echo "$(ts) — initialized empty state file at $STATE_FILE" >> "$LOG"
fi

# ----------------------------------------------------------------------------
# Ensure today's tasks file exists (in case mbs_daily.sh hasn't run yet today)
# ----------------------------------------------------------------------------

if [ ! -f "$DAILY_NOTE" ]; then
  mkdir -p "$(dirname "$DAILY_NOTE")"
  cat > "$DAILY_NOTE" <<EOF
---
journal: tasks
journal-date: $TODAY
---

EOF
  echo "$(ts) — pre-flight: created minimal $DAILY_NOTE" >> "$LOG"
fi

# ----------------------------------------------------------------------------
# Extract the YAML watcher list from the markdown file.
#
# admin/web_watchers.md contains exactly ONE ```yaml fenced block (the watcher
# list). awk pulls everything between the opening fence and the next fence.
# ----------------------------------------------------------------------------

TMP_YAML="$(mktemp -t web_watchers_yaml.XXXXXX)"
trap 'rm -f "$TMP_YAML"' EXIT

awk '
  /^```yaml[[:space:]]*$/ { in_block = 1; next }
  /^```[[:space:]]*$/     { if (in_block) { in_block = 0; exit } }
  in_block                { print }
' "$WATCH_LIST" > "$TMP_YAML"

if [ ! -s "$TMP_YAML" ]; then
  echo "$(ts) — ERROR: could not extract YAML block from $WATCH_LIST. Aborting." >> "$LOG"
  exit 1
fi

# Validate YAML parses + has the expected list shape.
if ! yq eval '. | type == "!!seq"' "$TMP_YAML" >/dev/null 2>&1; then
  echo "$(ts) — ERROR: extracted YAML is not a sequence (list). Aborting." >> "$LOG"
  exit 1
fi

WATCHER_COUNT="$(yq eval 'length' "$TMP_YAML")"
echo "$(ts) — parsed $WATCHER_COUNT watcher(s) from $WATCH_LIST" >> "$LOG"

# ----------------------------------------------------------------------------
# Helper: get/set per-slug state in the JSON state file
# ----------------------------------------------------------------------------

state_get() {
  local slug="$1"
  local field="$2"
  jq -r --arg slug "$slug" --arg field "$field" '.[$slug][$field] // ""' "$STATE_FILE"
}

state_set() {
  local slug="$1"
  local field="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp -t web_watchers_state.XXXXXX)"
  jq --arg slug "$slug" --arg field "$field" --arg value "$value" \
    '.[$slug] = (.[$slug] // {}) | .[$slug][$field] = $value' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_inc_errors() {
  local slug="$1"
  local current
  current="$(state_get "$slug" "consecutive_errors")"
  current="${current:-0}"
  state_set "$slug" "consecutive_errors" "$((current + 1))"
}

state_reset_errors() {
  state_set "$1" "consecutive_errors" "0"
}

# ----------------------------------------------------------------------------
# Helper: per-watcher frequency gate
# ----------------------------------------------------------------------------

is_due_today() {
  local slug="$1"
  local frequency="$2"
  local stamp="$STATE_DIR/last_web_watchers_${slug}_run"

  if [ ! -f "$stamp" ]; then
    return 0   # never run → due
  fi

  local last
  last="$(cat "$stamp" 2>/dev/null)"

  case "$frequency" in
    daily)
      [ "$last" != "$TODAY" ]
      ;;
    weekly)
      local this_week
      this_week="$(date +%G-W%V)"
      [ "$last" != "$this_week" ]
      ;;
    monthly)
      local this_month
      this_month="$(date +%Y-%m)"
      [ "$last" != "$this_month" ]
      ;;
    *)
      echo "$(ts) — WARN: unknown frequency '$frequency' for $slug, treating as daily" >> "$LOG"
      [ "$last" != "$TODAY" ]
      ;;
  esac
}

stamp_watcher() {
  local slug="$1"
  local frequency="$2"
  local stamp="$STATE_DIR/last_web_watchers_${slug}_run"
  case "$frequency" in
    daily)   echo "$TODAY" > "$stamp" ;;
    weekly)  date +%G-W%V > "$stamp" ;;
    monthly) date +%Y-%m > "$stamp" ;;
    *)       echo "$TODAY" > "$stamp" ;;
  esac
}

# ----------------------------------------------------------------------------
# Helper: notify daily note
# ----------------------------------------------------------------------------

DAILY_NOTE_HEADER_WRITTEN=0
daily_note_header() {
  if [ "$DAILY_NOTE_HEADER_WRITTEN" -eq 0 ]; then
    {
      echo ""
      echo "## Web Watchers — $TODAY"
      echo ""
      echo "**$NOW** — web_watchers | change events from this morning's run."
      echo ""
    } >> "$DAILY_NOTE"
    DAILY_NOTE_HEADER_WRITTEN=1
  fi
}

notify_daily_note() {
  local slug="$1"
  local url="$2"
  local change_description="$3"
  local prior_state="${4:-}"
  daily_note_header
  {
    echo "- [ ] **\`$slug\`** changed: $change_description"
    echo "    url: $url"
    if [ -n "$prior_state" ]; then
      echo "    previous: $prior_state"
    fi
    echo "    proposed: act on the change (review, schedule, etc.)"
    echo "    status:    "
    echo "    reply:"
    echo ""
  } >> "$DAILY_NOTE"
  echo "$(ts) — notified daily-note for $slug" >> "$LOG"
}

notify_email() {
  local slug="$1"
  local url="$2"
  local change_description="$3"
  local prior_state="${4:-}"
  local subject="web_watchers: $slug changed"
  local body_file
  body_file="$(mktemp -t web_watchers_body.XXXXXX)"
  {
    echo "Watcher: $slug"
    echo "URL: $url"
    echo "Detected at: $(ts)"
    echo ""
    echo "--- Current state ---"
    echo "$change_description"
    if [ -n "$prior_state" ]; then
      echo ""
      echo "--- Previous state ---"
      echo "$prior_state"
    fi
  } > "$body_file"

  if send_email "chris.preston@gmail.com" "$subject" "$body_file"; then
    echo "$(ts) — notified email for $slug" >> "$LOG"
  else
    echo "$(ts) — ERROR: email send failed for $slug" >> "$LOG"
  fi
  rm -f "$body_file"
}

# ----------------------------------------------------------------------------
# Helper: ask Claude the what_to_watch question against the fetched page
# ----------------------------------------------------------------------------

ask_claude() {
  local what_to_watch="$1"
  local page_text_file="$2"
  local prompt
  prompt="$(cat <<PROMPT_EOF
You are extracting a CANONICAL, DETERMINISTIC snapshot of specific facts from a web page, for exact-string comparison against tomorrow's snapshot of the same page. Two runs of you, given byte-identical page text, must produce byte-identical output. You will be given:
1. A question describing exactly what facts to extract.
2. The page text (visible text only; HTML tags and scripts are already stripped by the caller).

Rules:
- Extract ONLY the facts the question asks for, using ONLY information from the page text. Quote dates, version numbers, prices, and proper nouns exactly as they appear.
- Do NOT editorialize, do NOT comment on whether this is a first check or a repeat check, do NOT mention "last check", "baseline", or any other run of this prompt. You have no memory of prior runs and must not refer to one. Your only input is the page text given below, right now.
- If the question asks for a list, output one item per line in the exact field order and format the question specifies, in the order the items appear on the page. Do NOT sort or reorder the list yourself: the calling script sorts your output afterward, so matching page order is all that's required of you.
- Never show your work or reconsider out loud. If you notice a mistake partway through, silently discard it and output only the corrected final answer. The output must contain no trace of an earlier attempt: no "wait", no "actually", no visible self-correction of any kind. If you're not confident about a specific field for a specific item, re-check it against the page text before writing it, rather than writing a guess and correcting it visibly afterward.
- If the page does not contain enough information to extract the requested facts, output exactly "INSUFFICIENT_INFO" and nothing else, no explanation, no partial data.
- Output ONLY the extracted facts (or INSUFFICIENT_INFO). No preamble, no restated question, no markdown headings, no trailing remarks.

QUESTION:
$what_to_watch

PAGE TEXT:
$(cat "$page_text_file")
PROMPT_EOF
  )"
  # Wrap with auth detection. Because this function is called inside command
  # substitution ($(ask_claude ...)), `exit` from here would only exit the
  # subshell. Instead, on 401, touch a flag file the main loop polls between
  # watchers and aborts cleanly.
  local temp
  temp="$(mktemp -t web_watchers_claude.XXXXXX)"
  claude -p "$prompt" --model opus --dangerously-skip-permissions > "$temp" 2>>"$LOG"
  if la_is_credit_failure "$temp"; then
    alert_tasks_note "Automated run failed: web-watchers is out of Claude usage credits (model: opus). Some watchers did not run — top up (/usage-credits) or switch model (/model)."
    touch "$STATE_DIR/.web_watchers_auth_failed"
    rm -f "$temp"
    echo "INSUFFICIENT_INFO"
    return 2
  fi
  # Auth patterns come from $LA_AUTH_FAIL_RE in lib_auth.sh — single source of
  # truth. Before 2026-07-26 this grep was inlined and too narrow, so an expired
  # OAuth session was stored verbatim as a watcher answer, silently destroying
  # both baselines and reporting "no change (byte-equal)".
  if la_is_auth_failure "$temp"; then
    mark_reauth_needed "$LOG"
    touch "$STATE_DIR/.web_watchers_auth_failed"
    rm -f "$temp"
    echo "INSUFFICIENT_INFO"
    return 2
  fi
  cat "$temp"
  rm -f "$temp"
}

# ----------------------------------------------------------------------------
# NOTE (2026-08-07): a "semantic_equality" LLM judge used to live here,
# comparing prior vs. new free-form paragraphs and returning SAME/DIFFERENT
# to suppress false alarms from LLM phrasing variance. It was removed: it was
# itself non-deterministic and produced false "DIFFERENT" verdicts on
# unchanged pages (analogue_3d_firmware fired 4 false "changed" emails
# 2026-08-01..08-04 and again 08-07 for a firmware version that never moved;
# see ~/.mbs_automation/web_watchers.log). Root cause traced to ask_claude()
# producing non-deterministic wording even for identical page content, which
# made byte comparison unreliable, which made this LLM judge the load-bearing
# gate for every fire — and it was wrong more often than not.
#
# Fix: ask_claude() above now demands a canonical, deterministic snapshot
# (fixed field order, sorted lists, no editorializing, no self-reference to
# "prior checks"). With that in place, plain byte-equality is the correct and
# sufficient comparison — no second LLM call needed. See
# admin/mbs_system/_logs/log_2026-08-07_web_watchers_fix.md for the full
# writeup.
#
# ROUND 2 (2026-08-07, same day): a live test of the round-1 fix immediately
# false-fired on artdog_philip_williams: two back-to-back calls against the
# byte-identical fetched page produced different output, a visible
# self-correction ("Wait, sorted alphabetically...") whose wording changed
# between calls, AND a genuine extraction error (IN THE FOREGROUND A DUKE
# flipped available -> sold, confirmed against the raw page: it was actually
# sold both times). Root cause traced past the prompt to the INPUT: the fetched
# page is raw HTML (100-150KB of Squarespace config JSON, <script>/<style>
# noise) with maybe 3KB of actual visible content, and the model was losing
# track of which "Sold" badge belonged to which title across all that noise.
# Two changes: (1) page text is now run through html_to_text.py (stdlib-only
# HTML stripper) before it ever reaches ask_claude(), so the model sees only
# visible text; (2) list sorting moved out of the model's job into a plain
# `sort` in bash, removing the specific instruction that triggered the visible
# self-correction. Neither change makes a single LLM call provably
# deterministic, so a third change closes the gap structurally: on any
# byte-diff from baseline, the main loop below re-asks Claude a second,
# independent time on the same already-fetched text and only fires a
# notification if both reads agree. Disagreement is logged and treated as
# inconclusive (baseline preserved, retried next scheduled run), not as a
# change. This is two-sample agreement on a mechanical string compare, not a
# reintroduction of the round-1 LLM judge: the failure mode there was an LLM
# *judging* semantic sameness, this is bash doing `[ "$a" = "$b" ]` on two
# independent extractions.
# ----------------------------------------------------------------------------
# Main loop — iterate watchers
# ----------------------------------------------------------------------------

PROCESSED=0
CHANGED=0
SKIPPED_INACTIVE=0
SKIPPED_NOT_DUE=0
ERRORS=0

for i in $(seq 0 $((WATCHER_COUNT - 1))); do
  # Auth-failure short-circuit: ask_claude() touches this flag file when it
  # detects a 401. Stop processing further watchers; mark the sentinel; exit
  # non-zero so launchd doesn't stamp success.
  if [ -f "$STATE_DIR/.web_watchers_auth_failed" ]; then
    rm -f "$STATE_DIR/.web_watchers_auth_failed"
    mark_reauth_needed "$LOG"
    echo "$(ts) — aborting watcher loop on Claude Code auth failure; $PROCESSED of $WATCHER_COUNT processed before abort. Next trigger after re-auth will retry from scratch." >> "$LOG"
    exit 2
  fi

  slug="$(yq eval ".[$i].slug" "$TMP_YAML")"
  url="$(yq eval ".[$i].url" "$TMP_YAML")"
  frequency="$(yq eval ".[$i].frequency" "$TMP_YAML")"
  notification="$(yq eval ".[$i].notification" "$TMP_YAML")"
  what_to_watch="$(yq eval ".[$i].what_to_watch" "$TMP_YAML")"
  active="$(yq eval ".[$i].active" "$TMP_YAML")"

  if [ "$active" != "true" ]; then
    SKIPPED_INACTIVE=$((SKIPPED_INACTIVE + 1))
    echo "$(ts) — [$slug] inactive, skipping" >> "$LOG"
    continue
  fi

  if ! is_due_today "$slug" "$frequency"; then
    SKIPPED_NOT_DUE=$((SKIPPED_NOT_DUE + 1))
    echo "$(ts) — [$slug] not due (frequency=$frequency), skipping" >> "$LOG"
    continue
  fi

  echo "$(ts) — [$slug] fetching $url" >> "$LOG"

  # Fetch with network-aware retry (2026-07-07 hardening). A failed curl is
  # only a WATCHER error if the network itself is up — otherwise it's the
  # Mac's morning dark-wake window and retrying later is the fix, not
  # incrementing the slug's error counter. Same backoff schedule as
  # mbs_daily.sh; `sleep` pauses while the Mac sleeps, so these effectively
  # wait for "awake" time.
  page_file="$(mktemp -t web_watchers_page.XXXXXX)"
  FETCH_RETRY_DELAYS=(300 600 1800 3600)
  fetch_ok=0
  url_error=0
  for attempt in 1 2 3 4 5; do
    if curl -sSL --max-time 30 --user-agent "Mozilla/5.0 (web_watchers/1.0)" "$url" > "$page_file" 2>>"$LOG"; then
      fetch_ok=1
      break
    fi
    if network_up; then
      # Network is fine; the watched URL itself is failing. Real error.
      url_error=1
      break
    fi
    if [ "$attempt" -lt 5 ]; then
      delay="${FETCH_RETRY_DELAYS[$((attempt - 1))]}"
      echo "$(ts) — [$slug] curl failed with network down; sleeping ${delay}s before fetch retry $((attempt + 1))/5" >> "$LOG"
      sleep "$delay"
    fi
  done

  if [ "$fetch_ok" -ne 1 ] && [ "$url_error" -ne 1 ]; then
    # Network never came back across ~1.75 hr of awake-time. Abort the whole
    # run WITHOUT the outer stamp so the next launchd trigger (login, wake
    # coalesce, or tomorrow 08:30) retries from scratch. Watchers already
    # processed this run keep their per-slug stamps and won't re-fire. No
    # per-slug error counters are touched — this is not a watcher problem.
    echo "$(ts) — [$slug] ERROR: network still down after all fetch retries; aborting run without outer stamp" >> "$LOG"
    rm -f "$page_file"
    exit 1
  fi

  if [ "$url_error" -eq 1 ]; then
    echo "$(ts) — [$slug] ERROR: curl failed (network up — URL problem)" >> "$LOG"
    state_inc_errors "$slug"
    ERRORS=$((ERRORS + 1))
    err_count="$(state_get "$slug" "consecutive_errors")"
    if [ "$err_count" -ge "$ERROR_THRESHOLD" ]; then
      notify_daily_note "$slug" "$url" "**FAILED $err_count consecutive fires** — check URL or pause this watcher in admin/web_watchers.md"
    fi
    rm -f "$page_file"
    continue
  fi

  if [ ! -s "$page_file" ]; then
    echo "$(ts) — [$slug] ERROR: empty page response" >> "$LOG"
    state_inc_errors "$slug"
    ERRORS=$((ERRORS + 1))
    rm -f "$page_file"
    continue
  fi

  # Strip HTML down to visible text before handing it to Claude (2026-08-07
  # round 2; see the ROUND 2 note above ask_claude() for why).
  text_file="$(mktemp -t web_watchers_text.XXXXXX)"
  if ! python3 "$LIB_DIR/html_to_text.py" "$page_file" > "$text_file" 2>>"$LOG"; then
    echo "$(ts) — [$slug] WARN: html_to_text conversion failed; falling back to raw page text" >> "$LOG"
    cp "$page_file" "$text_file"
  fi
  rm -f "$page_file"

  # Ask Claude. Output is sorted in bash, not by the model (2026-08-07 round 2;
  # see ask_claude()'s prompt rules above).
  echo "$(ts) — [$slug] asking claude for semantic answer" >> "$LOG"
  new_answer="$(ask_claude "$what_to_watch" "$text_file" | sort)"

  if [ -z "$new_answer" ]; then
    echo "$(ts) — [$slug] ERROR: claude returned empty answer" >> "$LOG"
    state_inc_errors "$slug"
    ERRORS=$((ERRORS + 1))
    rm -f "$text_file"
    continue
  fi

  # Belt-and-braces (2026-07-26): never persist a CLI failure message as a
  # watcher answer, even if a future wording slips past the detectors above.
  # Storing one destroys the baseline AND reports "no change" when both days
  # fail with the same message — exactly what happened on 2026-07-25/26.
  if printf '%s' "$new_answer" | grep -q -iE "$LA_AUTH_FAIL_RE|$LA_CREDIT_FAIL_RE"; then
    echo "$(ts) — [$slug] ERROR: answer looks like a CLI failure message; refusing to store (baseline preserved)" >> "$LOG"
    touch "$STATE_DIR/.web_watchers_auth_failed"
    state_inc_errors "$slug"
    ERRORS=$((ERRORS + 1))
    rm -f "$text_file"
    continue
  fi

  # Reset error counter on a successful fetch+analyze
  state_reset_errors "$slug"

  prior_answer="$(state_get "$slug" "last_answer")"

  if [ -z "$prior_answer" ]; then
    # First observation for this slug — store, don't notify
    echo "$(ts) — [$slug] first observation, storing baseline (no notify)" >> "$LOG"
    state_set "$slug" "last_answer" "$new_answer"
    state_set "$slug" "last_checked" "$(ts)"
    stamp_watcher "$slug" "$frequency"
    PROCESSED=$((PROCESSED + 1))
    rm -f "$text_file"
    continue
  fi

  if [ "$new_answer" = "$prior_answer" ]; then
    echo "$(ts) — [$slug] no change (byte-equal)" >> "$LOG"
    state_set "$slug" "last_checked" "$(ts)"
    stamp_watcher "$slug" "$frequency"
    PROCESSED=$((PROCESSED + 1))
    rm -f "$text_file"
    continue
  fi

  # Byte-different from baseline. ask_claude() is asked to be deterministic,
  # but no single LLM call is provably deterministic: confirm with a second,
  # independent extraction on the SAME already-fetched page text before
  # treating this as a real change (2026-08-07 round 2; see the ROUND 2 note
  # above ask_claude() for the incident that motivated this). This is a plain
  # string-equality check between two independent reads, not a reintroduction
  # of the round-1 LLM semantic judge.
  echo "$(ts) — [$slug] byte-different from baseline; re-asking claude to confirm before notifying" >> "$LOG"
  confirm_answer="$(ask_claude "$what_to_watch" "$text_file" | sort)"
  rm -f "$text_file"

  if [ "$confirm_answer" != "$new_answer" ]; then
    echo "$(ts) — [$slug] NOT CONFIRMED: two independent reads of the same page text disagree; treating as extraction noise, not a real change. Baseline preserved; will retry next scheduled run." >> "$LOG"
    state_set "$slug" "last_checked" "$(ts)"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  echo "$(ts) — [$slug] CHANGE DETECTED (byte-different, confirmed by independent 2nd read)" >> "$LOG"
  CHANGED=$((CHANGED + 1))

  case "$notification" in
    email)
      notify_email "$slug" "$url" "$new_answer" "$prior_answer"
      ;;
    daily_note)
      notify_daily_note "$slug" "$url" "$new_answer" "$prior_answer"
      ;;
    *)
      echo "$(ts) — [$slug] WARN: unknown notification mode '$notification', falling back to daily_note" >> "$LOG"
      notify_daily_note "$slug" "$url" "$new_answer" "$prior_answer"
      ;;
  esac

  state_set "$slug" "last_answer" "$new_answer"
  state_set "$slug" "last_checked" "$(ts)"
  state_set "$slug" "last_changed" "$(ts)"
  stamp_watcher "$slug" "$frequency"
  PROCESSED=$((PROCESSED + 1))
done

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------

echo "$(ts) — summary: $PROCESSED processed, $CHANGED changed, $SKIPPED_INACTIVE inactive, $SKIPPED_NOT_DUE not-due, $ERRORS error(s)" >> "$LOG"

# macOS notification (silent if not granted; never blocks)
if [ "$CHANGED" -gt 0 ]; then
  /usr/bin/osascript -e "display notification \"$CHANGED watcher(s) changed\" with title \"web_watchers\"" 2>/dev/null || true
fi

# Final auth-failure check: if the very last watcher's claude call hit a 401
# right at the end of the loop, the flag check at the top of the loop never
# fired. Catch it here before stamping.
if [ -f "$STATE_DIR/.web_watchers_auth_failed" ]; then
  rm -f "$STATE_DIR/.web_watchers_auth_failed"
  mark_reauth_needed "$LOG"
  echo "$(ts) — aborting before stamp: Claude Code auth failure on the final watcher of the run. Next trigger after re-auth will retry." >> "$LOG"
  exit 2
fi

# Success: clear the reauth sentinel if it lingered from a previous failure.
clear_reauth_sentinel

# Outer stamp last (only on success)
echo "$TODAY" > "$STAMP"
echo "$(ts) — completed successfully; stamped $TODAY" >> "$LOG"
exit 0
