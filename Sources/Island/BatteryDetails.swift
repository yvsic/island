import AppKit
import IOKit
import IOKit.ps
import SwiftUI

/// The slower battery facts: time left, health, and which app is drawing the
/// most power. Read when the island opens, not continuously.
@Observable
final class BatteryDetails {
    struct TopApp: Equatable {
        var name: String
        var bundleID: String?
    }

    /// Minutes until empty (on battery) or until full (charging); nil while macOS is still working it out.
    private(set) var minutes: Int?
    /// Full-charge capacity against the capacity when new, in percent.
    private(set) var health: Int?
    private(set) var cycles: Int?
    private(set) var topApp: TopApp?

    @ObservationIgnored private var refreshedAt = Date.distantPast
    @ObservationIgnored private var previewing = false

    /// Just the time estimate: cheap enough to read every minute.
    func refreshEstimate(charging: Bool) {
        guard !previewing else { return }
        let estimate = Self.minutesRemaining(charging: charging)
        if estimate != minutes { minutes = estimate }
    }

    func refresh(charging: Bool) {
        guard !previewing else { return }
        refreshEstimate(charging: charging)
        guard Date.now.timeIntervalSince(refreshedAt) > 45 else { return }
        refreshedAt = .now
        Task { [weak self] in
            let (health, cycles) = await Task.detached { Self.healthAndCycles() }.value
            self?.health = health
            self?.cycles = cycles
            let lines = await Task.detached { Self.sampleEnergy() }.value
            self?.topApp = Self.pick(from: lines)
        }
    }

    func timeText(charging: Bool, pluggedIn: Bool, percent: Int) -> String {
        if pluggedIn, percent >= 100 || !charging { return charging ? "Charging" : "Not charging" }
        guard let minutes, minutes > 0 else { return charging ? "Charging" : "Working out time left" }
        let text = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
        return charging ? "\(text) until full" : "\(text) left"
    }

    private static func minutesRemaining(charging: Bool) -> Int? {
        if !charging {
            let seconds = IOPSGetTimeRemainingEstimate()
            return seconds > 0 ? Int(seconds / 60) : nil
        }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for item in list {
            if let desc = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
               let minutes = desc[kIOPSTimeToFullChargeKey] as? Int, minutes > 0 { return minutes }
        }
        return nil
    }

    /// Maximum capacity and cycle count, as System Settings reports them.
    nonisolated private static func healthAndCycles() -> (Int?, Int?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil,
              let root = try? JSONSerialization.jsonObject(with: pipe.fileHandleForReading.readDataToEndOfFile()) else {
            return (nil, nil)
        }
        var health: Int?, cycles: Int?
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let text = dict["sppower_battery_health_maximum_capacity"] as? String {
                    health = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
                }
                if let count = dict["sppower_battery_cycle_count"] as? Int { cycles = count }
                dict.values.forEach(walk)
            } else if let list = value as? [Any] {
                list.forEach(walk)
            }
        }
        walk(root)
        return (health, cycles)
    }

    /// Process names by power use, highest first, from a one-second sample.
    nonisolated private static func sampleEnergy() -> [(pid: pid_t, command: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "2", "-s", "1", "-n", "8", "-o", "power", "-stats", "pid,power,command"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // The second sample is the real one: the first has no interval to measure over.
        guard let block = text.components(separatedBy: "PID").last else { return [] }
        return block.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]), (Double(parts[1]) ?? 0) > 0.5 else { return nil }
            return (pid, parts[2].trimmingCharacters(in: .whitespaces))
        }
    }

    /// The first sampled process that belongs to a regular app (helpers count for their app).
    private static func pick(from lines: [(pid: pid_t, command: String)]) -> TopApp? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for line in lines {
            if let app = apps.first(where: { $0.processIdentifier == line.pid })
                ?? apps.first(where: { app in
                    guard let name = app.localizedName, name.count >= 4 else { return false }
                    return line.command.hasPrefix(name) || name.hasPrefix(line.command)
                }) {
                return TopApp(name: app.localizedName ?? line.command, bundleID: app.bundleIdentifier)
            }
        }
        return nil
    }

    /// For snapshots.
    func setPreview(minutes: Int, health: Int, top: String) {
        previewing = true
        self.minutes = minutes
        self.health = health
        cycles = 212
        topApp = TopApp(name: top, bundleID: "com.apple.Safari")
    }
}

/// One quiet line in the open island: charge, time left, health, and the app
/// using the most power.
struct BatteryRow: View {
    let model: IslandModel
    private var power: PowerMonitor { model.power }
    private var details: BatteryDetails { model.battery }

    var body: some View {
        HStack(spacing: 8) {
            BatteryGlyph(fill: Double(power.percent) / 100,
                         color: power.percent <= 20 && !power.isPluggedIn ? .lowRed : (power.isPluggedIn ? .chargeGreen : .white))
            Text("\(power.percent)%")
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            Text(details.timeText(charging: power.isCharging, pluggedIn: power.isPluggedIn, percent: power.percent))
                .foregroundStyle(.white.opacity(0.55))
                .contentTransition(.numericText())
            Spacer(minLength: 6)
            if let top = details.topApp {
                HStack(spacing: 4) {
                    if let id = top.bundleID, let icon = AppIcons.icon(bundleID: id) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                    }
                    Text(top.name).lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.55))
                .help("\(top.name) is using the most power right now")
                .transition(.opacity)
            }
            if let health = details.health {
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill").font(.system(size: 9, weight: .bold))
                    Text("\(health)%").monospacedDigit()
                }
                .foregroundStyle(.white.opacity(0.55))
                .help(details.cycles.map { "Battery health \(health)% · \($0) charge cycles" } ?? "Battery health \(health)%")
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: Layout.batteryRowHeight, alignment: .top)
        .animation(model.prefs.contentIn, value: details.topApp)
    }
}

extension Color {
    static let lowRed = Color(red: 1.0, green: 0.27, blue: 0.23)
}
