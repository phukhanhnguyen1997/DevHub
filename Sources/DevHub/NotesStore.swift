import Foundation
import SQLite3

struct NoteHit: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let title: String
    let snippet: String
}

@MainActor
final class NotesStore: ObservableObject {
    @Published var folder: String = UserDefaults.standard.string(forKey: "notesFolder") ?? ""
    @Published var all: [NoteHit] = []
    private var db: OpaquePointer?
    private var timer: Timer?

    init() {
        let path = Store.dir.appendingPathComponent("notes.sqlite").path
        sqlite3_open(path, &db)
        exec("CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(path UNINDEXED, mtime UNINDEXED, title, tags, body, tokenize='unicode61 remove_diacritics 2')")
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    func setFolder(_ f: String) {
        folder = f
        UserDefaults.standard.set(f, forKey: "notesFolder")
        exec("DELETE FROM notes_fts")
        scan()
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    /// Incremental re-index: only files whose mtime changed are rewritten. Source files stay where they are.
    func scan() {
        guard !folder.isEmpty else { all = []; return }
        let fm = FileManager.default
        var found: [String: Double] = [:]
        if let en = fm.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in en where url.pathExtension.lowercased() == "md" {
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
                found[url.path] = m
            }
        }
        var indexed: [String: Double] = [:]
        query("SELECT path, mtime FROM notes_fts") { st in
            indexed[Self.text(st, 0)] = Double(Self.text(st, 1)) ?? 0
        }
        var changed = false
        exec("BEGIN")
        for (path, m) in found where indexed[path] != m {
            changed = true
            guard let body = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            run("DELETE FROM notes_fts WHERE path = ?", [path])
            run("INSERT INTO notes_fts(path, mtime, title, tags, body) VALUES (?,?,?,?,?)",
                [path, String(m), Self.title(body, path), Self.tags(body).joined(separator: " "), body])
        }
        for path in indexed.keys where found[path] == nil {
            changed = true
            run("DELETE FROM notes_fts WHERE path = ?", [path])
        }
        exec("COMMIT")
        if changed || all.isEmpty { reloadAll() }
    }

    private func reloadAll() {
        var out: [NoteHit] = []
        query("SELECT path, title FROM notes_fts ORDER BY title COLLATE NOCASE") { st in
            out.append(NoteHit(path: Self.text(st, 0), title: Self.text(st, 1), snippet: ""))
        }
        all = out
    }

    func search(_ q: String) -> [NoteHit] {
        let tokens = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map { "\"\($0)\"*" }
        guard !tokens.isEmpty else { return all }
        var out: [NoteHit] = []
        let sql = "SELECT path, title, snippet(notes_fts, 4, '[', ']', '…', 14) FROM notes_fts WHERE notes_fts MATCH ? ORDER BY rank LIMIT 30"
        query(sql, [tokens.joined(separator: " ")]) { st in
            out.append(NoteHit(path: Self.text(st, 0), title: Self.text(st, 1), snippet: Self.text(st, 2).replacingOccurrences(of: "\n", with: " ")))
        }
        return out
    }

    // MARK: sqlite helpers

    private func run(_ sql: String, _ args: [String]) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() { sqlite3_bind_text(st, Int32(i + 1), a, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        sqlite3_step(st)
    }

    private func query(_ sql: String, _ args: [String] = [], row: (OpaquePointer?) -> Void) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() { sqlite3_bind_text(st, Int32(i + 1), a, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        while sqlite3_step(st) == SQLITE_ROW { row(st) }
    }

    private static func text(_ st: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(st, i) else { return "" }
        return String(cString: c)
    }

    static func title(_ body: String, _ path: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true).prefix(40) {
            if line.hasPrefix("# ") { return line.dropFirst(2).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("title:") { return line.dropFirst(6).trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\"'"))) }
        }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    static func tags(_ body: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "(?<![\\w&])#([A-Za-z][\\w/-]*)") else { return [] }
        let ns = body as NSString
        return Array(Set(re.matches(in: body, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })).sorted()
    }

    /// Fenced code blocks in a note, for one-click copy.
    static func codeBlocks(_ body: String) -> [(lang: String, code: String)] {
        var out: [(String, String)] = []
        var cur: [String] = []
        var lang = ""
        var inside = false
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inside { out.append((lang, cur.joined(separator: "\n"))); cur = [] } else { lang = String(line.dropFirst(3)) }
                inside.toggle()
            } else if inside { cur.append(line) }
        }
        return out
    }
}
