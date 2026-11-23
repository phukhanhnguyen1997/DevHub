import SwiftUI
import AppKit

enum NoteMode: String, CaseIterable { case edit = "Page", preview = "Preview", raw = "Markdown", split = "Split" }

struct NotesView: View {
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var app: AppState
    @EnvironmentObject var cm: ConnectionManager
    @State private var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinnedNotes") ?? [])
    @State private var jumpTo: Int?
    @State private var selected: String?
    @State private var text = ""
    @State private var saved = ""
    @State private var mode: NoteMode = .edit
    @State private var lastSaved: Date?
    @State private var find: FindRequest?
    @State private var arrived = true
    private let autosave = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var ordered: [NoteHit] { notes.all.filter { pinned.contains($0.path) } + notes.all.filter { !pinned.contains($0.path) } }
    var dirty: Bool { text != saved }

    var body: some View {
        VStack(spacing: 0) {
            chipBar
            Divider()
            detail
        }
        .onChange(of: selected) { old, new in
            if dirty, let old { save(old) }
            load(new)
            if let new { UserDefaults.standard.set(new, forKey: "lastNote") }
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
            else if selected == nil {
                let last = UserDefaults.standard.string(forKey: "lastNote")
                selected = notes.all.first { $0.path == last }?.path ?? ordered.first?.path
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            _ = ensureFolder()
            let added = notes.importFiles(urls)
            if let f = added.first { selected = f }
            return !added.isEmpty
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
        arrived = false
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.4)) { arrived = true } }
        DispatchQueue.main.async { find = FindRequest(term: term) }
    }

    // MARK: note chips

    private var chipBar: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ordered) { h in
                        let on = h.path == selected
                        HStack(spacing: 5) {
                            if pinned.contains(h.path) { Image(systemName: "pin.fill").font(.system(size: 9)) }
                            Text(h.title).lineLimit(1)
                        }
                        .font(.system(size: 13, weight: on ? .semibold : .medium))
                        .padding(.horizontal, 13).padding(.vertical, 6)
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                        .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
                        .contentShape(Capsule())
                        .help(h.title)
                        .onTapGesture { selected = h.path }
                        .contextMenu {
                            Button(pinned.contains(h.path) ? "Unpin" : "Pin") { togglePin(h.path) }
                        }
                    }
                    Menu {
                        Button("New note", systemImage: "square.and.pencil") { newNote() }
                        Button("Import .md files…", systemImage: "square.and.arrow.down") { importMD() }
                        Button("Index another folder…", systemImage: "folder") { pickFolder() }
                    } label: { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }.padding(.vertical, 2)
            }
            Button { app.showPalette = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Search").lineLimit(1)
                    Text("⌘K").font(.caption2).padding(.horizontal, 5).background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }.buttonStyle(.plain).fixedSize()
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }

    // MARK: detail

    @ViewBuilder
    private var detail: some View {
        if let sel = selected {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(NotesStore.title(text, sel)).font(.system(size: 24, weight: .bold)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Button { togglePin(sel) } label: { Image(systemName: pinned.contains(sel) ? "pin.fill" : "pin") }
                        .buttonStyle(.borderless).help("Pin note")
                    Picker("", selection: $mode) { ForEach(NoteMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Button("Save") { save(sel) }.keyboardShortcut("s", modifiers: .command).opacity(0).frame(width: 0)
                }.padding(.horizontal, 28).padding(.top, 14)
                metaLine(sel).padding(.horizontal, 28).padding(.top, 2).padding(.bottom, 6)
                HStack(alignment: .top, spacing: 0) {
                    Group {
                        switch mode {
                        case .preview: previewPane
                        case .edit: BlockEditor(text: $text, find: find).id(sel)
                        case .raw: editorPane
                        case .split:
                            HSplitView { BlockEditor(text: $text).id(sel).frame(minWidth: 280); previewPane.frame(minWidth: 280) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(arrived ? 1 : 0).offset(y: arrived ? 0 : 14)
                    if mode == .edit || mode == .preview { tocRail }
                }
                statusBar(sel)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 44)).foregroundStyle(.tertiary)
                Text(notes.all.isEmpty ? "No notes yet" : "Select a note").foregroundStyle(.secondary)
                if notes.all.isEmpty { Button("Import .md files…") { importMD() } }
                Text("⌘K to search everything").font(.caption).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metaLine(_ sel: String) -> some View {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: sel)) ?? [:]
        var parts: [String] = []
        if let m = attrs[.modificationDate] as? Date { parts.append("Edited \(m.formatted(date: .abbreviated, time: .omitted))") }
        parts.append("\(NotesStore.wordCount(text)) words")
        let tags = notes.all.first { $0.path == sel }?.tags ?? []
        if !tags.isEmpty { parts.append(tags.map { "#\($0)" }.joined(separator: " ")) }
        return Text(parts.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
    }

    // Sticky table of contents; hidden when the window is too narrow for it.
    private var tocRail: some View {
        let hs = MDParser.headings(text)
        return ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ON THIS PAGE").font(.system(size: 10.5, weight: .bold)).tracking(0.5).foregroundStyle(.secondary).padding(.bottom, 6)
                ForEach(Array(hs.enumerated()), id: \.offset) { _, h in
                    Button {
                        if mode == .preview { jumpTo = h.index } else { find = FindRequest(term: h.text) }
                    } label: {
                        Text(h.text).font(.system(size: 12, weight: h.level == 1 ? .semibold : .regular)).lineLimit(2)
                            .multilineTextAlignment(.leading).foregroundStyle(h.level == 1 ? Color.primary : Color.secondary)
                            .padding(.leading, 10 + CGFloat(max(0, h.level - 1)) * 10).padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 2) }
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 170).padding(.top, 16).padding(.trailing, 14)
            .opacity(hs.count > 1 ? 1 : 0)
            EmptyView()
        }
    }

    private func linkMenu(_ sel: String) -> some View {
        let from = notes.backlinks(to: sel)
        let to = NotesStore.wikiLinks(text).compactMap { n in notes.resolve(n).map { (n, $0) } }
        return Menu {
            Section("Linked from") {
                if from.isEmpty { Text("Nothing links here") }
                ForEach(from) { l in Button(l.title) { selected = l.path } }
            }
            Section("Links to") {
                if to.isEmpty { Text("No [[links]]") }
                ForEach(Array(to.enumerated()), id: \.offset) { _, l in Button(l.0) { selected = l.1 } }
            }
        } label: { Label("\(from.count) in · \(to.count) out", systemImage: "link") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func statusBar(_ sel: String) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: dirty ? "circle.dotted" : "checkmark.circle.fill").foregroundStyle(dirty ? .orange : .green)
                Text(dirty ? "Editing… autosave in ≤5s" : (lastSaved.map { "Saved \($0.formatted(date: .omitted, time: .standard))" } ?? "Saved"))
            }
            linkMenu(sel)
            Spacer()
            Text((sel as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.head).foregroundStyle(.tertiary)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 28).padding(.vertical, 6)
        .overlay(alignment: .top) { Divider() }
    }

    private var previewPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MarkdownView(source: text, onMakeProfile: makeProfile)
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
        if let path = notes.createNote(named: field.stringValue) { selected = path; mode = .edit }
    }

    private func importMD() {
        guard ensureFolder() else { return }
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.message = "Select .md files or folders to copy into the notes folder"
        if p.runModal() == .OK, let f = notes.importFiles(p.urls).first { selected = f }
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
    @Namespace private var selection

    struct Item: Identifiable {
        var id: String { section + "|" + title + "|" + subtitle }
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
            noteItems = notes.all.prefix(6).map { noteItem($0, "Notes", $0.tags.map { "#\($0)" }.joined(separator: " ")) }
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
                                Text(Self.highlighted(it.title, query))
                                Text(Self.highlighted(it.subtitle, query)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background {
                            if i == index {
                                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25))
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(Rectangle())
                        .modifier(SlideIn(delay: Double(min(i, 8)) * 0.03))
                        .onTapGesture { it.run(); dismiss() }
                    }
                }
                .padding(6)
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: index)
            }
        }
        .frame(width: 560, height: 380)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { index = min(index + 1, max(0, list.count - 1)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    static func highlighted(_ s: String, _ q: String) -> AttributedString {
        var a = AttributedString(s)
        for w in q.split(separator: " ") where !w.isEmpty {
            var from = a.startIndex
            while from < a.endIndex, let r = a[from...].range(of: String(w), options: [.caseInsensitive, .diacriticInsensitive]) {
                a[r].backgroundColor = .yellow.opacity(0.45)
                from = r.upperBound
            }
        }
        return a
    }

    private func run(_ list: [Item]) {
        guard index < list.count else { return }
        list[index].run()
        dismiss()
    }
}

// Rows slide in from the left the first time they appear (stagger via `delay`).
struct SlideIn: ViewModifier {
    let delay: Double
    @State private var shown = false
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(x: shown ? 0 : -14)
            .onAppear { withAnimation(.easeOut(duration: 0.2).delay(delay)) { shown = true } }
    }
}
