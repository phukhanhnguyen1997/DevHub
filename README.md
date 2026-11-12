# DevHub

Native macOS (SwiftUI) developer utility: tunnel manager, markdown notes with Cmd+K search, DB quick query, vault, port monitor and dev tools.

## Features
- **Connections**: manage `cloud-sql-proxy` / `gcloud compute start-iap-tunnel` commands; connect/disconnect per profile or group; status, logs, port-conflict detection; auto re-auth (password from Keychain injected via PTY, global Google work password via the shield button, auto `gcloud auth login` on expiry); auto-start, restore last session, recover after wake/network change; gcloud/ADC expiry banner; import/export profiles; copy connection strings.
- **Notes**: Notion-style Page editor (`/` menu, live styling, 5s autosave), import/create `.md`, FTS5 search, tags, pin, outline, `[[wiki links]]`, backlinks, block-based editor, "Make profile" from shell code blocks.
- **Clipboard**: in-memory history (max 100), pin, search, sensitive content masked.
- **DB Query**: read-only psql/mysql queries, saved queries.
- **Ports / Vault**: listening ports; Keychain-backed secrets.
- **Tools**: JSON, Base64, URL, JWT, Hash, UUID/ObjectId/ULID, Password generator, Timestamp (date picker, GMT+7), Regex, Diff, Cron (both directions: cron ↔ English), SQL format, CSV/JSON/INSERT, JSON to TypeScript.

## Shortcuts
- `⌘K` command palette (notes, actions, generators, epoch → GMT+7)
- `⌃⌥K` global hotkey: summon app and open palette

## Build and run
Requires only Command Line Tools (no Xcode).
```
./build.sh          # builds DevHub.app (ad-hoc signed)
open DevHub.app
./run-tests.sh      # logic self-tests
```
`SDKROOT` is pinned to `MacOSX26.sdk` because newer SDKs lack the SwiftUI macro plugin.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/CHANGELOG.md](docs/CHANGELOG.md).
