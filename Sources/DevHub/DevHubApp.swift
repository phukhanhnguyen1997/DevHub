import SwiftUI
import AppKit

@main
struct DevHubApp: App {
    @StateObject private var cm = ConnectionManager()
    @StateObject private var notes = NotesStore()
    @StateObject private var app = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        Window("DevHub", id: "main") {
            RootView()
                .environmentObject(cm)
                .environmentObject(notes)
                .environmentObject(app)
        }
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Command Palette") { app.showPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
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
        Button("Open DevHub") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Disconnect all") { cm.stopAll() }
        Button("Quit") { cm.stopAll(); NSApp.terminate(nil) }
    }
}
