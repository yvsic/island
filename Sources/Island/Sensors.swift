import AppKit
import ApplicationServices
import CoreAudio
import CoreMediaIO

/// An app the island names next to an indicator (the one on a call, or using the mic).
struct SensorApp: Equatable {
    var name: String
    var bundleID: String
    var pid: pid_t

    var icon: NSImage? { AppIcons.icon(bundleID: bundleID) }
}

/// App icons by bundle identifier, looked up once.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(bundleID: String) -> NSImage? {
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }
}

struct CallState: Equatable {
    var app: SensorApp
    var started: Date
}

/// Battery levels of headphones that just connected. Any part can be missing:
/// macOS only reports what the headphones tell it.
struct AirPodsStatus: Equatable {
    var name: String
    var symbol: String
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var main: Int?

    var hasLevels: Bool { left != nil || right != nil || caseLevel != nil || main != nil }
}

/// Watches what macOS shows as menu bar dots and small pop-ups: the microphone
/// and camera being used, calls, and headphones connecting. It polls a few
/// cheap system properties rather than asking for any permission.
@Observable
final class SystemSensors {
    /// The app using the microphone, if it's a regular app (not Island itself).
    private(set) var micApp: SensorApp?
    private(set) var cameraInUse = false
    /// A call in FaceTime, Zoom, Discord and the like: the mic is live in one of them.
    private(set) var call: CallState?
    /// The Mac's microphone is muted (by Island's call controls).
    private(set) var isMuted = false
    /// Ticks once a minute, so views that size themselves around a running
    /// clock get a chance to re-measure.
    private(set) var clock = 0

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onHeadphones: ((AirPodsStatus) -> Void)?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var lastOutput: AudioObjectID?
    @ObservationIgnored private var callMisses = 0
    @ObservationIgnored private var polls = 0
    @ObservationIgnored private var savedInputVolume: Float32?
    @ObservationIgnored private var previewing = false

    /// Apps whose live microphone means "on a call".
    static let callApps = ["com.apple.FaceTime", "us.zoom.xos", "com.hnc.Discord", "com.microsoft.teams",
                           "net.whatsapp.WhatsApp", "com.tinyspeck.slackmacgap"]

    func start() {
        lastOutput = AudioOutputs.current?.id
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    private func poll() {
        guard !previewing else { return }
        polls += 1
        if polls % 40 == 0 { clock &+= 1 }
        var changed = false

        let users = Self.micUsers().compactMap { Self.resolve(pid: $0.pid, bundle: $0.bundle) }
        let caller = users.first { app in Self.callApps.contains { app.bundleID.hasPrefix($0) } }
        let mic = caller ?? users.first
        if mic != micApp { micApp = mic; changed = true }

        let camera = Self.cameraRunning()
        if camera != cameraInUse { cameraInUse = camera; changed = true }

        if let caller {
            callMisses = 0
            if call?.app != caller { call = CallState(app: caller, started: call?.started ?? .now); changed = true }
        } else if call != nil {
            // Apps drop the mic for a moment when switching devices: wait before ending.
            callMisses += 1
            if callMisses >= 3 {
                call = nil
                changed = true
                if isMuted { setMuted(false) }
            }
        }

        let muted = Self.inputMuted()
        if muted != isMuted { isMuted = muted; changed = true }

        // Headphones: the sound output just became a Bluetooth device.
        if let output = AudioOutputs.current, output.id != lastOutput {
            lastOutput = output.id
            if output.transport == kAudioDeviceTransportTypeBluetooth || output.transport == kAudioDeviceTransportTypeBluetoothLE {
                announce(output)
            }
        }
        if changed { onChange?() }
    }

    // MARK: Headphones

    private func announce(_ device: AudioOutputs.Device) {
        let name = device.name, symbol = device.symbol == "hifispeaker.fill" ? "headphones" : device.symbol
        Task { [weak self] in
            // Battery levels arrive a moment after the connection.
            try? await Task.sleep(for: .seconds(2))
            let levels = await Task.detached { Self.bluetoothLevels(named: name) }.value
            self?.onHeadphones?(AirPodsStatus(name: name, symbol: symbol, left: levels["Left"], right: levels["Right"],
                                              caseLevel: levels["Case"], main: levels["Main"]))
        }
    }

    /// Battery levels macOS knows for a connected Bluetooth device, by part.
    nonisolated private static func bluetoothLevels(named name: String) -> [String: Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let section = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = section["device_connected"] as? [[String: Any]] else { return [:] }
        for entry in connected {
            guard let info = entry[name] as? [String: Any] else { continue }
            var levels: [String: Int] = [:]
            for part in ["Left", "Right", "Case", "Main"] {
                if let text = info["device_batteryLevel\(part)"] as? String,
                   let value = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) {
                    levels[part] = value
                }
            }
            return levels
        }
        return [:]
    }

    // MARK: Microphone and camera

    /// Processes with the microphone open right now.
    private static func micUsers() -> [(pid: pid_t, bundle: String)] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return ids.compactMap { id in
            guard let running: UInt32 = value(id, kAudioProcessPropertyIsRunningInput), running != 0,
                  let pid: pid_t = value(id, kAudioProcessPropertyPID), pid != me else { return nil }
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let ok = AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr
            return (pid, ok ? (bundle?.takeRetainedValue() as String?) ?? "" : "")
        }
    }

    private static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    /// Maps a process to the regular app it belongs to. System daemons that
    /// listen in the background (Siri and friends) resolve to nothing.
    private static func resolve(pid: pid_t, bundle: String) -> SensorApp? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        // FaceTime's audio runs in a helper daemon.
        if bundle.contains("avconferenced"),
           let faceTime = apps.first(where: { $0.bundleIdentifier == "com.apple.FaceTime" }) {
            return SensorApp(name: "FaceTime", bundleID: "com.apple.FaceTime", pid: faceTime.processIdentifier)
        }
        let owner = apps.first { $0.processIdentifier == pid }
            ?? apps.filter { app in
                guard let id = app.bundleIdentifier, !id.isEmpty else { return false }
                return bundle.hasPrefix(id)
            }.max { ($0.bundleIdentifier ?? "").count < ($1.bundleIdentifier ?? "").count }
        guard let owner, let id = owner.bundleIdentifier else { return nil }
        return SensorApp(name: owner.localizedName ?? id, bundleID: id, pid: owner.processIdentifier)
    }

    /// Whether any camera is streaming to some app.
    private static func cameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size = UInt32(0), used = UInt32(0)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == noErr else { return false }
        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        for id in ids {
            var running = UInt32(0)
            if CMIOObjectGetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == noErr,
               running != 0 { return true }
        }
        return false
    }

    // MARK: Mute

    private static var inputDevice: AudioObjectID? {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func inputMuted() -> Bool {
        guard let device = inputDevice else { return false }
        if let muted: UInt32 = value(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput) { return muted != 0 }
        if let volume: Float32 = value(device, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput) { return volume < 0.001 }
        return false
    }

    /// Mutes the Mac's microphone for every app, which works in any call app.
    func setMuted(_ muted: Bool) {
        guard let device = Self.inputDevice else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var flag = UInt32(muted ? 1 : 0)
        if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &flag) != noErr {
            // No mute switch on this microphone: turn its level all the way down instead.
            address.mSelector = kAudioDevicePropertyVolumeScalar
            if muted {
                savedInputVolume = Self.value(device, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput)
            }
            var level = muted ? Float32(0) : (savedInputVolume ?? 0.7)
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
        }
        isMuted = Self.inputMuted()
        onChange?()
    }

    // MARK: Leaving a call

    /// Presses the call app's own Leave / End button, found through Accessibility.
    /// Returns false if it couldn't (no permission, or no such button on screen).
    func leaveCall() async -> Bool {
        guard let call, AXIsProcessTrusted() else { return false }
        let pid = call.app.pid
        return await Task.detached { Self.pressLeave(pid: pid) }.value
    }

    nonisolated private static func pressLeave(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        // Electron apps (Discord, Slack) only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let words = ["leave", "end call", "end meeting", "hang up", "disconnect", "end"]
        var queue: [AXUIElement] = [app]
        var seen = 0
        while !queue.isEmpty, seen < 6000 {
            let element = queue.removeFirst()
            seen += 1
            if string(element, kAXRoleAttribute) == kAXButtonRole as String {
                let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                    .compactMap { string(element, $0)?.lowercased() }.joined(separator: " ")
                if words.contains(where: { word in label == word || label.hasPrefix(word + " ") || label.contains(" " + word) }) {
                    return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list)
            }
        }
        return false
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: Previews

    /// For snapshots and Settings previews: pretend, and stop polling.
    func setPreview(mic: SensorApp? = nil, camera: Bool = false, call: CallState? = nil) {
        previewing = true
        micApp = mic ?? call?.app
        cameraInUse = camera
        self.call = call
    }
}

extension Date {
    /// "0:42", "12:05" or "1:02:33" since this moment.
    func elapsedText(at now: Date = .now) -> String {
        let s = max(0, Int(now.timeIntervalSince(self)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
