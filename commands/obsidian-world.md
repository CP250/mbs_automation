---
description: Load P's identity, current state, and open threads in one shot — progressive levels to avoid burning tokens
category: vault
triggers_en: ["load context", "what is going on", "where am I", "load my world"]
---

Use the mbs_automation skill. Execute `/obsidian-world`:

1. Read `_CLAUDE.md` first (vault root) — the operating rules.

2. Load context progressively — start light, go deeper only as needed:

   **L0 — Identity (~400 tokens, always)**
   - `SOUL.md` — who P is, values, and how to work with him (direct honest mirror; don't flatter). Values are folded in here.
   - `CRITICAL_FACTS.md` — what's true right now: family, health (safety-relevant), work/transition, locations, timezone.

   **L1 — Navigation (~1-2K tokens)**
   - `index.md` — catalog of vault pages (what exists, without loading everything).
   - `log.md` → today's `log/YYYY-MM-DD.md` and the prior day or two — recent vault activity.

   **L2 — Current state (~2-5K tokens)**
   - Today's daily note: `daily_notes/tasks/tasks_YYYY-MM-DD.md` (and `daily_notes/health/daily/...` if relevant) — what's already in progress.
   - The last 3 task daily notes — recent momentum and open threads.
   - Tasks-plugin query for **overdue + due-today** across pillars (not kanban — P has no boards).
   - Active projects with no `next_action` (the missing-next-step signal).

   **L3 — Deep context (on demand, ~5-20K tokens)**
   - Only for a specific question/task.
   - Active project notes (`status: active`) in the relevant pillar(s) for goals/blockers.
   - Recent people from `social/` + the last 7 days of daily notes.
   - Full reference notes from a pillar if P asks about a topic.

3. Present a brief status after L0–L2 (do NOT load L3 unless needed):
   - **Who I am to you**: persona + communication style (from SOUL.md).
   - **Current priorities**: top 3–5 active threads (from index.md + active projects).
   - **Open threads from last session**: unfinished items (from log + daily notes).
   - **Needs attention**: overdue tasks, stale active projects, projects missing a next action.
   - **Today so far**: what's already logged today.

Keep it concise — a boot-up, not a report. P glances, confirms Claude is up to speed, and starts.

4. **Core-memory pinning** — for a deep task that needs persistent context, write task-specific facts to `PINNED.md` at the vault root (loaded at L0 alongside SOUL/CRITICAL_FACTS). Clear it when done. Proactively suggest pinning when P is deep in a complex task; this survives context compaction.

`SOUL.md`, `CRITICAL_FACTS.md`, and `index.md` already exist. If `index.md` is missing, offer `/obsidian-init`.

---

**Note rule:** Notes this command writes follow `references/ai-first-rules.md` (amnesia-test): self-contained, frontmatter, `next_action` on active projects, recency markers + verbatim sources, mandatory `[[wikilinks]]`. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault.
