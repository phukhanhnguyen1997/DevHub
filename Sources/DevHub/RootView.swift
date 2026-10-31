import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case connections = "Connections", notes = "Notes", clipboard = "Clipboard", db = "DB Query", ports = "Ports", vault = "Vault", tools = "Tools"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .connections: return "bolt.horizontal.circle"
        case .notes: return "note.text"
        case .clipboard: return "doc.on.clipboard"
        case .db: return "cylinder.split.1x2"
        case .ports: return "network"
        case .vault: return "key"
        case .tools: return "wrench.and.screwdriver"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var tab: Tab = .connections
    @Published var toolKind: ToolKind = .json
    @Published var showPalette = false
    @Published var selectedProfile: UUID?
    @Published var openNote: String?
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

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: Binding(get: { app.tab }, set: { app.tab = $0 ?? .connections })) { t in
                Label(t.rawValue, systemImage: t.icon).tag(t)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            switch app.tab {
            case .connections: ConnectionsView()
            case .notes: NotesView()
            case .clipboard: ClipboardView()
            case .db: DBQueryView()
            case .ports: PortsView()
            case .vault: VaultView()
            case .tools: ToolsView()
            }
        }
        .sheet(isPresented: $app.showPalette) { PaletteView() }
        .frame(minWidth: 980, minHeight: 620)
    }
}
