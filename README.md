# DevHub

Native macOS (SwiftUI) developer utility: tunnel manager, markdown notes with Cmd+K search, DB quick query, vault, port monitor and dev tools.

## Features
- **Connections**: manage `cloud-sql-proxy` / `gcloud compute start-iap-tunnel` commands; connect/disconnect per profile or group; status, logs, port-conflict detection; auto re-auth (password from Keychain injected via PTY, global Google work password via the shield button, auto `gcloud auth login` on expiry); auto-start, restore last session, recover after wake/network change; gcloud/ADC expiry banner; import/export profiles; copy connection strings.
- **Notes**: Notion-style Page editor (`/` menu, live styling, 5s autosave), import/create `.md`, FTS5 search, tags, pin, outline, `[[wiki links]]`, backlinks, block-based editor, "Make profile" from shell code blocks.
- **Todos**: todo list with a detail modal (title, description, sub-item checklist with live % progress, DONE button enabled only when every sub-item is ticked, links to other todos with searchable notes), priority and due date, permanent SQLite storage (`todos.sqlite`, soft delete only), Done log grouped by day, full Activity log, search and date-range filter (today to all time, or custom).
- **Clipboard**: SQLite-backed history (text, images, files), filter by type (Text/Image/File/Link/Email/Color), retention 1d/3d/7d/14d/1 month (pinned kept), pin, search, sensitive content masked.
- **DB Query**: read-only psql/mysql queries, saved queries.
- **Ports / Vault**: listening ports; Keychain-backed secrets.
- **Tools**: JSON, Base64, URL, JWT, Hash, UUID/ObjectId/ULID, Password generator, Timestamp (date picker, GMT+7), Regex, Diff, Cron (both directions: cron ↔ English), SQL format, CSV/JSON/INSERT, JSON to TypeScript.

## Shortcuts

All tab and tool shortcuts are customizable in **Settings (⌘,)**: click a shortcut and press new keys (Esc cancels, Delete clears, clashes are resolved automatically). The sidebar can be reordered by drag and drop; the order is remembered.

Defaults:
- `⌘1`…`⌘8` jump to tab (Connections, Notes, Todos, Clipboard, DB Query, Ports, Vault, Tools); see the **Go** menu
- `⌃⌘1`…`⌃⌘9` open tool (JSON Format, JSON minify, Base64, URL, JWT, Hash, UUID, Password, Unix Timestamp)
- `⌘K` command palette (notes, actions, generators, epoch → GMT+7)
- `⌃⌥K` global hotkey: summon app and open palette

## Repository

Local path: `/Users/admin/Documents/personal/DevHub`. Remote: `git@github-personal:phukhanhnguyen1997/DevHub.git` (personal GitHub account, SSH host alias `github-personal`).

## Build and run
Requires only Command Line Tools (no Xcode).
```
./build.sh          # builds DevHub.app (ad-hoc signed)
open DevHub.app
./run-tests.sh      # logic self-tests
```
`SDKROOT` is pinned to `MacOSX26.sdk` because newer SDKs lack the SwiftUI macro plugin.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/CHANGELOG.md](docs/CHANGELOG.md).
