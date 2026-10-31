import SwiftUI
import AppKit
import Carbon.HIToolbox

struct ClipEntry: Identifiable {
    let id = UUID()
    let text: String
    let date: Date
    var pinned = false
    var sensitive: Bool { ClipStore.looksSensitive(text) }
}

@MainActor
final class ClipStore: ObservableObject {
    @Published var entries: [ClipEntry] = []
    private var lastCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var selfWrite = false

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    nonisolated static func looksSensitive(_ s: String) -> Bool {
        let pats = ["eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.", "-----BEGIN [A-Z ]*PRIVATE KEY", "(?i)(password|passwd|secret|token|api[_-]?key)\\s*[=:]", "AKIA[0-9A-Z]{16}", "ghp_[A-Za-z0-9]{20,}", "sk-[A-Za-z0-9]{20,}"]
        return pats.contains { s.range(of: $0, options: .regularExpression) != nil }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        if selfWrite { selfWrite = false; return }
        let types = pb.types?.map(\.rawValue) ?? []
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") { return }
        guard let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let i = entries.firstIndex(where: { $0.text == s }) {
            let e = entries.remove(at: i)
            entries.insert(ClipEntry(text: s, date: Date(), pinned: e.pinned), at: 0)
        } else {
            entries.insert(ClipEntry(text: s, date: Date()), at: 0)
        }
        while entries.count > 100, let i = entries.lastIndex(where: { !$0.pinned }) { entries.remove(at: i) }
    }

    func copy(_ e: ClipEntry) {
        selfWrite = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.text, forType: .string)
        lastCount = NSPasteboard.general.changeCount
    }

    func togglePin(_ e: ClipEntry) {
        if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i].pinned.toggle() }
    }
    func delete(_ e: ClipEntry) { entries.removeAll { $0.id == e.id } }
    func clearUnpinned() { entries.removeAll { !$0.pinned } }
}

struct ClipboardView: View {
    @EnvironmentObject var clip: ClipStore
    @State private var query = ""
    @State private var revealed: Set<UUID> = []

    var shown: [ClipEntry] {
        let f = query.isEmpty ? clip.entries : clip.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
        return f.filter(\.pinned) + f.filter { !$0.pinned }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $query).textFieldStyle(.plain)
                Spacer()
                Text("\(clip.entries.count) items · memory only").font(.caption).foregroundStyle(.secondary)
                Button("Clear unpinned") { clip.clearUnpinned() }
            }.padding(10)
            Divider()
            if shown.isEmpty {
                Spacer(); Text("Copy something to see it here").foregroundStyle(.secondary); Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(shown) { e in row(e) }
                    }.padding(12)
                }
            }
        }
    }

    func row(_ e: ClipEntry) -> some View {
        let hidden = e.sensitive && !revealed.contains(e.id)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(hidden ? "•••••••• sensitive — click Reveal" : String(e.text.prefix(400)))
                    .font(.system(.callout, design: .monospaced)).lineLimit(5).textSelection(.enabled)
                Text(e.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if e.sensitive {
                Button(hidden ? "Reveal" : "Hide") {
                    if hidden { revealed.insert(e.id) } else { revealed.remove(e.id) }
                }.buttonStyle(.borderless)
            }
            Button { clip.copy(e) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy again")
            Button { clip.togglePin(e) } label: { Image(systemName: e.pinned ? "pin.fill" : "pin") }.buttonStyle(.borderless)
            Button { clip.delete(e) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

// Global hotkey: Ctrl+Option+K
@MainActor
enum GlobalHotKey {
    static var handler: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        handler = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x44564855), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}
