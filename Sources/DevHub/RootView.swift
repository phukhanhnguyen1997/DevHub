import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case connections = "Connections", notes = "Notes", todos = "Todos", clipboard = "Clipboard", db = "DB Query", ports = "Ports", vault = "Vault", tools = "Tools"
    var id: String { rawValue }
    static let defaultOrder: [Tab] = allCases
    var icon: String {
        switch self {
        case .connections: return "bolt.horizontal.circle"
        case .notes: return "note.text"
        case .todos: return "checklist"
        case .clipboard: return "doc.on.clipboard"
        case .db: return "cylinder.split.1x2"
        case .ports: return "network"
        case .vault: return "key"
        case .tools: return "wrench.and.screwdriver"
        }
    }
    var group: String {
        switch self {
        case .notes, .connections, .todos: return "Work"
        case .db, .ports, .vault: return "Data"
        case .clipboard, .tools: return "Utilities"
        }
    }
    var tint: Color {
        switch self {
        case .notes: return .blue
        case .connections: return .green
        case .todos: return .orange
        case .db: return .indigo
        case .ports: return .cyan
        case .vault: return .gray
        case .clipboard: return .pink
        case .tools: return .brown
        }
    }
    static let groups = ["Work", "Data", "Utilities"]
}

// Open todos that are overdue or due today (shown as the sidebar badge).
func todoAttentionCount(_ items: [TodoItem]) -> Int {
    items.filter { !$0.deleted && $0.done == nil && [.overdue, .today].contains(dueBucket($0.due)) }.count
}

@MainActor
final class AppState: ObservableObject {
    @Published var tab: Tab = .connections
    @Published var tabs: [Tab] = {
        let saved = (UserDefaults.standard.stringArray(forKey: "tabOrder") ?? []).compactMap(Tab.init(rawValue:))
        return saved + Tab.allCases.filter { !saved.contains($0) }
    }() {
        didSet { UserDefaults.standard.set(tabs.map(\.rawValue), forKey: "tabOrder") }
    }
    @Published var toolKind: ToolKind = .json
    @Published var showPalette = false
    @Published var selectedProfile: UUID?
    @Published var openNote: String?
    @Published var openNoteQuery: String?
    @Published var openTodo: Int64?
}

func statusColor(_ s: RunState) -> Color {
    switch s {
    case .running: return .green
    case .starting: return .yellow
    case .stopped: return .gray
    case .crashed, .portConflict: return .orange
    case .needsReauth: return .red
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var cm: ConnectionManager
    @EnvironmentObject var todos: TodoStore
    @ObservedObject private var shortcuts = ShortcutStore.shared

    private func badge(_ t: Tab) -> Int { t == .todos ? todoAttentionCount(todos.items) : 0 }

    private var dotColor: Color? {
        let o = cm.overall
        return o == .stopped ? nil : statusColor(o)
    }

    private var tunnelSummary: some View {
        let running = cm.profiles.filter { cm.state($0) == .running }.count
        let reauth = cm.profiles.filter { cm.state($0) == .needsReauth }.count
        return HStack(spacing: 6) {
            Circle().fill(reauth > 0 ? .red : running > 0 ? .green : .gray).frame(width: 7, height: 7)
            Text("\(running) running").foregroundStyle(.secondary)
            if reauth > 0 { Text("· \(reauth) re-auth").foregroundStyle(.red) }
            Spacer()
        }
        .font(.caption).lineLimit(1)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { app.tab = .connections }
        .background(.bar)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { app.tab }, set: { app.tab = $0 ?? .connections })) {
                ForEach(Tab.groups, id: \.self) { g in
                    Section(g.uppercased()) {
                        ForEach(app.tabs.filter { $0.group == g }) { t in
                            SidebarRow(tab: t, badge: badge(t), dot: t == .connections ? dotColor : nil, combo: shortcuts.combo("tab.\(t.rawValue)"))
                                .tag(t)
                        }
                        .onMove { from, to in
                            var sub = app.tabs.filter { $0.group == g }
                            sub.move(fromOffsets: from, toOffset: to)
                            app.tabs = Tab.groups.flatMap { gg in gg == g ? sub : app.tabs.filter { $0.group == gg } }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { tunnelSummary }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch app.tab {
            case .connections: ConnectionsView()
            case .notes: NotesView()
            case .todos: TodoView()
            case .clipboard: ClipboardView()
            case .db: DBQueryView()
            case .ports: PortsView()
            case .vault: VaultView()
            case .tools: ToolsView()
            }
        }
        .sheet(isPresented: $app.showPalette) { PaletteView() }
        .onReceive(NotificationCenter.default.publisher(for: .devhubOpenTarget)) { n in
            let info = n.userInfo as? [String: String] ?? [:]
            if let t = info["tab"], let tab = Tab(rawValue: t) { app.tab = tab }
            if let p = info["profile"], let id = UUID(uuidString: p) { app.selectedProfile = id }
        }
        .frame(minWidth: 980, minHeight: 620)
    }
}

struct SidebarRow: View {
    let tab: Tab
    let badge: Int
    let dot: Color?
    let combo: Combo?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: tab.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(tab.tint.gradient, in: RoundedRectangle(cornerRadius: 6))
            Text(tab.rawValue).lineLimit(1)
            Spacer(minLength: 4)
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            if badge > 0 {
                Text("\(badge)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Color.red, in: Capsule())
            }
            if let combo { Text(combo.display).font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 2)
    }
}
