# Changelog

Newest first. Hashes refer to git commits.

## Unreleased

- Todos: due date picker redesigned (bmad-ux review, direction A+B): quick list with dates, custom Monday-first calendar with workload dots, time presets. See docs/ux/due-date-picker/.

- Todos: new due date picker (popover with quick chips Today / Tomorrow / Next week / Next month, month calendar, optional time). Due labels show relative + absolute (e.g. "Tomorrow · 23 Nov, 09:00"); overdue is time-aware.

- Todos redesign: card UI with priority stripe, stats header, progress % (e.g. 1 of 3 sub-items = 33%), DONE enabled only when all sub-items are complete, todo-to-todo links with notes (table `todo_links`, searchable, logged as linked/unlinked/link note).

- Todos: "New…" / double-click opens a modal with title, description, sub-item checklist, priority, due date and done flag. Sub-items are stored in `todo_subs`, shown with progress on each row, searchable, and sub-item completions are written to the Activity log.

- Settings (⌘,): record custom shortcuts for every tab and tool, number tabs by sidebar order, reset. Sidebar tabs can be reordered by drag and drop (persisted).

- Go menu with shortcuts: ⌘1–⌘8 for tabs, ⌃⌘1–⌃⌘9 for the first nine tools.

- Todos tab: todo list stored permanently in SQLite (`todos.sqlite`), soft delete + trash, Done log by day, Activity log, search and date-range filter.

## v0.1.0

First release: tunnel manager with auto re-auth, notes with Cmd+K search, DB quick query, vault, port monitor, SQLite clipboard history and developer tools.

- Repo moved to ~/Documents/personal/DevHub; remote set to personal GitHub (`github-personal`); docs updated.
- Clipboard: filter by type (Text, Image, File, Link, Email, Color) with counts; Finder file copies are captured as paths.
- Clipboard: captures images (PNG in `ClipImages/`, thumbnail, copy back, cleaned up with retention).
- Clipboard: history stored in SQLite (`clipboard.sqlite`) with selectable retention (1d/3d/7d/14d/1 month, pinned kept).
- Notifications are native (click opens DevHub on the related tab/profile, no more Script Editor). Tools: JSON Format (+ output search, only-matching-lines), Unix Timestamp, Diff Checker, new Hex ↔ Text.

- Connections: child processes inherit the PATH of the user terminal (~/.zshrc, ~/bin, ~/.local/bin, Homebrew), so any CLI works without full paths. alloydb-auth-proxy counts as ADC-based.

- Cmd+K: opening a note from search scrolls to the first match and flashes it.

- Notes: Notion-style "Page" editor (live markdown styling, `/` block menu, list continuation, clickable to-dos, ⌘B/⌘I/⌘E) and 5s autosave (also on note switch / app deactivate).
- Cron: English → cron expression mode (rule-based, e.g. "every weekday at 8:30am").
- Connections: auto re-auth. Saved Google work password (Keychain) answers tunnel password prompts and `gcloud` reauth prompts; expired login auto-opens `gcloud auth login` (browser click still needed) and restarts blocked tunnels.

- `b13aa6d` Timestamp tool: date picker, friendly date input (dd-MM-yyyy, yyyy-MM-dd) with zone, auto epoch conversion.
- `1f2ad09` Clipboard history, global hotkey ⌃⌥K, palette quick actions, Cron/SQL/CSV/TS tools, session restore, wake/network recovery, gcloud/ADC expiry checks, import/export, tags/pin/backlinks.
- `4d9c548` Block-based note editor: code blocks shown as cards in Edit mode.
- `0450851` Notes UI redesign: markdown renderer, Preview/Edit/Raw/Split, unified 320pt left pane.
- `fa48483` Fix: Import works without a pre-selected notes folder (auto-creates default).
- `55815d1` Mongo ObjectId, UUID v7, ULID; timestamps in s/ms with GMT+7; diff checker with word highlight; note create/import/drag-drop.
- `6744845` Configurable password generator (length, charsets, exclusions, entropy, save to Vault).
- `a4dcdd1` Initial app: connections with re-auth, notes + Cmd+K, DB query, ports, vault, tools.

## Decisions
- SwiftUI + SwiftPM (no Xcode available).
- Kafka viewer dropped (user uses Redpanda UI).
- Notes keep `.md` files on disk; the SQLite index is only a search cache.
