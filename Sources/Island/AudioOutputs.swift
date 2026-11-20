import AppKit
import CoreAudio

/// The Mac's sound outputs (speakers, headphones, AirPods, displays), for the
/// output button in the music player.
enum AudioOutputs {
    struct Device: Identifiable, Equatable {
        let id: AudioObjectID
        let name: String
        let transport: UInt32

        /// A symbol that looks like the device.
        var symbol: String {
            let lower = name.lowercased()
            if lower.contains("airpods max") { return "airpodsmax" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            if lower.contains("headphone") || lower.contains("beats") { return "headphones" }
            if transport == kAudioDeviceTransportTypeBuiltIn { return "laptopcomputer" }
            if transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI { return "tv" }
            if transport == kAudioDeviceTransportTypeAirPlay { return "airplayaudio" }
            return "hifispeaker.fill"
        }
    }

    static var all: [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutput(id), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, name: name, transport: uint(id, kAudioDevicePropertyTransportType) ?? 0)
        }
    }

    static var current: Device? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return all.first { $0.id == id }
    }

    static func select(_ device: Device) {
        var id = device.id
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let name = value?.takeRetainedValue() else { return nil }
        return name as String
    }

    private static func uint(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// Shows a menu of outputs under the button; returns once it closes.
    @MainActor
    static func showMenu(from view: NSView?, at point: NSPoint) {
        let menu = NSMenu()
        let currentID = current?.id
        for device in all {
            let item = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: device.symbol, accessibilityDescription: nil)
            item.state = device.id == currentID ? .on : .off
            item.target = OutputMenuTarget.shared
            item.action = #selector(OutputMenuTarget.choose(_:))
            item.representedObject = NSNumber(value: device.id)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: view)
    }
}

final class OutputMenuTarget: NSObject {
    static let shared = OutputMenuTarget()
    @objc func choose(_ item: NSMenuItem) {
        guard let id = (item.representedObject as? NSNumber)?.uint32Value,
              let device = AudioOutputs.all.first(where: { $0.id == id }) else { return }
        AudioOutputs.select(device)
    }
}
