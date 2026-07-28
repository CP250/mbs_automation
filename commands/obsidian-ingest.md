---
description: Ingest a source into the vault as one clean reference note — extract, save verbatim source, propose links. Never auto-rewrites existing notes
category: vault
triggers_en: ["ingest this source", "add this article", "import this", "absorb this"]
---

Use the mbs_automation skill. Execute `/obsidian-ingest $ARGUMENTS`:

The argument is a URL, file path, or pasted text. If none, ask what to ingest. This is the **simplified** ingest: it creates one well-structured reference note and *proposes* connections. It does NOT autonomously rewrite the vault (the old "vault rewrites itself" behavior is removed — it violates the propose-don't-dispose boundary).

1. Read `admin/mbs_system/brain/_CLAUDE.md`.
2. Read or fetch the source:
   - **Article/URL** — fetch the page content.
   - **PDF/document/text** — read it directly.
   - **Image/screenshot** — read/OCR it; extract text and context.
   - **Transcript** — extract speakers, decisions, action items, quotes.
   (Heavy research tooling — yt-dlp, Whisper, API pulls — is out of scope for v1; if a source needs it, ask P to paste the text/transcript.)
3. Extract: key claims, people, companies, tools, concepts, action items, notable quotes.
4. **Search before writing** (per `references/write-rules.md` § Search before write, exhaustively per the search-completeness rule): look for an existing reference note on this source (filename + content). If one exists, update it rather than creating a duplicate. Otherwise **create one reference note** in the right pillar (or `captured/` if the destination is unclear — let triage route it): `<pillar>/ref_<slug>.md`. Frontmatter:
   ```yaml
   ---
   type: reference
   date: <YYYY-MM-DD>
   tags: [reference, <pillar>]
   source: "<verbatim URL or source path>"
   ---
   ```
   Body: a self-contained summary (amnesia test), the verbatim source URL inline, key claims with recency markers, and `[[wikilinks]]` to people/projects/concepts **that already exist** (stub only if clearly warranted — don't manufacture links).
5. **Propose, don't rewrite.** If the source updates, contradicts, or enriches an existing note, do NOT edit that note. Instead, list the proposed updates ("this supersedes the rate in [[ref_x]]"; "contradicts [[project_y]]'s assumption") and let P approve each. Existing human notes are never auto-modified.
6. Propagate: mention the ingest in today's tasks daily note (`## Vault Agent` section); append to `admin/mbs_system/design/log.md`.

---

**Anti-fabrication (hard rule):** record only what the source actually says; keep source URLs verbatim; mark external claims with recency. Do not infer facts the source doesn't support, and do not invent links to notes that don't exist.

**Note rule:** Follows `references/ai-first-rules.md` (amnesia test) and `references/write-rules.md`. No `## For future Claude` preamble, no `ai-first:` flag, no `wiki/`/`raw/` structure, no autonomous rewrites — hybrid vault, suggest-don't-dispose. Never touch P's own sections of the daily note.
