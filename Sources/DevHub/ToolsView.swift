import SwiftUI
import CryptoKit

enum ToolKind: String, CaseIterable, Identifiable {
    case json = "JSON", yaml = "JSON minify", base64 = "Base64", url = "URL", jwt = "JWT", hash = "Hash", uuid = "UUID / ObjectId", password = "Password", time = "Timestamp", regex = "Regex", diff = "Diff", cron = "Cron", sql = "SQL format", csv = "CSV / JSON / INSERT", ts = "JSON → TypeScript"
    var id: String { rawValue }
}

struct ToolsView: View {
    @EnvironmentObject var app: AppState
    @State private var csvMode = "CSV → JSON"
    @State private var input = ""
    @State private var extra = ""
    @State private var decode = false

    var kind: ToolKind { app.toolKind }

    private var toolPicker: some View {
        HStack {
            Picker("Tool", selection: $app.toolKind) { ForEach(ToolKind.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.menu).frame(width: 260)
            Spacer()
        }
    }

    var body: some View {
        if [.password, .uuid, .diff].contains(kind) {
            VStack(alignment: .leading) {
                toolPicker
                switch kind {
                case .password: PasswordGenView()
                case .uuid: IDGenView()
                default: DiffView()
                }
            }.padding()
        } else { mainBody }
    }

    var mainBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolPicker
            HStack {
                if kind == .csv {
                    Picker("", selection: $csvMode) {
                        ForEach(["CSV → JSON", "JSON → CSV", "CSV → INSERT", "JSON → INSERT"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented)
                    if csvMode.hasSuffix("INSERT") { TextField("Table name", text: $extra).textFieldStyle(.roundedBorder).frame(width: 160) }
                }
                if [.base64, .url].contains(kind) { Toggle("Decode", isOn: $decode).toggleStyle(.switch) }
                if kind == .regex { TextField("Regex pattern", text: $extra).textFieldStyle(.roundedBorder) }
            }
            Text(kind == .time ? "Epoch (seconds or ms) or ISO-8601 - empty = now" : kind == .cron ? "Cron expression (5 fields)" : "Input").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $input).font(.system(.body, design: .monospaced)).frame(minHeight: 140).border(.gray.opacity(0.4))
            HStack {
                Text("Output").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
            }
            ScrollView {
                Text(output).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }.padding(6).background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }.padding()
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
        case .cron: return Cron.report(input)
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

    static func time(_ s: String) -> String {
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
