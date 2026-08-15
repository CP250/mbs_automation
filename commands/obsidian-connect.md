---
description: Bridge two domains using the vault's link graph — forces creative friction to spark concrete new ideas
category: thinking
triggers_en: ["connect domains", "cross-pollinate", "bridge ideas", "find an unexpected link"]
---

Use the mbs_automation skill. Execute `/obsidian-connect $ARGUMENTS`:

Two topics/domains/notes to connect. If fewer than two are given, ask P for both.

1. Read `admin/mbs_system/brain/CLAUDE.md`.
2. Parse the two domains (e.g. `/obsidian-connect "rackets strategy" "portfolio construction"`).
3. For each domain, search the vault (shell-grep; exclude `trash/`): find related notes by title/tags/content and map their wikilinks into a local cluster.
4. **Find the bridge:**
   - Shared links, tags, or people between the two clusters; if a path exists in the link graph, trace it hop by hop.
   - If no direct path, find the closest real overlap — concepts, metaphors, structural similarities grounded in actual notes.
5. Generate concrete connections (not vague analogies):
   - **Structural analogy** — how a pattern in A maps to B.
   - **Transfer opportunities** — what works in A that could apply to B.
   - **Collision ideas** — concepts that only exist at the intersection.
6. Present 3–5 specific, actionable connections. If a connection is obvious, dig deeper.
7. Offer to save the best ones to `captured/` (linked to both source domains). Log the exercise in today's tasks daily note (`## Vault Agent` section).

---

**Anti-fabrication (hard rule):** ground the clusters in notes that actually exist — don't invent vault content to force a bridge. The creative leap (the analogy/idea) is yours to make and should be labeled as a suggestion; the vault evidence underneath it must be real.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault. Never touch P's own sections of the daily note.
