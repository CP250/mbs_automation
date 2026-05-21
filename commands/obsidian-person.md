---
description: Create or update a person note in social/ — relationship, last interaction, context. Dedup-aware (name variants)
category: vault
triggers_en: ["save this person", "add person", "new contact note", "create person note"]
---

Use the mbs_automation skill. Execute `/obsidian-person $ARGUMENTS`:

The argument is a person's name (handle typos and partial matches). People are the most duplicate-prone note type (name variants, nicknames, first-name-only), so searching before writing matters most here.

1. Read `_CLAUDE.md` at the vault root.
2. **Search before writing** (shell-grep, fuzzy): look for an existing note under the person's full name, nickname, or first name. `social/` already holds many people. If a typo or approximate name, show what was found and confirm before proceeding. Never silently create a near-duplicate (e.g. a second "Brendan" when "Brendan Contant" exists).
3. **If found:** confirm, then update — refresh `last_interaction` to today, append new context, add any new wikilinks.
4. **If not found:** create the note in the right `social/` subfolder (`friends`, `mentors`, `mentees`, `ftd`, `travel`, etc. — match where similar people live; default to `social/friends/` if unclear), named with the person's name. Frontmatter:
   ```yaml
   ---
   type: person
   date: <YYYY-MM-DD>
   tags: [person]
   relationship: "<wife | daughter | friend | mentee | mentor | colleague | lawyer | ...>"
   last_interaction: <YYYY-MM-DD>
   contact: ""
   ---
   ```
5. **Body (amnesia-self-sufficient):** who they are, how P knows them, role/company, where they are, and the context of recent interactions. Wikilink any projects or people referenced. Keep contact details (email/phone) as structural facts if known.
6. **Propagate:** log the interaction in today's tasks daily note (bounded `## Vault Agent` section); if the person is tied to a project, link them from that project note. Append to `log.md`; update `index.md` for a new note.

---

**Anti-fabrication (hard rule):** record only what's actually known about the person from the conversation or the vault. Do not invent a role, employer, relationship, or interaction. If a detail is unknown, leave it blank or `TBD` rather than guessing — a wrong fact about a real person is corrosive.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault. People route to `social/`. Existing human notes left as-is unless P asks.
