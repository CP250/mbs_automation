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
4. **If not found:** create the note. **Default location is `social/people/<first_last>.md`** (renamed 2026-06-12 from `social/friends/people/` because not everyone there is already a friend; `relationship:` is the discriminator, not the folder). Pillar-specific exceptions: Avery in `social/acrp/`, Madi in `social/ftd/`, dogs in `social/dogs/`, Polar contacts in `money/project_polar/`, Verition colleagues in `money/verition/`. Frontmatter:
   ```yaml
   ---
   type: person
   date: <YYYY-MM-DD>
   aliases:
     - Full Name
     - Nickname
   tags: [person, <relationship-bucket>]
   relationship: "<wife | daughter | son | friend | colleague | professional_contact | mentor | mentee | acquaintance>"
   last_interaction: <YYYY-MM-DD>
   contact: ""
   ---
   ```
   `relationship:` value set (expanded 2026-06-12): family roles; `friend`; `colleague` (direct workplace); `professional_contact` (industry/network, including evolving relationships); `mentor` / `mentee`; `acquaintance`. Custom prose permitted when the enum doesn't fit cleanly. Update the value when the relationship's dominant mode shifts; do not move the file.
5. **Body (amnesia-self-sufficient):** who they are, how P knows them, role/company, where they are, and the context of recent interactions. Wikilink any projects or people referenced. Keep contact details (email/phone) as structural facts if known.
6. **Meeting documentation (canonical 2026-06-12):** for any substantive meeting:
   - Add a one-line entry to `## Interactions` (chronological index).
   - Add a `### YYYY-MM-DD - <one-line title>` subsection under `## Meetings` with Setting, the arc of the conversation in named beats, P's takeaways, offers/asks, and action items as Tasks-plugin checkboxes with `#<pillar> 🆔 <id> 📅 <date>` so they flow into Morgen.
   - If P uploaded a loose meeting-notes file (typically named `YYYYMMDD_<who>_meeting.md` at vault root), integrate its content via this pattern, then archive the loose file.
   - Reference example: `social/people/tom_van_riper.md` (2026-06-12 lunch with TVR).
7. **Propagate:** log the interaction in today's tasks daily note (bounded `## Vault Agent` section); if the person is tied to a project, link them from that project note. Append to `admin/mbs_system/design/log.md`; update `index.md` for a new note.

---

**Anti-fabrication (hard rule):** record only what's actually known about the person from the conversation or the vault. Do not invent a role, employer, relationship, or interaction. If a detail is unknown, leave it blank or `TBD` rather than guessing — a wrong fact about a real person is corrosive.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag — hybrid vault. People route to `social/`. Existing human notes left as-is unless P asks.
