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
3. **State the next action, on projects, as a tickable body checkbox.** Active project notes carry at least one unchecked `- [ ] <action> #<pillar> 🆔 <id>` line in the body — typically inside a `## Next action` or `## Immediate next steps` section. This is the structural core of the whole system; an active project with no unchecked checkbox is the failure state the agent exists to catch. There is no longer a frontmatter `next_action:` field (retired 2026-06-06 — the body checklist is the single source of truth, ticking automatically advances to the next checkbox, and the project surfaces in the "needs new next step" dashboard block only when all checkboxes are ticked).
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
status: active            # active | planning | on_hold | someday | completed
trigger: "<event that reactivates on_hold>"   # on_hold only
people: ["[[Name]]"]
```
**Body requirement (replaces the old `next_action:` field):** if `status: active`, the body must contain at least one unchecked `- [ ] <action> #<pillar> 🆔 <id>` checkbox. This is the next step. Missing-next-step detection flags active projects whose body has zero unchecked checkboxes.

### reference (`ref_*`)
```yaml
type: reference
date: YYYY-MM-DD
tags: [reference, <pillar>]
source: "https://..."     # verbatim, if applicable
```

### person (social/people/, or pillar-specific subfolder)
```yaml
type: person
date: YYYY-MM-DD
aliases:
  - Full Name
  - Nickname
tags: [person, <relationship-bucket>]
relationship: "<wife | daughter | son | friend | colleague | professional_contact | mentor | mentee | acquaintance | custom-prose>"
last_interaction: YYYY-MM-DD
contact: ""
```

Default folder is `social/people/<first_last>.md` (renamed 2026-06-12 from `social/friends/people/`). Family members and dogs keep dedicated pillar folders; work colleagues live with their work context (Polar in `money/project_polar/`, Verition in `money/verition/`). Full convention (relationship values, growth_goal, meeting-documentation pattern) is in `social/friends/goals_friends.md` and `references/vault-schema.md`.

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
| Active project with no unchecked body `- [ ]` checkbox | The exact failure the agent exists to prevent. |
| Bulk-rewriting existing human notes | Hybrid vault — leave them unless P asks. |
