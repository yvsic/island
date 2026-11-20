import AppKit
import SystemConfiguration

/// Drives the Proton VPN app's own connection through the system's VPN
/// service list (the same switch as System Settings › VPN). Proton does the
/// tunnelling, server choice, kill switch and so on; Island only turns it on
/// and off and shows what it's doing.
final class ProtonLink {
    enum Status { case off, connecting, on, disconnecting }

    static let bundleID = "ch.protonvpn.mac"

    let serviceID: String
    private(set) var status: Status = .off
    var onStatus: ((Status) -> Void)?
    private var connection: SCNetworkConnection?

    /// The Proton VPN service, when the app is installed and has set itself up.
    static func find() -> ProtonLink? {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil,
              let prefs = SCPreferencesCreate(nil, "Island" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return nil }
        for service in services {
            guard SCNetworkServiceGetEnabled(service),
                  let name = SCNetworkServiceGetName(service) as String?,
                  name.localizedCaseInsensitiveContains("proton"),
                  let id = SCNetworkServiceGetServiceID(service) as String? else { continue }
            return ProtonLink(serviceID: id)
        }
        return nil
    }

    private init(serviceID: String) {
        self.serviceID = serviceID
    }

    func start() {
        var context = SCNetworkConnectionContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                                 retain: nil, release: nil, copyDescription: nil)
        connection = SCNetworkConnectionCreateWithServiceID(nil, serviceID as CFString, { _, _, info in
            guard let info else { return }
            let link = Unmanaged<ProtonLink>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { link.refresh() }
        }, &context)
        if let connection { SCNetworkConnectionSetDispatchQueue(connection, .main) }
        refresh()
    }

    @discardableResult
    func connect() -> Bool {
        guard let connection else { return false }
        return SCNetworkConnectionStart(connection, nil, false)
    }

    func disconnect() {
        guard let connection else { return }
        SCNetworkConnectionStop(connection, true)
    }

    /// Server choice, kill switch and the rest live in Proton's own app.
    static func openApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func refresh() {
        guard let connection else { return }
        let new: Status = switch SCNetworkConnectionGetStatus(connection) {
        case .connected: .on
        case .connecting: .connecting
        case .disconnecting: .disconnecting
        default: .off
        }
        guard new != status else { return }
        status = new
        onStatus?(new)
    }
}
