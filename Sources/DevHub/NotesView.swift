import SwiftUI
import AppKit

struct NotesView: View {
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var selected: String?
    @State private var text = ""
    @State private var dirty = false
    @State private var preview = false

    var hits: [NoteHit] { notes.search(query) }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search notes (title, content, #tag)", text: $query).textFieldStyle(.roundedBorder)
                    Button { pickFolder() } label: { Image(systemName: "folder") }.help("Choose notes folder")
                }.padding(8)
                if notes.folder.isEmpty {
                    Text("Choose a folder containing .md files").foregroundStyle(.secondary).frame(maxHeight: .infinity)
                } else {
                    List(hits, selection: $selected) { h in
                        VStack(alignment: .leading) {
                            Text(h.title).fontWeight(.medium)
                            if !h.snippet.isEmpty { Text(h.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }.tag(h.path)
                    }
                }
            }.frame(minWidth: 260, idealWidth: 300)

            VStack(alignment: .leading) {
                if let sel = selected {
                    HStack {
                        Text(URL(fileURLWithPath: sel).lastPathComponent).font(.headline)
                        Spacer()
                        Toggle("Preview", isOn: $preview).toggleStyle(.button)
                        Button("Save") { save(sel) }.disabled(!dirty).keyboardShortcut("s", modifiers: .command)
                    }
                    if preview {
                        ScrollView {
                            Text(markdown(text)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    } else {
                        TextEditor(text: $text).font(.system(.body, design: .monospaced))
                            .onChange(of: text) { _, _ in dirty = true }
                    }
                    let blocks = NotesStore.codeBlocks(text)
                    if !blocks.isEmpty {
                        Divider()
                        Text("Code blocks").font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                                HStack(alignment: .top) {
                                    Text(b.code).font(.system(.caption, design: .monospaced)).lineLimit(6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Button("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(Vault.substitute(b.code), forType: .string)
                                    }
                                }.padding(6).background(.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }.frame(maxHeight: 160)
                    }
                } else {
                    Text("Select a note").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.padding(8)
        }
        .onChange(of: selected) { _, new in load(new) }
        .onChange(of: app.openNote) { _, new in
            if let new { selected = new; app.openNote = nil }
        }
        .onAppear {
            if let n = app.openNote { selected = n; app.openNote = nil }
        }
    }

    private func load(_ path: String?) {
        guard let path else { return }
        text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        dirty = false
        DispatchQueue.main.async { dirty = false }
    }

    private func save(_ path: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        dirty = false
        notes.scan()
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
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
