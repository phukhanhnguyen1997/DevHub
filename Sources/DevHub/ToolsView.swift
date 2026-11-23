import SwiftUI
import CryptoKit

enum ToolKind: String, CaseIterable, Identifiable {
    case json = "JSON Format", yaml = "JSON minify", base64 = "Base64", url = "URL", jwt = "JWT", hash = "Hash", uuid = "UUID / ObjectId", password = "Password", time = "Unix Timestamp", regex = "Regex", diff = "Diff Checker", cron = "Cron", sql = "SQL format", csv = "CSV / JSON / INSERT", ts = "JSON → TypeScript", hex = "Hex ↔ Text"
    var id: String { rawValue }
}

struct ToolsView: View {
    @EnvironmentObject var app: AppState
    @State private var csvMode = "CSV → JSON"
    @State private var input = ""
    @State private var extra = ""
    @State private var decode = false
    @State private var search = ""
    @State private var onlyMatches = false
    @State private var cronMode = "Cron → English"

    var kind: ToolKind { app.toolKind }

    @AppStorage("pinnedTools") private var pinnedRaw = "JSON Format,JWT,Unix Timestamp"
    @State private var toolSearch = ""

    private var pinned: [ToolKind] { pinnedRaw.split(separator: ",").compactMap { ToolKind(rawValue: String($0)) } }
    private func togglePin(_ k: ToolKind) {
        var l = pinned
        if let i = l.firstIndex(of: k) { l.remove(at: i) } else { l.append(k) }
        pinnedRaw = l.map(\.rawValue).joined(separator: ",")
    }

    private static let groups: [(String, [ToolKind])] = [
        ("Format", [.json, .yaml, .csv, .ts, .sql]),
        ("Encode", [.base64, .url, .hex, .hash, .jwt]),
        ("Generate", [.uuid, .password]),
        ("Time & text", [.time, .cron, .regex, .diff]),
    ]

    private func railRow(_ k: ToolKind) -> some View {
        let on = k == kind
        return Text(k.rawValue).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(on ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(on ? Color.accentColor : .primary)
            .fontWeight(on ? .semibold : .regular)
            .contentShape(Rectangle())
            .onTapGesture { app.toolKind = k }
            .contextMenu {
                Button(pinned.contains(k) ? "Unpin" : "Pin to top") { togglePin(k) }
            }
    }

    private func railSection(_ title: String, _ items: [ToolKind]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.top, 8)
            ForEach(items) { railRow($0) }
        }
    }

    private var rail: some View {
        let q = toolSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let match: (ToolKind) -> Bool = { q.isEmpty || $0.rawValue.lowercased().contains(q) }
        return VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find tool", text: $toolSearch).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let pins = pinned.filter(match)
                    if !pins.isEmpty { railSection("★ Pinned", pins) }
                    ForEach(Self.groups, id: \.0) { g in
                        let items = g.1.filter(match)
                        if !items.isEmpty { railSection(g.0, items) }
                    }
                }
            }
            Text("Right-click a tool to pin").font(.caption2).foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(10)
        .frame(width: 190)
        .background(Color.primary.opacity(0.03))
    }

    private func header(_ extras: some View = EmptyView()) -> some View {
        HStack(spacing: 10) {
            Text(kind.rawValue).font(.title3.weight(.semibold)).lineLimit(1).fixedSize()
            extras
            Spacer()
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            Group {
                if [.password, .uuid, .diff, .time].contains(kind) {
                    VStack(alignment: .leading, spacing: 10) {
                        header()
                        switch kind {
                        case .password: PasswordGenView()
                        case .uuid: IDGenView()
                        case .time: TimeToolView()
                        default: DiffView()
                        }
                    }.padding()
                } else { mainBody }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var inputHint: String {
        kind == .time ? "Epoch (seconds or ms) or ISO-8601 - empty = now"
        : kind == .cron ? (cronMode == "Cron → English" ? "Cron expression (5 fields)" : "Describe the schedule, e.g. every weekday at 8:30am")
        : "Input"
    }

    private var options: some View {
        HStack {
            if kind == .csv {
                Picker("", selection: $csvMode) {
                    ForEach(["CSV → JSON", "JSON → CSV", "CSV → INSERT", "JSON → INSERT"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 380)
                if csvMode.hasSuffix("INSERT") { TextField("Table name", text: $extra).textFieldStyle(.roundedBorder).frame(width: 140) }
            }
            if [.base64, .url, .hex].contains(kind) { Toggle(kind == .hex ? "Hex → Text" : "Decode", isOn: $decode).toggleStyle(.switch) }
            if kind == .cron {
                Picker("", selection: $cronMode) { ForEach(["Cron → English", "English → Cron"], id: \.self) { Text($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            }
            if kind == .regex { TextField("Regex pattern", text: $extra).textFieldStyle(.roundedBorder) }
        }
    }

    private var statusLine: String {
        let n = output.utf8.count
        return output.isEmpty ? "" : "\(n) B · \(output.split(separator: "\n", omittingEmptySubsequences: false).count) lines"
    }

    var mainBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(options)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(inputHint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Paste") { input = NSPasteboard.general.string(forType: .string) ?? input }
                        Button("Clear") { input = "" }.disabled(input.isEmpty)
                    }.buttonStyle(.borderless).font(.caption)
                    TextEditor(text: $input).font(.system(.body, design: .monospaced))
                        .padding(4).background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Output").font(.caption).foregroundStyle(.secondary)
                        if kind == .json || kind == .yaml {
                            HStack(spacing: 4) {
                                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                TextField("Search output", text: $search).textFieldStyle(.plain).frame(minWidth: 80, maxWidth: 160)
                                if !search.isEmpty { Text("\(OutputSearch.count(output, search))").font(.caption).foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                            Toggle("Only matches", isOn: $onlyMatches).toggleStyle(.checkbox).font(.caption)
                        }
                        Spacer()
                        Button("⇄ Swap") { input = output }.disabled(output.isEmpty)
                        if kind == .cron && cronMode == "English → Cron", let r = CronNL.parse(input) {
                            Button("Copy expr") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(r.expr, forType: .string)
                            }
                        }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(output, forType: .string)
                        }
                    }.buttonStyle(.borderless).font(.caption)
                    ScrollView {
                        Text(shownOutput).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(8)
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                }
            }
            Text(statusLine).font(.caption).foregroundStyle(.tertiary)
        }.padding()
    }

    var shownOutput: AttributedString {
        guard kind == .json || kind == .yaml else { return AttributedString(output) }
        return OutputSearch.highlight(output, term: search, onlyMatches: onlyMatches)
    }

    var output: String {
        switch kind {
        case .json: return Self.jsonFormat(input, pretty: true)
        case .yaml: return Self.jsonFormat(input, pretty: false)
        case .base64:
            if decode {
                guard let d = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines)) else { return "Invalid Base64" }
                return String(data: d, encoding: .utf8) ?? "(binary data)"
            }
            return Data(input.utf8).base64EncodedString()
        case .url:
            return decode ? (input.removingPercentEncoding ?? "Invalid") : (input.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? "")
        case .jwt: return Self.jwt(input)
        case .hash:
            let d = Data(input.utf8)
            return """
            MD5:    \(Insecure.MD5.hash(data: d).hex)
            SHA1:   \(Insecure.SHA1.hash(data: d).hex)
            SHA256: \(SHA256.hash(data: d).hex)
            SHA512: \(SHA512.hash(data: d).hex)
            """
        case .password: return ""
        case .cron: return cronMode == "Cron → English" ? Cron.report(input) : CronNL.report(input)
        case .sql: return SQLFormat.format(input)
        case .ts: return TSGen.generate(input)
        case .csv:
            switch csvMode {
            case "JSON → CSV": return CSVTool.jsonToCSV(input)
            case "CSV → INSERT": return CSVTool.csvToInserts(input, table: extra)
            case "JSON → INSERT": return CSVTool.jsonToInserts(input, table: extra)
            default: return CSVTool.csvToJSON(input)
            }
        case .uuid, .diff: return ""
        case .time: return Self.time(input)
        case .hex: return HexTool.convert(input, decode: decode)
        case .regex: return Self.regex(extra, input)
        }
    }

    static func jsonFormat(_ s: String, pretty: Bool) -> String {
        guard let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else { return s.isEmpty ? "" : "Invalid JSON" }
        let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let out = try? JSONSerialization.data(withJSONObject: o, options: opts.union(.fragmentsAllowed)) else { return "Invalid JSON" }
        return String(data: out, encoding: .utf8) ?? ""
    }

    static func jwt(_ t: String) -> String {
        let parts = t.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count >= 2 else { return "Not a JWT" }
        func dec(_ p: Substring) -> String {
            var b = p.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            guard let d = Data(base64Encoded: b) else { return "?" }
            return jsonFormat(String(data: d, encoding: .utf8) ?? "", pretty: true)
        }
        var out = "HEADER\n\(dec(parts[0]))\n\nPAYLOAD\n\(dec(parts[1]))"
        if let b = Data(base64Encoded: String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - parts[1].count % 4) % 4)),
           let o = try? JSONSerialization.jsonObject(with: b) as? [String: Any] {
            for k in ["exp", "iat", "nbf"] {
                if let v = o[k] as? Double { out += "\n\(k): \(Date(timeIntervalSince1970: v).formatted(.iso8601))" }
            }
        }
        return out
    }

    static func time(_ s: String, inputTZ: TimeZone = TimeZone(secondsFromGMT: 7 * 3600)!) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let tz7 = TimeZone(secondsFromGMT: 7 * 3600)!
        func fmt(_ d: Date, _ tz: TimeZone, _ suffix: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = tz
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
            return f.string(from: d) + suffix
        }
        func report(_ d: Date) -> String {
            let sec = Int(d.timeIntervalSince1970.rounded(.down))
            let ms = Int((d.timeIntervalSince1970 * 1000).rounded(.down))
            return """
            Unix (s):   \(sec)
            Unix (ms):  \(ms)
            UTC (Z):    \(fmt(d, TimeZone(identifier: "UTC")!, "Z"))
            GMT+7:      \(fmt(d, tz7, "+07:00"))
            Local:      \(fmt(d, .current, ""))  [\(TimeZone.current.identifier)]
            """
        }
        if t.isEmpty { return "NOW\n" + report(Date()) }
        if let n = Double(t) {
            let isMs = abs(n) >= 1e11
            return "Input read as \(isMs ? "milliseconds" : "seconds")\n" + report(Date(timeIntervalSince1970: isMs ? n / 1000 : n))
        }
        for pat in ["dd-MM-yyyy HH:mm:ss", "dd-MM-yyyy HH:mm", "dd-MM-yyyy", "dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm", "dd/MM/yyyy", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = inputTZ; df.dateFormat = pat; df.isLenient = false
            if let d = df.date(from: t) { return report(d) }
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: t) ?? ISO8601DateFormatter().date(from: t) { return report(d) }
        return "Enter epoch (s/ms) or ISO-8601 (e.g. 2026-10-31T16:00:00Z or ...+07:00)"
    }

    static func regex(_ pattern: String, _ text: String) -> String {
        guard !pattern.isEmpty else { return "Enter a pattern" }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return "Invalid regex" }
        let ns = text as NSString
        let ms = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if ms.isEmpty { return "No match" }
        return ms.enumerated().map { i, m in
            var l = "#\(i + 1) [\(m.range.location)]: \(ns.substring(with: m.range))"
            for g in 1..<max(1, m.numberOfRanges) where m.range(at: g).location != NSNotFound { l += "\n   $\(g) = \(ns.substring(with: m.range(at: g)))" }
            return l
        }.joined(separator: "\n")
    }

    static func uuid7() -> String {
        var b = [UInt8](repeating: 0, count: 16)
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        for i in 0..<6 { b[i] = UInt8((ms >> UInt64(8 * (5 - i))) & 0xff) }
        for i in 6..<16 { b[i] = UInt8.random(in: 0...255) }
        b[6] = (b[6] & 0x0f) | 0x70
        b[8] = (b[8] & 0x3f) | 0x80
        let h = b.map { String(format: "%02x", $0) }.joined()
        let c = Array(h)
        return "\(String(c[0..<8]))-\(String(c[8..<12]))-\(String(c[12..<16]))-\(String(c[16..<20]))-\(String(c[20..<32]))"
    }

    static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        return String((0..<n).map { _ in chars.randomElement()! })
    }
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

struct PasswordGenView: View {
    @State private var length = 20.0
    @State private var upper = true
    @State private var lower = true
    @State private var digits = true
    @State private var symbols = true
    @State private var noAmbiguous = true
    @State private var customSymbols = "!@#$%^&*()-_=+[]{}:,.?"
    @State private var exclude = ""
    @State private var count = 5
    @State private var results: [String] = []
    @State private var vaultName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Length: \(Int(length))").frame(width: 90, alignment: .leading)
                Slider(value: $length, in: 8...128, step: 1)
                Stepper("Count: \(count)", value: $count, in: 1...20).frame(width: 130)
            }
            HStack(spacing: 16) {
                Toggle("A-Z", isOn: $upper)
                Toggle("a-z", isOn: $lower)
                Toggle("0-9", isOn: $digits)
                Toggle("Symbols", isOn: $symbols)
                Toggle("No ambiguous (0O1lI)", isOn: $noAmbiguous)
            }
            HStack {
                TextField("Allowed symbols", text: $customSymbols).textFieldStyle(.roundedBorder).disabled(!symbols)
                TextField("Exclude chars", text: $exclude).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Generate") { generate() }.buttonStyle(.borderedProminent)
                TextField("Vault name", text: $vaultName).textFieldStyle(.roundedBorder).frame(width: 180)
                Text("Entropy ≈ \(Int(entropy)) bits").font(.caption).foregroundStyle(.secondary)
            }
            List(results, id: \.self) { r in
                HStack {
                    Text(r).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(r, forType: .string)
                    }
                    Button("Save to Vault") {
                        guard !vaultName.isEmpty else { return }
                        Vault.set(vaultName, r)
                    }.disabled(vaultName.isEmpty)
                }
            }
        }
        .onAppear { if results.isEmpty { generate() } }
        .onChange(of: length) { _, _ in generate() }
        .onChange(of: upper) { _, _ in generate() }
        .onChange(of: lower) { _, _ in generate() }
        .onChange(of: digits) { _, _ in generate() }
        .onChange(of: symbols) { _, _ in generate() }
        .onChange(of: noAmbiguous) { _, _ in generate() }
        .onChange(of: count) { _, _ in generate() }
    }

    private var pools: [[Character]] {
        let excl = Set(exclude + (noAmbiguous ? "0O1lI|" : ""))
        let defs: [(Bool, String)] = [
            (upper, "ABCDEFGHIJKLMNOPQRSTUVWXYZ"), (lower, "abcdefghijklmnopqrstuvwxyz"),
            (digits, "0123456789"), (symbols, customSymbols),
        ]
        return defs.filter { $0.0 }.map { Array($0.1.filter { !excl.contains($0) }) }.filter { !$0.isEmpty }
    }

    private var entropy: Double {
        let size = Set(pools.flatMap { $0 }).count
        return size > 1 ? length * log2(Double(size)) : 0
    }

    private func generate() {
        let pools = pools
        guard !pools.isEmpty else { results = ["Select at least one character set"]; return }
        let all = pools.flatMap { $0 }
        let n = Int(length)
        results = (0..<count).map { _ in
            var chars = pools.prefix(n).map { $0.randomElement()! }
            while chars.count < n { chars.append(all.randomElement()!) }
            chars.shuffle()
            return String(chars)
        }
    }
}


struct TimeToolView: View {
    @State private var date = Date()
    @State private var zone = "GMT+7"
    @State private var text = ""
    private let zones = ["GMT+7", "UTC", "Local"]

    var tz: TimeZone {
        switch zone {
        case "UTC": return TimeZone(identifier: "UTC")!
        case "Local": return .current
        default: return TimeZone(secondsFromGMT: 7 * 3600)!
        }
    }

    var result: String {
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { return ToolsView.time(text, inputTZ: tz) }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var c2 = Calendar(identifier: .gregorian); c2.timeZone = tz
        return ToolsView.time(String(c2.date(from: c)!.timeIntervalSince1970), inputTZ: tz)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DatePicker("Date & time", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().onChange(of: date) { _, _ in text = "" }
                Picker("Zone", selection: $zone) { ForEach(zones, id: \.self) { Text($0) } }.pickerStyle(.segmented).frame(width: 220)
                Button("Now") { date = Date(); text = "" }
            }
            TextField("Or type: 31-10-2026 14:30:00 · 2026-10-31 · epoch s/ms · ISO-8601", text: $text).textFieldStyle(.roundedBorder)
            Text("Typed dates (dd-MM-yyyy, dd/MM/yyyy, yyyy-MM-dd) are read in the selected zone. Picker values are read in that zone too.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Result").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy seconds") { copy(1) }
                Button("Copy ms") { copy(1000) }
            }
            ScrollView {
                Text(result).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }.padding(6).background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    func copy(_ mult: Int) {
        let key = mult == 1 ? "Unix (s):" : "Unix (ms):"
        guard let line = result.split(separator: "\n").first(where: { $0.hasPrefix(key) }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line.replacingOccurrences(of: key, with: "").trimmingCharacters(in: .whitespaces), forType: .string)
    }
}


enum OutputSearch {
    static func count(_ text: String, _ term: String) -> Int {
        guard !term.isEmpty else { return 0 }
        return text.components(separatedBy: "\n").reduce(0) { $0 + $1.lowercased().components(separatedBy: term.lowercased()).count - 1 }
    }

    static func highlight(_ text: String, term: String, onlyMatches: Bool) -> AttributedString {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return AttributedString(text) }
        var lines = text.components(separatedBy: "\n")
        var numbers = Array(1...max(1, lines.count))
        if onlyMatches {
            let keep = lines.indices.filter { lines[$0].range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            numbers = keep.map { $0 + 1 }
            lines = keep.map { lines[$0] }
            if lines.isEmpty { return AttributedString("No match for \"\(t)\"") }
        }
        let width = String(numbers.last ?? 0).count
        var out = AttributedString()
        for (i, line) in lines.enumerated() {
            var row = AttributedString(line + (i == lines.count - 1 ? "" : "\n"))
            var from = row.startIndex
            while from < row.endIndex, let r = row[from...].range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) {
                row[r].backgroundColor = .yellow.opacity(0.55)
                row[r].foregroundColor = .black
                from = r.upperBound
            }
            if onlyMatches {
                var n = AttributedString(String(repeating: " ", count: width - String(numbers[i]).count) + "\(numbers[i])  ")
                n.foregroundColor = .secondary
                out += n
            }
            out += row
        }
        return out
    }
}

enum HexTool {
    static func convert(_ s: String, decode: Bool) -> String {
        if s.isEmpty { return "" }
        if !decode { return Data(s.utf8).map { String(format: "%02x", $0) }.joined(separator: " ") }
        var h = s.replacingOccurrences(of: "(?i)0x|\\\\x|[\\s,:;-]", with: "", options: .regularExpression)
        guard h.range(of: "^[0-9a-fA-F]*$", options: .regularExpression) != nil else { return "Invalid hex: only 0-9 a-f allowed" }
        if h.count % 2 != 0 { return "Invalid hex: odd number of digits (\(h.count))" }
        var bytes: [UInt8] = []
        while !h.isEmpty {
            bytes.append(UInt8(h.prefix(2), radix: 16)!)
            h.removeFirst(2)
        }
        if let utf8 = String(bytes: bytes, encoding: .utf8) { return utf8 }
        return String(bytes: bytes, encoding: .isoLatin1).map { "(not valid UTF-8, shown as Latin-1)\n" + $0 } ?? "(binary data)"
    }
}
