import SwiftUI
import AppKit
import Combine

struct DBConn: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "local-db"
    var engine = "postgres"
    var host = "127.0.0.1"
    var port = 5432
    var user = ""
    var database = ""
    var secretName = ""
}

struct SavedQuery: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var sql: String
}

struct DBStore: Codable {
    var conns: [DBConn] = []
    var queries: [SavedQuery] = []
}

struct DBQueryView: View {
    @State private var store: DBStore = Store.load("db.json", default: DBStore())
    @State private var connID: UUID?
    @State private var sql = "SELECT 1;"
    @State private var output = ""
    @State private var running = false
    @State private var editing: DBConn?
    @State private var saveName = ""

    var conn: DBConn? { store.conns.first { $0.id == connID } }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                HStack {
                    Text("Connections").font(.headline)
                    Spacer()
                    Button { editing = DBConn() } label: { Image(systemName: "plus") }
                }
                List(store.conns, selection: $connID) { c in
                    HStack {
                        Text("\(c.name)  :\(c.port)")
                        Spacer()
                        Button { editing = c } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
                    }.tag(c.id)
                }.frame(maxHeight: 180)
                Text("Saved queries").font(.headline)
                List {
                    ForEach(store.queries) { q in
                        HStack {
                            Text(q.name)
                            Spacer()
                            Button { store.queries.removeAll { $0.id == q.id }; persist() } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                        }.contentShape(Rectangle()).onTapGesture { sql = q.sql }
                    }
                }
            }.padding(8).frame(minWidth: 240, idealWidth: 270)

            VStack(alignment: .leading, spacing: 8) {
                Text("Read-only: SELECT / WITH / SHOW / EXPLAIN / DESCRIBE, single statement").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $sql).font(.system(.body, design: .monospaced)).frame(height: 130).border(.gray.opacity(0.4))
                HStack {
                    Button(running ? "Running…" : "Run") { run() }
                        .disabled(running || conn == nil).keyboardShortcut(.return, modifiers: .command)
                    TextField("Save as…", text: $saveName).frame(width: 160)
                    Button("Save query") {
                        guard !saveName.isEmpty else { return }
                        store.queries.append(SavedQuery(name: saveName, sql: sql)); saveName = ""; persist()
                    }
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(output.isEmpty ? "(no result)" : output)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }.padding(6).background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }.padding(8)
        }
        .sheet(item: $editing) { c in DBConnEditor(conn: c) { saved in
            if let i = store.conns.firstIndex(where: { $0.id == saved.id }) { store.conns[i] = saved } else { store.conns.append(saved) }
            persist()
        } onDelete: { id in store.conns.removeAll { $0.id == id }; persist() } }
    }

    private func persist() { Store.save("db.json", store) }

    static func isReadOnly(_ q: String) -> Bool {
        var s = q.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(";") { s.removeLast(); s = s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if s.contains(";") { return false }
        let first = s.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first.map { $0.lowercased() } ?? ""
        return ["select", "with", "show", "explain", "describe", "desc", "table", "values"].contains(first)
    }

    private func run() {
        guard let c = conn else { return }
        guard Self.isReadOnly(sql) else { output = "Rejected: only a single read-only statement is allowed."; return }
        running = true
        let q = sql
        let pw = c.secretName.isEmpty ? "" : (Vault.get(c.secretName) ?? "")
        DispatchQueue.global().async {
            let cmd: String
            var env: [String: String] = [:]
            let esc = q.replacingOccurrences(of: "'", with: "'\\''")
            if c.engine == "postgres" {
                env["PGPASSWORD"] = pw
                env["PGOPTIONS"] = "-c default_transaction_read_only=on -c statement_timeout=30000"
                cmd = "psql -X -h '\(c.host)' -p \(c.port) -U '\(c.user)' -d '\(c.database)' -c '\(esc)'"
            } else {
                env["MYSQL_PWD"] = pw
                cmd = "mysql -h '\(c.host)' -P \(c.port) -u '\(c.user)' '\(c.database)' -t -e 'SET SESSION TRANSACTION READ ONLY; \(esc)'"
            }
            let r = shell(cmd, env: env, timeout: 40)
            DispatchQueue.main.async { output = r.out; running = false }
        }
    }
}

struct DBConnEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var conn: DBConn
    var onSave: (DBConn) -> Void
    var onDelete: (UUID) -> Void
    @State private var portText = ""

    var body: some View {
        VStack(alignment: .leading) {
            Form {
                TextField("Name", text: $conn.name)
                Picker("Engine", selection: $conn.engine) { Text("postgres").tag("postgres"); Text("mysql").tag("mysql") }
                TextField("Host", text: $conn.host)
                TextField("Port (matches a proxy profile)", text: $portText)
                TextField("User", text: $conn.user)
                TextField("Database", text: $conn.database)
                TextField("Password secret name (Vault)", text: $conn.secretName)
            }
            HStack {
                Button("Delete", role: .destructive) { onDelete(conn.id); dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { conn.port = Int(portText) ?? conn.port; onSave(conn); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding().frame(width: 420).onAppear { portText = String(conn.port) }
    }
}

struct PortEntry: Identifiable {
    let id = UUID()
    let command: String, pid: Int32, user: String, name: String
}

struct PortsView: View {
    @State private var entries: [PortEntry] = []
    @State private var filter = ""
    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var shown: [PortEntry] {
        filter.isEmpty ? entries : entries.filter { "\($0.command) \($0.pid) \($0.name)".localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack {
            HStack {
                TextField("Filter (port, process)", text: $filter).textFieldStyle(.roundedBorder)
                Button("Refresh") { refresh() }
            }
            Table(shown) {
                TableColumn("Process", value: \.command)
                TableColumn("PID") { Text(String($0.pid)) }
                TableColumn("User", value: \.user)
                TableColumn("Listening on", value: \.name)
                TableColumn("") { e in
                    Button("Kill") { kill(e.pid, SIGTERM); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refresh() } }
                }
            }
        }
        .padding()
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        DispatchQueue.global().async {
            let out = shell("lsof -iTCP -sTCP:LISTEN -nP -F pcLn", timeout: 10).out
            var res: [PortEntry] = []
            var pid: Int32 = 0, cmd = "", user = ""
            for line in out.split(separator: "\n") {
                let v = String(line.dropFirst())
                switch line.first {
                case "p": pid = Int32(v) ?? 0
                case "c": cmd = v
                case "L": user = v
                case "n": res.append(PortEntry(command: cmd, pid: pid, user: user, name: v))
                default: break
                }
            }
            res.sort { $0.name < $1.name }
            DispatchQueue.main.async { entries = res }
        }
    }
}

struct VaultView: View {
    @State private var names = Vault.names()
    @State private var name = ""
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Secrets live in the macOS Keychain. Use {{secret:name}} in profile commands.").foregroundStyle(.secondary)
            HStack {
                TextField("name", text: $name).textFieldStyle(.roundedBorder)
                SecureField("value", text: $value).textFieldStyle(.roundedBorder)
                Button("Save") {
                    guard !name.isEmpty, !value.isEmpty else { return }
                    Vault.set(name, value); name = ""; value = ""; names = Vault.names()
                }
            }
            List(names, id: \.self) { n in
                HStack {
                    Text("{{secret:\(n)}}").font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("Copy ref") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("{{secret:\(n)}}", forType: .string)
                    }
                    Button("Delete", role: .destructive) { Vault.delete(n); names = Vault.names() }
                }
            }
        }.padding()
    }
}
