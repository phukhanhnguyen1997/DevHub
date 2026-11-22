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

struct SubDraft: Identifiable, Equatable {
    var uid = UUID()
    var id: UUID { uid }
    var dbId: Int64?
    var title: String
    var done: Bool
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
    @Published var subs: [Int64: [SubDraft]] = [:]
    private var db: OpaquePointer?

    init() {
        sqlite3_open(Store.dir.appendingPathComponent("todos.sqlite").path, &db)
        run("CREATE TABLE IF NOT EXISTS todos (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '', priority INTEGER NOT NULL DEFAULT 0, due REAL, created REAL NOT NULL, done REAL, deleted INTEGER NOT NULL DEFAULT 0)")
        run("CREATE TABLE IF NOT EXISTS todo_log (id INTEGER PRIMARY KEY AUTOINCREMENT, todo_id INTEGER NOT NULL, action TEXT NOT NULL, title TEXT NOT NULL, date REAL NOT NULL)")
        run("CREATE TABLE IF NOT EXISTS todo_subs (id INTEGER PRIMARY KEY AUTOINCREMENT, todo_id INTEGER NOT NULL, title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0, pos INTEGER NOT NULL DEFAULT 0)")
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
        var sm: [Int64: [SubDraft]] = [:]
        var s3: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, todo_id, title, done FROM todo_subs ORDER BY todo_id, pos, id", -1, &s3, nil) == SQLITE_OK {
            while sqlite3_step(s3) == SQLITE_ROW {
                sm[sqlite3_column_int64(s3, 1), default: []].append(SubDraft(dbId: sqlite3_column_int64(s3, 0), title: text(s3, 2), done: sqlite3_column_int(s3, 3) != 0))
            }
        }
        sqlite3_finalize(s3)
        subs = sm
    }

    // Creates (id == 0) or updates a todo together with its sub-items; every change is logged.
    func save(_ item: TodoItem, subs drafts: [SubDraft]) {
        var i = item
        let t = i.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        i.title = t
        let old = i.id == 0 ? [] : (subs[i.id] ?? [])
        if i.id == 0 {
            run("INSERT INTO todos (title, detail, priority, due, created, done) VALUES (?, ?, ?, ?, ?, ?)",
                [t, i.detail, i.priority, i.due?.timeIntervalSince1970, Date().timeIntervalSince1970, i.done?.timeIntervalSince1970])
            i.id = sqlite3_last_insert_rowid(db)
            log(i.id, "created", t)
        } else {
            let prev = items.first { $0.id == i.id }
            run("UPDATE todos SET title = ?, detail = ?, priority = ?, due = ?, done = ? WHERE id = ?",
                [t, i.detail, i.priority, i.due?.timeIntervalSince1970, i.done?.timeIntervalSince1970, i.id])
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
        reload()
    }

    func toggleSub(_ todo: TodoItem, _ sub: SubDraft) {
        guard let id = sub.dbId else { return }
        run("UPDATE todo_subs SET done = ? WHERE id = ?", [sub.done ? 0 : 1, id])
        log(todo.id, sub.done ? "subtask reopened" : "subtask done", "\(todo.title) › \(sub.title)")
        reload()
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
    @State private var creating = false

    func inRange(_ d: Date) -> Bool {
        guard let b = range.bounds(from: from, to: to) else { return true }
        return d >= b.0 && d < b.1
    }
    func matches(_ t: String, _ d: String, _ id: Int64? = nil) -> Bool {
        query.isEmpty || t.localizedCaseInsensitiveContains(query) || d.localizedCaseInsensitiveContains(query)
            || (id.map { store.subs[$0]?.contains { $0.title.localizedCaseInsensitiveContains(query) } ?? false } ?? false)
    }

    var active: [TodoItem] {
        store.items.filter { !$0.deleted && $0.done == nil && matches($0.title, $0.detail, $0.id) && inRange($0.created) }
            .sorted { ($0.priority, $1.due ?? .distantFuture) > ($1.priority, $0.due ?? .distantFuture) }
    }
    var doneItems: [TodoItem] {
        store.items.filter { !$0.deleted && $0.done != nil && matches($0.title, $0.detail, $0.id) && inRange($0.done!) }
            .sorted { $0.done! > $1.done! }
    }
    var trash: [TodoItem] { store.items.filter { $0.deleted && matches($0.title, $0.detail, $0.id) } }
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
        .sheet(item: $editing) { item in TodoModal(item: item, subs: store.subs[item.id] ?? []) { store.save($0, subs: $1) } }
        .sheet(isPresented: $creating) {
            TodoModal(item: TodoItem(id: 0, title: newTitle, detail: "", priority: newPriority, due: newDue, created: Date(), done: nil, deleted: false), subs: []) {
                store.save($0, subs: $1); newTitle = ""; newPriority = 0; newDue = nil
            }
        }
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
            Button { creating = true } label: { Label("New…", systemImage: "square.and.pencil") }.help("Open the full todo form with description and sub-items")
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
                        Text(e.action.capitalized).frame(width: 120, alignment: .leading).foregroundStyle(.secondary)
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
        case "subtask done": return "checkmark.square.fill"
        case "subtask reopened": return "square"
        case "restored": return "arrow.uturn.up.circle"
        default: return "pencil.circle"
        }
    }
    func color(_ a: String) -> Color {
        switch a { case "completed", "subtask done": return .green; case "deleted": return .red; case "created": return .blue; default: return .secondary }
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
                if let ss = store.subs[i.id], !ss.isEmpty {
                    let n = ss.filter(\.done).count
                    ProgressView(value: Double(n), total: Double(ss.count)).frame(width: 160)
                    ForEach(ss.prefix(4)) { sub in
                        HStack(spacing: 6) {
                            Button { store.toggleSub(i, sub) } label: { Image(systemName: sub.done ? "checkmark.square.fill" : "square").foregroundStyle(sub.done ? Color.green : Color.secondary) }
                                .buttonStyle(.plain).disabled(i.deleted)
                            Text(sub.title).font(.caption).strikethrough(sub.done).foregroundStyle(sub.done ? .secondary : .primary)
                        }
                    }
                    if ss.count > 4 { Text("+\(ss.count - 4) more · \(n)/\(ss.count) done").font(.caption2).foregroundStyle(.secondary) }
                    else { Text("\(n)/\(ss.count) done").font(.caption2).foregroundStyle(.secondary) }
                }
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
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(count: 2) { if !i.deleted { editing = i } }
    }
}

struct TodoModal: View {
    @Environment(\.dismiss) var dismiss
    @State var item: TodoItem
    @State private var subs: [SubDraft]
    @State private var hasDue: Bool
    @State private var newSub = ""
    @FocusState private var subFocus: Bool
    var onSave: (TodoItem, [SubDraft]) -> Void

    init(item: TodoItem, subs: [SubDraft], onSave: @escaping (TodoItem, [SubDraft]) -> Void) {
        _item = State(initialValue: item)
        _subs = State(initialValue: subs)
        _hasDue = State(initialValue: item.due != nil)
        self.onSave = onSave
    }

    var isNew: Bool { item.id == 0 }

    func addSub() {
        let t = newSub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        subs.append(SubDraft(dbId: nil, title: t, done: false))
        newSub = ""; subFocus = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isNew ? "New todo" : "Todo").font(.headline)
                Spacer()
                if !isNew {
                    Toggle("Done", isOn: Binding(get: { item.done != nil }, set: { item.done = $0 ? (item.done ?? Date()) : nil }))
                        .toggleStyle(.checkbox)
                }
            }
            TextField("Title", text: $item.title).textFieldStyle(.roundedBorder).font(.title3)
            Text("Description").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $item.detail).font(.body).frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Text("Sub-items").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !subs.isEmpty { Text("\(subs.filter(\.done).count)/\(subs.count) done").font(.caption).foregroundStyle(.secondary) }
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach($subs) { $sub in
                        HStack {
                            Toggle("", isOn: $sub.done).toggleStyle(.checkbox).labelsHidden()
                            TextField("Sub-item", text: $sub.title).textFieldStyle(.plain)
                                .strikethrough(sub.done).foregroundStyle(sub.done ? .secondary : .primary)
                            Button { subs.removeAll { $0.uid == sub.uid } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                }.padding(6)
            }
            .frame(minHeight: 60, maxHeight: 180)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                TextField("Add a sub-item and press Return", text: $newSub).textFieldStyle(.roundedBorder)
                    .focused($subFocus).onSubmit(addSub)
                Button("Add", action: addSub).disabled(newSub.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Picker("Priority", selection: $item.priority) {
                Text("None").tag(0); Text("Low").tag(1); Text("Medium").tag(2); Text("High").tag(3)
            }.pickerStyle(.segmented)
            HStack {
                Toggle("Due date", isOn: $hasDue)
                if hasDue {
                    DatePicker("", selection: Binding(get: { item.due ?? Date() }, set: { item.due = $0 }), displayedComponents: .date).labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
                    if !hasDue { item.due = nil } else if item.due == nil { item.due = Date() }
                    onSave(item, subs); dismiss()
                }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                    .disabled(item.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("⌘Return to save · double-click a todo to open it").font(.caption2).foregroundStyle(.secondary)
        }.padding(20).frame(width: 520)
    }
}
