# Note Rules — the Amnesia Test

(This file was formerly "AI-First Note Rules." Filename kept so command references stay valid; the content is reframed to P's amnesia-test / hybrid model. The canonical write spec for `mbs_automation`.)

## The premise — hybrid, not AI-first

This vault is **hybrid**, not LLM-first. P reads his own vault. There are ~4,500 existing human-readable notes. So:

- **New notes the agent writes must pass the amnesia test** (below).
- **Existing notes are left as they are.** No bulk rewrite, no retrofitting `## For future Claude` headers onto human notes. Upgrade a note only when P asks or when actively editing it. Migration is voluntary, never automatic.

There is **no `ai-first: true` flag** and **no mandatory machine-preamble**. Notes should read naturally to P *and* be self-sufficient for a future reader (P-with-amnesia, or Claude) who arrives with zero context. Those two goals are the same goal, framed two ways.

## The amnesia test

> If P woke up remembering nothing, this note should tell him what the thing is, where it is, and what to do next.

Concretely, a note the agent writes should:

1. **Explain itself.** State the *what*, *why*, and *when* inside the note. Don't rely on backlinks alone for meaning — a note may be retrieved in isolation. For a substantial note, lead with a sentence or two of plain context; for a short note, the title + first line should already make it self-evident. No mandatory header ceremony — just don't write something only-today-you understands.
2. **Carry frontmatter.** Machine-readable metadata so notes are filterable. Minimum: `type`, `date` (`YYYY-MM-DD`), `tags`. Type-specific fields below.
3. **State the next action, on projects.** Active project notes carry `next_action:` — the single next actionable step. This is the structural core of the whole system; an active project with no next action is the failure state the agent exists to catch.
4. **Mark recency on external claims.** `Polestar opened a Montreal office (as of 2026-04, polestar.com/...)` so a future reader knows what to re-verify.
5. **Preserve sources verbatim.** Keep the actual URL inline, not a paraphrased citation.
6. **Wikilink everything referenced.** Every person, project, place, and recurring concept → `[[wikilink]]`, so the graph is traversable. If the target doesn't exist, a stub is fine (see write-rules § Stub Notes). Links resolve by basename (default Obsidian setting).
7. **Locate physical things.** "Where they are" is part of the amnesia test — account IDs, file paths, contact info, physical locations are structural facts in the note, not vague references.

**Not required** (dropped from Ghelbur's stricter spec): the `## For future Claude` preamble on every note, the `ai-first: true` flag, mandatory confidence levels on every claim, and bi-temporal `timeline:` arrays. Use a confidence note inline only when it genuinely matters; use a plain `date` for time, not event/transaction pairs.

## Type schemas

Minimum frontmatter by type. Paths/pillars per `vault-schema.md`. Add fields as useful; keep `type`/`date`/`tags`.

### project
```yaml
type: project
date: YYYY-MM-DD
tags: [project, <pillar>]
status: active            # active | planning | completed | on-hold
next_action: "<single next step>"   # MANDATORY when status is active
people: ["[[Name]]"]
```

### reference (`ref_*`)
```yaml
type: reference
date: YYYY-MM-DD
tags: [reference, <pillar>]
source: "https://..."     # verbatim, if applicable
```

### person (social/)
```yaml
type: person
date: YYYY-MM-DD
tags: [person]
relationship: "<wife | daughter | friend | mentee | ...>"
last_interaction: YYYY-MM-DD
contact: ""
```

### decision
```yaml
type: decision
date: YYYY-MM-DD
tags: [decision, <pillar>]
project: "[[<project>]]"
```

### log (dated event/session)
```yaml
type: log
date: YYYY-MM-DD
tags: [log, <pillar>]
project: "[[<project>]]"
```

### review (weekly)
```yaml
type: review
date: YYYY-MM-DD
period_start: YYYY-MM-DD
period_end: YYYY-MM-DD
tags: [review]
```

Daily notes are owned by the Journals plugin — the agent appends to them, doesn't create them. See `vault-schema.md`.

## Anti-patterns

| Don't | Why |
|---|---|
| `date: today` | Use the real `YYYY-MM-DD`; "today" is meaningless when read later. |
| Bare external claim, no date | "Polar is the best fit" — as of when, from where? |
| Source URL omitted | Keep the verbatim link so it can be re-verified. |
| Plain-text names instead of `[[wikilinks]]` | Breaks the graph. |
| "See above" / "as mentioned" | The note may be read in isolation; restate the context. |
| Active project with no `next_action` | The exact failure the agent exists to prevent. |
| Bulk-rewriting existing human notes | Hybrid vault — leave them unless P asks. |
