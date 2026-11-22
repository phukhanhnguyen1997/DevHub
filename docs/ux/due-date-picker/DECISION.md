# Due date picker: design decision

Status: implemented. Mocks of all three explored directions: `.working/directions-1.html` (light + dark).

## Review of the previous picker

1. Native graphical calendar looked dated and clashed with the card UI.
2. Four quick chips were crammed into 300pt.
3. Time toggle and time field were disconnected.
4. No way to see how busy a day already is.

## Chosen direction: A + B

- **A, quick list**: Today, Tomorrow, This weekend, Next week, Next month, each with weekday + date on the right.
- **B, workload calendar**: custom Monday-first month grid. A dot marks days that already have open todos (orange at 3 or more). A caption under the grid names the count for the selected day.
- **Time**: "Add time" reveals presets 9:00, 12:00, 15:00, 18:00 plus a custom field; the x removes the time.
- **Colors**: system accent color (no custom palette).
- Rejected for now: C, natural-language input (can be added later on top of this layout).

## Behavior

- Picking a day keeps the chosen time.
- A due date without time is overdue after the day ends; with time it is overdue at that moment.
- Esc cancels, Return sets, Clear removes the due date.
