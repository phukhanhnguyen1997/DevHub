import Foundation
import SQLite3

// One progress report attached to a sub-item (written by external tools through the `devhub-todo` CLI).
struct SubNote: Identifiable, Equatable {
    var id: Int64
    var subId: Int64
    var todoId: Int64
    var at: Date
    var author: String
    var status: String
    var note: String
}

// Tool-agnostic write path into the todo database. Used by the CLI mode of the app binary (`DevHub --todo ...`).
enum TodoBridge {
    struct Failure: Error { let message: String }

    static let statuses = ["started", "done", "rework", "blocked", "note"]

    enum Command: Equatable {
        case create(title: String, subs: [String])
        case sub(todo: String, step: String, status: String, note: String, author: String)
        case status(todo: String)
        case help
    }

    static let usage = """
    devhub-todo create --title "<title>" --subs "Step 1,Step 2"
    devhub-todo sub --todo "<title>" --step "<sub-item>" --status started|done|rework|blocked|note [--note "<text>" | --note -] [--author <name>]
    devhub-todo status --todo "<title>"
    Sub-item is matched by exact title, then by title prefix. --note - reads the note from stdin.
    """

    // MARK: parsing

    static func parse(_ args: [String]) throws -> Command {
        guard let verb = args.first else { return .help }
        var flags: [String: String] = [:]
        var i = 1
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("--"), i + 1 < args.count else { throw Failure(message: "bad argument: \(a)") }
            flags[String(a.dropFirst(2))] = args[i + 1]
            i += 2
        }
        func need(_ k: String) throws -> String {
            guard let v = flags[k], !v.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure(message: "missing --\(k)") }
            return v
        }
        switch verb {
        case "create":
            let subs = (flags["subs"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return .create(title: try need("title"), subs: subs)
        case "sub":
            let st = try need("status").lowercased()
            guard statuses.contains(st) else { throw Failure(message: "--status must be one of: \(statuses.joined(separator: ", "))") }
            return .sub(todo: try need("todo"), step: try need("step"), status: st, note: flags["note"] ?? "", author: flags["author"] ?? "ai")
        case "status": return .status(todo: try need("todo"))
        case "help", "--help", "-h": return .help
        default: throw Failure(message: "unknown command: \(verb)")
        }
    }

    // MARK: sqlite helpers

    static func ensureSchema(_ db: OpaquePointer?) {
        let sql = [
            "CREATE TABLE IF NOT EXISTS todos (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '', priority INTEGER NOT NULL DEFAULT 0, due REAL, created REAL NOT NULL, done REAL, deleted INTEGER NOT NULL DEFAULT 0)",
            "CREATE TABLE IF NOT EXISTS todo_log (id INTEGER PRIMARY KEY AUTOINCREMENT, todo_id INTEGER NOT NULL, action TEXT NOT NULL, title TEXT NOT NULL, date REAL NOT NULL)",
            "CREATE TABLE IF NOT EXISTS todo_subs (id INTEGER PRIMARY KEY AUTOINCREMENT, todo_id INTEGER NOT NULL, title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0, pos INTEGER NOT NULL DEFAULT 0)",
            "CREATE TABLE IF NOT EXISTS todo_links (id INTEGER PRIMARY KEY AUTOINCREMENT, a INTEGER NOT NULL, b INTEGER NOT NULL, note TEXT NOT NULL DEFAULT '', created REAL NOT NULL)",
            "CREATE TABLE IF NOT EXISTS todo_sub_notes (id INTEGER PRIMARY KEY AUTOINCREMENT, sub_id INTEGER NOT NULL, todo_id INTEGER NOT NULL, at REAL NOT NULL, author TEXT NOT NULL DEFAULT 'ai', status TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '')",
            "CREATE INDEX IF NOT EXISTS idx_log_date ON todo_log(date)",
            "CREATE INDEX IF NOT EXISTS idx_sub_notes_sub ON todo_sub_notes(sub_id)",
            "ALTER TABLE todos ADD COLUMN status INTEGER NOT NULL DEFAULT 0", // no-op error when the column already exists
        ]
        for s in sql { sqlite3_exec(db, s, nil, nil, nil) }
    }

    static func open(_ path: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw Failure(message: "cannot open database at \(path)") }
        sqlite3_busy_timeout(db, 5000)
        ensureSchema(db)
        return db
    }

    private static func bind(_ db: OpaquePointer?, _ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
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
        return st
    }

    @discardableResult
    private static func exec(_ db: OpaquePointer?, _ sql: String, _ args: [Any?] = []) -> Bool {
        guard let st = bind(db, sql, args) else { return false }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_DONE
    }

    private static func rows<T>(_ db: OpaquePointer?, _ sql: String, _ args: [Any?] = [], _ map: (OpaquePointer) -> T) -> [T] {
        guard let st = bind(db, sql, args) else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [T] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(map(st)) }
        return out
    }

    private static func str(_ st: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }

    private static func log(_ db: OpaquePointer?, _ todo: Int64, _ action: String, _ title: String) {
        exec(db, "INSERT INTO todo_log (todo_id, action, title, date) VALUES (?, ?, ?, ?)", [todo, action, title, Date().timeIntervalSince1970])
    }

    // MARK: operations

    struct Sub { var id: Int64; var title: String; var done: Bool }

    static func findTodo(_ db: OpaquePointer?, _ key: String) -> (id: Int64, title: String, done: Bool)? {
        rows(db, "SELECT id, title, done IS NOT NULL FROM todos WHERE deleted = 0 AND lower(title) = lower(?) ORDER BY created DESC LIMIT 1", [key]) {
            (sqlite3_column_int64($0, 0), str($0, 1), sqlite3_column_int($0, 2) != 0)
        }.first
    }

    static func subs(_ db: OpaquePointer?, _ todo: Int64) -> [Sub] {
        rows(db, "SELECT id, title, done FROM todo_subs WHERE todo_id = ? ORDER BY pos, id", [todo]) {
            Sub(id: sqlite3_column_int64($0, 0), title: str($0, 1), done: sqlite3_column_int($0, 2) != 0)
        }
    }

    // Exact (case-insensitive) title first, then a unique prefix.
    static func matchSub(_ list: [Sub], _ step: String) throws -> Sub {
        let s = step.lowercased()
        if let m = list.first(where: { $0.title.lowercased() == s }) { return m }
        let p = list.filter { $0.title.lowercased().hasPrefix(s) }
        if p.count == 1 { return p[0] }
        if p.isEmpty { throw Failure(message: "no sub-item matches \"\(step)\" (have: \(list.map(\.title).joined(separator: " | ")))") }
        throw Failure(message: "\"\(step)\" is ambiguous: \(p.map(\.title).joined(separator: " | "))")
    }

    static func create(_ db: OpaquePointer?, title: String, subs wanted: [String]) throws -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var id: Int64
        var existed = false
        if let ex = findTodo(db, t) {
            id = ex.id
            existed = true
        } else {
            exec(db, "INSERT INTO todos (title, created) VALUES (?, ?)", [t, Date().timeIntervalSince1970])
            id = sqlite3_last_insert_rowid(db)
            log(db, id, "created", t)
        }
        let have = Set(subs(db, id).map { $0.title.lowercased() })
        var pos = subs(db, id).count
        var added = 0
        for s in wanted where !have.contains(s.lowercased()) {
            exec(db, "INSERT INTO todo_subs (todo_id, title, done, pos) VALUES (?, ?, 0, ?)", [id, s, pos])
            pos += 1; added += 1
        }
        if existed && added > 0 { log(db, id, "edited", t) }
        return "\(existed ? "exists" : "created") todo \"\(t)\" (id \(id)), +\(added) sub-items"
    }

    static func addNote(_ db: OpaquePointer?, todo: String, step: String, status: String, note: String, author: String) throws -> String {
        guard let t = findTodo(db, todo) else { throw Failure(message: "no todo titled \"\(todo)\"") }
        let sub = try matchSub(subs(db, t.id), step)
        exec(db, "INSERT INTO todo_sub_notes (sub_id, todo_id, at, author, status, note) VALUES (?, ?, ?, ?, ?, ?)",
             [sub.id, t.id, Date().timeIntervalSince1970, author, status, note])
        let label = "\(t.title) › \(sub.title)"
        switch status {
        case "done":
            if !sub.done {
                exec(db, "UPDATE todo_subs SET done = 1 WHERE id = ?", [sub.id])
                log(db, t.id, "subtask done", label)
            }
        default:
            if sub.done && status != "note" {
                exec(db, "UPDATE todo_subs SET done = 0 WHERE id = ?", [sub.id])
                log(db, t.id, "subtask reopened", label)
            }
            if status != "note" && t.done {
                exec(db, "UPDATE todos SET done = NULL WHERE id = ?", [t.id])
                log(db, t.id, "reopened", t.title)
            }
            if status == "started" && !t.done { exec(db, "UPDATE todos SET status = 1 WHERE id = ?", [t.id]) }
        }
        log(db, t.id, "subtask note", "\(label): \(status)")
        return "\(label): \(status)"
    }

    static func report(_ db: OpaquePointer?, todo: String) throws -> String {
        guard let t = findTodo(db, todo) else { throw Failure(message: "no todo titled \"\(todo)\"") }
        let list = subs(db, t.id)
        let done = list.filter(\.done).count
        var out = ["\(t.title): \(done)/\(list.count)\(t.done ? " (completed)" : "")"]
        for s in list {
            let latest = rows(db, "SELECT status FROM todo_sub_notes WHERE sub_id = ? ORDER BY at DESC, id DESC LIMIT 1", [s.id]) { str($0, 0) }.first
            out.append("  [\(s.done ? "x" : " ")] \(s.title)\(latest.map { " (\($0))" } ?? "")")
        }
        return out.joined(separator: "\n")
    }

    static func loadNotes(_ db: OpaquePointer?) -> [Int64: [SubNote]] {
        var out: [Int64: [SubNote]] = [:]
        let all = rows(db, "SELECT id, sub_id, todo_id, at, author, status, note FROM todo_sub_notes ORDER BY at, id") {
            SubNote(id: sqlite3_column_int64($0, 0), subId: sqlite3_column_int64($0, 1), todoId: sqlite3_column_int64($0, 2),
                    at: Date(timeIntervalSince1970: sqlite3_column_double($0, 3)), author: str($0, 4), status: str($0, 5), note: str($0, 6))
        }
        for n in all { out[n.subId, default: []].append(n) }
        return out
    }

    // MARK: entry point

    static func execute(_ cmd: Command, db: OpaquePointer?) throws -> String {
        switch cmd {
        case let .create(title, subs): return try create(db, title: title, subs: subs)
        case let .sub(todo, step, status, note, author):
            return try addNote(db, todo: todo, step: step, status: status, note: note, author: author)
        case let .status(todo): return try report(db, todo: todo)
        case .help: return usage
        }
    }

    // Returns an exit code when the process was started as `DevHub --todo ...`, nil for a normal GUI launch.
    static func runIfRequested(_ argv: [String]) -> Int32? {
        guard argv.count >= 2, argv[1] == "--todo" else { return nil }
        do {
            var cmd = try parse(Array(argv.dropFirst(2)))
            if case let .sub(t, s, st, n, a) = cmd, n == "-" {
                cmd = .sub(todo: t, step: s, status: st, note: String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "", author: a)
            }
            if cmd == .help { print(usage); return 0 }
            let path = ProcessInfo.processInfo.environment["DEVHUB_TODO_DB"] ?? Store.dir.appendingPathComponent("todos.sqlite").path
            let db = try open(path)
            defer { sqlite3_close(db) }
            print(try execute(cmd, db: db))
            return 0
        } catch let f as Failure {
            FileHandle.standardError.write(Data("error: \(f.message)\n\n\(usage)\n".utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }
}
