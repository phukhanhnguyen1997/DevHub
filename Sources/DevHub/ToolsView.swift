import SwiftUI
import CryptoKit

enum ToolKind: String, CaseIterable, Identifiable {
    case json = "JSON", yaml = "JSON minify", base64 = "Base64", url = "URL", jwt = "JWT", hash = "Hash", uuid = "UUID", time = "Timestamp", regex = "Regex"
    var id: String { rawValue }
}

struct ToolsView: View {
    @State private var kind: ToolKind = .json
    @State private var input = ""
    @State private var extra = ""
    @State private var decode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $kind) { ForEach(ToolKind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            HStack {
                if [.base64, .url].contains(kind) { Toggle("Decode", isOn: $decode).toggleStyle(.switch) }
                if kind == .regex { TextField("Regex pattern", text: $extra).textFieldStyle(.roundedBorder) }
                if kind == .uuid { Button("Regenerate") { input = String(Int.random(in: 0...Int.max)) } }
            }
            Text(kind == .uuid ? "Generates v4, v7 and ULID-style values" : "Input").font(.caption).foregroundStyle(.secondary)
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
        case .uuid: return "v4:   \(UUID().uuidString.lowercased())\nv7:   \(Self.uuid7())\nrand: \(Self.randomString(24))"
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
        if t.isEmpty { return "Now: \(Int(Date().timeIntervalSince1970)) / \(Date().formatted(.iso8601))" }
        if var n = Double(t) {
            if n > 1e11 { n /= 1000 }
            let d = Date(timeIntervalSince1970: n)
            let f = ISO8601DateFormatter()
            f.timeZone = TimeZone(identifier: "UTC")
            let l = ISO8601DateFormatter()
            l.timeZone = .current
            return "UTC:   \(f.string(from: d))\nLocal: \(l.string(from: d))"
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: t) ?? ISO8601DateFormatter().date(from: t) {
            return "seconds: \(Int(d.timeIntervalSince1970))\nmillis:  \(Int(d.timeIntervalSince1970 * 1000))"
        }
        return "Enter epoch (s/ms) or ISO-8601"
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
