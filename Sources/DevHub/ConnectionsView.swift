import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConnectionsView: View {
    @EnvironmentObject var cm: ConnectionManager
    @EnvironmentObject var app: AppState
    @State private var editing: Profile?
    @State private var showAuth = false

    var groups: [String] { Array(Set(cm.profiles.map(\.group))).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            AuthBanner()
            HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $app.selectedProfile) {
                    ForEach(groups, id: \.self) { g in
                        Section {
                            ForEach(cm.profiles.filter { $0.group == g }) { p in
                                ProfileRow(p: p).tag(p.id)
                            }
                        } header: {
                            HStack {
                                Text(g.uppercased())
                                Spacer()
                                Button("Connect all") { cm.startGroup(g) }.buttonStyle(.link)
                                Button("Disable all") { cm.stopGroup(g) }.buttonStyle(.link)
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    Button { editing = Profile() } label: { Label("Add profile", systemImage: "plus") }
                    Spacer()
                    Button { showAuth = true } label: { Image(systemName: cm.hasGooglePassword ? "lock.shield.fill" : "lock.shield") }
                        .help("Auto re-auth (Google work account)")
                    Button("Import") { importProfiles() }
                    Button("Export") { exportProfiles() }
                }.padding(8)
            }
            .frame(minWidth: Theme.listWidth, idealWidth: Theme.listWidth, maxWidth: Theme.listWidth + 80)

            if let id = app.selectedProfile, let p = cm.profiles.first(where: { $0.id == id }) {
                ProfileDetail(p: p, onEdit: { editing = p })
                    .id(p.id)
            } else {
                Text("Select a profile").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }
        }
        .sheet(item: $editing) { p in ProfileEditor(profile: p) }
        .sheet(isPresented: $showAuth) { GoogleAuthSettings() }
    }

    private func exportProfiles() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "devhub-profiles.json"
        p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let u = p.url { cm.exportProfiles(to: u) }
    }

    private func importProfiles() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let u = p.url { _ = cm.importProfiles(from: u) }
    }
}

struct AuthBanner: View {
    @EnvironmentObject var cm: ConnectionManager

    var body: some View {
        if cm.gcloudAuthExpired || cm.adcExpired {
            VStack(spacing: 0) {
                if cm.gcloudAuthExpired { row("gcloud login expired - IAP tunnels will fail", "gcloud auth login", adc: false) }
                if cm.adcExpired { row("Application Default Credentials expired - cloud-sql-proxy will fail", "gcloud auth application-default login", adc: true) }
                Divider()
            }
        }
    }

    private func row(_ msg: String, _ cmd: String, adc: Bool) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(msg).font(.callout)
            Spacer()
            if !cm.googleStatus.isEmpty { Text(cm.googleStatus).font(.caption).foregroundStyle(.secondary) }
            Button("Run `\(cmd)`") { cm.googleLogin(adc: adc) }.buttonStyle(.borderedProminent).tint(.red)
        }
        .padding(.horizontal, Theme.page).padding(.vertical, 8)
        .background(Color.red.opacity(0.12))
    }
}

struct ProfileRow: View {
    @EnvironmentObject var cm: ConnectionManager
    let p: Profile

    var body: some View {
        let s = cm.state(p)
        HStack {
            Circle().fill(statusColor(s)).frame(width: 10, height: 10)
            VStack(alignment: .leading) {
                Text(p.name).fontWeight(.medium)
                Text(p.port > 0 ? "\(p.kind) · :\(p.port) · \(s.label)" : "\(p.kind) · \(s.label)")
                    .font(.caption).foregroundStyle(s == .needsReauth ? .red : .secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { cm.isActive(p) }, set: { _ in cm.toggle(p) }))
                .toggleStyle(.switch).labelsHidden()
        }
    }
}

struct ProfileDetail: View {
    @EnvironmentObject var cm: ConnectionManager
    let p: Profile
    var onEdit: () -> Void
    @State private var filter = ""
    @State private var password = ""
    @State private var askPassword = false

    var body: some View {
        let s = cm.state(p)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(statusColor(s)).frame(width: 12, height: 12)
                Text(p.name).font(.title2).bold()
                Text(s.label).foregroundStyle(.secondary)
                Spacer()
                Button(cm.isActive(p) ? "Disconnect" : "Connect") { cm.toggle(p) }.buttonStyle(.borderedProminent)
                Button("Restart") { cm.restart(p) }
                if p.port > 0 { copyMenu }
                Button("Edit", action: onEdit)
            }
            Text(p.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)

            if s == .needsReauth {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text("Re-authentication required").bold()
                    Spacer()
                    if cm.hasStoredSecret(p) {
                        Button("Re-auth (Keychain)") { cm.reauth(p) }.buttonStyle(.borderedProminent).tint(.red)
                    }
                    Button("Enter password…") { password = ""; askPassword = true }
                }
                .padding(8).background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            TextField("Search logs", text: $filter).textFieldStyle(.roundedBorder)
            LogView(text: filtered)
        }
        .padding(Theme.page)
        .sheet(isPresented: $askPassword) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Re-auth: \(p.name)").font(.headline)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder).onSubmit(send)
                HStack {
                    Spacer()
                    Button("Cancel") { askPassword = false }
                    Button("Send", action: send).keyboardShortcut(.defaultAction)
                }
            }.padding().frame(width: 360)
        }
    }

    private var copyMenu: some View {
        Menu("Copy") {
            let c = ConnInfo.match(port: p.port)
            Button("host:port  (127.0.0.1:\(p.port))") { ConnInfo.copy("127.0.0.1:\(p.port)") }
            Button("PostgreSQL URL") { ConnInfo.copy(ConnInfo.url(engine: "postgresql", port: p.port, conn: c, includePassword: false)) }
            Button("PostgreSQL URL (with password)") { ConnInfo.copy(ConnInfo.url(engine: "postgresql", port: p.port, conn: c, includePassword: true)) }
            Button("MySQL URL") { ConnInfo.copy(ConnInfo.url(engine: "mysql", port: p.port, conn: c, includePassword: false)) }
            Button("psql command") { ConnInfo.copy("psql -h 127.0.0.1 -p \(p.port) -U \(c?.user ?? "USER") -d \(c?.database ?? "DB")") }
            Button("mysql command") { ConnInfo.copy("mysql -h 127.0.0.1 -P \(p.port) -u \(c?.user ?? "USER") \(c?.database ?? "")") }
        }.fixedSize()
    }

    private func send() {
        cm.reauth(p, password: password)
        password = ""
        askPassword = false
    }

    var filtered: String {
        let t = cm.logs[p.id] ?? ""
        guard !filter.isEmpty else { return String(t.suffix(20_000)) }
        return t.components(separatedBy: "\n").filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
    }
}

struct LogView: View {
    let text: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "(no output yet)" : text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Color.clear.frame(height: 1).id("bottom")
            }
            .padding(8)
            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: text) { _, _ in proxy.scrollTo("bottom") }
        }
    }
}

struct ProfileEditor: View {
    @EnvironmentObject var cm: ConnectionManager
    @Environment(\.dismiss) private var dismiss
    @State var profile: Profile
    @State private var portText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profile").font(.headline)
            Form {
                TextField("Name", text: $profile.name)
                TextField("Group (dev / uat / prod…)", text: $profile.group)
                Picker("Kind", selection: $profile.kind) {
                    ForEach(["DB", "Kafka", "Other"], id: \.self) { Text($0) }
                }
                TextField("Local port", text: $portText)
                TextField("Working dir (optional)", text: $profile.workDir)
                Toggle("Auto-reconnect on crash", isOn: $profile.autoReconnect)
                Toggle("Start automatically when DevHub opens", isOn: $profile.autoStart)
                TextField("Re-auth secret name (Vault, optional)", text: $profile.reauthSecret)
            }
            Text("Command (use {{secret:name}} for Vault values)").font(.caption)
            TextEditor(text: $profile.command).font(.system(.body, design: .monospaced)).frame(height: 70).border(.gray.opacity(0.4))
            Text("Re-auth patterns (regex, one per line)").font(.caption)
            TextEditor(text: $profile.reauthPatterns).font(.system(.body, design: .monospaced)).frame(height: 70).border(.gray.opacity(0.4))
            HStack {
                if cm.profiles.contains(where: { $0.id == profile.id }) {
                    Button("Delete", role: .destructive) { cm.remove(profile); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    profile.port = Int(portText) ?? 0
                    cm.upsert(profile)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding().frame(width: 520)
        .onAppear { portText = profile.port > 0 ? String(profile.port) : "" }
    }
}

enum ConnInfo {
    /// A saved DB Query connection that targets the same local port, used to prefill user/db/password.
    static func match(port: Int) -> DBConn? {
        let store: DBStore = Store.load("db.json", default: DBStore())
        return store.conns.first { $0.port == port }
    }

    static func url(engine: String, port: Int, conn: DBConn?, includePassword: Bool) -> String {
        let allowed = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: ":@/?#"))
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        let user = enc(conn?.user.isEmpty == false ? conn!.user : "USER")
        var cred = user
        if includePassword, let n = conn?.secretName, !n.isEmpty, let pw = Vault.get(n) { cred += ":" + enc(pw) }
        return "\(engine)://\(cred)@127.0.0.1:\(port)/\(conn?.database ?? "DB")"
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}


struct GoogleAuthSettings: View {
    @EnvironmentObject var cm: ConnectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Auto re-authentication").font(.title3).bold()
            Text("Saved in macOS Keychain (service DevHub). Used for any profile without its own re-auth secret.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField(cm.hasGooglePassword ? "Password saved - type to replace" : "Google work account password", text: $password)
                .textFieldStyle(.roundedBorder)
            Toggle("Auto-answer password prompts (tunnels + gcloud checks)", isOn: $cm.autoReauth)
            Toggle("Auto-open `gcloud auth login` when login/ADC expires", isOn: $cm.autoGoogleLogin)
            Text("""
            • Password prompts ("Reauthentication required") are answered automatically, max 2 tries per 10 min to avoid locking the account.
            • An expired login (refresh token revoked) needs the browser: DevHub opens it for you, you only click Allow. Tunnels restart on their own afterwards.
            """).font(.caption).foregroundStyle(.secondary)
            HStack {
                if cm.hasGooglePassword { Button("Remove password", role: .destructive) { Vault.delete(ConnectionManager.googlePwKey); dismiss() } }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if !password.isEmpty { Vault.set(ConnectionManager.googlePwKey, password) }
                    cm.objectWillChange.send()
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 460)
    }
}
