import AppKit
import ApplicationServices

/// Takes over the volume, mute, and brightness keys so macOS's own pop-up never
/// shows: Island changes the level itself and shows it in the island instead.
/// Needs Accessibility permission; without it the keys work as normal.
@Observable
final class MediaKeys {
    /// True while the keys are being handled by Island.
    private(set) var isActive = false
    private(set) var isTrusted = AXIsProcessTrusted()

    @ObservationIgnored private let levels: LevelMonitor
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var trustWatcher: Task<Void, Never>?

    // Media key codes (IOKit's NX_KEYTYPE_*).
    private enum Key: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    }

    init(levels: LevelMonitor) {
        self.levels = levels
    }

    /// Starts or stops to match the setting and the permission.
    func update() {
        isTrusted = AXIsProcessTrusted()
        KeyLog.write("update: setting=\(Preferences.shared.hideSystemHUD) trusted=\(isTrusted) active=\(isActive)")
        if Preferences.shared.hideSystemHUD {
            if isTrusted { startTap() } else { stopTap() }
            watchTrust()
        } else {
            stopTap()
            trustWatcher?.cancel()
            trustWatcher = nil
        }
    }

    /// Shows the system prompt and opens the Accessibility list.
    func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        watchTrust()
    }

    /// Permission can be granted (or revoked) at any time in System Settings.
    private func watchTrust() {
        guard trustWatcher == nil else { return }
        trustWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                let trusted = AXIsProcessTrusted()
                if trusted != self.isTrusted || trusted != self.isActive { self.update() }
            }
        }
    }

    /// Debug: presses Volume Down then Volume Up through the system and reports
    /// whether Island caught them, then exits.
    func selfTest() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            print("trusted=\(AXIsProcessTrusted()) active=\(isActive)")
            for key in [Key.soundDown, .soundUp] {
                for down in [true, false] {
                    let data1 = (key.rawValue << 16) | ((down ? 0xA : 0xB) << 8)
                    let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                                   modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                                                   timestamp: 0, windowNumber: 0, context: nil,
                                                   subtype: 8, data1: data1, data2: -1)
                    event?.cgEvent?.post(tap: .cghidEventTap)
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            print("handled=\(handledCount) showing=\(levels.isShowing) kind=\(levels.kind) level=\(levels.level)")
            exit(0)
        }
    }
    @ObservationIgnored private var handledCount = 0

    // MARK: Event tap

    private func startTap() {
        guard tap == nil else { return }
        // NX_SYSDEFINED carries media and brightness keys; key down/up only feed the debug log.
        var mask = CGEventMask(1 << 14)
        if KeyLog.enabled { mask |= CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        // The HID-level tap sees keys before the system acts on them; fall back to the session tap.
        var created: CFMachPort?
        var location = "hid"
        for place in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            created = CGEvent.tapCreate(tap: place, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: mediaKeyCallback, userInfo: context)
            if created != nil { break }
            location = "session"
        }
        KeyLog.write("tap \(created == nil ? "FAILED" : "created at \(location)") trusted=\(AXIsProcessTrusted())")
        guard let tap = created else {
            isActive = false
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isActive = true
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isActive = false
    }

    /// Returns true when Island handled the key and macOS shouldn't see it.
    fileprivate func shouldSwallow(type: CGEventType, event: CGEvent) -> Bool {
        // macOS switches a slow tap off; switch it straight back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if KeyLog.enabled {
            if type == .keyDown || type == .keyUp {
                // Only function-row keys, never ordinary typing.
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                guard [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 144, 145, 160, 131, 176, 177, 179].contains(code) else {
                    return false
                }
                KeyLog.write("key \(type == .keyDown ? "down" : "up") code=\(event.getIntegerValueField(.keyboardEventKeycode))")
            } else if type.rawValue == 14, let ns = NSEvent(cgEvent: event) {
                KeyLog.write("sysdefined subtype=\(ns.subtype.rawValue) data1=0x\(String(ns.data1, radix: 16))")
            } else {
                KeyLog.write("event type=\(type.rawValue)")
            }
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return false
        }
        let data = ns.data1
        guard let key = Key(rawValue: (data & 0xFFFF_0000) >> 16) else { return false }
        let isDown = ((data & 0xFF00) >> 8) == 0xA
        let fine = ns.modifierFlags.contains([.option, .shift])
        let prefs = Preferences.shared

        switch key {
        case .soundUp, .soundDown, .mute:
            guard prefs.showVolumeHUD, levels.canSetVolume else { return false }
            if isDown {
                switch key {
                case .mute: levels.toggleMute()
                case .soundUp: levels.changeVolume(by: LevelMonitor.step(fine: fine))
                default: levels.changeVolume(by: -LevelMonitor.step(fine: fine))
                }
            }
        case .brightnessUp, .brightnessDown:
            guard prefs.showBrightnessHUD, levels.canSetBrightness else { return false }
            if isDown {
                let step = LevelMonitor.step(fine: fine)
                levels.changeBrightness(by: key == .brightnessUp ? step : -step)
            }
        }
        // Swallow both press and release so macOS shows nothing.
        handledCount += 1
        KeyLog.write("  swallowed key \(key)")
        return true
    }
}

nonisolated private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let keys = Unmanaged<MediaKeys>.fromOpaque(refcon).takeUnretainedValue()
    // The tap's run loop source is on the main run loop.
    nonisolated(unsafe) let mainEvent = event
    let swallow = MainActor.assumeIsolated { keys.shouldSwallow(type: type, event: mainEvent) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// Debug log of key events, on when `defaults write com.local.island logKeys -bool true`.
/// Written to ~/Library/Logs/Island-keys.log.
enum KeyLog {
    static let enabled = UserDefaults.standard.bool(forKey: "logKeys")
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Island-keys.log")

    static func write(_ line: String) {
        guard enabled else { return }
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
