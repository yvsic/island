import AppKit
import CoreWLAN
import Network
import SwiftUI

/// A measured internet speed, from macOS's own `networkQuality` test.
struct SpeedTest: Codable, Equatable {
    /// Bits per second.
    var down: Double
    var up: Double
    var date: Date
}

/// How fast the network is: what is moving right now (read from the interface's
/// own byte counters, so it costs nothing), the Wi-Fi link rate, and a real
/// speed test on request. It also knows when the network goes away.
@Observable
final class NetworkMonitor {
    /// Bytes per second on the active interface, smoothed a little.
    private(set) var down: Double = 0
    private(set) var up: Double = 0
    /// The Wi-Fi link's negotiated rate in megabits per second.
    private(set) var linkRate: Double?
    /// Signal strength in dBm (closer to zero is stronger).
    private(set) var rssi: Int?
    private(set) var isOnline = true
    private(set) var isWiFi = true
    private(set) var test: SpeedTest?
    private(set) var isTesting = false

    @ObservationIgnored var onOffline: (() -> Void)?
    @ObservationIgnored private let path = NWPathMonitor()
    @ObservationIgnored private var interface = "en0"
    @ObservationIgnored private var sampler: Task<Void, Never>?
    @ObservationIgnored private var last: (received: UInt32, sent: UInt32, time: Date)?
    @ObservationIgnored private var previewing = false
    private static let key = "speedTest"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            test = try? JSONDecoder().decode(SpeedTest.self, from: data)
        }
    }

    func start() {
        path.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            let name = path.availableInterfaces.first?.name
            Task { @MainActor in
                guard let self, !self.previewing else { return }
                let wasOnline = self.isOnline
                self.isOnline = online
                self.isWiFi = wifi || !online
                if let name, name != self.interface {
                    self.interface = name
                    self.last = nil
                }
                if wasOnline, !online { self.onOffline?() }
            }
        }
        path.start(queue: DispatchQueue(label: "island.network-path"))
    }

    /// Sampling runs only while the open island is showing it.
    func setLive(_ live: Bool) {
        guard !previewing else { return }
        guard live else {
            sampler?.cancel()
            sampler = nil
            last = nil
            return
        }
        guard sampler == nil else { return }
        sampler = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                self?.sample()
                if ticks % 5 == 0 { await self?.readLink() }
                ticks += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func sample() {
        guard let counters = Self.counters(for: interface) else { return }
        let now = Date.now
        if let last, now.timeIntervalSince(last.time) > 0.2 {
            let seconds = now.timeIntervalSince(last.time)
            // The counters are 32 bits wide and wrap; wrapping subtraction rides over it.
            let received = Double(counters.received &- last.received) / seconds
            let sent = Double(counters.sent &- last.sent) / seconds
            down = down * 0.4 + received * 0.6
            up = up * 0.4 + sent * 0.6
        }
        last = (counters.received, counters.sent, now)
    }

    /// Bytes in and out of one interface since it came up.
    private static func counters(for name: String) -> (received: UInt32, sent: UInt32)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var entry = list
        while let item = entry {
            defer { entry = item.pointee.ifa_next }
            guard item.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: item.pointee.ifa_name) == name,
                  let raw = item.pointee.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            return (data.ifi_ibytes, data.ifi_obytes)
        }
        return nil
    }

    private func readLink() async {
        let reading = await Task.detached { () -> (Double, Int)? in
            guard let wifi = CWWiFiClient.shared().interface(), wifi.powerOn() else { return nil }
            let rate = wifi.transmitRate()
            return rate > 0 ? (rate, wifi.rssiValue()) : nil
        }.value
        linkRate = reading?.0
        rssi = reading?.1
    }

    // MARK: Speed test

    /// Measures the connection for real. It moves real data for about ten
    /// seconds, so it only ever runs when asked.
    func runTest() {
        guard !isTesting, !previewing else { return }
        isTesting = true
        Task { [weak self] in
            let result = await Task.detached { Self.measure() }.value
            guard let self else { return }
            self.isTesting = false
            guard let result else { return }
            self.test = result
            if let data = try? JSONEncoder().encode(result) { UserDefaults.standard.set(data, forKey: Self.key) }
        }
    }

    nonisolated private static func measure() -> SpeedTest? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        process.arguments = ["-c", "-M", "12"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let down = (root["dl_throughput"] as? NSNumber)?.doubleValue,
              let up = (root["ul_throughput"] as? NSNumber)?.doubleValue, down > 0 else { return nil }
        return SpeedTest(down: down, up: up, date: .now)
    }

    /// Signal strength as zero to three bars.
    var bars: Int {
        guard let rssi else { return 3 }
        return rssi > -60 ? 3 : rssi > -72 ? 2 : rssi > -82 ? 1 : 0
    }

    /// For snapshots.
    func setPreview(down: Double, up: Double, link: Double, test: SpeedTest?) {
        previewing = true
        self.down = down
        self.up = up
        linkRate = link
        rssi = -52
        self.test = test
    }

    /// "12.4 Mbps" or "1.6 MB/s", from bits per second.
    static func format(bits: Double, unit: Preferences.SpeedUnit) -> String {
        switch unit {
        case .bits:
            if bits >= 1_000_000_000 { return String(format: "%.1f Gbps", bits / 1_000_000_000) }
            if bits >= 10_000_000 { return String(format: "%.0f Mbps", bits / 1_000_000) }
            if bits >= 1_000_000 { return String(format: "%.1f Mbps", bits / 1_000_000) }
            return String(format: "%.0f Kbps", bits / 1000)
        case .bytes:
            let bytes = bits / 8
            if bytes >= 10_000_000 { return String(format: "%.0f MB/s", bytes / 1_000_000) }
            if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
            return String(format: "%.0f KB/s", bytes / 1000)
        }
    }
}

/// One quiet line in the open island: what the network is doing now, how fast
/// the Wi-Fi link is, and a button that measures the real speed.
struct NetworkRow: View {
    let model: IslandModel
    private var network: NetworkMonitor { model.network }
    private var unit: Preferences.SpeedUnit { model.prefs.speedUnit }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(network.isOnline ? .white : Color.lowRed)
                .frame(width: 18)
                .contentTransition(.symbolEffect(.replace))
            if !network.isOnline {
                Text("No connection")
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 6)
            } else {
                rate("arrow.down", network.down * 8)
                rate("arrow.up", network.up * 8)
                Spacer(minLength: 6)
                if network.isTesting {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Measuring")
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .transition(.opacity)
                } else if let test = network.test {
                    Text("\(NetworkMonitor.format(bits: test.down, unit: unit)) down · \(NetworkMonitor.format(bits: test.up, unit: unit)) up")
                        .foregroundStyle(.white.opacity(0.55))
                        .monospacedDigit()
                        .help("Measured \(test.date.formatted(.relative(presentation: .named)))")
                        .transition(.opacity)
                } else if let link = network.linkRate {
                    Text("\(Int(link.rounded())) Mbps link")
                        .foregroundStyle(.white.opacity(0.55))
                        .monospacedDigit()
                        .help("The speed your Mac and the router have agreed on. Press Test for the internet speed.")
                }
                Button(network.test == nil ? "Test" : "Retest") { network.runTest() }
                    .buttonStyle(QuietTextButtonStyle())
                    .disabled(network.isTesting)
                    .help("Measure the real speed. Takes about ten seconds and uses some data.")
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: Layout.networkRowHeight, alignment: .top)
        .animation(model.prefs.contentIn, value: network.isTesting)
        .animation(model.prefs.contentIn, value: network.isOnline)
    }

    private var symbol: String {
        guard network.isOnline else { return "wifi.slash" }
        guard network.isWiFi else { return "cable.connector" }
        return ["wifi.exclamationmark", "wifi", "wifi", "wifi"][network.bars]
    }

    private func rate(_ arrow: String, _ bits: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: arrow)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
            Text(NetworkMonitor.format(bits: bits, unit: unit))
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .frame(minWidth: 84, alignment: .leading)
        .animation(.snappy(duration: 0.3).paced, value: Int(bits / 20_000))
    }
}
