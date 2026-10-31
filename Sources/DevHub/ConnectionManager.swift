import Foundation
import Darwin
import AppKit
import Network

@MainActor
final class ConnectionManager: ObservableObject {
    @Published var profiles: [Profile] = Store.load("profiles.json", default: [Profile]())
    @Published var states: [UUID: RunState] = [:]
    @Published var logs: [UUID: String] = [:]

    private var procs: [UUID: Process] = [:]
    private var inputs: [UUID: FileHandle] = [:]
    private var intentional: Set<UUID> = []
    private var retries: [UUID: Int] = [:]
    private var timer: Timer?
    private var authTimer: Timer?
    private var desired: Set<UUID> = []
    private var pathMonitor: NWPathMonitor?
    private var lastPathOK = true
    private let maxLog = 200_000

    @Published var gcloudAuthExpired = false
    @Published var adcExpired = false
    @Published var restoreLast: Bool = UserDefaults.standard.bool(forKey: "restoreLast") {
        didSet { UserDefaults.standard.set(restoreLast, forKey: "restoreLast") }
    }

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.healthCheck() }
        }
        authTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkGoogleAuth() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self?.recover(reason: "wake from sleep") }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        let mon = NWPathMonitor()
        mon.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if ok && !self.lastPathOK {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.recover(reason: "network change") }
                }
                self.lastPathOK = ok
            }
        }
        mon.start(queue: .global())
        pathMonitor = mon

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.launchStart() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkGoogleAuth() }
    }

    // MARK: session / auto-start

    private func launchStart() {
        let last = Set((UserDefaults.standard.array(forKey: "lastSession") as? [String] ?? []).compactMap(UUID.init))
        for p in profiles where p.autoStart || (restoreLast && last.contains(p.id)) { start(p) }
    }

    /// Remembers what was running, then stops every child so no orphaned tunnels keep ports busy.
    func shutdown() {
        let active = profiles.filter { procs[$0.id] != nil }.map { $0.id.uuidString }
        UserDefaults.standard.set(active, forKey: "lastSession")
        timer?.invalidate()
        for p in profiles { if let proc = procs[p.id] { Self.killTree(proc.processIdentifier) } }
    }

    /// After sleep or a network change, restart tunnels the user wanted that lost their port.
    func recover(reason: String) {
        for p in profiles where desired.contains(p.id) && state(p) != .needsReauth {
            let dead = procs[p.id] == nil
            let portDown = p.port > 0 && !Self.portOpen(p.port)
            guard dead || portDown else { continue }
            append(p.id, "[DevHub] reconnecting after \(reason)\n")
            retries[p.id] = 0
            if let proc = procs[p.id] {
                intentional.insert(p.id)
                Self.killTree(proc.processIdentifier)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.start(p) }
            } else { start(p) }
        }
        checkGoogleAuth()
    }

    // MARK: google auth pre-check

    func usesGcloud(_ p: Profile) -> Bool { p.command.contains("gcloud") }
    func usesADC(_ p: Profile) -> Bool { p.command.contains("cloud-sql-proxy") }

    func checkGoogleAuth() {
        let needGcloud = profiles.contains { usesGcloud($0) && procs[$0.id] != nil }
        let needADC = profiles.contains { usesADC($0) && procs[$0.id] != nil }
        guard needGcloud || needADC else { gcloudAuthExpired = false; adcExpired = false; return }
        DispatchQueue.global().async {
            let g = needGcloud ? shell("gcloud auth print-access-token >/dev/null 2>&1", timeout: 20).code != 0 : false
            let a = needADC ? shell("gcloud auth application-default print-access-token >/dev/null 2>&1", timeout: 20).code != 0 : false
            Task { @MainActor in
                if g && !self.gcloudAuthExpired { Self.notify("gcloud login expired", "Run: gcloud auth login") }
                if a && !self.adcExpired { Self.notify("gcloud ADC expired", "Run: gcloud auth application-default login") }
                self.gcloudAuthExpired = g
                self.adcExpired = a
            }
        }
    }

    func googleLogin(adc: Bool) {
        let cmd = adc ? "gcloud auth application-default login" : "gcloud auth login"
        DispatchQueue.global().async {
            _ = shell(cmd, timeout: 300)
            Task { @MainActor in self.checkGoogleAuth() }
        }
    }

    // MARK: import / export

    func exportProfiles(to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(profiles) { try? d.write(to: url) }
    }

    @discardableResult
    func importProfiles(from url: URL) -> Int {
        guard let d = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Profile].self, from: d) else { return 0 }
        for var p in list {
            if let existing = profiles.first(where: { $0.name == p.name && $0.group == p.group }) { p.id = existing.id }
            upsert(p)
        }
        return list.count
    }

    func state(_ p: Profile) -> RunState { states[p.id] ?? .stopped }

    var overall: RunState {
        let all = profiles.map { state($0) }
        if all.contains(.needsReauth) { return .needsReauth }
        if all.contains(where: { $0 == .crashed || $0 == .portConflict }) { return .crashed }
        if all.contains(.running) { return .running }
        if all.contains(.starting) { return .starting }
        return .stopped
    }

    func persist() { Store.save("profiles.json", profiles) }

    func upsert(_ p: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
        persist()
    }

    func remove(_ p: Profile) {
        stop(p)
        profiles.removeAll { $0.id == p.id }
        persist()
    }

    // MARK: lifecycle

    func start(_ p: Profile) {
        guard procs[p.id] == nil else { return }
        intentional.remove(p.id)
        desired.insert(p.id)
        if p.port > 0 && Self.portOpen(p.port) {
            states[p.id] = .portConflict
            append(p.id, "[DevHub] port \(p.port) is already in use - free it in the Ports tab\n")
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // `script` gives the command a real controlling TTY so gcloud can prompt for passwords.
        proc.arguments = ["-q", "/dev/null", "/bin/zsh", "-lc", Vault.substitute(p.command)]
        if !p.workDir.isEmpty { proc.currentDirectoryURL = URL(fileURLWithPath: (p.workDir as NSString).expandingTildeInPath) }
        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = outPipe

        let id = p.id
        let patterns = p.reauthPatterns
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.received(id, s, patterns: patterns) }
        }
        proc.terminationHandler = { [weak self] pr in
            outPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in self?.didExit(p, proc: pr) }
        }
        do {
            try proc.run()
            procs[id] = proc
            inputs[id] = inPipe.fileHandleForWriting
            states[id] = .starting
            append(id, "[DevHub] started: \(p.command)\n")
        } catch {
            states[id] = .crashed
            append(id, "[DevHub] failed to start: \(error)\n")
        }
    }

    func stop(_ p: Profile) {
        desired.remove(p.id)
        intentional.insert(p.id)
        retries[p.id] = 0
        if let proc = procs[p.id] { Self.killTree(proc.processIdentifier) } else { states[p.id] = .stopped }
    }

    func restart(_ p: Profile) {
        if procs[p.id] != nil {
            stop(p)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start(p) }
        } else { start(p) }
    }

    func isActive(_ p: Profile) -> Bool { procs[p.id] != nil }

    func toggle(_ p: Profile) { isActive(p) ? stop(p) : start(p) }

    func startGroup(_ g: String) { profiles.filter { $0.group == g }.forEach(start) }
    func stopGroup(_ g: String) { profiles.filter { $0.group == g }.forEach(stop) }

    func stopAll() { profiles.forEach(stop) }

    // MARK: re-auth

    /// Sends the password to the running prompt, or restarts the process if it already exited.
    func reauth(_ p: Profile, password: String? = nil) {
        let pw = password ?? (p.reauthSecret.isEmpty ? nil : Vault.get(p.reauthSecret))
        guard let pw else { return }
        if procs[p.id] != nil, let h = inputs[p.id] {
            h.write(Data((pw + "\n").utf8))
            states[p.id] = .starting
            append(p.id, "[DevHub] re-auth password sent\n")
        } else {
            start(p)
        }
    }

    func hasStoredSecret(_ p: Profile) -> Bool { !p.reauthSecret.isEmpty && Vault.get(p.reauthSecret) != nil }

    // MARK: internals

    private func received(_ id: UUID, _ raw: String, patterns: String) {
        let text = Self.clean(raw)
        append(id, text)
        let pats = patterns.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        for pat in pats {
            if text.range(of: pat, options: [.regularExpression, .caseInsensitive]) != nil {
                if states[id] != .needsReauth {
                    states[id] = .needsReauth
                    let name = profiles.first { $0.id == id }?.name ?? "profile"
                    Self.notify("Re-authentication needed", name)
                }
                return
            }
        }
    }

    private func didExit(_ p: Profile, proc: Process) {
        guard procs[p.id] === proc else { return }
        procs[p.id] = nil
        inputs[p.id] = nil
        append(p.id, "[DevHub] exited with status \(proc.terminationStatus)\n")
        if intentional.remove(p.id) != nil {
            states[p.id] = .stopped
            return
        }
        let wasReauth = states[p.id] == .needsReauth
        if !wasReauth { states[p.id] = .crashed }
        let n = retries[p.id, default: 0]
        if p.autoReconnect && !wasReauth && n < 5 {
            retries[p.id] = n + 1
            let delay = Double(min(30, 2 << n))
            append(p.id, "[DevHub] auto-reconnect #\(n + 1) in \(Int(delay))s\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.state(p) == .crashed else { return }
                self.start(p)
            }
        }
    }

    private func healthCheck() {
        for p in profiles where procs[p.id] != nil && p.port > 0 {
            let open = Self.portOpen(p.port)
            let s = state(p)
            if open && (s == .starting || s == .needsReauth) {
                states[p.id] = .running
                retries[p.id] = 0
            } else if !open && s == .running {
                states[p.id] = .starting
            }
        }
        // profiles without a port are considered running once started
        for p in profiles where procs[p.id] != nil && p.port == 0 && state(p) == .starting {
            states[p.id] = .running
        }
    }

    private func append(_ id: UUID, _ s: String) {
        var cur = logs[id, default: ""] + s
        if cur.count > maxLog { cur = String(cur.suffix(maxLog / 2)) }
        logs[id] = cur
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }

    nonisolated static func portOpen(_ port: Int) -> Bool {
        func tryConnect(_ family: Int32) -> Bool {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            if family == AF_INET {
                var a = sockaddr_in()
                a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                a.sin_family = sa_family_t(AF_INET)
                a.sin_port = in_port_t(port).bigEndian
                a.sin_addr.s_addr = inet_addr("127.0.0.1")
                return withUnsafePointer(to: &a) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
                }
            }
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = in_port_t(port).bigEndian
            a.sin6_addr = in6addr_loopback
            return withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
            }
        }
        return tryConnect(AF_INET) || tryConnect(AF_INET6)
    }

    nonisolated static func killTree(_ pid: Int32) {
        let kids = shell("pgrep -P \(pid)", timeout: 3).out.split(separator: "\n").compactMap { Int32($0) }
        kids.forEach { killTree($0) }
        kill(pid, SIGTERM)
    }

    static func notify(_ title: String, _ body: String) {
        let t = title.replacingOccurrences(of: "\"", with: "'")
        let b = body.replacingOccurrences(of: "\"", with: "'")
        DispatchQueue.global().async {
            _ = shell("osascript -e 'display notification \"\(b)\" with title \"\(t)\" sound name \"Glass\"'", timeout: 5)
        }
    }
}
