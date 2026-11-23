# Plan: ai-plan → DevHub Todo bridge

Goal: running `/ai-plan <KEY>` creates a DevHub todo whose sub-items are the workflow steps; the AI moves each step's status and appends a report (what it did, which file).

## As-is
- `TodoStore` (`Sources/DevHub/TodoView.swift`) holds items in memory, loaded from SQLite `~/Library/Application Support/DevHub/` (tables `todos`, `todo_subs`, append-only action log). The app never reloads when the DB changes.
- Sub-items have title + done only; no notes, no external writer.
- ai-plan skill (`.github/skills/ai-plan/SKILL.md`, `references/steps.md`) has no todo integration.

## Confirmed decisions
- CLI `devhub-todo` (not raw SQLite, not MCP).
- UI: bmad-ux direction B (timeline per sub-item), long notes collapse to 2 lines, tap to expand; every AI report is appended (history kept).
- DDL (confirmed by user):
```sql
CREATE TABLE IF NOT EXISTS todo_sub_notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sub_id INTEGER NOT NULL,
  todo_id INTEGER NOT NULL,
  at REAL NOT NULL,
  author TEXT NOT NULL DEFAULT 'ai',
  status TEXT NOT NULL DEFAULT '',
  note TEXT NOT NULL DEFAULT ''
);
```
No change to `todos` / `todo_subs`.

## Tasks
1. **Schema + store**: create `todo_sub_notes` (additive); load notes per sub; `appendNote(subId, status, note)`; log in the action log. Test the pure grouping helper.
2. **CLI** (`Sources/DevHubCLI`, new SwiftPM executable, bundled to `DevHub.app/Contents/Resources/devhub-todo`; `build.sh` symlinks to `~/.local/bin`):
   - `create --title KEY --subs "DEV-1,DEV-2,..."` → prints todo id (idempotent by title).
   - `sub --todo KEY --step DEV-2 --status started|done|rework|blocked --note "…"` → appends note; `done` ticks the sub-item; `rework` un-ticks it.
   - `status --todo KEY`.
   - Writes with SQLite WAL + busy timeout.
3. **Live reload**: DispatchSource file watcher on the DB (debounced 300ms) → `TodoStore.reload()`.
4. **UI** (direction B): per sub-item "N updates ▾" with a timeline (time, status, note 2-line clamp, tap to expand, file paths as mono chips); AI badge; progress % unchanged. Long values: 2-line clamp + expand (confirmed).
5. **ai-plan skill**: at run start call `create` with the step list from `steps.md`; after each step call `sub --status done --note "<what + file>"`; on reject/rework call `sub --status rework`. Gates remain human.
6. **Docs/tests**: README, ARCHITECTURE, CHANGELOG; CLI argument parsing tests.

## Open items
- Step list per US type (normal vs solution-change) taken from `steps.md` (TA steps only when solution-change).
- FE prototype: none provided; the mock `docs/ux/ai-step-notes/.working/directions-1.html` is the reference.

## Human Review Checklist (before executing)

- [ ] **Is this needed?** Does every task trace back to a specific AC? For any task that doesn't, is there a clear reason (perf/regression/consistency)?
- [ ] **Reinventing something that already exists?** Does the "As-is" section cite real file:line references, or just vague descriptions?
- [ ] **Proportional abstraction?** Count new files/components vs. new behaviors — is anything superfluous?
- [ ] **Self-decided scope creep?** Any place the plan expands beyond the AC WITHOUT clearly noting it, why, and who needs to confirm it?
- [ ] **Cross-repo/deploy-order risk?** If one repo deploys before another, does the system break, or is it just a missing optional field?
- [ ] **Are the tests real?** Any test that only exists "to have a test" (wouldn't fail if the logic were wrong)?
- [ ] **Any decision that needs human sign-off (design/QA/PO) not clearly flagged as such?**
