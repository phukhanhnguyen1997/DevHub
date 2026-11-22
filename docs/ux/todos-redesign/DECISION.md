# Todos redesign: decision

Chosen: direction A (soft cards), moderate font sizes, aligned text. Mock: `.working/directions-1.html`.

- Cards collapse/expand individually; toolbar has Expand all / Collapse all. Items without detail, sub-items or links have no chevron.
- Progress: 15pt bold %, thick bar, count (e.g. 20% 1/5), fixed-width % column so rows align.
- Sub-items: round check (not radio: radio means single choice).
- Long title/description/sub-item text wraps fully.
- Layouts: List (by date / by priority), Board (To do / Doing / Done, drag to move), Calendar (month + week, Monday-first).
- Schema (additive): `ALTER TABLE todos ADD COLUMN status INTEGER NOT NULL DEFAULT 0` (0 to do, 1 doing; done stays `done`).
- Not verified at runtime by screenshot (no capture permission in the build environment).
