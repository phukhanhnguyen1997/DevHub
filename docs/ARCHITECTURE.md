# Architecture

SwiftPM executable `DevHub`, sources in `Sources/DevHub/`.

| File | Role |
|---|---|
| `DevHubApp.swift` | App, menu bar, global hotkey wiring, launch at login |
| `RootView.swift` | Tabs, `AppState` (tab, toolKind, palette) |
| `Models.swift` | `Profile`, `RunState`, JSON store, Keychain `Vault`, `shell()` |
| `ConnectionManager.swift` | Process/PTY core, re-auth, auto-start, recover, gcloud auth check |
| `ConnectionsView.swift` | Profile list/editor, auth banner, copy-connection menu |
| `NotesStore.swift` / `NotesView.swift` | SQLite FTS5 index, tags, backlinks, UI, Cmd+K `PaletteView` |
| `Markdown.swift` / `BlockEditor.swift` | Markdown renderer; block editor (`SegCodec`) |
| `DataViews.swift` | DB Query, Ports, Vault views |
| `Shortcuts.swift` | `ShortcutStore` (UserDefaults `shortcutMap.v1`), key recorder, Settings view |
| `TodoView.swift` | `TodoStore` (SQLite `todos.sqlite`: `todos` + append-only `todo_log`), Todos UI |
| `Clipboard.swift` | `ClipStore` (SQLite `clipboard.sqlite` + `ClipImages/`, retention, type classification), view, Carbon global hotkey (⌃⌥K) |
| `ToolsView.swift`, `ToolsExtra.swift`, `Converters.swift` | All dev tools |

## Re-auth flow
Each profile runs its command through `/usr/bin/script -q /dev/null zsh -lc <cmd>` so a PTY exists. Output is matched against per-profile regexes (defaults: `Password:`, `reauthenticat`, `SASL authentication failed`, `Unauthorized`, `session expired`). On match: state becomes `needsReauth`, a notification is shown (`osascript`), and the saved password from Keychain is written to stdin.

## Data locations
`~/Library/Application Support/DevHub/`: `profiles.json`, `db.json`, `notes.sqlite`, `Notes/` (default notes folder).
UserDefaults: `notesFolder`, `restoreLast`, `lastSession`, `pinnedNotes`.

## Constraints
- DB Query shells out to `psql`/`mysql`; passwords via `PGPASSWORD`/`MYSQL_PWD`; read-only via `DBQueryView.isReadOnly` + `PGOPTIONS`.
- XCTest/Swift Testing unavailable under CLT: `run-tests.sh` compiles app sources (minus `DevHubApp.swift`) with `Tests/main.swift`.
- Launch at login (SMAppService) may fail for an ad-hoc app outside /Applications.
- Hotkey, clipboard and several UI features are build-verified, not runtime-tested.
