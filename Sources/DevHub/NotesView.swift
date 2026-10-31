import SwiftUI
import AppKit

enum NoteMode: String, CaseIterable { case preview = "Preview", edit = "Edit", split = "Split" }

struct NotesView: View {
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var selected: String?
    @State private var text = ""
    @State private var saved = ""
    @State private var mode: NoteMode = .preview

    var hits: [NoteHit] { notes.search(query) }
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
            Text(h.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
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
                    Picker("", selection: $mode) { ForEach(NoteMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 220).labelsHidden()
                    Button("Save") { save(sel) }.disabled(!dirty).keyboardShortcut("s", modifiers: .command)
                }.padding(Theme.page)
                Divider()
                switch mode {
                case .preview: previewPane
                case .edit: editorPane
                case .split:
                    HSplitView { editorPane.frame(minWidth: 240); previewPane.frame(minWidth: 240) }
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

    private var previewPane: some View {
        ScrollView {
            MarkdownView(source: text)
                .frame(maxWidth: Theme.readingWidth, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .center)
        }
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
        let actions = q.isEmpty ? out : out.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q) }
        var noteItems: [Item] = []
        if !q.isEmpty {
            noteItems = notes.search(q).prefix(8).map { h in
                Item(title: h.title, subtitle: h.snippet.isEmpty ? "Note" : h.snippet, icon: "note.text") {
                    app.tab = .notes; app.openNote = h.path
                }
            }
        }
        return Array((actions.prefix(8) + noteItems))
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
