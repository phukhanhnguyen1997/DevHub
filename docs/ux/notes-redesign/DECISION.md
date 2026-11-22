# Notes redesign: decision (v2)

v1 (tabs + inspector, `.working/directions-1.html`) was rejected: three columns were too cramped for a small, work-only note set.

Chosen v2: direction C (`.working/directions-2.html`).
- Few notes (about 5), so no sidebar list, no tabs, no Recent. Note chips on top, horizontally scrollable, pinned first.
- Full-width title (one line) and editor; code-block Copy button never wraps.
- Sticky "On this page" rail on the right, hidden when narrow. Backlinks and outgoing links live in a status-bar menu.
- Search is the existing ⌘K palette (Notes / Inside notes / Actions / New note).
- Notes hold no secrets by user decision, so code blocks are not masked.
- No schema or file-format change. Not verified at runtime by screenshot.
