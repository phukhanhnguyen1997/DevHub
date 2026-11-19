import SwiftUI
import AppKit
import Carbon.HIToolbox
import SQLite3

struct ClipEntry: Identifiable {
    var id: Int64
    let text: String
    let date: Date
    var pinned = false
    var sensitive: Bool { ClipStore.looksSensitive(text) }
}

@MainActor
final class ClipStore: ObservableObject {
    static let retentionOptions: [(days: Int, label: String)] = [(1, "1 day"), (3, "3 days"), (7, "7 days"), (14, "14 days"), (30, "1 month")]
    @Published var entries: [ClipEntry] = []
    @Published var retentionDays: Int = {
        let d = UserDefaults.standard.integer(forKey: "clipRetentionDays")
        return d == 0 ? 7 : d
    }() {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "clipRetentionDays"); prune() }
    }
    private var lastCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var pruneTimer: Timer?
    private var selfWrite = false
    private var db: OpaquePointer?

    init() {
        sqlite3_open(Store.dir.appendingPathComponent("clipboard.sqlite").path, &db)
        run("CREATE TABLE IF NOT EXISTS clips (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL UNIQUE, date REAL NOT NULL, pinned INTEGER NOT NULL DEFAULT 0)")
        run("CREATE INDEX IF NOT EXISTS idx_clips_date ON clips(date)")
        prune()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
    }

    @discardableResult
    private func run(_ sql: String, _ args: [Any] = []) -> Bool {
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
            default: break
            }
        }
        return sqlite3_step(st) == SQLITE_DONE
    }

    private func reload() {
        var out: [ClipEntry] = []
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, text, date, pinned FROM clips ORDER BY date DESC LIMIT 1000", -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                let t = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
                out.append(ClipEntry(id: sqlite3_column_int64(st, 0), text: t,
                                     date: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)),
                                     pinned: sqlite3_column_int(st, 3) != 0))
            }
        }
        sqlite3_finalize(st)
        entries = out
    }

    // Pinned items never expire.
    func prune() {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400).timeIntervalSince1970
        run("DELETE FROM clips WHERE pinned = 0 AND date < ?", [cutoff])
        reload()
    }

    nonisolated static func looksSensitive(_ s: String) -> Bool {
        let pats = ["eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.", "-----BEGIN [A-Z ]*PRIVATE KEY", "(?i)(password|passwd|secret|token|api[_-]?key)\\s*[=:]", "AKIA[0-9A-Z]{16}", "ghp_[A-Za-z0-9]{20,}", "sk-[A-Za-z0-9]{20,}"]
        return pats.contains { s.range(of: $0, options: .regularExpression) != nil }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        if selfWrite { selfWrite = false; return }
        let types = pb.types?.map(\.rawValue) ?? []
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") { return }
        guard let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        run("INSERT INTO clips (text, date) VALUES (?, ?) ON CONFLICT(text) DO UPDATE SET date = excluded.date", [s, Date().timeIntervalSince1970])
        run("DELETE FROM clips WHERE pinned = 0 AND id NOT IN (SELECT id FROM clips ORDER BY date DESC LIMIT 5000)")
        reload()
    }

    func copy(_ e: ClipEntry) {
        selfWrite = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.text, forType: .string)
        lastCount = NSPasteboard.general.changeCount
    }

    func togglePin(_ e: ClipEntry) {
        run("UPDATE clips SET pinned = ? WHERE id = ?", [e.pinned ? 0 : 1, e.id]); reload()
    }
    func delete(_ e: ClipEntry) { run("DELETE FROM clips WHERE id = ?", [e.id]); reload() }
    func clearUnpinned() { run("DELETE FROM clips WHERE pinned = 0"); reload() }
}

struct ClipboardView: View {
    @EnvironmentObject var clip: ClipStore
    @State private var query = ""
    @State private var revealed: Set<Int64> = []

    var shown: [ClipEntry] {
        let f = query.isEmpty ? clip.entries : clip.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
        return f.filter(\.pinned) + f.filter { !$0.pinned }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $query).textFieldStyle(.plain)
                Spacer()
                Text("\(clip.entries.count) items").font(.caption).foregroundStyle(.secondary)
                Picker("Keep", selection: $clip.retentionDays) {
                    ForEach(ClipStore.retentionOptions, id: \.days) { Text($0.label).tag($0.days) }
                }.frame(width: 130).help("Unpinned items older than this are deleted automatically. Pinned items are kept.")
                Button("Clear unpinned") { clip.clearUnpinned() }
            }.padding(10)
            Divider()
            if shown.isEmpty {
                Spacer(); Text("Copy something to see it here").foregroundStyle(.secondary); Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(shown) { e in row(e) }
                    }.padding(12)
                }
            }
        }
    }

    func row(_ e: ClipEntry) -> some View {
        let hidden = e.sensitive && !revealed.contains(e.id)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(hidden ? "•••••••• sensitive — click Reveal" : String(e.text.prefix(400)))
                    .font(.system(.callout, design: .monospaced)).lineLimit(5).textSelection(.enabled)
                Text(e.date.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if e.sensitive {
                Button(hidden ? "Reveal" : "Hide") {
                    if hidden { revealed.insert(e.id) } else { revealed.remove(e.id) }
                }.buttonStyle(.borderless)
            }
            Button { clip.copy(e) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy again")
            Button { clip.togglePin(e) } label: { Image(systemName: e.pinned ? "pin.fill" : "pin") }.buttonStyle(.borderless)
            Button { clip.delete(e) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

// Global hotkey: Ctrl+Option+K
@MainActor
enum GlobalHotKey {
    static var handler: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        handler = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x44564855), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}
