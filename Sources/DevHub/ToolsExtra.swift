import SwiftUI
import AppKit

enum IDGen {
    private static let processRandom: [UInt8] = (0..<5).map { _ in UInt8.random(in: 0...255) }
    private static var counter = UInt32.random(in: 0...0xFFFFFF)

    /// MongoDB ObjectId: 4-byte timestamp + 5-byte process random + 3-byte counter.
    static func objectId() -> String {
        let ts = UInt32(Date().timeIntervalSince1970)
        counter = (counter + 1) & 0xFFFFFF
        var b: [UInt8] = (0..<4).map { UInt8((ts >> UInt32(8 * (3 - $0))) & 0xff) }
        b += processRandom
        b += (0..<3).map { UInt8((counter >> UInt32(8 * (2 - $0))) & 0xff) }
        return b.hex
    }

    static func objectIdDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count == 24, let ts = UInt32(t.prefix(8), radix: 16), t.allSatisfy(\.isHexDigit) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    static func ulid() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var ms = UInt64(Date().timeIntervalSince1970 * 1000)
        var time: [Character] = []
        for _ in 0..<10 { time.insert(alphabet[Int(ms % 32)], at: 0); ms /= 32 }
        return String(time) + String((0..<16).map { _ in alphabet.randomElement()! })
    }
}

struct IDGenView: View {
    @State private var count = 3
    @State private var upper = false
    @State private var kind = "ObjectId"
    @State private var results: [String] = []
    @State private var decodeInput = ""

    let kinds = ["ObjectId", "UUID v4", "UUID v7", "ULID"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Type", selection: $kind) { ForEach(kinds, id: \.self) { Text($0) } }.frame(width: 220)
                Stepper("Count: \(count)", value: $count, in: 1...50).frame(width: 130)
                Toggle("UPPERCASE", isOn: $upper)
                Button("Generate") { generate() }.buttonStyle(.borderedProminent)
            }
            List(results, id: \.self) { r in
                HStack {
                    Text(r).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r, forType: .string) }
                }
            }
            Divider()
            Text("ObjectId → creation time").font(.caption).foregroundStyle(.secondary)
            TextField("Paste an ObjectId (24 hex chars)", text: $decodeInput).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            if !decodeInput.isEmpty {
                if let d = IDGen.objectIdDate(decodeInput) {
                    Text(ToolsView.time(String(Int(d.timeIntervalSince1970)))).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                } else {
                    Text("Not a valid ObjectId").foregroundStyle(.red).font(.caption)
                }
            }
        }
        .onAppear { if results.isEmpty { generate() } }
        .onChange(of: kind) { _, _ in generate() }
        .onChange(of: count) { _, _ in generate() }
        .onChange(of: upper) { _, _ in generate() }
    }

    private func generate() {
        results = (0..<count).map { _ in
            let v: String
            switch kind {
            case "UUID v4": v = UUID().uuidString.lowercased()
            case "UUID v7": v = ToolsView.uuid7()
            case "ULID": v = IDGen.ulid()
            default: v = IDGen.objectId()
            }
            return upper ? v.uppercased() : (kind == "ULID" ? v : v.lowercased())
        }
    }
}

// MARK: diff

struct DiffRow: Identifiable {
    enum Kind { case same, add, del }
    let id = UUID()
    let kind: Kind
    let oldNo: Int?
    let newNo: Int?
    let text: AttributedString
}

enum Differ {
    static func rows(old: String, new: String, ignoreWhitespace: Bool) -> [DiffRow] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        func norm(_ s: String) -> String { ignoreWhitespace ? s.split(whereSeparator: \.isWhitespace).joined(separator: " ") : s }
        let diff = b.map(norm).difference(from: a.map(norm))
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in diff {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var i = 0, j = 0
        var out: [DiffRow] = []
        var delBlock: [Int] = [], addBlock: [Int] = []

        func flush() {
            // pair removed/added lines to highlight the exact words that changed
            let n = max(delBlock.count, addBlock.count)
            var dels: [DiffRow] = [], adds: [DiffRow] = []
            for k in 0..<n {
                let o = k < delBlock.count ? a[delBlock[k]] : nil
                let nw = k < addBlock.count ? b[addBlock[k]] : nil
                if let o {
                    dels.append(DiffRow(kind: .del, oldNo: delBlock[k] + 1, newNo: nil, text: inline(o, vs: nw, kind: .del)))
                }
                if let nw {
                    adds.append(DiffRow(kind: .add, oldNo: nil, newNo: addBlock[k] + 1, text: inline(nw, vs: o, kind: .add)))
                }
            }
            out += dels + adds
            delBlock = []; addBlock = []
        }

        while i < a.count || j < b.count {
            if i < a.count && removed.contains(i) { delBlock.append(i); i += 1 }
            else if j < b.count && inserted.contains(j) { addBlock.append(j); j += 1 }
            else {
                flush()
                if i < a.count && j < b.count {
                    out.append(DiffRow(kind: .same, oldNo: i + 1, newNo: j + 1, text: AttributedString(b[j])))
                }
                i += 1; j += 1
            }
        }
        flush()
        return out
    }

    private static func tokens(_ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "\\s+|\\w+|[^\\w\\s]") else { return [s] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func inline(_ line: String, vs other: String?, kind: DiffRow.Kind) -> AttributedString {
        let t = tokens(line)
        guard let other else {
            var s = AttributedString(line)
            s.backgroundColor = (kind == .add ? Color.green : Color.red).opacity(0.45)
            return s
        }
        let o = tokens(other)
        var changed = Set<Int>()
        if kind == .add {
            for c in t.difference(from: o) { if case .insert(let off, _, _) = c { changed.insert(off) } }
        } else {
            for c in o.difference(from: t) { if case .remove(let off, _, _) = c { changed.insert(off) } }
        }
        var out = AttributedString()
        for (idx, tok) in t.enumerated() {
            var piece = AttributedString(tok)
            if changed.contains(idx) { piece.backgroundColor = (kind == .add ? Color.green : Color.red).opacity(0.55) }
            out += piece
        }
        return out
    }
}

struct DiffView: View {
    @State private var left = ""
    @State private var right = ""
    @State private var ignoreWS = false

    var body: some View {
        let rows = Differ.rows(old: left, new: right, ignoreWhitespace: ignoreWS)
        let adds = rows.filter { $0.kind == .add }.count, dels = rows.filter { $0.kind == .del }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Ignore whitespace", isOn: $ignoreWS)
                Spacer()
                Text("+\(adds)  −\(dels)").font(.system(.body, design: .monospaced))
                Button("Swap") { swap(&left, &right) }
                Button("Clear") { left = ""; right = "" }
            }
            HStack {
                VStack(alignment: .leading) {
                    Text("Original").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $left).font(.system(.caption, design: .monospaced)).border(.gray.opacity(0.4))
                }
                VStack(alignment: .leading) {
                    Text("Changed").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $right).font(.system(.caption, design: .monospaced)).border(.gray.opacity(0.4))
                }
            }.frame(height: 190)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { r in
                        HStack(spacing: 6) {
                            Text(r.oldNo.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
                            Text(r.newNo.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
                            Text(r.kind == .add ? "+" : r.kind == .del ? "−" : " ")
                            Text(r.text).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .padding(.vertical, 1)
                        .background(r.kind == .add ? Color.green.opacity(0.15) : r.kind == .del ? Color.red.opacity(0.15) : .clear)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(4).background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
