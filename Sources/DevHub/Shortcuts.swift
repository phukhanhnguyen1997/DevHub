import SwiftUI
import AppKit

struct Combo: Codable, Equatable {
    var key: String
    var mods: Int // NSEvent.ModifierFlags raw value limited to cmd/ctrl/opt/shift

    static let mask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: UInt(mods)).intersection(Self.mask) }
    var eventMods: EventModifiers {
        var m: EventModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        return m
    }
    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key.uppercased()
    }
    static func cmd(_ k: String, _ extra: NSEvent.ModifierFlags = []) -> Combo {
        Combo(key: k, mods: Int(NSEvent.ModifierFlags.command.union(extra).rawValue))
    }
}

extension View {
    @ViewBuilder func shortcut(_ c: Combo?) -> some View {
        if let c, let ch = c.key.first { keyboardShortcut(KeyEquivalent(ch), modifiers: c.eventMods) } else { self }
    }
}

// Action ids: "tab.<Tab.rawValue>" and "tool.<ToolKind.rawValue>".
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    private let defaultsKey = "shortcutMap.v1"
    @Published private(set) var map: [String: Combo]

    init() {
        if let d = UserDefaults.standard.data(forKey: defaultsKey), let m = try? JSONDecoder().decode([String: Combo].self, from: d) {
            map = m
        } else {
            map = Self.defaults()
        }
    }

    static func defaults() -> [String: Combo] {
        var m: [String: Combo] = [:]
        for (i, t) in Tab.defaultOrder.enumerated() { m["tab.\(t.rawValue)"] = .cmd(String(i + 1)) }
        for (i, k) in ToolKind.allCases.prefix(9).enumerated() { m["tool.\(k.rawValue)"] = .cmd(String(i + 1), .control) }
        return m
    }

    func combo(_ id: String) -> Combo? { map[id] }

    // Returns the id of an action that lost its shortcut because of a clash.
    @discardableResult
    func set(_ id: String, _ c: Combo?) -> String? {
        var bumped: String?
        if let c, let other = map.first(where: { $0.value == c && $0.key != id })?.key {
            map[other] = nil; bumped = other
        }
        map[id] = c
        save()
        return bumped
    }

    func reset() { map = Self.defaults(); save() }

    func numberTabs(_ order: [Tab]) {
        for t in Tab.allCases { map["tab.\(t.rawValue)"] = nil }
        for (i, t) in order.prefix(9).enumerated() { map["tab.\(t.rawValue)"] = .cmd(String(i + 1)) }
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(map) { UserDefaults.standard.set(d, forKey: defaultsKey) }
    }
}

// Click, then press the new combination. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    let id: String
    @ObservedObject var store: ShortcutStore
    var onClash: (String) -> Void = { _ in }
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys…" : (store.combo(id)?.display ?? "None"))
                    .font(.system(.body, design: .monospaced)).frame(width: 110)
            }
            .buttonStyle(.bordered).tint(recording ? .accentColor : nil)
            Button { store.set(id, nil) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).disabled(store.combo(id) == nil).help("Clear shortcut")
        }
        .onDisappear { stop() }
    }

    func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil } // Esc
            if e.keyCode == 51 || e.keyCode == 117 { store.set(id, nil); stop(); return nil } // Delete
            let mods = e.modifierFlags.intersection(Combo.mask)
            guard let ch = e.charactersIgnoringModifiers?.lowercased().first, ch.isLetter || ch.isNumber || "[]-=;',./`\\".contains(ch),
                  mods.contains(.command) || mods.contains(.control) || mods.contains(.option) else { NSSound.beep(); return nil }
            if let bumped = store.set(id, Combo(key: String(ch), mods: Int(mods.rawValue))) { onClash(bumped) }
            stop()
            return nil
        }
    }

    func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var store = ShortcutStore.shared
    @State private var notice = ""

    func label(_ id: String) -> String {
        id.replacingOccurrences(of: "tab.", with: "Tab: ").replacingOccurrences(of: "tool.", with: "Tool: ")
    }

    var body: some View {
        Form {
            Section("Tabs (drag items in the sidebar to reorder)") {
                ForEach(app.tabs) { t in row("tab.\(t.rawValue)", t.rawValue, t.icon) }
            }
            Section("Tools") {
                ForEach(ToolKind.allCases) { k in row("tool.\(k.rawValue)", k.rawValue, "wrench.and.screwdriver") }
            }
            Section {
                HStack {
                    Button("Number tabs by sidebar order") { store.numberTabs(app.tabs); notice = "⌘1…⌘\(min(9, app.tabs.count)) now follow the sidebar order." }
                    Button("Reset shortcuts") { store.reset(); notice = "Shortcuts reset to defaults." }
                    Button("Reset sidebar order") { app.tabs = Tab.defaultOrder; notice = "Sidebar order reset." }
                }
                if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
                Text("Click a shortcut, then press the new keys (needs ⌘, ⌃ or ⌥). Esc cancels, Delete clears. A clashing shortcut is taken from the other action.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
    }

    func row(_ id: String, _ name: String, _ icon: String) -> some View {
        HStack {
            Label(name, systemImage: icon)
            Spacer()
            ShortcutRecorder(id: id, store: store) { bumped in notice = "Removed the same shortcut from \(label(bumped))." }
        }
    }
}
