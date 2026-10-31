import SwiftUI
import AppKit

enum NoteMode: String, CaseIterable { case preview = "Preview", edit = "Edit", raw = "Raw", split = "Split" }

struct NotesView: View {
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var app: AppState
    @EnvironmentObject var cm: ConnectionManager
    @State private var query = ""
    @State private var tagFilter: String?
    @State private var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinnedNotes") ?? [])
    @State private var jumpTo: Int?
    @State private var selected: String?
    @State private var text = ""
    @State private var saved = ""
    @State private var mode: NoteMode = .preview

    var hits: [NoteHit] {
        var h = notes.search(query)
        if let t = tagFilter { h = h.filter { $0.tags.contains(t) } }
        if query.isEmpty { h = h.filter { pinned.contains($0.path) } + h.filter { !pinned.contains($0.path) } }
        return h
    }
    var dirty: Bool { text != saved }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: Theme.listWidth, idealWidth: Theme.listWidth, maxWidth: Theme.listWidth + 80)
            detail.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selected) { _, new in load(new) }
        .onChange(of: app.openNote) { _, new in
            if let new { selected = new; app.openNote = nil }
        }
        .onAppear {
            if let n = app.openNote { selected = n; app.openNote = nil }
        }
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search notes", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                Menu {
                    Button("New note", systemImage: "square.and.pencil") { newNote() }
                    Button("Import .md files…", systemImage: "square.and.arrow.down") { importMD() }
                    Button("Index another folder…", systemImage: "folder") { pickFolder() }
                } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
            }.padding(Theme.page)

            if !notes.allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(notes.allTags, id: \.self) { t in
                            Text("#\(t)").font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(tagFilter == t ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08), in: Capsule())
                                .onTapGesture { tagFilter = tagFilter == t ? nil : t }
                        }
                    }.padding(.horizontal, Theme.page)
                }.padding(.bottom, 8)
            }

            Divider()

            if hits.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: query.isEmpty ? "note.text" : "magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "No notes yet" : "No results").foregroundStyle(.secondary)
                    if query.isEmpty { Button("Import .md files…") { importMD() } }
                    Text("Tip: drag .md files here").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(hits) { h in noteRow(h) }
                    }.padding(10)
                }
            }
            Divider()
            HStack {
                Text("\(notes.all.count) notes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text((notes.folder as NSString).abbreviatingWithTildeInPath).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }.padding(.horizontal, Theme.page).padding(.vertical, 8)
        }
        .dropDestination(for: URL.self) { urls, _ in
            _ = ensureFolder()
            let added = notes.importFiles(urls)
            if let f = added.first { selected = f }
            return !added.isEmpty
        }
    }

    private func noteRow(_ h: NoteHit) -> some View {
        let on = selected == h.path
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if pinned.contains(h.path) { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                Text(h.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            }
            if !h.snippet.isEmpty {
                Text(h.snippet).font(.caption).foregroundStyle(Color.secondary).lineLimit(2)
            } else {
                Text(URL(fileURLWithPath: h.path).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(on ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { selected = h.path }
    }

    // MARK: detail

    @ViewBuilder
    private var detail: some View {
        if let sel = selected {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(NotesStore.title(text, sel)).font(.title3.bold()).lineLimit(1)
                            if dirty { Circle().fill(.orange).frame(width: 8, height: 8).help("Unsaved changes") }
                        }
                        Text(URL(fileURLWithPath: sel).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { togglePin(sel) } label: { Image(systemName: pinned.contains(sel) ? "pin.fill" : "pin") }
                        .buttonStyle(.borderless).help("Pin note")
                    outlineMenu
                    Picker("", selection: $mode) { ForEach(NoteMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 290).labelsHidden()
                    Button("Save") { save(sel) }.disabled(!dirty).keyboardShortcut("s", modifiers: .command)
                }.padding(Theme.page)
                Divider()
                switch mode {
                case .preview: previewPane
                case .edit: BlockEditor(text: $text).id(sel)
                case .raw: editorPane
                case .split:
                    HSplitView { BlockEditor(text: $text).id(sel).frame(minWidth: 280); previewPane.frame(minWidth: 280) }
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 44)).foregroundStyle(.tertiary)
                Text("Select a note").foregroundStyle(.secondary)
                Text("⌘K to search everything").font(.caption).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var outlineMenu: some View {
        let hs = MDParser.headings(text)
        return Menu {
            ForEach(Array(hs.enumerated()), id: \.offset) { _, h in
                Button(String(repeating: "   ", count: max(0, h.level - 1)) + h.text) { mode = .preview; jumpTo = h.index }
            }
        } label: { Image(systemName: "list.bullet.indent") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).disabled(hs.isEmpty).help("Outline")
    }

    private var previewPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MarkdownView(source: text, onMakeProfile: makeProfile)
                    backlinksSection
                }
                .frame(maxWidth: Theme.readingWidth, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: jumpTo) { _, new in
                if let new { withAnimation { proxy.scrollTo(new, anchor: .top) }; jumpTo = nil }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "devhub-note" else { return .systemAction }
            let name = (url.host(percentEncoded: false) ?? "").removingPercentEncoding ?? ""
            if let p = notes.resolve(name) { selected = p } else { NSSound.beep() }
            return .handled
        })
    }

    @ViewBuilder
    private var backlinksSection: some View {
        if let sel = selected {
            let links = notes.backlinks(to: sel)
            if !links.isEmpty {
                Divider()
                Text("Linked from").font(.headline)
                ForEach(links) { l in
                    Button { selected = l.path } label: { Label(l.title, systemImage: "arrow.turn.up.left") }.buttonStyle(.link)
                }
            }
        }
    }

    private func makeProfile(_ code: String) {
        var p = Profile()
        p.name = NotesStore.title(text, selected ?? "note")
        p.command = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = p.command.range(of: "(?:-L\\s*|--local-port[= ]|--port[= ]|:)(\\d{4,5})(?::|\\b)", options: .regularExpression),
           let n = Int(p.command[m].filter(\.isNumber)) { p.port = n }
        cm.upsert(p)
        app.selectedProfile = p.id
        app.tab = .connections
    }

    private func togglePin(_ path: String) {
        if pinned.contains(path) { pinned.remove(path) } else { pinned.insert(path) }
        UserDefaults.standard.set(Array(pinned), forKey: "pinnedNotes")
    }

    private var editorPane: some View {
        TextEditor(text: $text)
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(12)
            .background(Theme.card)
    }

    // MARK: actions

    private func load(_ path: String?) {
        guard let path else { return }
        text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        saved = text
    }

    private func save(_ path: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        saved = text
        notes.scan()
    }

    private func ensureFolder() -> Bool {
        if notes.folder.isEmpty {
            // default notes folder so Import / New note work without a separate setup step
            let d = Store.dir.appendingPathComponent("Notes")
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            notes.setFolder(d.path)
        }
        return true
    }

    private func newNote() {
        guard ensureFolder() else { return }
        let alert = NSAlert()
        alert.messageText = "New note"
        alert.informativeText = "File name (saved as .md in \(notes.folder))"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let path = notes.createNote(named: field.stringValue) { query = ""; selected = path; mode = .edit }
    }

    private func importMD() {
        guard ensureFolder() else { return }
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.message = "Select .md files or folders to copy into the notes folder"
        if p.runModal() == .OK, let f = notes.importFiles(p.urls).first { query = ""; selected = f }
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = "Choose the NOTES FOLDER to index (to add a file, use Import instead)"
        p.prompt = "Use this folder"
        if p.runModal() == .OK, let u = p.url { notes.setFolder(u.path) }
    }
}

struct PaletteView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var cm: ConnectionManager
    @EnvironmentObject var notes: NotesStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let icon: String
        let run: () -> Void
    }

    var items: [Item] {
        var out: [Item] = []
        for t in Tab.allCases {
            out.append(Item(title: "Go to \(t.rawValue)", subtitle: "Navigate", icon: t.icon) { app.tab = t })
        }
        for p in cm.profiles {
            let on = cm.isActive(p)
            out.append(Item(title: (on ? "Disconnect " : "Connect ") + p.name, subtitle: "\(p.group) · \(cm.state(p).label)", icon: "bolt") { cm.toggle(p) })
            out.append(Item(title: "Open logs: \(p.name)", subtitle: "Connections", icon: "text.alignleft") {
                app.selectedProfile = p.id; app.tab = .connections
            })
        }
        for g in Set(cm.profiles.map(\.group)).sorted() {
            out.append(Item(title: "Connect group \(g)", subtitle: "Group", icon: "bolt.fill") { cm.startGroup(g) })
            out.append(Item(title: "Disable group \(g)", subtitle: "Group", icon: "bolt.slash") { cm.stopGroup(g) })
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        func copyItem(_ title: String, _ value: @autoclosure @escaping () -> String) -> Item {
            Item(title: title, subtitle: "Copy to clipboard", icon: "doc.on.doc") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value(), forType: .string)
            }
        }
        out.append(copyItem("Generate UUID v4", UUID().uuidString.lowercased()))
        out.append(copyItem("Generate UUID v7", ToolsView.uuid7()))
        out.append(copyItem("Generate Mongo ObjectId", IDGen.objectId()))
        out.append(copyItem("Generate ULID", IDGen.ulid()))
        out.append(copyItem("Epoch seconds now", String(Int(Date().timeIntervalSince1970))))
        out.append(copyItem("Epoch ms now", String(Int(Date().timeIntervalSince1970 * 1000))))
        out.append(copyItem("Random password (24)", String((0..<24).map { _ in "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*".randomElement()! })))
        for k in ToolKind.allCases {
            out.append(Item(title: "Open tool: \(k.rawValue)", subtitle: "Tools", icon: "wrench.and.screwdriver") { app.toolKind = k; app.tab = .tools })
        }
        var tsItem: Item?
        if let n = Double(q), n > 1_000_000_000 {
            let ms = n > 100_000_000_000
            let d = Date(timeIntervalSince1970: ms ? n / 1000 : n)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
            tsItem = copyItem("\(f.string(from: d)) GMT+7", f.string(from: d))
        }
        let actions = q.isEmpty ? out : out.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q) }
        var noteItems: [Item] = []
        if !q.isEmpty {
            noteItems = notes.search(q).prefix(8).map { h in
                Item(title: h.title, subtitle: h.snippet.isEmpty ? "Note" : h.snippet, icon: "note.text") {
                    app.tab = .notes; app.openNote = h.path
                }
            }
        }
        return Array(([tsItem].compactMap { $0 } + actions.prefix(8) + noteItems))
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            TextField("Search notes or run an action…", text: $query)
                .textFieldStyle(.plain).font(.title3).padding(12).focused($focused)
                .onSubmit { run(list) }
                .onChange(of: query) { _, _ in index = 0 }
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                        HStack {
                            Image(systemName: it.icon).frame(width: 22)
                            VStack(alignment: .leading) {
                                Text(it.title)
                                Text(it.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(i == index ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { it.run(); dismiss() }
                    }
                }.padding(6)
            }
        }
        .frame(width: 560, height: 380)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { index = min(index + 1, max(0, list.count - 1)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func run(_ list: [Item]) {
        guard index < list.count else { return }
        list[index].run()
        dismiss()
    }
}
