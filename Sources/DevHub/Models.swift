import Foundation
import Security

struct Profile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "new-profile"
    var group = "dev"
    var kind = "DB"
    var command = ""
    var port = 0
    var workDir = ""
    var reauthPatterns = "Password:\nreauthenticat\nSASL authentication failed\nUnauthorized\nsession expired"
    var reauthSecret = ""
    var autoReconnect = true
}

enum RunState: String {
    case stopped, starting, running, crashed, portConflict, needsReauth

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .crashed: return "Crashed"
        case .portConflict: return "Port conflict"
        case .needsReauth: return "Re-auth needed"
        }
    }
}

enum Store {
    static var dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevHub")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func load<T: Decodable>(_ name: String, default def: T) -> T {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let v = try? JSONDecoder().decode(T.self, from: data) else { return def }
        return v
    }

    static func save<T: Encodable>(_ name: String, _ value: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(value) {
            try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
    }
}

enum Vault {
    static let service = "DevHub"

    static func set(_ name: String, _ value: String) {
        delete(name)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ name: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ name: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        SecItemDelete(q as CFDictionary)
    }

    static func names() -> [String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let arr = out as? [[String: Any]] else { return [] }
        return arr.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    /// Replaces `{{secret:name}}` placeholders with Keychain values.
    static func substitute(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\{\\{secret:([^}]+)\\}\\}") else { return text }
        var result = text
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if let v = get(name), let r = Range(m.range, in: result) {
                result.replaceSubrange(r, with: v)
            }
        }
        return result
    }
}

func shell(_ cmd: String, env: [String: String] = [:], timeout: TimeInterval = 30) -> (out: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", cmd]
    var e = ProcessInfo.processInfo.environment
    env.forEach { e[$0.key] = $0.value }
    p.environment = e
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("failed to run: \(error)", -1) }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
}
