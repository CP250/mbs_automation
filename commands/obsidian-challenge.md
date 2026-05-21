---
description: Red-team a current idea or plan against your own vault history — past failures, reversals, and blind spots. The honest mirror
category: thinking
triggers_en: ["challenge this", "grill me on this", "red team my idea", "stress test this"]
---

Use the mbs_automation skill. Execute `/obsidian-challenge $ARGUMENTS`:

The optional argument is the idea/belief/plan to challenge; if absent, infer P's current position from the conversation. This is the honest-mirror duty (see SOUL.md): do not flatter, do not soften, expose what P is avoiding.

1. Read `_CLAUDE.md`, `SOUL.md`.
2. State P's current claim/plan and extract its key premises.
3. **Search the vault for counter-evidence** (shell-grep; parallel read subagents for breadth). Exclude `trash/`; `_archive/` is fair game as history:
   - Project Key Decisions for past decisions that contradicted or reversed similar thinking.
   - Daily notes, work logs, and archives for past failures, regrets, or lessons on this topic.
   - Notes where P held the opposite position or flagged risks about this exact approach.
4. Synthesize a **Red Team** analysis:
   - **Your position** — restate it clearly and fairly.
   - **Counter-evidence from your vault** — cite specific notes, dates, and quotes.
   - **Blind spots** — what P may be ignoring based on his own history.
   - **Verdict** — is this consistent with past experience, or does the vault suggest caution? Say it straight.
5. Log the challenge in today's tasks daily note under the `## Vault Agent` section.

Do not be agreeable; the point is to pressure-test. If you genuinely find no counter-evidence after a thorough search, say so honestly rather than manufacturing doubt.

---

**Anti-fabrication (hard rule):** cite only real notes, real dates, real quotes. Do not invent a "past failure" or a contradicting decision to make the challenge sharper. A fabricated counter-argument is worse than a thin one. Distinguish what the vault actually shows from your own reasoning, and label which is which.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault. Never touch P's own sections of the daily note.
