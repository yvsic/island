import AppKit
import SwiftUI

/// `Island --snapshot <dir>` renders every state to PNG, for checking the design
/// without a pointer or music playing.
enum Snapshot {
    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let art = sampleArtwork()
        let song = Track(source: .spotify, id: "1", title: "Midnight City", artist: "M83", album: "Hurry Up",
                         duration: 243, position: 71, isPlaying: true, artworkURL: nil)

        ChargeIndicator.startsFilled = true
        Snapshotting.begin()
        func shot(_ name: String, music: Bool, playing: Bool = true, timer: IslandTimer.State = .idle,
                  expanded: Bool, hovering: Bool = false, charging: Bool = false,
                  level: (LevelMonitor.Kind, Double)? = nil, longTitle: Bool = false,
                  events: [UpcomingEvent]? = nil, weather: WeatherNow? = nil, banner: Bool = false, sunsetIn: Double? = nil, pinCalendar: Bool = false, page: IslandModel.Page = .home,
                  alert: IslandAlert? = nil, recording: Bool = false, call: Bool = false, camera: Bool = false) {
            let model = IslandModel()
            model.notchSize = NSScreen.screens.compactMap(\.notchSize).first ?? CGSize(width: 185, height: 32)
            var track = song
            track.isPlaying = playing
            if longTitle {
                track.title = "Midnight City (Eric Prydz Private Remix) [Extended Version]"
                track.artist = "M83, Eric Prydz, and an Unusually Long List of Featured Artists"
            }
            model.player.setPreview(track: music ? track : nil, artwork: music ? art : nil, banner: banner)
            model.timer.setPreview(timer)
            if let level { model.levels.setSnapshot(level.0, level: level.1) }
            if let events { model.calendar.setPreview(events) } else { model.calendar.setPreviewHidden() }
            model.weather.setPreview(weather, sunsetIn: sunsetIn)
            model.recorder.setPreview(recordingFor: recording ? 42 : nil)
            let zoom = SensorApp(name: "FaceTime", bundleID: "com.apple.FaceTime", pid: 0)
            model.sensors.setPreview(camera: camera, call: call ? CallState(app: zoom, started: .now - 754) : nil)
            model.battery.setPreview(minutes: 222, health: 91, top: "Safari")
            model.power.setPreview(percent: 84, alert: charging)
            model.setPreview(expanded: expanded, hovering: hovering, page: page)
            if let alert { model.raise(alert) }
            model.shelf.setPreview(page == .shelf && !music ? [] : Snapshot.sampleFiles)
            model.setCalendarPinned(pinCalendar)
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.18, green: 0.26, blue: 0.44), Color(red: 0.42, green: 0.3, blue: 0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(.white.opacity(0.12)).frame(height: model.notchSize.height)
                IslandView(model: model)
                // Where the camera is: anything showing through red is hidden on a real Mac.
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                    .fill(.red.opacity(0.45))
                    .frame(width: model.notchSize.width, height: model.notchSize.height)
            }
            .frame(width: NotchController.canvas.width, height: NotchController.canvas.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
            print("wrote \(name).png")
        }

        let running = IslandTimer.State.running(end: .now + 287, total: 300)
        shot("01-idle", music: false, expanded: false)
        shot("02-idle-hover", music: false, expanded: false, hovering: true)
        shot("03-compact-music", music: true, expanded: false)
        shot("04-compact-timer", music: false, timer: running, expanded: false)
        shot("05-compact-both", music: true, timer: running, expanded: false)
        shot("06-expanded-empty", music: false, expanded: true)
        shot("07-expanded-music", music: true, expanded: true)
        shot("08-expanded-music-paused", music: true, playing: false, expanded: true)
        shot("09-expanded-timer", music: false, timer: running, expanded: true)
        shot("10-expanded-both", music: true, timer: running, expanded: true)
        shot("11-ringing", music: true, timer: .ringing, expanded: true)
        shot("12-charging", music: false, expanded: false, charging: true)
        let hour = IslandTimer.State.running(end: .now + 3599, total: 3600)
        let long = IslandTimer.State.running(end: .now + 7199, total: 7200)
        shot("14-compact-hour-timer", music: true, timer: hour, expanded: false)
        shot("15-compact-long-timer", music: false, timer: long, expanded: false)
        shot("16-expanded-long-timer", music: false, timer: long, expanded: true)
        shot("17-volume", music: true, expanded: false, level: (.volume, 0.62))
        shot("18-brightness", music: false, expanded: false, level: (.brightness, 0.8))
        PresetRow.snapshotOpen = false
        shot("24-timer-options-folded", music: false, expanded: true)
        PresetRow.snapshotOpen = true
        let now = Date.now
        let sample = [
            UpcomingEvent(id: "a", title: "Design Review", start: now + 12 * 60, end: now + 72 * 60,
                          isAllDay: false, color: .purple),
            UpcomingEvent(id: "b", title: "Dinner with Sam", start: Calendar.current.date(byAdding: .day, value: 1, to: now)!,
                          end: Calendar.current.date(byAdding: .day, value: 1, to: now)! + 5400, isAllDay: false, color: .orange),
            UpcomingEvent(id: "c", title: "Dentist", start: now + 2 * 86400, end: now + 2 * 86400 + 1800,
                          isAllDay: false, color: .blue),
        ]
        shot("21-calendar-music", music: true, expanded: true, events: sample)
        shot("22-calendar-empty-island", music: false, expanded: true, events: Array(sample.prefix(1)))
        shot("23-calendar-none", music: false, expanded: true, events: [])
        let sunny = WeatherNow(temperature: 22.4, high: 25, low: 14, code: 1, isDay: true, place: "Current Location")
        shot("25-weather-and-events", music: true, expanded: true, events: sample, weather: sunny, sunsetIn: 42)
        shot("26-weather-only", music: false, expanded: true, events: [], weather: sunny, sunsetIn: 42)
        shot("28-song-banner", music: true, expanded: false, banner: true)
        shot("27-calendar-panel", music: false, expanded: true, events: sample, weather: sunny)
        shot("29-calendar-over-music", music: true, expanded: true, events: sample, weather: sunny, pinCalendar: true)
        shot("30-shelf", music: true, expanded: true, page: .shelf)
        shot("31-shelf-empty", music: false, expanded: true, page: .shelf)
        for tab in SettingsPanel.Tab.allCases {
            SettingsPanel.snapshotTab = tab
            shot("32-settings-\(tab.rawValue)", music: true, expanded: true, page: .settings)
        }
        shot("34-record-page", music: true, expanded: true, page: .record)
        shot("35-vpn-page", music: true, expanded: true, page: .vpn)
        VPNPanel.snapshotLink = "vless://11111111-2222-3333-4444-555555555555@vpn.example.com:443?security=tls&type=ws&sni=vpn.example.com&path=%2Fws#Home%20Server"
        shot("36-vpn-add", music: true, expanded: true, page: .vpn)
        VPNPanel.snapshotLink = nil
        shot("35-recording-compact", music: false, expanded: false, recording: true)
        shot("36-bubble-music-timer", music: true, timer: running, expanded: false)
        shot("37-bubble-call-recording", music: false, expanded: false, recording: true, call: true)
        shot("38-camera-dot", music: false, expanded: false, camera: true)
        shot("39-low-battery", music: false, expanded: false, alert: .lowBattery(20))
        shot("40-airpods", music: false, expanded: false,
             alert: .headphones(AirPodsStatus(name: "AirPods Pro", symbol: "airpodspro", left: 82, right: 79, caseLevel: 64)))
        shot("41-rain", music: true, expanded: false, alert: .rain(minutes: 12))
        let lunch = IslandNote(id: "s", source: .messages, sender: "Sam", text: "Are we still on for lunch?")
        shot("42-message-banner", music: false, expanded: false, alert: .note(lunch))
        shot("43-message-open", music: true, expanded: true, alert: .note(lunch))
        shot("44-call-and-recording-open", music: true, expanded: true, recording: true, call: true)
        shot("19-long-title", music: true, expanded: true, longTitle: true)
        shot("20-paused-long-title", music: true, playing: false, timer: running, expanded: true, longTitle: true)
        shot("13-charging-music", music: true, expanded: false, charging: true)
    }

    static let sampleFiles = ["/System/Applications/Calculator.app", "/System/Library/Sounds/Glass.aiff",
                              "/System/Library/CoreServices/DefaultDesktop.heic", "/Library/Fonts", "/etc/hosts"]
        .map { URL(fileURLWithPath: $0) }

    static func sampleArtwork() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.95, green: 0.3, blue: 0.55, alpha: 1),
                                NSColor(red: 0.35, green: 0.2, blue: 0.85, alpha: 1)])?.draw(in: rect, angle: -45)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 105, dy: 105)).fill()
            return true
        }
    }
}
