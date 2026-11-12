import SwiftUI
import AppKit

struct Seg: Identifiable, Equatable {
    let id = UUID()
    var isCode: Bool
    var lang: String = ""
    var text: String
}

enum SegCodec {
    static func parse(_ src: String) -> [Seg] {
        var out: [Seg] = []
        var buf: [String] = []
        var code: [String] = []
        var lang = ""
        var inCode = false
        for line in src.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if inCode {
                    out.append(Seg(isCode: true, lang: lang, text: code.joined(separator: "\n")))
                    code = []; inCode = false
                } else {
                    if !buf.isEmpty { out.append(Seg(isCode: false, text: buf.joined(separator: "\n"))); buf = [] }
                    lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
            } else if inCode { code.append(line) } else { buf.append(line) }
        }
        if inCode { out.append(Seg(isCode: true, lang: lang, text: code.joined(separator: "\n"))) }
        else if !buf.isEmpty { out.append(Seg(isCode: false, text: buf.joined(separator: "\n"))) }
        return out
    }

    static func serialize(_ segs: [Seg]) -> String {
        segs.map { $0.isCode ? "```\($0.lang)\n\($0.text)\n```" : $0.text }.joined(separator: "\n")
    }

    static func hasClosedFence(_ s: String) -> Bool {
        s.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count >= 2
    }
}

/// Auto-growing text area (TextEditor has no intrinsic height, so a hidden Text drives the size).
struct GrowingEditor: View {
    @Binding var text: String
    var font: Font
    var minHeight: CGFloat = 26

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(text + "\n").font(font).padding(.horizontal, 5).padding(.vertical, 8).opacity(0)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextEditor(text: $text).font(font).scrollContentBackground(.hidden)
        }
        .frame(minHeight: minHeight)
    }
}

struct BlockEditor: View {
    @Binding var text: String
    @State private var segs: [Seg] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($segs) { $seg in
                    if seg.isCode {
                        CodeEditorCard(seg: $seg) { segs.removeAll { $0.id == seg.id } }
                    } else {
                        LiveTextEditor(text: $seg.text)
                    }
                }
                HStack {
                    Button { segs.append(Seg(isCode: false, text: "")) } label: { Label("Text", systemImage: "plus") }
                    Button { segs.append(Seg(isCode: true, text: "")) } label: { Label("Code block", systemImage: "plus") }
                    Spacer()
                    Text("Type / for blocks · ⌘B bold · ⌘I italic · ⌘E code").font(.caption).foregroundStyle(.tertiary)
                }.buttonStyle(.borderless).padding(.top, 6)
            }
            .frame(maxWidth: Theme.readingWidth)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onAppear { segs = SegCodec.parse(text) }
        .onChange(of: text) { _, new in
            if SegCodec.serialize(segs) != new { segs = SegCodec.parse(new) }
        }
        .onChange(of: segs) { _, new in
            if new.contains(where: { !$0.isCode && SegCodec.hasClosedFence($0.text) }) {
                segs = SegCodec.parse(SegCodec.serialize(new))
                return
            }
            let s = SegCodec.serialize(new)
            if s != text { text = s }
        }
    }
}

struct CodeEditorCard: View {
    @Binding var seg: Seg
    var onDelete: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.caption).foregroundStyle(.secondary)
                TextField("language", text: $seg.lang).textFieldStyle(.plain).font(.caption).frame(width: 100)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Vault.substitute(seg.text), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption) }
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash").font(.caption) }.help("Delete block")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06))
            Divider()
            GrowingEditor(text: $seg.text, font: .system(size: 12.5, design: .monospaced), minHeight: 40)
                .padding(.horizontal, 5)
        }
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}
