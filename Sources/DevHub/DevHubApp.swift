import SwiftUI
import AppKit
import ServiceManagement

@main
enum Launcher {
    static func main() {
        // `DevHub --todo ...` is the headless CLI (see TodoBridge); everything else starts the GUI.
        if let code = TodoBridge.runIfRequested(CommandLine.arguments) { exit(code) }
        DevHubApp.main()
    }
}

struct DevHubApp: App {
    @StateObject private var cm = ConnectionManager()
    @StateObject private var notes = NotesStore()
    @StateObject private var app = AppState()
    @StateObject private var clip = ClipStore()
    @StateObject private var todos = TodoStore()
    @ObservedObject private var shortcuts = ShortcutStore.shared

    init() {
        Notifier.shared.setup()
        DispatchQueue.global().async { _ = UserEnv.env }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func summon() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        app.showPalette = true
    }

    var body: some Scene {
        Window("DevHub", id: "main") {
            RootView()
                .environmentObject(cm)
                .environmentObject(notes)
                .environmentObject(app)
                .environmentObject(clip)
                .environmentObject(todos)
                .onAppear { GlobalHotKey.register { summon() } }
        }
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Command Palette") { app.showPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandMenu("Go") {
                ForEach(app.tabs) { t in
                    Button(t.rawValue) { app.tab = t }.shortcut(shortcuts.combo("tab.\(t.rawValue)"))
                }
                Divider()
                ForEach(ToolKind.allCases) { k in
                    Button("Tool: \(k.rawValue)") { app.tab = .tools; app.toolKind = k }
                        .shortcut(shortcuts.combo("tool.\(k.rawValue)"))
                }
            }
        }

        Settings {
            SettingsView().environmentObject(app)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(cm).environmentObject(app)
        } label: {
            Image(nsImage: Self.dot(statusColor(cm.overall)))
        }
    }

    static func dot(_ c: Color) -> NSImage {
        let img = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            NSColor(c).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var cm: ConnectionManager
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(cm.profiles) { p in
            let s = cm.state(p)
            HStack {
                Button((cm.isActive(p) ? "Disconnect " : "Connect ") + p.name) { cm.toggle(p) }
                Text(s.label)
            }
            if s == .needsReauth {
                Button("⚠️ Re-auth \(p.name)") {
                    app.tab = .connections
                    app.selectedProfile = p.id
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                    if cm.hasStoredSecret(p) { cm.reauth(p) }
                }
            }
        }
        Divider()
        Toggle("Restore last session on launch", isOn: $cm.restoreLast)
        Toggle("Launch DevHub at login", isOn: Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { on in try? (on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()) }
        ))
        Divider()
        Button("Open DevHub") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Disconnect all") { cm.stopAll() }
        Button("Quit") { NSApp.terminate(nil) }
    }
}
