# Notes redesign: decision

Chosen: direction B (Workspace: tabs + inspector). Mock: `.working/directions-1.html`.

- Tabs for open notes (persisted in UserDefaults `noteTabs`), recent list (`recentNotes`), back/forward history in memory.
- Slim sidebar: search, tag chips, Pinned / Recent / All notes. Titles and snippets wrap to max 2 lines (tooltip shows full title).
- Right inspector (toggle, `notesInspector`): outline, linked from, links to (missing targets shown), properties. Status bar: save state, words, backlinks.
- ⌘K: Recent notes (empty query), Notes (title match), Inside notes (body match with snippet), Actions, "New note".
- Not chosen: daily note and templates (suggested features 4 and 5), Library and Gallery directions.
- No schema or file-format change. Not verified at runtime by screenshot.
