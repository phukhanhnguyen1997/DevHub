import SwiftUI
import SQLite3

struct TodoItem: Identifiable, Equatable {
    var id: Int64
    var title: String
    var detail: String
    var priority: Int // 0 none, 1 low, 2 medium, 3 high
    var due: Date?
    var created: Date
    var done: Date?
    var deleted: Bool
    var status: Int = 0 // 0 to do, 1 doing; done is tracked by `done`
}

struct SubDraft: Identifiable, Equatable {
    var uid = UUID()
    var id: UUID { uid }
    var dbId: Int64?
    var title: String
    var done: Bool
}

// A link between two todos. `outgoing` is true when this todo is the source of the stored link.
struct TodoLink: Identifiable, Equatable {
    var uid = UUID()
    var id: UUID { uid }
    var otherId: Int64
    var note: String
    var outgoing: Bool
}

struct TodoEvent: Identifiable {
    var id: Int64
    var todoId: Int64
    var action: String
    var title: String
    var date: Date
}

func subProgress(_ subs: [SubDraft]) -> (done: Int, total: Int, percent: Int) {
    let d = subs.filter(\.done).count
    return (d, subs.count, subs.isEmpty ? 0 : Int((Double(d) * 100 / Double(subs.count)).rounded()))
}

// Permanent storage: nothing is ever hard-deleted. "Delete" is a soft flag and every change is appended to the log.
@MainActor
final class TodoStore: ObservableObject {
    @Published var items: [TodoItem] = []
    @Published var events: [TodoEvent] = []
    @Published var subs: [Int64: [SubDraft]] = [:]
    @Published var links: [Int64: [TodoLink]] = [:]
    private var db: OpaquePointer?

    init() {
        sqlite3_open(Store.dir.appendingPathComponent("todos.sqlite").path, &db)
        run("CREATE TABLE IF NOT EXISTS todos (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '', priority INTEGER NOT NULL DEFAULT 0, due REAL, created REAL NOT NULL, done REAL, deleted INTEGER NOT NULL DEFAULT 0)")
        run("CREATE TABLE IF NOT EXISTS todo_log (id INTEGER PRIMARY KEY AUTOINCREMENT, todo_id INTEGER NOT NULL, action TEXT NOT NULL, title TEXT NOT NULL, date REAL NOT NULL)")
        run("CREATE TABLE IF NOT EXISTS todo_subs (id INTEGER PRIMARY KEY AUTOINCREMENT, todo_id INTEGER NOT NULL, title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0, pos INTEGER NOT NULL DEFAULT 0)")
        run("CREATE TABLE IF NOT EXISTS todo_links (id INTEGER PRIMARY KEY AUTOINCREMENT, a INTEGER NOT NULL, b INTEGER NOT NULL, note TEXT NOT NULL DEFAULT '', created REAL NOT NULL)")
        run("CREATE INDEX IF NOT EXISTS idx_log_date ON todo_log(date)")
        run("ALTER TABLE todos ADD COLUMN status INTEGER NOT NULL DEFAULT 0") // no-op error when the column already exists
        reload()
    }

    @discardableResult
    private func run(_ sql: String, _ args: [Any?] = []) -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        let tr = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case let v as String: sqlite3_bind_text(st, n, v, -1, tr)
            case let v as Double: sqlite3_bind_double(st, n, v)
            case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, n, v)
            default: sqlite3_bind_null(st, n)
            }
        }
        return sqlite3_step(st) == SQLITE_DONE
    }

    private func text(_ st: OpaquePointer?, _ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
    private func optDate(_ st: OpaquePointer?, _ i: Int32) -> Date? {
        sqlite3_column_type(st, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(st, i))
    }

    func reload() {
        var out: [TodoItem] = []
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, title, detail, priority, due, created, done, deleted, status FROM todos ORDER BY created DESC", -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                out.append(TodoItem(id: sqlite3_column_int64(st, 0), title: text(st, 1), detail: text(st, 2),
                                    priority: Int(sqlite3_column_int(st, 3)), due: optDate(st, 4),
                                    created: Date(timeIntervalSince1970: sqlite3_column_double(st, 5)),
                                    done: optDate(st, 6), deleted: sqlite3_column_int(st, 7) != 0,
                                    status: Int(sqlite3_column_int(st, 8))))
            }
        }
        sqlite3_finalize(st)
        items = out
        var ev: [TodoEvent] = []
        var s2: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, todo_id, action, title, date FROM todo_log ORDER BY date DESC, id DESC", -1, &s2, nil) == SQLITE_OK {
            while sqlite3_step(s2) == SQLITE_ROW {
                ev.append(TodoEvent(id: sqlite3_column_int64(s2, 0), todoId: sqlite3_column_int64(s2, 1),
                                    action: text(s2, 2), title: text(s2, 3),
                                    date: Date(timeIntervalSince1970: sqlite3_column_double(s2, 4))))
            }
        }
        sqlite3_finalize(s2)
        events = ev
        var sm: [Int64: [SubDraft]] = [:]
        var s3: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, todo_id, title, done FROM todo_subs ORDER BY todo_id, pos, id", -1, &s3, nil) == SQLITE_OK {
            while sqlite3_step(s3) == SQLITE_ROW {
                sm[sqlite3_column_int64(s3, 1), default: []].append(SubDraft(dbId: sqlite3_column_int64(s3, 0), title: text(s3, 2), done: sqlite3_column_int(s3, 3) != 0))
            }
        }
        sqlite3_finalize(s3)
        subs = sm
        var lm: [Int64: [TodoLink]] = [:]
        var s4: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT a, b, note FROM todo_links ORDER BY id", -1, &s4, nil) == SQLITE_OK {
            while sqlite3_step(s4) == SQLITE_ROW {
                let a = sqlite3_column_int64(s4, 0), b = sqlite3_column_int64(s4, 1), n = text(s4, 2)
                lm[a, default: []].append(TodoLink(otherId: b, note: n, outgoing: true))
                lm[b, default: []].append(TodoLink(otherId: a, note: n, outgoing: false))
            }
        }
        sqlite3_finalize(s4)
        links = lm
    }

    func title(_ id: Int64) -> String { items.first { $0.id == id }?.title ?? "(unknown)" }

    func canComplete(_ id: Int64) -> Bool {
        let s = subs[id] ?? []
        return s.allSatisfy(\.done)
    }

    private func log(_ id: Int64, _ action: String, _ title: String) {
        run("INSERT INTO todo_log (todo_id, action, title, date) VALUES (?, ?, ?, ?)", [id, action, title, Date().timeIntervalSince1970])
    }

    func add(title: String, priority: Int = 0, due: Date? = nil) {
        save(TodoItem(id: 0, title: title, detail: "", priority: priority, due: due, created: Date(), done: nil, deleted: false), subs: [], links: [])
    }

    // Creates (id == 0) or updates a todo with its sub-items and links; every change is logged.
    func save(_ item: TodoItem, subs drafts: [SubDraft], links linkDrafts: [TodoLink]) {
        var i = item
        let t = i.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        i.title = t
        if i.done != nil && !drafts.allSatisfy(\.done) { i.done = nil }
        let old = i.id == 0 ? [] : (subs[i.id] ?? [])
        let oldLinks = i.id == 0 ? [] : (links[i.id] ?? [])
        if i.id == 0 {
            run("INSERT INTO todos (title, detail, priority, due, created, done, status) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [t, i.detail, i.priority, i.due?.timeIntervalSince1970, Date().timeIntervalSince1970, i.done?.timeIntervalSince1970, i.status])
            i.id = sqlite3_last_insert_rowid(db)
            log(i.id, "created", t)
        } else {
            let prev = items.first { $0.id == i.id }
            run("UPDATE todos SET title = ?, detail = ?, priority = ?, due = ?, done = ?, status = ? WHERE id = ?",
                [t, i.detail, i.priority, i.due?.timeIntervalSince1970, i.done?.timeIntervalSince1970, i.status, i.id])
            if prev?.done == nil && i.done != nil { log(i.id, "completed", t) }
            else if prev?.done != nil && i.done == nil { log(i.id, "reopened", t) }
            if prev?.title != t || prev?.detail != i.detail || prev?.priority != i.priority || prev?.due != i.due || old.count != drafts.count { log(i.id, "edited", t) }
        }
        for d in drafts {
            let was = old.first { $0.dbId != nil && $0.dbId == d.dbId }
            if d.done && was?.done != true { log(i.id, "subtask done", "\(t) › \(d.title)") }
            else if !d.done && was?.done == true { log(i.id, "subtask reopened", "\(t) › \(d.title)") }
        }
        run("DELETE FROM todo_subs WHERE todo_id = ?", [i.id])
        for (n, d) in drafts.enumerated() where !d.title.trimmingCharacters(in: .whitespaces).isEmpty {
            if let id = d.dbId {
                run("INSERT INTO todo_subs (id, todo_id, title, done, pos) VALUES (?, ?, ?, ?, ?)", [id, i.id, d.title, d.done ? 1 : 0, n])
            } else {
                run("INSERT INTO todo_subs (todo_id, title, done, pos) VALUES (?, ?, ?, ?)", [i.id, d.title, d.done ? 1 : 0, n])
            }
        }
        // Links: rewrite every link touching this todo, keeping its original direction.
        for l in linkDrafts {
            let was = oldLinks.first { $0.otherId == l.otherId }
            if was == nil { log(i.id, "linked", "\(t) ↔ \(title(l.otherId))\(l.note.isEmpty ? "" : ": \(l.note)")") }
            else if was?.note != l.note { log(i.id, "link note", "\(t) ↔ \(title(l.otherId)): \(l.note)") }
        }
        for l in oldLinks where !linkDrafts.contains(where: { $0.otherId == l.otherId }) {
            log(i.id, "unlinked", "\(t) ↔ \(title(l.otherId))")
        }
        run("DELETE FROM todo_links WHERE a = ? OR b = ?", [i.id, i.id])
        for l in linkDrafts {
            let (a, b) = l.outgoing ? (i.id, l.otherId) : (l.otherId, i.id)
            run("INSERT INTO todo_links (a, b, note, created) VALUES (?, ?, ?, ?)", [a, b, l.note, Date().timeIntervalSince1970])
        }
        reload()
    }

    func toggleSub(_ todo: TodoItem, _ sub: SubDraft) {
        guard let id = sub.dbId else { return }
        run("UPDATE todo_subs SET done = ? WHERE id = ?", [sub.done ? 0 : 1, id])
        log(todo.id, sub.done ? "subtask reopened" : "subtask done", "\(todo.title) › \(sub.title)")
        // Un-ticking a sub-item reopens a finished todo.
        if sub.done, todo.done != nil {
            run("UPDATE todos SET done = NULL WHERE id = ?", [todo.id])
            log(todo.id, "reopened", todo.title)
        }
        reload()
    }

    // Board moves: 0 = To do, 1 = Doing. Returns false when the todo can't change (e.g. already done).
    func setStatus(_ i: TodoItem, _ status: Int) {
        guard i.done == nil, i.status != status else { return }
        run("UPDATE todos SET status = ? WHERE id = ?", [status, i.id])
        log(i.id, status == 1 ? "started" : "moved to to do", i.title)
        reload()
    }

    func toggleDone(_ i: TodoItem) {
        if i.done == nil {
            guard canComplete(i.id) else { return }
            run("UPDATE todos SET done = ? WHERE id = ?", [Date().timeIntervalSince1970, i.id])
            log(i.id, "completed", i.title)
        } else {
            run("UPDATE todos SET done = NULL, status = 0 WHERE id = ?", [i.id])
            log(i.id, "reopened", i.title)
        }
        reload()
    }

    func remove(_ i: TodoItem) {
        run("UPDATE todos SET deleted = 1 WHERE id = ?", [i.id])
        log(i.id, "deleted", i.title)
        reload()
    }

    func restore(_ i: TodoItem) {
        run("UPDATE todos SET deleted = 0 WHERE id = ?", [i.id])
        log(i.id, "restored", i.title)
        reload()
    }
}

enum TodoRange: String, CaseIterable, Identifiable {
    case all = "All time", today = "Today", week = "7 days", month = "30 days", quarter = "90 days", year = "1 year", custom = "Custom"
    var id: String { rawValue }
    func bounds(from: Date, to: Date) -> (Date, Date)? {
        let cal = Calendar.current
        let end = Date.distantFuture
        switch self {
        case .all: return nil
        case .today: return (cal.startOfDay(for: Date()), end)
        case .week: return (cal.date(byAdding: .day, value: -7, to: Date())!, end)
        case .month: return (cal.date(byAdding: .day, value: -30, to: Date())!, end)
        case .quarter: return (cal.date(byAdding: .day, value: -90, to: Date())!, end)
        case .year: return (cal.date(byAdding: .year, value: -1, to: Date())!, end)
        case .custom: return (cal.startOfDay(for: from), cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to))!)
        }
    }
}

// A due date counts as "timed" unless it sits exactly at midnight.
func dueHasTime(_ d: Date) -> Bool { d != Calendar.current.startOfDay(for: d) }

func isOverdue(_ d: Date) -> Bool {
    dueHasTime(d) ? d < Date() : d < Calendar.current.startOfDay(for: Date())
}

func dueLabel(_ d: Date) -> String {
    let cal = Calendar.current
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0
    let rel: String
    switch days {
    case 0: rel = "Today"
    case 1: rel = "Tomorrow"
    case -1: rel = "Yesterday"
    case 2...6: rel = d.formatted(.dateTime.weekday(.wide))
    case ..<(-1): rel = "\(-days) days overdue"
    default: rel = "In \(days) days"
    }
    var s = "\(rel) · \(d.formatted(.dateTime.day().month(.abbreviated)))"
    if dueHasTime(d) { s += ", \(d.formatted(date: .omitted, time: .shortened))" }
    return s
}

enum DueBucket: Int, CaseIterable {
    case overdue, today, upcoming, none
    var title: String { ["Overdue", "Today", "Upcoming", "No date"][rawValue] }
}

func dueBucket(_ d: Date?) -> DueBucket {
    guard let d else { return .none }
    if isOverdue(d) { return .overdue }
    return Calendar.current.isDateInToday(d) ? .today : .upcoming
}

// Monday-first grid of days for the month (or week) containing `anchor`.
func calendarDays(anchor: Date, week: Bool) -> [Date] {
    var cal = Calendar.current
    cal.firstWeekday = 2
    if week {
        let start = cal.dateInterval(of: .weekOfYear, for: anchor)!.start
        return (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }
    }
    let month = cal.dateInterval(of: .month, for: anchor)!
    let first = cal.dateInterval(of: .weekOfYear, for: month.start)!.start
    let last = cal.dateInterval(of: .weekOfYear, for: cal.date(byAdding: .day, value: -1, to: month.end)!)!.end
    let n = cal.dateComponents([.day], from: first, to: last).day ?? 35
    return (0..<n).map { cal.date(byAdding: .day, value: $0, to: first)! }
}

struct DueDateButton: View {
    @Binding var due: Date?
    var excludeId: Int64 = 0
    @EnvironmentObject var store: TodoStore
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text(due.map(dueLabel) ?? "Set due date")
                if due != nil {
                    Button { due = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(due.map { isOverdue($0) ? Color.red : Color.accentColor } ?? Color.secondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill((due.map { isOverdue($0) ? Color.red : Color.accentColor } ?? Color.primary).opacity(0.1)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            DuePopover(due: $due, workload: workload, close: { open = false })
        }
    }

    // Open todos per due day, excluding the one being edited.
    var workload: [Date: Int] {
        var m: [Date: Int] = [:]
        let cal = Calendar.current
        for t in store.items where !t.deleted && t.done == nil && t.id != excludeId {
            if let d = t.due { m[cal.startOfDay(for: d), default: 0] += 1 }
        }
        return m
    }
}

// Quick list + month grid (Monday first) with workload dots + optional time presets.
struct DuePopover: View {
    @Binding var due: Date?
    var workload: [Date: Int]
    var close: () -> Void
    @State private var day: Date          // selected day at 00:00
    @State private var time: Date?        // selected time of day, nil = date only
    @State private var month: Date        // first day of the visible month
    @State private var customTime = Date()

    static var cal: Calendar { var c = Calendar.current; c.firstWeekday = 2; return c }

    init(due: Binding<Date?>, workload: [Date: Int], close: @escaping () -> Void) {
        _due = due
        self.workload = workload
        self.close = close
        let cal = Self.cal
        let d = due.wrappedValue ?? Date()
        let start = cal.startOfDay(for: d)
        _day = State(initialValue: start)
        _time = State(initialValue: due.wrappedValue.flatMap { dueHasTime($0) ? $0 : nil })
        _month = State(initialValue: cal.date(from: cal.dateComponents([.year, .month], from: start))!)
        _customTime = State(initialValue: due.wrappedValue.flatMap { dueHasTime($0) ? $0 : nil } ?? cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!)
    }

    var cal: Calendar { Self.cal }
    var today: Date { cal.startOfDay(for: Date()) }

    var result: Date {
        guard let t = time else { return day }
        let c = cal.dateComponents([.hour, .minute], from: t)
        return cal.date(bySettingHour: c.hour ?? 9, minute: c.minute ?? 0, second: 0, of: day) ?? day
    }

    func offset(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: today)! }
    var nextMonday: Date {
        let w = cal.component(.weekday, from: today) // 1 = Sunday
        let n = (9 - w) % 7
        return offset(n == 0 ? 7 : n)
    }
    var saturday: Date {
        let w = cal.component(.weekday, from: today)
        return offset((7 - w + 7) % 7 == 0 ? 7 : (7 - w + 7) % 7)
    }

    func pick(_ d: Date) {
        day = cal.startOfDay(for: d)
        month = cal.date(from: cal.dateComponents([.year, .month], from: day))!
    }

    var presets: [(String, String, Date)] {
        [("Today", "sun.max", today), ("Tomorrow", "sunrise", offset(1)), ("This weekend", "figure.walk", saturday),
         ("Next week", "arrow.right.circle", nextMonday), ("Next month", "calendar.badge.plus", cal.date(byAdding: .month, value: 1, to: today)!)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 2) {
                ForEach(presets, id: \.0) { p in
                    let on = cal.isDate(day, inSameDayAs: p.2)
                    Button { pick(p.2) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: p.1).frame(width: 18).foregroundStyle(on ? Color.accentColor : .secondary)
                            Text(p.0)
                            Spacer()
                            Text(p.2.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                .font(.caption).foregroundStyle(on ? Color.accentColor : .secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.accentColor.opacity(0.14) : .clear))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Button { month = cal.date(byAdding: .month, value: -1, to: month)! } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button { pick(today) } label: { Text("Today").font(.caption) }.buttonStyle(.borderless)
                Button { month = cal.date(byAdding: .month, value: 1, to: month)! } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
            }.padding(.horizontal, 4)
            grid
            let n = workload[day] ?? 0
            Text(n == 0 ? "Nothing else due \(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))" : "\(n) other todo\(n == 1 ? "" : "s") due \(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))")
                .font(.caption).foregroundStyle(n >= 3 ? Color.orange : .secondary).padding(.horizontal, 4)
            Divider()
            timeRow
            HStack {
                Button("Clear") { due = nil; close() }.foregroundStyle(.red).buttonStyle(.borderless)
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Set \(result.formatted(.dateTime.day().month(.abbreviated)))\(time == nil ? "" : ", " + result.formatted(date: .omitted, time: .shortened))") { due = result; close() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width: 320)
    }

    var grid: some View {
        let days = monthDays()
        return VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, d in
                    Text(d).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, d in
                    if let d {
                        let sel = cal.isDate(d, inSameDayAs: day)
                        let isToday = cal.isDate(d, inSameDayAs: today)
                        let count = workload[d] ?? 0
                        Button { pick(d) } label: {
                            ZStack {
                                Circle().fill(sel ? Color.accentColor : .clear)
                                if isToday && !sel { Circle().stroke(Color.accentColor, lineWidth: 1.5) }
                                Text("\(cal.component(.day, from: d))").font(.callout.weight(sel ? .bold : .regular))
                                    .foregroundStyle(sel ? Color.white : (d < today ? Color.secondary : (isToday ? Color.accentColor : Color.primary)))
                                if count > 0 {
                                    Circle().fill(sel ? Color.white.opacity(0.8) : (count >= 3 ? Color.orange : Color.secondary))
                                        .frame(width: 4, height: 4).offset(y: 11)
                                }
                            }.frame(height: 34).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(count == 0 ? "" : "\(count) due")
                    } else { Color.clear.frame(height: 34) }
                }
            }
        }
    }

    func monthDays() -> [Date?] {
        let first = month
        let wd = cal.component(.weekday, from: first)
        let lead = (wd - cal.firstWeekday + 7) % 7
        let count = cal.range(of: .day, in: .month, for: first)!.count
        return Array(repeating: nil, count: lead) + (0..<count).map { cal.date(byAdding: .day, value: $0, to: first) }
    }

    @ViewBuilder var timeRow: some View {
        if let t = time {
            HStack(spacing: 6) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                ForEach([9, 12, 15, 18], id: \.self) { h in
                    let on = cal.component(.hour, from: t) == h && cal.component(.minute, from: t) == 0
                    Button { setTime(h, 0) } label: {
                        Text(String(format: "%d:00", h)).font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.08)))
                            .foregroundStyle(on ? Color.white : Color.primary)
                    }.buttonStyle(.plain)
                }
                DatePicker("", selection: Binding(get: { t }, set: { time = $0; customTime = $0 }), displayedComponents: .hourAndMinute).labelsHidden()
                Spacer(minLength: 0)
                Button { time = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Remove time")
            }
        } else {
            Button { setTime(9, 0) } label: { Label("Add time", systemImage: "clock") }.buttonStyle(.borderless)
        }
    }

    func setTime(_ h: Int, _ m: Int) {
        time = cal.date(bySettingHour: h, minute: m, second: 0, of: Date())
    }
}

private let priorityNames = ["None", "Low", "Medium", "High"]
private let priorityColors: [Color] = [.gray, .blue, .orange, .red]

struct TodoView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case active = "Active", done = "Done log", history = "Activity", trash = "Trash"
        var id: String { rawValue }
        var icon: String {
            switch self { case .active: return "circle.dashed"; case .done: return "checkmark.circle"; case .history: return "clock.arrow.circlepath"; case .trash: return "trash" }
        }
    }
    @EnvironmentObject var store: TodoStore
    @State private var mode: Mode = .active
    @State private var query = ""
    @State private var range: TodoRange = .all
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var to = Date()
    @State private var newTitle = ""
    @State private var editing: TodoItem?
    @State private var creating = false
    @State private var layout: Layout = .list
    @State private var grouping: Grouping = .date
    @State private var collapsed: Set<Int64> = []
    @State private var calWeek = false
    @State private var calAnchor = Date()

    enum Layout: String, CaseIterable, Identifiable {
        case list = "List", board = "Board", calendar = "Calendar"
        var id: String { rawValue }
        var icon: String { ["list.bullet", "rectangle.split.3x1", "calendar"][Self.allCases.firstIndex(of: self)!] }
    }
    enum Grouping: String, CaseIterable, Identifiable {
        case date = "By date", priority = "By priority"
        var id: String { rawValue }
    }

    func inRange(_ d: Date) -> Bool {
        guard let b = range.bounds(from: from, to: to) else { return true }
        return d >= b.0 && d < b.1
    }

    func matches(_ i: TodoItem) -> Bool {
        if query.isEmpty { return true }
        if i.title.localizedCaseInsensitiveContains(query) || i.detail.localizedCaseInsensitiveContains(query) { return true }
        if store.subs[i.id]?.contains(where: { $0.title.localizedCaseInsensitiveContains(query) }) == true { return true }
        return store.links[i.id]?.contains { $0.note.localizedCaseInsensitiveContains(query) || store.title($0.otherId).localizedCaseInsensitiveContains(query) } == true
    }

    var active: [TodoItem] {
        store.items.filter { !$0.deleted && $0.done == nil && matches($0) && inRange($0.created) }
            .sorted { ($0.priority, $1.due ?? .distantFuture) > ($1.priority, $0.due ?? .distantFuture) }
    }
    var doneItems: [TodoItem] {
        store.items.filter { !$0.deleted && $0.done != nil && matches($0) && inRange($0.done!) }.sorted { $0.done! > $1.done! }
    }
    var trash: [TodoItem] { store.items.filter { $0.deleted && matches($0) } }
    var history: [TodoEvent] {
        store.events.filter { (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.action.localizedCaseInsensitiveContains(query)) && inRange($0.date) }
    }

    var openCount: Int { store.items.filter { !$0.deleted && $0.done == nil }.count }
    var overdueCount: Int {
        store.items.filter { !$0.deleted && $0.done == nil && ($0.due.map(isOverdue) ?? false) }.count
    }
    var doneToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return store.items.filter { !$0.deleted && ($0.done ?? .distantPast) >= start }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if mode == .active { quickAdd }
            if mode != .history { viewBar }
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editing) { item in
            TodoModal(item: item, subs: store.subs[item.id] ?? [], links: store.links[item.id] ?? []) { store.save($0, subs: $1, links: $2) }
                .environmentObject(store)
        }
        .sheet(isPresented: $creating) {
            TodoModal(item: TodoItem(id: 0, title: newTitle, detail: "", priority: 0, due: nil, created: Date(), done: nil, deleted: false), subs: [], links: []) {
                store.save($0, subs: $1, links: $2); newTitle = ""
            }.environmentObject(store)
        }
    }

    var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                stat("\(openCount)", "Open", .blue)
                stat("\(overdueCount)", "Overdue", overdueCount > 0 ? .red : .gray)
                stat("\(doneToday)", "Done today", .green)
                Spacer()
                Button { creating = true } label: { Label("New todo", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            HStack(spacing: 10) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 380)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search todos, sub-items, link notes", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                Picker("", selection: $range) { ForEach(TodoRange.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 110)
                if range == .custom {
                    DatePicker("", selection: $from, displayedComponents: .date).labelsHidden()
                    Text("–").foregroundStyle(.secondary)
                    DatePicker("", selection: $to, displayedComponents: .date).labelsHidden()
                }
            }
        }.padding(14)
    }

    var viewBar: some View {
        HStack(spacing: 10) {
            if mode == .active {
                Picker("", selection: $layout) {
                    ForEach(Layout.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 270)
                if layout == .list {
                    Picker("", selection: $grouping) { ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }
            }
            Spacer()
            if mode != .active || layout == .list {
                Button { collapsed = [] } label: { Label("Expand all", systemImage: "chevron.down.2") }
                Button { collapsed = Set(store.items.map(\.id)) } label: { Label("Collapse all", systemImage: "chevron.up.2") }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.top, 10)
    }

    func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(value).font(.title2.bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.1)))
    }

    var quickAdd: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor).font(.title3)
            TextField("Quick add: type a title and press Return", text: $newTitle).textFieldStyle(.plain).onSubmit {
                store.add(title: newTitle); newTitle = ""
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 14).padding(.top, 12)
    }

    @ViewBuilder var content: some View {
        switch mode {
        case .active:
            switch layout {
            case .list: groupedList
            case .board: board
            case .calendar: calendar
            }
        case .done: doneLog
        case .trash: cards(trash, icon: "trash", empty: "Trash is empty", hint: "Deleted todos stay here and can be restored.")
        case .history: historyList
        }
    }

    func emptyState(_ icon: String, _ title: String, _ hint: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(hint).font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func cards(_ items: [TodoItem], icon: String, empty: String, hint: String) -> some View {
        Group {
            if items.isEmpty { emptyState(icon, empty, hint) }
            else { ScrollView { LazyVStack(spacing: 10) { ForEach(items) { card($0) } }.padding(14) } }
        }
    }

    var doneLog: some View {
        let groups = Dictionary(grouping: doneItems) { Calendar.current.startOfDay(for: $0.done!) }
        let days = groups.keys.sorted(by: >)
        return Group {
            if doneItems.isEmpty { emptyState("checkmark.circle", "No completed todos", "Nothing finished in this range.") }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(days, id: \.self) { day in
                            HStack {
                                Text(day.formatted(date: .complete, time: .omitted)).font(.headline)
                                Text("\(groups[day]!.count)").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.green.opacity(0.2)))
                            }.padding(.top, 8)
                            ForEach(groups[day]!) { card($0) }
                        }
                    }.padding(14)
                }
            }
        }
    }

    var historyList: some View {
        Group {
            if history.isEmpty { emptyState("clock.arrow.circlepath", "No activity", "Nothing logged in this range.") }
            else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(history) { e in
                            HStack(spacing: 12) {
                                Image(systemName: icon(e.action)).foregroundStyle(color(e.action)).frame(width: 22)
                                Text(e.action.capitalized).font(.caption.bold()).foregroundStyle(color(e.action)).frame(width: 110, alignment: .leading)
                                Text(e.title).lineLimit(2)
                                Spacer()
                                Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8).padding(.horizontal, 14)
                            Divider().padding(.leading, 48)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
    }

    func icon(_ a: String) -> String {
        switch a {
        case "created": return "plus.circle.fill"
        case "started": return "play.circle.fill"
        case "completed": return "checkmark.circle.fill"
        case "reopened": return "arrow.uturn.backward.circle"
        case "deleted": return "trash.fill"
        case "restored": return "arrow.uturn.up.circle"
        case "subtask done": return "checkmark.square.fill"
        case "subtask reopened": return "square"
        case "linked", "link note": return "link"
        case "unlinked": return "link.badge.plus"
        default: return "pencil.circle"
        }
    }
    func color(_ a: String) -> Color {
        switch a {
        case "completed", "subtask done": return .green
        case "deleted", "unlinked": return .red
        case "created": return .blue
        case "linked", "link note": return .purple
        default: return .secondary
        }
    }

    func expandable(_ i: TodoItem) -> Bool {
        !i.detail.isEmpty || !(store.subs[i.id] ?? []).isEmpty || !(store.links[i.id] ?? []).isEmpty
    }

    func toggleCollapse(_ id: Int64) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }

    func progressRow(_ p: (done: Int, total: Int, percent: Int)) -> some View {
        let color: Color = p.percent == 100 ? .green : .accentColor
        return HStack(spacing: 10) {
            Text("\(p.percent)%").font(.system(size: 15, weight: .bold).monospacedDigit()).foregroundStyle(color)
                .frame(width: 44, alignment: .leading)
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).tint(color).scaleEffect(x: 1, y: 1.8)
            Text("\(p.done)/\(p.total)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    func card(_ i: TodoItem) -> some View {
        let subs = store.subs[i.id] ?? []
        let p = subProgress(subs)
        let overdue = i.done == nil && (i.due.map(isOverdue) ?? false)
        let canDone = store.canComplete(i.id)
        let canExpand = expandable(i)
        let open = canExpand && !collapsed.contains(i.id)
        return HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2).fill(i.priority == 0 ? Color.clear : priorityColors[i.priority]).frame(width: 4)
            HStack(alignment: .top, spacing: 12) {
                if i.deleted {
                    Image(systemName: "trash").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 22)
                } else {
                    Button { store.toggleDone(i) } label: {
                        Image(systemName: i.done == nil ? "circle" : "checkmark.circle.fill").font(.system(size: 20))
                            .foregroundStyle(i.done != nil ? Color.green : (canDone ? Color.secondary : Color.secondary.opacity(0.3)))
                    }
                    .buttonStyle(.plain).disabled(i.done == nil && !canDone)
                    .help(i.done == nil && !canDone ? "Finish all sub-items first" : (i.done == nil ? "Mark as done" : "Reopen"))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(i.title).font(.system(size: 14, weight: .semibold)).strikethrough(i.done != nil)
                        .foregroundStyle(i.done != nil ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if i.priority > 0 { chip(priorityNames[i.priority], "flag.fill", priorityColors[i.priority]) }
                        if i.status == 1 && i.done == nil { chip("Doing", "play.fill", .blue) }
                        if let d = i.due { chip(dueLabel(d), "calendar", overdue ? .red : .secondary) }
                        if let d = i.done { chip("Done \(d.formatted(date: .abbreviated, time: .shortened))", "checkmark", .green) }
                        let nl = store.links[i.id]?.count ?? 0
                        if nl > 0 { chip("\(nl)", "link", .purple) }
                    }
                    if !subs.isEmpty { progressRow(p) }
                    if open {
                        if !i.detail.isEmpty {
                            Text(i.detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if !subs.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(subs) { sub in
                                    Button { store.toggleSub(i, sub) } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                                            SubCheck(on: sub.done).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                                            Text(sub.title).font(.system(size: 13)).strikethrough(sub.done)
                                                .foregroundStyle(sub.done ? .secondary : .primary)
                                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 0)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain).disabled(i.deleted)
                                }
                            }
                            .padding(.top, 8)
                            .overlay(alignment: .top) { Divider() }
                        }
                        linkChips(i)
                    }
                    if i.done == nil { Text("Created \(i.created.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 11)).foregroundStyle(.tertiary) }
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    if i.deleted {
                        Button("Restore") { store.restore(i) }
                    } else {
                        Menu {
                            Button("Open") { editing = i }
                            if i.done == nil { Button(i.status == 1 ? "Move to To do" : "Start (Doing)") { store.setStatus(i, i.status == 1 ? 0 : 1) } }
                            Button("Delete", role: .destructive) { store.remove(i) }
                        } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                    if canExpand {
                        Button { toggleCollapse(i.id) } label: {
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 22, height: 22).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(open ? "Collapse" : "Expand")
                    }
                }
            }.padding(14)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(count: 2) { if !i.deleted { editing = i } }
    }

    @ViewBuilder func linkChips(_ i: TodoItem) -> some View {
        if let ls = store.links[i.id], !ls.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ls) { l in
                    Button {
                        if let t = store.items.first(where: { $0.id == l.otherId }) { editing = t }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "link").font(.system(size: 10))
                            Text(store.title(l.otherId)).font(.system(size: 11, weight: .semibold))
                            if !l.note.isEmpty { Text("— \(l.note)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.purple.opacity(0.12)))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: list grouped by date or priority

    var groupedList: some View {
        let groups: [(String, Color, [TodoItem])]
        if grouping == .date {
            groups = DueBucket.allCases.map { b in
                (b.title, b == .overdue ? Color.red : Color.secondary, active.filter { dueBucket($0.due) == b }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) })
            }
        } else {
            groups = [3, 2, 1, 0].map { p in
                (p == 0 ? "No priority" : priorityNames[p] + " priority", priorityColors[p], active.filter { $0.priority == p })
            }
        }
        return Group {
            if active.isEmpty { emptyState("checklist", "Nothing to do", "Add a todo above, or press New todo for sub-items and links.") }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(groups.filter { !$0.2.isEmpty }, id: \.0) { g in
                            HStack(spacing: 8) {
                                Text(g.0.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(g.1)
                                Text("\(g.2.count)").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 1)
                                    .background(Capsule().fill(g.1.opacity(0.15)))
                            }.padding(.top, 8)
                            ForEach(g.2) { card($0) }
                        }
                    }.padding(14)
                }
            }
        }
    }

    // MARK: board

    func boardCard(_ i: TodoItem) -> some View {
        let subs = store.subs[i.id] ?? []
        let p = subProgress(subs)
        let overdue = i.done == nil && (i.due.map(isOverdue) ?? false)
        return VStack(alignment: .leading, spacing: 7) {
            Text(i.title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if !subs.isEmpty { progressRow(p) }
            HStack(spacing: 5) {
                if i.priority > 0 { chip(priorityNames[i.priority], "flag.fill", priorityColors[i.priority]) }
                if let d = i.due { chip(dueLabel(d), "calendar", overdue ? .red : .secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        .onTapGesture(count: 2) { editing = i }
        .draggable(String(i.id))
    }

    @discardableResult func moveCard(_ ids: [String], to column: Int) -> Bool {
        guard let id = ids.first.flatMap({ Int64($0) }), var item = store.items.first(where: { $0.id == id }) else { return false }
        if column == 2 { store.toggleDone(item); return true }
        if item.done != nil { store.toggleDone(item); item = store.items.first { $0.id == id } ?? item }
        store.setStatus(item, column)
        return true
    }

    var board: some View {
        let todo = active.filter { $0.status == 0 }
        let doing = active.filter { $0.status == 1 }
        let done = Array(doneItems.prefix(30))
        let cols: [(String, Color, [TodoItem])] = [("To do", .secondary, todo), ("Doing", .blue, doing), ("Done", .green, done)]
        return HStack(alignment: .top, spacing: 12) {
            ForEach(Array(cols.enumerated()), id: \.offset) { n, c in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(c.0.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(c.1)
                        Text("\(c.2.count)").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 1)
                            .background(Capsule().fill(c.1.opacity(0.15)))
                    }.padding(.horizontal, 4)
                    ScrollView { LazyVStack(spacing: 8) { ForEach(c.2) { boardCard($0) } } }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                .dropDestination(for: String.self) { ids, _ in moveCard(ids, to: n) }
            }
        }.padding(14)
    }

    // MARK: calendar

    var calendar: some View {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let days = calendarDays(anchor: calAnchor, week: calWeek)
        let dated = store.items.filter { !$0.deleted && $0.due != nil && matches($0) }
        let undated = store.items.filter { !$0.deleted && $0.done == nil && $0.due == nil && matches($0) }.count
        let title = calWeek
            ? "\(days.first!.formatted(.dateTime.day().month(.abbreviated))) – \(days.last!.formatted(.dateTime.day().month(.abbreviated).year()))"
            : calAnchor.formatted(.dateTime.month(.wide).year())
        let step = { (n: Int) in calAnchor = cal.date(byAdding: calWeek ? .weekOfYear : .month, value: n, to: calAnchor)! }
        let maxEvents = calWeek ? 12 : 3
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                Text(title).font(.system(size: 15, weight: .semibold)).frame(minWidth: 170)
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                Button("Today") { calAnchor = Date() }
                Spacer()
                if undated > 0 { Text("\(undated) without a due date").font(.caption).foregroundStyle(.secondary) }
                Picker("", selection: $calWeek) { Text("Month").tag(false); Text("Week").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 130)
            }
            HStack(spacing: 4) {
                ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) {
                    Text($0).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(days, id: \.self) { d in
                        let list = dated.filter { cal.isDate($0.due!, inSameDayAs: d) }.sorted { $0.due! < $1.due! }
                        let inMonth = calWeek || cal.isDate(d, equalTo: calAnchor, toGranularity: .month)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(cal.component(.day, from: d))")
                                .font(.system(size: 11, weight: cal.isDateInToday(d) ? .bold : .regular))
                                .foregroundStyle(cal.isDateInToday(d) ? Color.white : (inMonth ? .primary : .secondary))
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(cal.isDateInToday(d) ? Color.accentColor : .clear))
                            ForEach(list.prefix(maxEvents)) { i in
                                Button { editing = i } label: {
                                    Text(i.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .foregroundStyle(eventColor(i))
                                        .background(RoundedRectangle(cornerRadius: 4).fill(eventColor(i).opacity(0.15)))
                                }.buttonStyle(.plain).help(i.title)
                            }
                            if list.count > maxEvents { Text("+\(list.count - maxEvents) more").font(.system(size: 10)).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity, minHeight: calWeek ? 300 : 96, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(inMonth ? 0.05 : 0.02)))
                    }
                }
            }
        }.padding(14)
    }

    func eventColor(_ i: TodoItem) -> Color {
        if i.done != nil { return .green }
        return i.due.map(isOverdue) == true ? .red : .accentColor
    }

    func chip(_ text: String, _ icon: String, _ color: Color) -> some View {
        Label(text, systemImage: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct SubCheck: View {
    let on: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.5).opacity(on ? 0 : 1)
            if on {
                Circle().fill(Color.green)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
            }
        }.frame(width: 18, height: 18)
    }
}

struct TodoModal: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var store: TodoStore
    @State var item: TodoItem
    @State private var subs: [SubDraft]
    @State private var links: [TodoLink]
    @State private var newSub = ""
    @State private var linkQuery = ""
    @FocusState private var subFocus: Bool
    var onSave: (TodoItem, [SubDraft], [TodoLink]) -> Void

    init(item: TodoItem, subs: [SubDraft], links: [TodoLink], onSave: @escaping (TodoItem, [SubDraft], [TodoLink]) -> Void) {
        _item = State(initialValue: item)
        _subs = State(initialValue: subs)
        _links = State(initialValue: links)
        self.onSave = onSave
    }

    var isNew: Bool { item.id == 0 }
    var progress: (done: Int, total: Int, percent: Int) { subProgress(subs) }
    var allDone: Bool { subs.allSatisfy(\.done) }
    var titleOK: Bool { !item.title.trimmingCharacters(in: .whitespaces).isEmpty }

    func addSub() {
        let t = newSub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        subs.append(SubDraft(dbId: nil, title: t, done: false))
        newSub = ""; subFocus = true
    }

    func commit(done: Date?? = nil) {
        if let d = done { item.done = d }
        onSave(item, subs, links); dismiss()
    }

    var linkCandidates: [TodoItem] {
        guard !linkQuery.isEmpty else { return [] }
        let linked = Set(links.map(\.otherId))
        return store.items.filter { t in
            !t.deleted && t.id != item.id && !linked.contains(t.id) && t.title.localizedCaseInsensitiveContains(linkQuery)
        }.prefix(5).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isNew ? "New todo" : "Todo").font(.title3.bold())
                if item.done != nil { Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption.bold()) }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }.buttonStyle(.plain)
            }.padding([.horizontal, .top], 20).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("What needs to be done?", text: $item.title).textFieldStyle(.plain).font(.title2.weight(.semibold))
                    section("Description") {
                        TextEditor(text: $item.detail).font(.body).frame(height: 80).scrollContentBackground(.hidden)
                            .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    }
                    section("Sub-items") {
                        VStack(alignment: .leading, spacing: 8) {
                            if !subs.isEmpty {
                                HStack(spacing: 10) {
                                    ProgressView(value: Double(progress.done), total: Double(progress.total)).tint(progress.percent == 100 ? .green : .accentColor)
                                    Text("\(progress.percent)%").font(.headline.monospacedDigit()).foregroundStyle(progress.percent == 100 ? .green : .primary)
                                    Text("\(progress.done)/\(progress.total)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            ForEach($subs) { $sub in
                                HStack {
                                    Toggle("", isOn: $sub.done).toggleStyle(.checkbox).labelsHidden()
                                    TextField("Sub-item", text: $sub.title).textFieldStyle(.plain)
                                        .strikethrough(sub.done).foregroundStyle(sub.done ? .secondary : .primary)
                                    Button { subs.removeAll { $0.uid == sub.uid } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                            }
                            HStack {
                                Image(systemName: "plus").foregroundStyle(.secondary)
                                TextField("Add a sub-item, e.g. Math, Physics, Chemistry", text: $newSub).textFieldStyle(.plain)
                                    .focused($subFocus).onSubmit(addSub)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4])))
                        }
                    }
                    section("Linked todos") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach($links) { $l in
                                HStack(spacing: 8) {
                                    Image(systemName: l.outgoing ? "arrow.right" : "arrow.left").foregroundStyle(.purple).font(.caption)
                                    Text(store.title(l.otherId)).font(.callout.bold()).lineLimit(1).frame(maxWidth: 150, alignment: .leading)
                                    TextField("Note about this link", text: $l.note).textFieldStyle(.plain)
                                    Button { links.removeAll { $0.uid == l.uid } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.08)))
                            }
                            HStack {
                                Image(systemName: "link").foregroundStyle(.secondary)
                                TextField("Search a todo to link", text: $linkQuery).textFieldStyle(.plain)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4])))
                            ForEach(linkCandidates) { c in
                                Button {
                                    links.append(TodoLink(otherId: c.id, note: "", outgoing: true)); linkQuery = ""
                                } label: {
                                    HStack { Image(systemName: "plus.circle"); Text(c.title); Spacer() }
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
                                }.buttonStyle(.plain)
                            }
                            if isNew && !linkQuery.isEmpty && linkCandidates.isEmpty { Text("No matching todo").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    HStack(spacing: 16) {
                        section("Priority") {
                            Picker("", selection: $item.priority) {
                                ForEach(0..<4, id: \.self) { Text(priorityNames[$0]).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden()
                        }
                        section("Due date") { DueDateButton(due: $item.due, excludeId: item.id) }
                    }
                }.padding(20)
            }
            Divider()
            HStack {
                if !isNew {
                    if item.done == nil {
                        Button { commit(done: .some(Date())) } label: { Label("DONE", systemImage: "checkmark.circle.fill").frame(minWidth: 70) }
                            .buttonStyle(.borderedProminent).tint(.green).disabled(!allDone || !titleOK)
                            .help(allDone ? "Mark this todo as done" : "Complete all sub-items to enable DONE")
                        if !allDone { Text("Finish all sub-items to enable DONE").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Button { commit(done: .some(nil)) } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { commit() }
                    .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent).disabled(!titleOK)
            }.padding(16)
        }
        .frame(width: 600, height: 640)
    }

    func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
