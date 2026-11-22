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
}

struct TodoEvent: Identifiable {
    var id: Int64
    var todoId: Int64
    var action: String
    var title: String
    var date: Date
}

// Permanent storage: nothing is ever hard-deleted. "Delete" is a soft flag and every change is appended to the log.
@MainActor
final class TodoStore: ObservableObject {
    @Published var items: [TodoItem] = []
    @Published var events: [TodoEvent] = []
    private var db: OpaquePointer?

    init() {
        sqlite3_open(Store.dir.appendingPathComponent("todos.sqlite").path, &db)
        run("CREATE TABLE IF NOT EXISTS todos (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '', priority INTEGER NOT NULL DEFAULT 0, due REAL, created REAL NOT NULL, done REAL, deleted INTEGER NOT NULL DEFAULT 0)")
        run("CREATE TABLE IF NOT EXISTS todo_log (id INTEGER PRIMARY KEY AUTOINCREMENT, todo_id INTEGER NOT NULL, action TEXT NOT NULL, title TEXT NOT NULL, date REAL NOT NULL)")
        run("CREATE INDEX IF NOT EXISTS idx_log_date ON todo_log(date)")
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
        if sqlite3_prepare_v2(db, "SELECT id, title, detail, priority, due, created, done, deleted FROM todos ORDER BY created DESC", -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                out.append(TodoItem(id: sqlite3_column_int64(st, 0), title: text(st, 1), detail: text(st, 2),
                                    priority: Int(sqlite3_column_int(st, 3)), due: optDate(st, 4),
                                    created: Date(timeIntervalSince1970: sqlite3_column_double(st, 5)),
                                    done: optDate(st, 6), deleted: sqlite3_column_int(st, 7) != 0))
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
    }

    private func log(_ id: Int64, _ action: String, _ title: String) {
        run("INSERT INTO todo_log (todo_id, action, title, date) VALUES (?, ?, ?, ?)", [id, action, title, Date().timeIntervalSince1970])
    }

    func add(title: String, detail: String = "", priority: Int = 0, due: Date? = nil) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        run("INSERT INTO todos (title, detail, priority, due, created) VALUES (?, ?, ?, ?, ?)",
            [t, detail, priority, due?.timeIntervalSince1970, Date().timeIntervalSince1970])
        log(sqlite3_last_insert_rowid(db), "created", t)
        reload()
    }

    func update(_ i: TodoItem) {
        run("UPDATE todos SET title = ?, detail = ?, priority = ?, due = ? WHERE id = ?",
            [i.title, i.detail, i.priority, i.due?.timeIntervalSince1970, i.id])
        log(i.id, "edited", i.title)
        reload()
    }

    func toggleDone(_ i: TodoItem) {
        if i.done == nil {
            run("UPDATE todos SET done = ? WHERE id = ?", [Date().timeIntervalSince1970, i.id])
            log(i.id, "completed", i.title)
        } else {
            run("UPDATE todos SET done = NULL WHERE id = ?", [i.id])
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

struct TodoView: View {
    enum Mode: String, CaseIterable, Identifiable { case active = "Active", done = "Done log", history = "Activity", trash = "Trash"; var id: String { rawValue } }
    @EnvironmentObject var store: TodoStore
    @State private var mode: Mode = .active
    @State private var query = ""
    @State private var range: TodoRange = .all
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var to = Date()
    @State private var newTitle = ""
    @State private var newPriority = 0
    @State private var newDue: Date?
    @State private var editing: TodoItem?

    func inRange(_ d: Date) -> Bool {
        guard let b = range.bounds(from: from, to: to) else { return true }
        return d >= b.0 && d < b.1
    }
    func matches(_ t: String, _ d: String) -> Bool {
        query.isEmpty || t.localizedCaseInsensitiveContains(query) || d.localizedCaseInsensitiveContains(query)
    }

    var active: [TodoItem] {
        store.items.filter { !$0.deleted && $0.done == nil && matches($0.title, $0.detail) && inRange($0.created) }
            .sorted { ($0.priority, $1.due ?? .distantFuture) > ($1.priority, $0.due ?? .distantFuture) }
    }
    var doneItems: [TodoItem] {
        store.items.filter { !$0.deleted && $0.done != nil && matches($0.title, $0.detail) && inRange($0.done!) }
            .sorted { $0.done! > $1.done! }
    }
    var trash: [TodoItem] { store.items.filter { $0.deleted && matches($0.title, $0.detail) } }
    var history: [TodoEvent] { store.events.filter { matches($0.title, $0.action) && inRange($0.date) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 340).labelsHidden()
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search todos and history", text: $query).textFieldStyle(.plain)
                Picker("Range", selection: $range) { ForEach(TodoRange.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 150)
                if range == .custom {
                    DatePicker("", selection: $from, displayedComponents: .date).labelsHidden()
                    Text("–")
                    DatePicker("", selection: $to, displayedComponents: .date).labelsHidden()
                }
            }.padding(10)
            Divider()
            if mode == .active { addBar; Divider() }
            content
            Divider()
            HStack {
                Text("\(store.items.filter { !$0.deleted && $0.done == nil }.count) open · \(store.items.filter { !$0.deleted && $0.done != nil }.count) done · \(store.events.count) log entries · stored permanently")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(8)
        }
        .sheet(item: $editing) { item in TodoEditor(item: item) { store.update($0) } }
    }

    var addBar: some View {
        HStack {
            TextField("Add a todo and press Return", text: $newTitle).textFieldStyle(.roundedBorder).onSubmit(add)
            Picker("", selection: $newPriority) {
                Text("No priority").tag(0); Text("Low").tag(1); Text("Medium").tag(2); Text("High").tag(3)
            }.labelsHidden().frame(width: 120)
            if let d = newDue {
                DatePicker("", selection: Binding(get: { d }, set: { newDue = $0 }), displayedComponents: .date).labelsHidden()
                Button { newDue = nil } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
            } else {
                Button("Due date") { newDue = Date() }
            }
            Button("Add", action: add).disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }.padding(10)
    }

    func add() {
        store.add(title: newTitle, priority: newPriority, due: newDue)
        newTitle = ""; newPriority = 0; newDue = nil
    }

    @ViewBuilder var content: some View {
        switch mode {
        case .active: list(active, empty: "Nothing to do. Add a todo above.")
        case .done: doneLog
        case .trash: list(trash, empty: "Trash is empty")
        case .history: historyList
        }
    }

    func list(_ items: [TodoItem], empty: String) -> some View {
        Group {
            if items.isEmpty { VStack { Spacer(); Text(empty).foregroundStyle(.secondary); Spacer() } }
            else {
                ScrollView { LazyVStack(spacing: 6) { ForEach(items) { row($0) } }.padding(12) }
            }
        }.frame(maxHeight: .infinity)
    }

    var doneLog: some View {
        let groups = Dictionary(grouping: doneItems) { Calendar.current.startOfDay(for: $0.done!) }
        let days = groups.keys.sorted(by: >)
        return Group {
            if doneItems.isEmpty { VStack { Spacer(); Text("No completed todos in this range").foregroundStyle(.secondary); Spacer() } }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(days, id: \.self) { day in
                            Text("\(day.formatted(date: .complete, time: .omitted)) · \(groups[day]!.count)")
                                .font(.headline).padding(.top, 10)
                            ForEach(groups[day]!) { row($0) }
                        }
                    }.padding(12)
                }
            }
        }.frame(maxHeight: .infinity)
    }

    var historyList: some View {
        Group {
            if history.isEmpty { VStack { Spacer(); Text("No activity in this range").foregroundStyle(.secondary); Spacer() } }
            else {
                List(history) { e in
                    HStack {
                        Image(systemName: icon(e.action)).foregroundStyle(color(e.action)).frame(width: 20)
                        Text(e.action.capitalized).frame(width: 80, alignment: .leading).foregroundStyle(.secondary)
                        Text(e.title).lineLimit(2)
                        Spacer()
                        Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.frame(maxHeight: .infinity)
    }

    func icon(_ a: String) -> String {
        switch a {
        case "created": return "plus.circle"
        case "completed": return "checkmark.circle.fill"
        case "reopened": return "arrow.uturn.backward.circle"
        case "deleted": return "trash"
        case "restored": return "arrow.uturn.up.circle"
        default: return "pencil.circle"
        }
    }
    func color(_ a: String) -> Color {
        switch a { case "completed": return .green; case "deleted": return .red; case "created": return .blue; default: return .secondary }
    }

    func row(_ i: TodoItem) -> some View {
        let overdue = i.done == nil && (i.due.map { $0 < Calendar.current.startOfDay(for: Date()) } ?? false)
        return HStack(alignment: .top, spacing: 10) {
            if i.deleted {
                Image(systemName: "trash").foregroundStyle(.secondary)
            } else {
                Button { store.toggleDone(i) } label: {
                    Image(systemName: i.done == nil ? "circle" : "checkmark.circle.fill").font(.title3)
                        .foregroundStyle(i.done == nil ? Color.secondary : Color.green)
                }.buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(i.title).strikethrough(i.done != nil).foregroundStyle(i.done != nil ? .secondary : .primary)
                if !i.detail.isEmpty { Text(i.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                HStack(spacing: 8) {
                    if i.priority > 0 {
                        Text(["", "Low", "Medium", "High"][i.priority]).font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill([Color.clear, .blue, .orange, .red][i.priority].opacity(0.2)))
                    }
                    if let d = i.due {
                        Label(d.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                            .font(.caption2).foregroundStyle(overdue ? .red : .secondary)
                    }
                    Text("Created \(i.created.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                    if let d = i.done { Text("Done \(d.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.green) }
                }
            }
            Spacer()
            if i.deleted {
                Button("Restore") { store.restore(i) }.buttonStyle(.borderless)
            } else {
                Button { editing = i } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                Button { store.remove(i) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

struct TodoEditor: View {
    @Environment(\.dismiss) var dismiss
    @State var item: TodoItem
    @State private var hasDue: Bool
    var onSave: (TodoItem) -> Void

    init(item: TodoItem, onSave: @escaping (TodoItem) -> Void) {
        _item = State(initialValue: item)
        _hasDue = State(initialValue: item.due != nil)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit todo").font(.headline)
            TextField("Title", text: $item.title).textFieldStyle(.roundedBorder)
            TextEditor(text: $item.detail).frame(height: 90).border(Color.secondary.opacity(0.3))
            Picker("Priority", selection: $item.priority) {
                Text("None").tag(0); Text("Low").tag(1); Text("Medium").tag(2); Text("High").tag(3)
            }.pickerStyle(.segmented)
            Toggle("Due date", isOn: $hasDue)
            if hasDue {
                DatePicker("", selection: Binding(get: { item.due ?? Date() }, set: { item.due = $0 }), displayedComponents: .date).labelsHidden()
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if !hasDue { item.due = nil } else if item.due == nil { item.due = Date() }
                    onSave(item); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(item.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(20).frame(width: 440)
    }
}
