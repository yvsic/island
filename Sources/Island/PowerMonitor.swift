import Foundation
import IOKit.ps

/// Watches the power adapter and battery. When the Mac is plugged in, it raises
/// a short "Charging" moment for the island, like iPhone does.
@Observable
final class PowerMonitor {
    private(set) var percent = 100
    private(set) var isPluggedIn = false
    private(set) var isCharging = false
    private(set) var hasBattery = false
    /// True for a few seconds after the charger is connected.
    private(set) var showsChargingAlert = false
    /// Changes every time the alert is raised, to replay its animation.
    private(set) var alertID = 0

    @ObservationIgnored var onChange: (() -> Void)?
    /// Called once as the charge falls to 20% and again at 10%, on battery.
    @ObservationIgnored var onLow: ((Int) -> Void)?
    /// Called when the charger comes out (or the power to it goes).
    @ObservationIgnored var onUnplugged: (() -> Void)?
    @ObservationIgnored private var lastPercent: Int?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    static let alertDuration: Duration = .seconds(3.2)

    func start() {
        read(announce: false)
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.read(announce: true) }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    private func read(announce: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        let wasPluggedIn = isPluggedIn
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        isPluggedIn = type == kIOPSACPowerValue

        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for item in list {
            guard let desc = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            hasBattery = true
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : 0
            isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
        }

        if announce, hasBattery, !isPluggedIn, let before = lastPercent {
            for mark in [20, 10] where before > mark && percent <= mark { onLow?(percent) }
        }
        if hasBattery { lastPercent = percent }
        if announce, hasBattery, wasPluggedIn, !isPluggedIn { onUnplugged?() }

        if announce, hasBattery, isPluggedIn, !wasPluggedIn, Preferences.shared.showChargingAlert {
            raiseAlert()
        } else if !isPluggedIn, showsChargingAlert {
            hideAlert()
        }
    }

    /// Shows the charging moment (also used by Settings' preview).
    func raiseAlert() {
        alertID &+= 1
        showsChargingAlert = true
        onChange?()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.alertDuration)
            guard !Task.isCancelled else { return }
            self?.hideAlert()
        }
    }

    private func hideAlert() {
        hideTask?.cancel()
        showsChargingAlert = false
        onChange?()
    }

    /// For snapshots.
    func setPreview(percent: Int, alert: Bool) {
        self.percent = percent
        hasBattery = true
        isPluggedIn = alert
        isCharging = alert
        showsChargingAlert = alert
    }
}
