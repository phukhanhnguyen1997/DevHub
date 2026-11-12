# Changelog

Newest first. Hashes refer to git commits.

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
