import SwiftUI
import AppKit

enum Theme {
    static let page: CGFloat = 16
    static let radius: CGFloat = 10
    static let listWidth: CGFloat = 320
    static let readingWidth: CGFloat = 780
    static var card: Color { Color(nsColor: .controlBackgroundColor) }
    static var line: Color { Color.primary.opacity(0.08) }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
    }
}

// MARK: block model

enum MDBlock: Identifiable {
    case heading(Int, String)
    case paragraph(String)
    case code(String, String)
    case list([(depth: Int, marker: String, text: String)])
    case quote(String)
    case table([String], [[String]])
    case rule

    var id: UUID { UUID() }
}

enum MDParser {
    static func headings(_ src: String) -> [(index: Int, level: Int, text: String)] {
        parse(src).enumerated().compactMap { i, b in
            if case .heading(let l, let t) = b { return (i, l, t) }
            return nil
        }
    }

    static func parse(_ src: String) -> [MDBlock] {
        var lines = src.components(separatedBy: "\n")
        // strip YAML front matter
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines = Array(lines[(end + 1)...]) }
        var out: [MDBlock] = []
        var i = 0
        var para: [String] = []
        func flushPara() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flushPara()
                let lang = String(t.drop(while: { $0 == "`" || $0 == "~" })).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```"), !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
                    code.append(lines[i]); i += 1
                }
                out.append(.code(lang, code.joined(separator: "\n")))
                i += 1
                continue
            }
            if t.isEmpty { flushPara(); i += 1; continue }
            if let m = t.range(of: "^#{1,6} ", options: .regularExpression) {
                flushPara()
                let level = t[m].count - 1
                out.append(.heading(level, String(t[m.upperBound...])))
                i += 1; continue
            }
            if t.range(of: "^(-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil { flushPara(); out.append(.rule); i += 1; continue }
            if t.hasPrefix(">") {
                flushPara()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                out.append(.quote(q.joined(separator: " ")))
                continue
            }
            if t.hasPrefix("|"), i + 1 < lines.count, lines[i + 1].range(of: "^\\s*\\|?[\\s:|-]+\\|[\\s:|-]*$", options: .regularExpression) != nil {
                flushPara()
                func cells(_ s: String) -> [String] {
                    var c = s.trimmingCharacters(in: .whitespaces)
                    if c.hasPrefix("|") { c.removeFirst() }
                    if c.hasSuffix("|") { c.removeLast() }
                    return c.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                let header = cells(t)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(cells(lines[i])); i += 1 }
                out.append(.table(header, rows))
                continue
            }
            if listItem(line) != nil {
                flushPara()
                var items: [(depth: Int, marker: String, text: String)] = []
                while i < lines.count, let it = listItem(lines[i]) { items.append(it); i += 1 }
                out.append(.list(items))
                continue
            }
            para.append(t)
            i += 1
        }
        flushPara()
        return out
    }

    private static func listItem(_ line: String) -> (depth: Int, marker: String, text: String)? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let t = line.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: "^[-*+] ", options: .regularExpression) {
            var rest = String(t[r.upperBound...])
            var marker = "•"
            if rest.hasPrefix("[ ] ") { marker = "☐"; rest = String(rest.dropFirst(4)) }
            else if rest.lowercased().hasPrefix("[x] ") { marker = "☑"; rest = String(rest.dropFirst(4)) }
            return (indent / 2, marker, rest)
        }
        if let r = t.range(of: "^\\d+[.)] ", options: .regularExpression) {
            return (indent / 2, String(t[..<r.upperBound]).trimmingCharacters(in: .whitespaces), String(t[r.upperBound...]))
        }
        return nil
    }
}

// MARK: renderer

struct MarkdownView: View {
    let source: String
    var onMakeProfile: ((String) -> Void)? = nil

    var body: some View {
        let blocks = MDParser.parse(source)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in render(b) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    static func inline(_ s: String) -> AttributedString {
        // [[note]] / [[note|label]] become links handled by the notes view
        var s = s
        if let re = try? NSRegularExpression(pattern: "\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]") {
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                let target = ns.substring(with: m.range(at: 1))
                let label = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : target
                let enc = target.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? target
                s = (s as NSString).replacingCharacters(in: m.range, with: "[\(label)](devhub-note://\(enc))")
            }
        }
        return (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnly))) ?? AttributedString(s)
    }

    @ViewBuilder
    private func render(_ b: MDBlock) -> some View {
        switch b {
        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.inline(text))
                    .font(.system(size: [30, 24, 20, 17, 15, 14][min(level - 1, 5)], weight: level <= 2 ? .bold : .semibold))
                    .padding(.top, level <= 2 ? 8 : 2)
                if level <= 2 { Divider() }
            }
        case .paragraph(let text):
            Text(Self.inline(text)).font(.system(size: 14.5)).lineSpacing(5)
        case .code(let lang, let code):
            CodeCard(lang: lang, code: code, onMakeProfile: onMakeProfile)
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(it.marker).foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
                        Text(Self.inline(it.text)).font(.system(size: 14.5)).lineSpacing(4)
                    }.padding(.leading, CGFloat(it.depth) * 20)
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.6)).frame(width: 4)
                Text(Self.inline(text)).font(.system(size: 14.5)).foregroundStyle(.secondary).lineSpacing(4)
            }.fixedSize(horizontal: false, vertical: true)
        case .table(let header, let rows):
            Card(padding: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow {
                            ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                                Text(Self.inline(h)).font(.system(size: 13, weight: .semibold)).padding(8)
                            }
                        }.background(Color.primary.opacity(0.06))
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                            Divider()
                            GridRow {
                                ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                                    Text(Self.inline(c)).font(.system(size: 13)).padding(8)
                                }
                            }
                        }
                    }
                }
            }
        case .rule:
            Divider()
        }
    }
}

struct CodeCard: View {
    let lang: String
    let code: String
    var onMakeProfile: ((String) -> Void)? = nil
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let onMakeProfile, ["", "sh", "bash", "zsh", "shell", "console"].contains(lang.lowercased()) {
                    Button { onMakeProfile(code) } label: { Label("Make profile", systemImage: "bolt.badge.plus").font(.caption) }
                        .buttonStyle(.borderless).help("Create a Connection profile from this command")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Vault.substitute(code), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption).lineLimit(1).fixedSize()
                }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06))
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 12.5, design: .monospaced)).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}
