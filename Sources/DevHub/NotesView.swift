import SwiftUI
import AppKit

enum NoteMode: String, CaseIterable { case edit = "Page", preview = "Preview", raw = "Markdown", split = "Split" }

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
    @State private var mode: NoteMode = .edit
    @State private var lastSaved: Date?
    @State private var find: FindRequest?
    @State private var tabs: [String] = UserDefaults.standard.stringArray(forKey: "noteTabs") ?? []
    @State private var recent: [String] = UserDefaults.standard.stringArray(forKey: "recentNotes") ?? []
    @State private var back: [String] = []
    @State private var forward: [String] = []
    @State private var navigating = false
    @AppStorage("notesInspector") private var showInspector = true
    private let autosave = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var hits: [NoteHit] {
        var h = notes.search(query)
        if let t = tagFilter { h = h.filter { $0.tags.contains(t) } }
        return h
    }
    var dirty: Bool { text != saved }
    var filtering: Bool { !query.isEmpty || tagFilter != nil }
    func hit(_ path: String) -> NoteHit? { notes.all.first { $0.path == path } }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 210, idealWidth: 240, maxWidth: 320)
            detail.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selected) { old, new in
            if dirty, let old { save(old) }
            load(new)
            if let new {
                if !tabs.contains(new) { tabs.append(new) }
                recent.removeAll { $0 == new }
                recent.insert(new, at: 0)
                recent = Array(recent.prefix(12))
                UserDefaults.standard.set(tabs, forKey: "noteTabs")
                UserDefaults.standard.set(recent, forKey: "recentNotes")
            }
            if navigating { navigating = false }
            else if let old, old != new { back.append(old); forward = [] }
        }
        .onReceive(autosave) { _ in
            if dirty, let s = selected { save(s) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if dirty, let s = selected { save(s) }
        }
        .onDisappear { if dirty, let s = selected { save(s) } }
        .onChange(of: app.openNote) { _, new in
            if let new { open(new) }
        }
        .onAppear {
            if let n = app.openNote { open(n) }
            else if selected == nil { selected = tabs.first { hit($0) != nil } }
        }
    }

    private func open(_ path: String) {
        let term = app.openNoteQuery?.trimmingCharacters(in: .whitespaces) ?? ""
        app.openNote = nil
        app.openNoteQuery = nil
        if selected != path { selected = path }
        else if dirty { save(path) }
        if term.isEmpty { return }
        mode = .edit
        load(path)
        DispatchQueue.main.async { find = FindRequest(term: term) }
    }

    private func goBack() {
        guard let p = back.popLast() else { return }
        if let cur = selected { forward.append(cur) }
        navigating = true
        selected = p
    }

    private func goForward() {
        guard let p = forward.popLast() else { return }
        if let cur = selected { back.append(cur) }
        navigating = true
        selected = p
    }

    private func closeTab(_ path: String) {
        guard let i = tabs.firstIndex(of: path) else { return }
        if path == selected, dirty { save(path) }
        tabs.remove(at: i)
        UserDefaults.standard.set(tabs, forKey: "noteTabs")
        if path == selected {
            let live = tabs.filter { hit($0) != nil }
            selected = live.isEmpty ? nil : live[min(i, live.count - 1)]
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

            if notes.all.isEmpty || (filtering && hits.isEmpty) {
                VStack(spacing: 10) {
                    Image(systemName: filtering ? "magnifyingglass" : "note.text").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(filtering ? "No results" : "No notes yet").foregroundStyle(.secondary)
                    if !filtering { Button("Import .md files…") { importMD() } }
                    Text("Tip: drag .md files here").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if filtering {
                            sectionTitle("Results", hits.count)
                            ForEach(hits) { noteRow($0) }
                        } else {
                            let pins = notes.all.filter { pinned.contains($0.path) }
                            let recents = recent.compactMap(hit).filter { !pinned.contains($0.path) }.prefix(6)
                            if !pins.isEmpty { sectionTitle("Pinned", pins.count); ForEach(pins) { noteRow($0) } }
                            if !recents.isEmpty { sectionTitle("Recent", recents.count); ForEach(Array(recents)) { noteRow($0) } }
                            sectionTitle("All notes", notes.all.count)
                            ForEach(notes.all) { noteRow($0) }
                        }
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

    private func sectionTitle(_ t: String, _ n: Int) -> some View {
        HStack(spacing: 6) {
            Text(t.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.5)
            Text("\(n)").font(.system(size: 10.5))
        }.foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 3)
    }

    private func noteRow(_ h: NoteHit) -> some View {
        let on = selected == h.path
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if pinned.contains(h.path) { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                Text(h.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
            }
            if filtering, !h.snippet.isEmpty {
                Text(h.snippet).font(.system(size: 11.5)).foregroundStyle(Color.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(on ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .help(h.title)
        .onTapGesture { selected = h.path }
    }

    // MARK: detail

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs.compactMap(hit)) { h in
                    let on = h.path == selected
                    HStack(spacing: 8) {
                        Text(h.title).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1).frame(maxWidth: 160)
                        Button { closeTab(h.path) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(on ? Color(nsColor: .windowBackgroundColor) : Color.primary.opacity(0.06), in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
                    .contentShape(Rectangle())
                    .help(h.title)
                    .onTapGesture { selected = h.path }
                }
            }.padding(.horizontal, 8).padding(.top, 6)
        }
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var detail: some View {
        if let sel = selected {
            VStack(spacing: 0) {
                if !tabs.isEmpty { tabBar }
                HStack(spacing: 12) {
                    Text(NotesStore.title(text, sel)).font(.title3.bold()).lineLimit(2)
                    Spacer()
                    Button { goBack() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless).disabled(back.isEmpty).help("Back (⌘[)").keyboardShortcut("[", modifiers: .command)
                    Button { goForward() } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless).disabled(forward.isEmpty).help("Forward (⌘])").keyboardShortcut("]", modifiers: .command)
                    Button { togglePin(sel) } label: { Image(systemName: pinned.contains(sel) ? "pin.fill" : "pin") }
                        .buttonStyle(.borderless).help("Pin note")
                    Picker("", selection: $mode) { ForEach(NoteMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 290).labelsHidden()
                    Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                        .buttonStyle(.borderless).help("Toggle inspector")
                    Button("Save") { save(sel) }.keyboardShortcut("s", modifiers: .command).opacity(0).frame(width: 0)
                }.padding(.horizontal, Theme.page).padding(.vertical, 10)
                Divider()
                HStack(spacing: 0) {
                    Group {
                        switch mode {
                        case .preview: previewPane
                        case .edit: BlockEditor(text: $text, find: find).id(sel)
                        case .raw: editorPane
                        case .split:
                            HSplitView { BlockEditor(text: $text).id(sel).frame(minWidth: 280); previewPane.frame(minWidth: 280) }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showInspector { Divider(); inspector(sel) }
                }
                statusBar(sel)
            }
        } else {
            VStack(spacing: 0) {
                if !tabs.isEmpty { tabBar }
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text("Select a note").foregroundStyle(.secondary)
                    Text("⌘K to search everything").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func statusBar(_ sel: String) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: dirty ? "circle.dotted" : "checkmark.circle.fill").foregroundStyle(dirty ? .orange : .green)
                Text(dirty ? "Editing… autosave in ≤5s" : (lastSaved.map { "Saved \($0.formatted(date: .omitted, time: .standard))" } ?? "Saved"))
            }
            Text("\(NotesStore.wordCount(text)) words")
            Text("\(notes.backlinks(to: sel).count) backlinks")
            Spacer()
            Text("⌘[ ⌘]  back / forward").foregroundStyle(.tertiary)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, Theme.page).padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .top) { Divider() }
    }

    private func inspector(_ sel: String) -> some View {
        let hs = MDParser.headings(text)
        let from = notes.backlinks(to: sel)
        let to = NotesStore.wikiLinks(text).map { ($0, notes.resolve($0)) }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: sel)) ?? [:]
        let words = NotesStore.wordCount(text)
        func head(_ t: String) -> some View {
            Text(t.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.5).foregroundStyle(.secondary).padding(.top, 14)
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                head("Outline")
                if hs.isEmpty { Text("No headings").font(.caption).foregroundStyle(.tertiary) }
                ForEach(Array(hs.enumerated()), id: \.offset) { _, h in
                    Button { mode = .preview; jumpTo = h.index } label: {
                        Text(h.text).font(.system(size: 12, weight: h.level == 1 ? .semibold : .regular)).lineLimit(2).multilineTextAlignment(.leading)
                            .padding(.leading, CGFloat(max(0, h.level - 1)) * 10).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
                head("Linked from (\(from.count))")
                if from.isEmpty { Text("Nothing links here").font(.caption).foregroundStyle(.tertiary) }
                ForEach(from) { l in
                    Button { selected = l.path } label: {
                        Label(l.title, systemImage: "arrow.turn.up.left").font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                    }.buttonStyle(.link)
                }
                head("Links to (\(to.count))")
                if to.isEmpty { Text("No [[links]]").font(.caption).foregroundStyle(.tertiary) }
                ForEach(Array(to.enumerated()), id: \.offset) { _, l in
                    if let path = l.1 {
                        Button { selected = path } label: {
                            Label(l.0, systemImage: "link").font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                        }.buttonStyle(.link)
                    } else {
                        Label("\(l.0) (missing)", systemImage: "link.badge.plus").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                head("Properties")
                Group {
                    if let c = attrs[.creationDate] as? Date { Text("Created \(c.formatted(date: .abbreviated, time: .omitted))") }
                    if let m = attrs[.modificationDate] as? Date { Text("Edited \(m.formatted(date: .abbreviated, time: .shortened))") }
                    Text("\(words) words · \(max(1, words / 200)) min read")
                    if let t = hit(sel)?.tags, !t.isEmpty { Text(t.map { "#\($0)" }.joined(separator: " ")) }
                    Text((sel as NSString).abbreviatingWithTildeInPath).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                }.font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 220)
        .background(Color.primary.opacity(0.03))
    }

    private var previewPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MarkdownView(source: text, onMakeProfile: makeProfile)
                    if !showInspector { backlinksSection }
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
        lastSaved = Date()
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
        var section = "Actions"
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
        func noteItem(_ h: NoteHit, _ section: String, _ sub: String) -> Item {
            Item(title: h.title, subtitle: sub, icon: "note.text", section: section) {
                app.tab = .notes; app.openNoteQuery = q.isEmpty ? nil : q; app.openNote = h.path
            }
        }
        var noteItems: [Item] = []
        var inside: [Item] = []
        if q.isEmpty {
            let recent = (UserDefaults.standard.stringArray(forKey: "recentNotes") ?? []).compactMap { p in notes.all.first { $0.path == p } }
            noteItems = recent.prefix(5).map { noteItem($0, "Recent notes", $0.tags.map { "#\($0)" }.joined(separator: " ")) }
        } else {
            let words = q.split(separator: " ").map(String.init)
            for h in notes.search(q).prefix(15) {
                if words.allSatisfy({ h.title.localizedCaseInsensitiveContains($0) }) {
                    noteItems.append(noteItem(h, "Notes", h.tags.map { "#\($0)" }.joined(separator: " ")))
                } else {
                    inside.append(noteItem(h, "Inside notes", h.snippet.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")))
                }
            }
        }
        var create: [Item] = []
        if !q.isEmpty {
            create = [Item(title: "New note \"\(q)\"", subtitle: "Create and open", icon: "square.and.pencil") {
                if notes.folder.isEmpty {
                    let d = Store.dir.appendingPathComponent("Notes")
                    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                    notes.setFolder(d.path)
                }
                if let path = notes.createNote(named: q) { app.tab = .notes; app.openNote = path }
            }]
        }
        let shown = [tsItem].compactMap { $0 } + noteItems.prefix(6) + inside.prefix(6) + actions.prefix(8) + create
        return Array(shown)
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
                        if i == 0 || list[i - 1].section != it.section {
                            Text(it.section.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.5)
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.top, i == 0 ? 2 : 8)
                        }
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
