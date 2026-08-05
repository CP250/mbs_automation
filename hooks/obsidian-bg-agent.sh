#!/usr/bin/env bash
# obsidian-bg-agent.sh — PostCompact vault propagation hook (OPT-IN, DISABLED BY DEFAULT)
#
# =============================================================================
# TRUST CAVEAT — READ BEFORE ENABLING
# =============================================================================
# This hook spawns a HEADLESS Claude subprocess with --dangerously-skip-permissions
# that writes to P's vault UNATTENDED after every context compaction. The vault
# holds taxes, legal, health, and financial data. An unattended writer that skips
# permission prompts is a real trust surface.
#
# It is therefore SHIPPED INERT. Nothing wires it automatically — not install.sh,
# not scripts/setup.sh, not SKILL.md. It does NOTHING until P deliberately:
#   1. sets OBSIDIAN_VAULT_PATH, and
#   2. adds the PostCompact hook block to ~/.claude/settings.json (steps below).
# Until both are done, this file is dormant. As an extra guard, the hook also
# requires OBSIDIAN_BG_AGENT_ENABLED=1 — so even a stray hook registration will
# no-op unless P has explicitly flipped the enable flag.
#
# Safety boundaries the spawned agent MUST respect (encoded in the prompt below):
#   - ADD or UPDATE only. NEVER delete, move, or archive anything.
#   - NEVER touch trash/ or .obsidian/. NEVER bulk-rewrite existing human notes.
#   - Suggest-don't-dispose: it does not act on _archive/ at all.
#   - New notes pass the amnesia test; it never adds an AI-first preamble/flag.
# =============================================================================
#
# Fires after Claude compacts the conversation context. Reads the compaction
# summary from the transcript, then runs a headless agent to propagate
# anything worth preserving into the pillar-structured vault.
#
# ENABLE (P does this manually, when ready — see hooks/postcompact.hook.example.json):
#   1. Set OBSIDIAN_VAULT_PATH in ~/.claude/settings.json env section.
#   2. Set OBSIDIAN_BG_AGENT_ENABLED=1 in the same env section.
#   3. Add the PostCompact hook block (see the example file) to ~/.claude/settings.json.
#   4. chmod +x ~/.claude/skills/mbs_automation/hooks/obsidian-bg-agent.sh
#
# Logs: /tmp/obsidian-bg-agent.log

# Hard gate: stay inert unless BOTH the vault path and the explicit enable flag are set.
[[ "${OBSIDIAN_BG_AGENT_ENABLED:-}" == "1" ]] || exit 0
VAULT="${OBSIDIAN_VAULT_PATH:-}"
[[ -z "$VAULT" ]] && exit 0
[[ -d "$VAULT" ]] || exit 0

# PostCompact stdin includes `transcript_path`; the compaction summary itself
# is written into the transcript JSONL as entries with `isCompactSummary: true`.
# We read the most recent one here.
INPUT=$(cat)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || true)
[[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0

# Stream the JSONL (transcripts can be 100MB+). base64-encode each match so the
# multi-line content stays on one line, then decode the most recent one.
SUMMARY=$(jq -rc 'select(.isCompactSummary == true) | .message.content // "" | @base64' "$TRANSCRIPT" 2>/dev/null | tail -n 1 | base64 -d 2>/dev/null || true)
[[ -z "$SUMMARY" ]] && exit 0

TODAY=$(date +%Y-%m-%d)

# Build prompt in a temp file to handle special characters in the summary safely
PROMPT_FILE=$(mktemp /tmp/obsidian-bg-XXXXXX.txt)

cat > "$PROMPT_FILE" << HEADER
You are an autonomous Obsidian vault agent for P's vault. The Claude session was just compacted.
Propagate everything worth preserving from the summary into the vault. Run silently.

VAULT: $VAULT
TODAY: $TODAY

SESSION SUMMARY:
HEADER

printf '%s\n\n' "$SUMMARY" >> "$PROMPT_FILE"

cat >> "$PROMPT_FILE" << 'INSTRUCTIONS'
INSTRUCTIONS:
1. Read CLAUDE.md, SOUL.md, and CRITICAL_FACTS.md in admin/mbs_system/brain/ first — follow their rules
   exactly. Where silent, follow references/ai-first-rules.md, references/vault-schema.md, and
   references/write-rules.md from the mbs_automation skill.
2. Identify vault-worthy items in the summary: decisions made, tasks created or completed,
   people interacted with, projects worked on or updated, work/dev sessions, ideas or learnings.
3. SEARCH BEFORE WRITING. For every person/project/note, grep the vault exhaustively for an
   existing one before creating. Never duplicate. Per the search-completeness rule, do not
   conclude a note is absent without listing and grepping the candidate pillars.
4. Route each item to the correct life pillar (admin, create, culture, health, money, skills,
   social, sports) per references/vault-schema.md — never to People/, Projects/, Dev Logs/,
   Boards/, Knowledge/, or wiki/ (those folders do not exist in this vault):
   - People  -> social/ (update last_interaction; create a stub only if clearly warranted).
   - Projects-> the right pillar; if status is active, ensure a real next_action is set.
   - Work/dev session -> a log note in the project/pillar folder's _logs/
     (<pillar>/.../_logs/log_YYYY-MM-DD_<slug>.md; create _logs/ if absent).
   - Tasks   -> a Tasks-plugin line "- [ ] <desc> #<pillar> 📅 <due if known>" in the relevant
     pillar's todo. There are NO kanban boards. Never delete completed tasks (task-archiver
     handles archiving).
   - Decisions -> the project note's ## Key Decisions section.
5. New notes must pass the AMNESIA TEST: self-contained context, frontmatter (type, date, tags,
   plus type-specific fields), next_action on active projects, recency markers + verbatim source
   URLs on external claims, and [[wikilinks]] for every person/project/place/concept. Do NOT add a
   "## For future Claude" preamble and do NOT add an ai-first: flag — this is a hybrid vault.
6. Propagate (never write in isolation): link new items from today's tasks daily note inside a
   bounded "## Vault Agent" section only (daily_notes/tasks/tasks_TODAY.md, using the TODAY value
   above) — never touch P's own sections of that note. Append a timestamped line to
   admin/mbs_system/design/log/TODAY.md (the ops log, same TODAY value; never a bare root log.md).

CONSTRAINTS:
- Use filesystem tools only (Read, Write, Edit, Glob, Grep) — MCP is not available here.
- Run completely silently. No output to the user. No questions.
- If the summary contains nothing vault-worthy, exit without touching the vault.
- Match each pillar's existing writing style, frontmatter, and naming (lowercase snake_case) — read
  1-2 existing notes in a folder before writing there.
- ADD or UPDATE only. NEVER delete, move, or archive anything. NEVER touch trash/ or .obsidian/.
- NEVER bulk-rewrite existing human notes. Suggest-don't-dispose: do not act on _archive/.
INSTRUCTIONS

PROMPT=$(cat "$PROMPT_FILE")
rm -f "$PROMPT_FILE"

# Run headless agent in vault directory — async, logs to /tmp for debugging
(
  cd "$VAULT" && \
  claude --dangerously-skip-permissions -p "$PROMPT" >> /tmp/obsidian-bg-agent.log 2>&1
) &

exit 0
