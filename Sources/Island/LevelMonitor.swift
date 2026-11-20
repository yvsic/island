import AppKit
import CoreAudio
import AudioToolbox

/// Watches output volume and built-in screen brightness, and raises a short
/// indicator in the island whenever either changes.
@Observable
final class LevelMonitor {
    enum Kind: Equatable { case volume, brightness }

    private(set) var kind: Kind = .volume
    /// 0...1
    private(set) var level: Double = 0
    private(set) var isMuted = false
    private(set) var isShowing = false
    /// Bumped when a key pushes past 0% or 100%, so the bar can stretch like rubber.
    private(set) var nudge = 0
    private(set) var nudgedUp = true

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var device = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var lastVolume: Double?
    @ObservationIgnored private var lastMuted: Bool?
    @ObservationIgnored private var lastBrightness: Double?
    @ObservationIgnored private var brightnessAnchor: (value: Double, time: Date)?
    @ObservationIgnored private var brightnessPoller: Task<Void, Never>?

    static let visibleFor: Duration = .milliseconds(1600)

    func start() {
        watchDefaultDevice()
        attachToOutputDevice()
        brightnessPoller = Task { [weak self] in
            // Brightness has no public change notification, so read it often; it's a cheap call.
            while !Task.isCancelled {
                self?.readBrightness()
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }

    // MARK: Showing

    private func show(_ kind: Kind, level: Double, muted: Bool = false) {
        let prefs = Preferences.shared
        guard kind == .volume ? prefs.showVolumeHUD : prefs.showBrightnessHUD else { return }
        let wasShowing = isShowing
        self.kind = kind
        self.level = max(0, min(1, level))
        self.isMuted = muted
        isShowing = true
        if !wasShowing { onChange?() }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled, let self else { return }
            self.isShowing = false
            self.onChange?()
        }
    }

    /// For Settings' preview and snapshots.
    func preview(_ kind: Kind, level: Double, muted: Bool = false) { show(kind, level: level, muted: muted) }

    func setSnapshot(_ kind: Kind, level: Double) {
        self.kind = kind
        self.level = level
        isShowing = true
    }

    // MARK: Volume

    private func watchDefaultDevice() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attachToOutputDevice() }
        }
    }

    private func attachToOutputDevice() {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != device else { return }
        device = id
        lastVolume = readVolume()
        lastMuted = readMuted()
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                      mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(id, &property, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.volumeChanged(on: id) }
            }
        }
    }

    private func volumeChanged(on id: AudioObjectID) {
        guard id == device, let volume = readVolume() else { return }
        let muted = readMuted() ?? false
        defer { lastVolume = volume; lastMuted = muted }
        guard volume != lastVolume || muted != lastMuted else { return }
        show(.volume, level: volume, muted: muted)
    }

    private func readVolume() -> Double? {
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    private func readMuted() -> Bool? {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    // MARK: Changing levels (when Island handles the keys)

    /// One key press, like macOS: 1/16 of the range, or 1/64 with Option-Shift.
    static func step(fine: Bool) -> Double { fine ? 1.0 / 64 : 1.0 / 16 }

    var canSetVolume: Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    func changeVolume(by delta: Double) {
        guard var volume = readVolume() else { return }
        let old = volume
        // Snap to the step grid, the way the system does.
        let step = abs(delta)
        volume = ((volume / step).rounded() + (delta > 0 ? 1 : -1)) * step
        volume = max(0, min(1, volume))
        noteLimit(old: old, new: volume, up: delta > 0)
        if delta > 0, readMuted() == true { writeMuted(false) }
        var value = Float32(volume)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        // Show at once, even at the ends of the range where nothing changes.
        show(.volume, level: volume, muted: readMuted() ?? false)
    }

    private func noteLimit(old: Double, new: Double, up: Bool) {
        let atTop = up && old >= 0.999 && new >= 0.999
        let atBottom = !up && old <= 0.001 && new <= 0.001
        guard atTop || atBottom else { return }
        nudgedUp = up
        nudge &+= 1
    }

    func toggleMute() {
        let muted = !(readMuted() ?? false)
        writeMuted(muted)
        show(.volume, level: readVolume() ?? level, muted: muted)
    }

    private func writeMuted(_ muted: Bool) {
        var value = UInt32(muted ? 1 : 0)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    var canSetBrightness: Bool { Self.getBrightness != nil && Self.setBrightness != nil && builtInDisplay != nil }

    func changeBrightness(by delta: Double) {
        guard let get = Self.getBrightness, let set = Self.setBrightness, let display = builtInDisplay else { return }
        var current = Float(0)
        guard get(display, &current) == 0 else { return }
        let step = abs(delta)
        var target = ((Double(current) / step).rounded() + (delta > 0 ? 1 : -1)) * step
        target = max(0, min(1, target))
        noteLimit(old: Double(current), new: target, up: delta > 0)
        _ = set(display, Float(target))
        lastBrightness = target
        brightnessAnchor = (target, .now)
        show(.brightness, level: target)
    }

    // MARK: Brightness

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getBrightness: GetBrightness? = {
        guard let symbol = dlsym(displayServices, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }()
    private static let setBrightness: SetBrightness? = {
        guard let symbol = dlsym(displayServices, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: SetBrightness.self)
    }()

    private var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count = UInt32(0)
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private func readBrightness() {
        guard let get = Self.getBrightness, let display = builtInDisplay else { return }
        var value = Float(0)
        guard get(display, &value) == 0 else { return }
        let brightness = Double(value)
        defer { lastBrightness = brightness }
        guard let last = lastBrightness else {
            brightnessAnchor = (brightness, .now)
            return
        }
        // While showing, follow every step so the bar tracks the keys.
        if isShowing, kind == .brightness {
            if abs(brightness - last) > 0.002 { show(.brightness, level: brightness) }
            brightnessAnchor = (brightness, .now)
            return
        }
        // Otherwise only a quick, sizable change counts (a key press or slider),
        // so Auto-Brightness drifting slowly never pops the indicator.
        let anchor = brightnessAnchor ?? (brightness, .now)
        if Date.now.timeIntervalSince(anchor.time) > 0.5 {
            brightnessAnchor = (brightness, .now)
        } else if abs(brightness - anchor.value) > 0.03 {
            show(.brightness, level: brightness)
            brightnessAnchor = (brightness, .now)
        }
    }
}
