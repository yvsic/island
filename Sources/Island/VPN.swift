import AppKit
import Darwin
import Network
import Security
import SwiftUI

// MARK: - Profiles

/// One VLESS server reached over TLS + WebSocket. The whole profile, the
/// UUID included, lives only in the Keychain: nothing about the servers is
/// written to disk in the clear.
struct VPNProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var address: String
    var port: Int
    var uuid: String
    var sni: String
    /// The WebSocket path and Host header. Both optional.
    var path: String = "/"
    var host: String = ""
    /// Everything else the link said (security, type, flow, reality keys…),
    /// so any VLESS link runs exactly as its server expects.
    var params: [String: String]? = nil

    var title: String { name.isEmpty ? address : name }

    /// What's wrong with it, if anything, in a few words.
    var problem: String? {
        if address.trimmingCharacters(in: .whitespaces).isEmpty { return "Address is empty" }
        if !(1...65535).contains(port) { return "Port must be 1 to 65535" }
        // xray takes a real UUID or any id of up to 30 bytes (it hashes that into one).
        let id = uuid.trimmingCharacters(in: .whitespaces)
        if id.isEmpty { return "The link has no user id" }
        if UUID(uuidString: id) == nil, id.utf8.count > 30 { return "The user id in the link is too long" }
        return nil
    }

    /// Reads a `vless://uuid@host:port?security=tls&type=ws&sni=…&path=…&host=…#name` link.
    static func parse(link: String) -> Result<VPNProfile, VPNError> {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("vless://"), let url = URLComponents(string: text),
              let host = url.host, let port = url.port, let user = url.user else {
            return .failure(.message("That isn't a vless:// link"))
        }
        let query = Dictionary((url.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let address = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let profile = VPNProfile(
            name: url.fragment?.removingPercentEncoding ?? "",
            address: address,
            port: port,
            uuid: user.removingPercentEncoding ?? user,
            sni: query["sni"].flatMap { $0.isEmpty ? nil : $0 } ?? query["host"] ?? "",
            path: query["path"].flatMap { $0.isEmpty ? nil : $0 } ?? "/",
            host: query["host"] ?? "",
            params: query
        )
        if let problem = profile.problem { return .failure(.message(problem)) }
        return .success(profile)
    }
}

enum VPNError: Error, Equatable {
    case message(String)
    var text: String { if case .message(let text) = self { text } else { "" } }
}

/// The profiles, kept as one Keychain item that never leaves this Mac
/// (not synced to iCloud, not readable before first unlock).
private enum VPNKeychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.local.island.vpn",
        kSecAttrAccount as String: "profiles",
    ]

    static func load() -> [VPNProfile] {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return [] }
        return (try? JSONDecoder().decode([VPNProfile].self, from: data)) ?? []
    }

    static func save(_ profiles: [VPNProfile]) {
        SecItemDelete(base as CFDictionary)
        guard !profiles.isEmpty, let data = try? JSONEncoder().encode(profiles) else { return }
        var query = base
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false
        SecItemAdd(query as CFDictionary, nil)
    }
}

// MARK: - Controller

/// Runs the bundled xray-core as a child process with a local SOCKS5 and HTTP
/// proxy on 127.0.0.1, and points the Mac's proxy settings at it.
///
/// Always on: it connects at launch, checks the tunnel every 30 s, restarts
/// xray when it dies or stops passing traffic, and reapplies the proxy when a
/// new network appears. While it reconnects the system proxy stays pointed at
/// the dead local port, so apps that follow it fail closed instead of
/// quietly going direct.
@Observable
final class VPNController {
    enum State: Equatable {
        case off, connecting, on, reconnecting
        case failed(String)
    }

    private(set) var state: State = .off
    private(set) var profiles: [VPNProfile] = []
    private(set) var selectedID: UUID?
    /// When it went on, for the elapsed time on the page.
    private(set) var connectedAt: Date?
    var alwaysOn: Bool { didSet { UserDefaults.standard.set(alwaysOn, forKey: Keys.alwaysOn) } }
    /// Keep a shield beside the camera for as long as it's on.
    var showInNotch: Bool {
        didSet { UserDefaults.standard.set(showInNotch, forKey: Keys.showInNotch); onChange?() }
    }

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onEvent: ((IslandAlert) -> Void)?

    /// The user wants it on (as opposed to whether it is on right now).
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var ports: (socks: Int, http: Int)?
    /// The Mac's proxy settings point at us right now.
    private(set) var proxyApplied = false
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastInterfaces: Set<String> = []
    @ObservationIgnored private var output = Data()
    /// Proton VPN, when it's installed: then the page drives Proton instead of xray.
    @ObservationIgnored private(set) var proton: ProtonLink?
    /// Proton was asked to connect and hasn't yet: open its app if it doesn't.
    @ObservationIgnored private var protonNudge: Task<Void, Never>?

    private enum Keys {
        static let alwaysOn = "vpn.alwaysOn"
        static let showInNotch = "vpn.showInNotch"
        static let selected = "vpn.selected"
        static let wanted = "vpn.wanted"
        static let pid = "vpn.pid"
    }

    init() {
        let d = UserDefaults.standard
        alwaysOn = d.object(forKey: Keys.alwaysOn) as? Bool ?? true
        showInNotch = d.object(forKey: Keys.showInNotch) as? Bool ?? false
        selectedID = d.string(forKey: Keys.selected).flatMap(UUID.init(uuidString:))
    }

    var selected: VPNProfile? { profiles.first { $0.id == selectedID } ?? profiles.first }
    var isOn: Bool { state == .on }
    var isBusy: Bool { state == .connecting || state == .reconnecting }
    /// Wanted but not passing traffic: worth the camera's attention.
    var needsAttention: Bool {
        switch state {
        case .reconnecting: true
        case .failed: wanted
        default: false
        }
    }
    static var helperURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/xray")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    // MARK: Lifecycle

    func start() {
        cleanUpAfterCrash()
        if let link = ProtonLink.find() {
            startProton(link)
            return
        }
        profiles = VPNKeychain.load()
        watchNetwork()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSoon() }
        }
        if alwaysOn || UserDefaults.standard.bool(forKey: Keys.wanted), selected != nil { connect() }
    }

    /// Quitting: stop xray and give the Mac its old proxy settings back.
    /// Runs synchronously, since the app is about to exit.
    func shutdown() {
        watchdog?.cancel()
        generation += 1
        stopProcess()
        SystemProxy.queue.sync { SystemProxy.restore() }
        proxyApplied = false
    }

    func toggle() { state == .on || isBusy ? disconnect() : connect() }

    func connect() {
        if proton != nil { protonConnect(); return }
        guard let profile = selected else { state = .failed("Add a server first"); onChange?(); return }
        if let problem = profile.problem { state = .failed(problem); onChange?(); return }
        guard Self.helperURL != nil else { state = .failed("xray is missing from Island.app"); onChange?(); return }
        wanted = true
        UserDefaults.standard.set(true, forKey: Keys.wanted)
        attempt = 0
        launch(profile, reconnecting: false)
    }

    func disconnect() {
        if let proton {
            wanted = false
            protonNudge?.cancel()
            proton.disconnect()
            return
        }
        let wasOn = state == .on
        wanted = false
        UserDefaults.standard.set(false, forKey: Keys.wanted)
        watchdog?.cancel()
        generation += 1
        stopProcess()
        state = .off
        connectedAt = nil
        onChange?()
        if proxyApplied {
            proxyApplied = false
            SystemProxy.queue.async { SystemProxy.restore() }
        }
        if wasOn { onEvent?(.vpn(.off)) }
    }

    func select(_ id: UUID) {
        guard id != selectedID else { return }
        selectedID = id
        UserDefaults.standard.set(id.uuidString, forKey: Keys.selected)
        if wanted, let profile = selected { attempt = 0; launch(profile, reconnecting: state == .on) }
        onChange?()
    }

    func save(_ profile: VPNProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        VPNKeychain.save(profiles)
        if selectedID == nil || profiles.count == 1 { selectedID = profile.id; UserDefaults.standard.set(profile.id.uuidString, forKey: Keys.selected) }
        // Edited the server in use: reconnect with the new details.
        if wanted, profile.id == selected?.id { attempt = 0; launch(profile, reconnecting: true) }
        onChange?()
    }

    func delete(_ id: UUID) {
        let inUse = id == selected?.id
        profiles.removeAll { $0.id == id }
        VPNKeychain.save(profiles)
        if inUse {
            disconnect()
            selectedID = profiles.first?.id
            UserDefaults.standard.set(selectedID?.uuidString, forKey: Keys.selected)
        }
        onChange?()
    }

    // MARK: Proton VPN

    private func startProton(_ link: ProtonLink) {
        proton = link
        link.start()
        // Already on at launch: show it quietly, and keep it on from here.
        if link.status == .on { state = .on; connectedAt = .now; wanted = true }
        link.onStatus = { [weak self] status in self?.protonChanged(status) }
        if alwaysOn, link.status == .off { protonConnect() }
    }

    private func protonConnect() {
        guard let proton else { return }
        wanted = true
        state = .connecting
        onChange?()
        let started = proton.connect()
        // Proton's service won't start on its own (signed out, first run):
        // open its app so the user can connect there.
        protonNudge?.cancel()
        protonNudge = Task { [weak self] in
            try? await Task.sleep(for: .seconds(started ? 12 : 0.5))
            guard let self, !Task.isCancelled, self.state != .on else { return }
            ProtonLink.openApp()
            self.state = .failed("Connect once in Proton VPN to finish setting it up")
            self.onChange?()
        }
    }

    private func protonChanged(_ status: ProtonLink.Status) {
        let wasOn = state == .on
        switch status {
        case .on:
            protonNudge?.cancel()
            state = .on
            if connectedAt == nil { connectedAt = .now }
            if !wasOn { onEvent?(.vpn(.on("Proton VPN"))) }
        case .connecting:
            state = wasOn ? .reconnecting : .connecting
        case .disconnecting:
            break
        case .off:
            connectedAt = nil
            if wanted && alwaysOn && wasOn {
                // Dropped without being asked to: put it back.
                state = .reconnecting
                onEvent?(.vpn(.dropped))
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, self.wanted, self.state != .on else { return }
                    self.protonConnect()
                }
            } else {
                if case .failed = state {} else { state = .off }
                if wasOn { onEvent?(.vpn(.off)) }
            }
        }
        onChange?()
    }

    // MARK: Running xray

    private func launch(_ profile: VPNProfile, reconnecting: Bool) {
        watchdog?.cancel()
        generation += 1
        let gen = generation
        stopProcess()
        state = reconnecting || proxyApplied ? .reconnecting : .connecting
        onChange?()

        guard let socks = LocalPort.free(), let http = LocalPort.free(excluding: socks),
              let helper = Self.helperURL,
              let config = try? XrayConfig.json(profile, socks: socks, http: http) else {
            fail("Couldn't prepare the connection", gen: gen)
            return
        }
        let task = Process()
        task.executableURL = helper
        // The config, UUID included, goes in through a pipe: never written to disk.
        task.arguments = ["run", "-format", "json", "-c", "stdin:"]
        task.environment = ["PATH": "/usr/bin:/bin"]
        let input = Pipe(), out = Pipe()
        task.standardInput = input
        task.standardOutput = out
        task.standardError = out
        output = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor in self?.keepOutput(chunk) }
        }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.processExited(gen: gen) }
        }
        do {
            try task.run()
        } catch {
            fail("Couldn't start xray", gen: gen)
            return
        }
        input.fileHandleForWriting.write(config)
        try? input.fileHandleForWriting.close()
        process = task
        ports = (socks, http)
        UserDefaults.standard.set(Int(task.processIdentifier), forKey: Keys.pid)

        Task { [weak self] in
            // Up to 5 s for the local port to open, then prove traffic flows.
            var listening = false
            for _ in 0..<50 {
                if await LocalPort.isListening(socks) { listening = true; break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, gen == self.generation else { return }
            guard listening else { self.fail(self.lastError ?? "xray didn't start", gen: gen); return }
            let works = await TunnelCheck.passes(httpPort: http)
            guard gen == self.generation else { return }
            guard works else { self.fail("Server didn't answer. Check address, UUID, SNI and path", gen: gen); return }
            let applied = await self.applyProxy(socks: socks, http: http)
            guard gen == self.generation else { return }
            guard applied else { self.wanted = false; self.fail("macOS didn't accept the proxy settings", gen: gen); return }
            let first = self.state != .on
            self.state = .on
            self.attempt = 0
            if self.connectedAt == nil { self.connectedAt = .now }
            self.onChange?()
            if first { self.onEvent?(.vpn(.on(self.selected?.title ?? "VPN"))) }
            self.startWatchdog(gen: gen)
        }
    }

    private func applyProxy(socks: Int, http: Int) async -> Bool {
        let ok = await withCheckedContinuation { done in
            SystemProxy.queue.async { done.resume(returning: SystemProxy.apply(socks: socks, http: http)) }
        }
        proxyApplied = true
        return ok
    }

    private func stopProcess() {
        guard let process else { return }
        self.process = nil
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
            // Give it a moment to close sockets, then make sure.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        }
        UserDefaults.standard.removeObject(forKey: Keys.pid)
    }

    private func processExited(gen: Int) {
        guard gen == generation, wanted else { return }
        process = nil
        fail(lastError ?? "xray stopped", gen: gen)
    }

    /// A failed attempt: keep trying while it's wanted and always-on, or stop.
    private func fail(_ reason: String, gen: Int) {
        guard gen == generation else { return }
        stopProcess()
        // Worked before: keep at it. Never worked: three tries, then say why.
        if wanted && (proxyApplied || attempt < 3) {
            scheduleRetry(reason: reason)
        } else {
            // Always-on stays wanted, so the next network change tries again.
            wanted = wanted && alwaysOn
            if proxyApplied {
                proxyApplied = false
                SystemProxy.queue.async { SystemProxy.restore() }
            }
            state = .failed(reason)
            connectedAt = nil
            onChange?()
        }
    }

    private func scheduleRetry(reason: String) {
        let wasOn = state == .on
        attempt += 1
        state = .reconnecting
        onChange?()
        if wasOn { onEvent?(.vpn(.dropped)) }
        generation += 1
        let gen = generation
        let delay = min(30, 1 << min(attempt - 1, 5))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, gen == self.generation, self.wanted, let profile = self.selected else { return }
            self.launch(profile, reconnecting: true)
        }
    }

    private func startWatchdog(gen: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, gen == self.generation, let http = self.ports?.http else { return }
                if await TunnelCheck.passes(httpPort: http) {
                    misses = 0
                } else {
                    misses += 1
                    if misses >= 2, gen == self.generation { self.scheduleRetry(reason: "Tunnel stopped passing traffic"); return }
                }
            }
        }
    }

    /// Woke from sleep: check right away rather than in up to 30 s.
    private func checkSoon() {
        guard wanted, state == .on, let http = ports?.http else { return }
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if await TunnelCheck.passes(httpPort: http) { return }
            guard let self, gen == self.generation else { return }
            self.scheduleRetry(reason: "Tunnel didn't survive sleep")
        }
    }

    /// A new network service (USB tether, Ethernet) gets the proxy too.
    private func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let names = Set(path.availableInterfaces.map(\.name))
            Task { @MainActor in
                guard let self, names != self.lastInterfaces else { return }
                self.lastInterfaces = names
                if self.wanted, case .failed = self.state { self.connect(); return }
                guard self.proxyApplied, let ports = self.ports else { return }
                SystemProxy.queue.async { _ = SystemProxy.apply(socks: ports.socks, http: ports.http) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "island.vpn.path"))
        pathMonitor = monitor
    }

    /// Island was killed last time with xray running: stop that xray and put
    /// the old proxy settings back before anything else.
    private func cleanUpAfterCrash() {
        let d = UserDefaults.standard
        if let pid = d.object(forKey: Keys.pid) as? Int, pid > 0 {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if proc_pidpath(pid_t(pid), &path, UInt32(path.count)) > 0,
               String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasSuffix("Island.app/Contents/MacOS/xray") {
                kill(pid_t(pid), SIGKILL)
            }
            d.removeObject(forKey: Keys.pid)
        }
        if SystemProxy.hasSaved { SystemProxy.queue.sync { SystemProxy.restore() } }
    }

    private func keepOutput(_ chunk: Data) {
        output.append(chunk)
        if output.count > 4096 { output = output.suffix(2048) }
    }

    /// xray's own last complaint, for the page. Kept in memory only.
    private var lastError: String? {
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n")
        guard let line = lines.last(where: { $0.localizedCaseInsensitiveContains("fail") || $0.localizedCaseInsensitiveContains("error") }) else { return nil }
        return String(line.suffix(90))
    }
}

// MARK: - xray config

private enum XrayConfig {
    private static func user(_ p: VPNProfile) -> [String: Any] {
        var user: [String: Any] = ["id": p.uuid.trimmingCharacters(in: .whitespaces),
                                   "encryption": p.params?["encryption"].flatMap { $0.isEmpty ? nil : $0 } ?? "none", "level": 0]
        if let flow = p.params?["flow"], !flow.isEmpty { user["flow"] = flow }
        return user
    }

    /// Transport and encryption, straight from what the link asked for.
    /// Profiles saved before links were kept whole default to TLS + WebSocket.
    private static func stream(_ p: VPNProfile, sni: String, host: String, path: String) -> [String: Any] {
        let q = p.params ?? ["type": "ws", "security": "tls"]
        func v(_ key: String) -> String? { q[key].flatMap { $0.isEmpty ? nil : $0 } }
        let network = v("type") ?? "tcp"
        let security = v("security") ?? "none"
        var s: [String: Any] = ["network": network, "security": security, "sockopt": ["tcpKeepAliveInterval": 30]]
        switch security {
        case "tls":
            var tls: [String: Any] = ["serverName": sni, "fingerprint": v("fp") ?? "chrome", "allowInsecure": false]
            if let alpn = v("alpn") { tls["alpn"] = alpn.split(separator: ",").map(String.init) }
            else if network == "ws" { tls["alpn"] = ["http/1.1"] }
            s["tlsSettings"] = tls
        case "reality":
            s["realitySettings"] = ["serverName": sni, "fingerprint": v("fp") ?? "chrome", "publicKey": v("pbk") ?? "",
                                    "shortId": v("sid") ?? "", "spiderX": v("spx") ?? ""]
        default: break
        }
        switch network {
        case "ws": s["wsSettings"] = ["path": path, "host": host]
        case "httpupgrade": s["httpupgradeSettings"] = ["path": path, "host": host]
        case "xhttp", "splithttp": s["network"] = "xhttp"; s["xhttpSettings"] = ["path": path, "host": host, "mode": v("mode") ?? "auto"]
        case "grpc": s["grpcSettings"] = ["serviceName": v("servicename") ?? "", "multiMode": v("mode") == "multi"]
        default: break
        }
        return s
    }

    static func json(_ p: VPNProfile, socks: Int, http: Int) throws -> Data {
        let sni = p.sni.isEmpty ? p.address : p.sni
        let host = p.host.isEmpty ? sni : p.host
        var path = p.path.isEmpty ? "/" : p.path
        if !path.hasPrefix("/") { path = "/" + path }
        let config: [String: Any] = [
            // No logs at all: no access log, no DNS log, nothing on disk.
            "log": ["loglevel": "none", "access": "none", "error": "none", "dnsLog": false],
            "inbounds": [
                ["tag": "socks", "listen": "127.0.0.1", "port": socks, "protocol": "socks",
                 "settings": ["auth": "noauth", "udp": true, "ip": "127.0.0.1"]],
                ["tag": "http", "listen": "127.0.0.1", "port": http, "protocol": "http",
                 "settings": ["allowTransparent": false]],
            ],
            "outbounds": [
                ["tag": "proxy", "protocol": "vless",
                 "settings": ["vnext": [["address": p.address, "port": p.port,
                                          "users": [user(p)]]]],
                 "streamSettings": stream(p, sni: sni, host: host, path: path)],
                ["tag": "direct", "protocol": "freedom"],
                ["tag": "block", "protocol": "blackhole"],
            ],
            "routing": [
                // Names go to the server unresolved, so DNS happens there.
                "domainStrategy": "AsIs",
                "rules": [
                    ["type": "field", "ip": ["127.0.0.0/8", "::1/128"], "outboundTag": "block"],
                    ["type": "field", "ip": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fc00::/7", "fe80::/10"],
                     "outboundTag": "direct"],
                ],
            ],
            "policy": ["levels": ["0": ["handshake": 4, "connIdle": 300, "uplinkOnly": 1, "downlinkOnly": 1]]],
        ]
        return try JSONSerialization.data(withJSONObject: config)
    }
}

// MARK: - System proxy

/// The Mac's own proxy settings, through `networksetup`. What each network
/// service had before is saved first and put back on disconnect.
nonisolated enum SystemProxy {
    private static let savedKey = "vpn.savedProxies"
    private static let bypass = ["localhost", "127.0.0.1", "::1", "*.local", "169.254/16"]

    /// Every change goes through here, one at a time, so a disconnect's
    /// restore can't land in the middle of a reconnect's apply.
    static let queue = DispatchQueue(label: "island.vpn.proxy")

    static var hasSaved: Bool { UserDefaults.standard.dictionary(forKey: savedKey) != nil }

    /// True when at least one service reads back pointing at us.
    @discardableResult
    static func apply(socks: Int, http: Int) -> Bool {
        let services = Self.services()
        // Save once per connection: never overwrite the real originals with our own settings.
        if !hasSaved {
            var saved: [String: [String: String]] = [:]
            for service in services { saved[service] = snapshot(service) }
            UserDefaults.standard.set(saved, forKey: savedKey)
        } else if var saved = UserDefaults.standard.dictionary(forKey: savedKey) as? [String: [String: String]] {
            // A service that appeared since: remember its settings too.
            for service in services where saved[service] == nil { saved[service] = snapshot(service) }
            UserDefaults.standard.set(saved, forKey: savedKey)
        }
        for service in services {
            run(["-setsocksfirewallproxy", service, "127.0.0.1", String(socks)])
            run(["-setwebproxy", service, "127.0.0.1", String(http)])
            run(["-setsecurewebproxy", service, "127.0.0.1", String(http)])
            run(["-setproxybypassdomains", service] + bypass)
        }
        return services.contains { service in
            let fields = parse(run(["-getsocksfirewallproxy", service]))
            return fields["Enabled"] == "Yes" && fields["Port"] == String(socks)
        }
    }

    static func restore() {
        guard let saved = UserDefaults.standard.dictionary(forKey: savedKey) as? [String: [String: String]] else { return }
        let present = Set(services())
        for (service, s) in saved where present.contains(service) {
            for (kind, flag) in [("socks", "-setsocksfirewallproxy"), ("web", "-setwebproxy"), ("secure", "-setsecurewebproxy")] {
                let server = s["\(kind).server"] ?? "", port = s["\(kind).port"] ?? "0"
                if !server.isEmpty, port != "0" { run([flag, service, server, port]) }
                let stateFlag = flag.replacingOccurrences(of: "proxy", with: "proxystate")
                run([stateFlag, service, s["\(kind).on"] == "1" ? "on" : "off"])
            }
            let domains = (s["bypass"] ?? "").split(separator: " ").map(String.init)
            run(["-setproxybypassdomains", service] + (domains.isEmpty ? ["Empty"] : domains))
        }
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    private static func snapshot(_ service: String) -> [String: String] {
        var s: [String: String] = [:]
        for (kind, flag) in [("socks", "-getsocksfirewallproxy"), ("web", "-getwebproxy"), ("secure", "-getsecurewebproxy")] {
            let fields = parse(run([flag, service]))
            s["\(kind).on"] = fields["Enabled"] == "Yes" ? "1" : "0"
            s["\(kind).server"] = fields["Server"] ?? ""
            s["\(kind).port"] = fields["Port"] ?? "0"
        }
        let bypass = run(["-getproxybypassdomains", service])
        s["bypass"] = bypass.contains("aren't any") ? "" : bypass.split(separator: "\n").joined(separator: " ")
        return s
    }

    /// Enabled network services; disabled ones are marked with `*`.
    private static func services() -> [String] {
        run(["-listallnetworkservices"]).split(separator: "\n").dropFirst()
            .map(String.init).filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    private static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { out[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    @discardableResult
    private static func run(_ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Small helpers

nonisolated enum LocalPort {
    /// A free TCP port on 127.0.0.1, picked by the kernel.
    static func free(excluding other: Int = 0) -> Int? {
        for _ in 0..<5 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
                }
            }
            let port = Int(UInt16(bigEndian: addr.sin_port))
            if bound, port != 0, port != other { return port }
        }
        return nil
    }

    static func isListening(_ port: Int) async -> Bool {
        await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = UInt16(port).bigEndian
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }.value
    }
}

/// Proves the tunnel carries traffic: one tiny request through the local
/// proxy to a standard "no content" endpoint. No cookies, no cache.
nonisolated enum TunnelCheck {
    static func passes(httpPort: Int) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: httpPort,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: httpPort,
        ]
        config.timeoutIntervalForRequest = 8
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://cp.cloudflare.com/generate_204")!)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0) < 400
    }
}

// MARK: - Page

/// The VPN page: on/off, which server, and always-on. Adding a server
/// happens right here too: one field for the vless:// link, filled in from
/// the clipboard when there's one on it.
struct VPNPanel: View {
    let model: IslandModel
    private var vpn: VPNController { model.vpn }
    @State private var adding = VPNPanel.snapshotLink != nil
    @State private var link = VPNPanel.snapshotLink ?? ""
    /// Snapshots render the add-server view with this link typed in.
    nonisolated(unsafe) static var snapshotLink: String?
    @FocusState private var focused: Bool

    static let bodyHeight: CGFloat = 114

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(adding ? "ADD SERVER" : "VPN")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(height: 16)
            if adding { addRow } else { mainRow }
        }
        .padding(.top, model.contentTop - 4)
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: model.contentTop + Self.bodyHeight, alignment: .top)
        .animation(model.prefs.contentIn, value: vpn.state)
        .animation(model.prefs.contentIn, value: adding)
        .staggered(0)
        .onDisappear { if adding { model.setTyping(false) } }
    }

    // MARK: Main

    @ViewBuilder private var mainRow: some View {
        HStack(spacing: 12) {
            Button { if needsServer { startAdding() } else { vpn.toggle() } } label: {
                VPNLock(state: vpn.state)
                    .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .help(needsServer ? "Add a server" : vpn.isOn || vpn.isBusy ? "Disconnect" : "Connect")

            VStack(alignment: .leading, spacing: 3) {
                Button { if vpn.proton != nil { ProtonLink.openApp() } else if needsServer { startAdding() } else { choose() } } label: {
                    HStack(spacing: 5) {
                        Text(vpn.proton != nil ? "Proton VPN" : vpn.selected?.title ?? "Add a Server").lineLimit(1)
                        Image(systemName: vpn.proton != nil ? "arrow.up.forward" : needsServer ? "plus" : "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold)).opacity(0.5)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(.white.opacity(0.14)))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .help(vpn.proton != nil ? "Open Proton VPN to pick a server" : needsServer ? "Add a server" : "Pick, add or remove a server")
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                option("Always on", isOn: Binding(get: { vpn.alwaysOn }, set: { vpn.alwaysOn = $0 }),
                       help: "Connect at launch and reconnect by itself")
                option("In notch", isOn: Binding(get: { vpn.showInNotch }, set: { vpn.showInNotch = $0 }),
                       help: "Keep a shield beside the camera while connected")
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch vpn.state {
        case .on:
            HStack(spacing: 5) {
                Circle().fill(Color.chargeGreen).frame(width: 6, height: 6)
                Text("Connected").foregroundStyle(Color.chargeGreen)
                if let since = vpn.connectedAt {
                    Text(since, style: .timer).monospacedDigit().foregroundStyle(.white.opacity(0.45))
                }
            }
            .font(.system(size: 11.5, weight: .semibold))
        case .connecting:
            line("Connecting…", .white.opacity(0.55))
        case .reconnecting:
            line(vpn.proxyApplied ? "Reconnecting… traffic held" : "Retrying…", .timerOrange)
        case .failed(let reason):
            line(reason, .lowRed.opacity(0.9))
        case .off:
            line(needsServer ? "Click to add your server" : "Off", .white.opacity(0.45))
        }
    }

    /// No Proton and no server of its own: the first click adds one.
    private var needsServer: Bool { vpn.proton == nil && vpn.profiles.isEmpty }

    // MARK: Adding

    private var parsed: Result<VPNProfile, VPNError>? {
        link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : VPNProfile.parse(link: link)
    }

    private var canAdd: Bool { if case .success = parsed { true } else { false } }

    @ViewBuilder private var addRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: stopAdding) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.14)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .help("Back")
                TextField("Paste your vless:// link", text: $link)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit(add)
                    .onExitCommand(perform: stopAdding)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(.white.opacity(0.1)))
                    .onChange(of: link) { _, text in
                        if text.count > 2000 { link = String(text.prefix(2000)) }
                    }
                Button(action: add) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canAdd ? .black : .white.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(canAdd ? Color.chargeGreen : Color.white.opacity(0.14)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .disabled(!canAdd)
                .help("Add and connect")
            }
            Group {
                switch parsed {
                case .success(let profile):
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.shield.fill")
                        Text(profile.title).foregroundStyle(.white)
                        Text("· \(profile.address):\(String(profile.port)) · press Return")
                    }
                    .foregroundStyle(Color.chargeGreen)
                case .failure(let error):
                    Text(error.text).foregroundStyle(Color.lowRed.opacity(0.9))
                case nil:
                    Text("Copy the link from your VPN provider or server panel, then paste it here")
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(height: 16)
        }
    }

    private func startAdding() {
        // Fill it in from the clipboard when a link is already on it.
        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        link = clip.lowercased().hasPrefix("vless://") ? clip : ""
        // A good link is already copied: nothing to type, just use it.
        if canAdd { add(); return }
        adding = true
        model.setTyping(true)
        Task {
            try? await Task.sleep(for: .milliseconds(140))
            focused = true
        }
    }

    private func stopAdding() {
        adding = false
        link = ""
        focused = false
        model.setTyping(false)
    }

    private func add() {
        guard case .success(var profile) = parsed else { return }
        // The same server again replaces the old entry rather than doubling it.
        if let same = vpn.profiles.first(where: { $0.address == profile.address && $0.port == profile.port && $0.uuid == profile.uuid }) {
            profile.id = same.id
        }
        vpn.save(profile)
        vpn.select(profile.id)
        // The link holds the UUID: don't leave it sitting on the clipboard.
        if NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == link.trimmingCharacters(in: .whitespacesAndNewlines) {
            NSPasteboard.general.clearContents()
        }
        stopAdding()
        if !vpn.isOn && !vpn.isBusy { vpn.connect() }
    }

    // MARK: Bits

    private func line(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func option(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Switch(isOn: isOn)
        }
        .help(help)
    }

    private func choose() {
        let profiles = vpn.profiles
        var titles = profiles.map(\.title)
        var actions: [() -> Void] = profiles.map { profile in { vpn.select(profile.id) } }
        titles.append("Add Server…"); actions.append(startAdding)
        if let current = vpn.selected {
            titles.append("Remove “\(current.title)”"); actions.append { vpn.delete(current.id) }
        }
        let current = profiles.firstIndex { $0.id == vpn.selected?.id } ?? -1
        guard let picked = IslandMenu.chooseIndex(from: titles, current: current, model: model) else { return }
        actions[picked]()
    }
}

/// The connect button's lock: open while off, shut while connected.
/// Connecting, the open lock breathes; when the tunnel comes up the shackle
/// snaps down with a springy pop and a green ripple. Disconnecting, it
/// springs back open with a little shake.
struct VPNLock: View {
    let state: VPNController.State

    @State private var locked = false
    @State private var locks = 0
    @State private var unlocks = 0
    @State private var breathe = false

    var body: some View {
        ZStack {
            // The ripple that rings out as it locks.
            Circle()
                .stroke(Color.chargeGreen, lineWidth: 2)
                .keyframeAnimator(initialValue: Ripple(), trigger: locks) { ring, value in
                    ring.scaleEffect(value.scale).opacity(value.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        LinearKeyframe(1, duration: 0.01)
                        CubicKeyframe(1.55, duration: 0.6)
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(0.9, duration: 0.01)
                        CubicKeyframe(0, duration: 0.6)
                    }
                }
            Circle()
                .fill(locked ? Color.chargeGreen : .white.opacity(busy ? 0.2 : 0.14))
                .animation(.smooth(duration: 0.35), value: locked)
                .animation(.smooth(duration: 0.35), value: busy)
            Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(locked ? .black : .white)
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
                // Unlocking: a quick, springy shake.
                .keyframeAnimator(initialValue: 0.0, trigger: unlocks) { lock, angle in
                    lock.rotationEffect(.degrees(angle))
                } keyframes: { _ in
                    SpringKeyframe(-14, duration: 0.12, spring: .snappy)
                    SpringKeyframe(10, duration: 0.14, spring: .snappy)
                    SpringKeyframe(-5, duration: 0.12, spring: .snappy)
                    SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                }
        }
        // Locking: squash down, then pop past full size and settle.
        .keyframeAnimator(initialValue: 1.0, trigger: locks) { button, scale in
            button.scaleEffect(scale)
        } keyframes: { _ in
            SpringKeyframe(0.86, duration: 0.12, spring: .snappy)
            SpringKeyframe(1.12, duration: 0.2, spring: .bouncy)
            SpringKeyframe(1.0, duration: 0.45, spring: .bouncy(duration: 0.45, extraBounce: 0.15))
        }
        // Waiting on the connection: a slow, soft breath.
        .scaleEffect(breathe ? 1.06 : 1)
        .animation(busy ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .smooth(duration: 0.3), value: breathe)
        .onAppear { locked = state == .on }
        .onChange(of: busy) { _, now in breathe = now }
        .onChange(of: state == .on) { _, on in
            withAnimation(.bouncy(duration: 0.45, extraBounce: 0.1)) { locked = on }
            if on { locks += 1 } else { unlocks += 1 }
        }
    }

    private var busy: Bool { state == .connecting || state == .reconnecting }

    private struct Ripple { var scale = 1.0; var opacity = 0.0 }
}

/// Beside the camera: a shield, green when on, orange while it reconnects.
struct VPNWing: View {
    let model: IslandModel
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: model.vpn.isOn ? "lock.shield.fill" : "exclamationmark.shield.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(model.vpn.isOn ? Color.chargeGreen : Color.timerOrange)
            .symbolEffect(.pulse, isActive: model.vpn.needsAttention)
    }

    static var label: String { "VPN" }
}
