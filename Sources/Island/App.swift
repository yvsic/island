import AppKit
import ServiceManagement
import SwiftUI

@main
struct IslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        #if ISLAND_RELEASE_HARDENING
        AntiTamper.harden()
        #endif
    }

    // Island lives in the notch only: no menu bar item, no windows.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel()
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second, independent call: `harden()` is idempotent, so this just
        // means an attacker has to find and patch two call sites, not one.
        #if ISLAND_RELEASE_HARDENING
        AntiTamper.harden()
        #endif
        // Every `--flag` below is a dev/testing convenience (snapshots, probes,
        // demo playback, forced recordings) with no reason to exist in a build
        // anyone else runs: a release binary doesn't even compile this in, so
        // there's no runtime check to patch around and no flag names sitting
        // in the string table hinting at internal state to dump for free.
        #if !ISLAND_RELEASE_HARDENING
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot") {
            let dir = i + 1 < args.count ? args[i + 1] : FileManager.default.currentDirectoryPath + "/shots"
            Snapshot.run(into: URL(fileURLWithPath: dir))
            exit(0)
        }
        #endif
        NSApp.setActivationPolicy(.accessory)
        controller = NotchController(model: model)
        model.player.start()
        model.power.start()
        model.levels.start()
        model.keys?.update()
        model.calendar.start()
        model.weather.start()
        model.sensors.start()
        model.notes.start()
        Updater.shared.start()
        model.vpn.start()
        // Ask once for the permission the key takeover needs.
        if Preferences.shared.hideSystemHUD, let keys = model.keys, !keys.isTrusted,
           !UserDefaults.standard.bool(forKey: "askedAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedAccessibility")
            keys.requestPermission()
        }
        #if !ISLAND_RELEASE_HARDENING
        if args.contains("--test-keys") { model.keys?.selfTest() }
        // `--start-timer <minutes>` starts a timer at launch (handy for testing).
        if let i = args.firstIndex(of: "--start-timer"), i + 1 < args.count, let minutes = Int(args[i + 1]) {
            model.timer.start(minutes: minutes)
        }
        // `--settings` opens Settings; `--demo` opens and closes the island once.
        if args.contains("--settings") {
            model.setExpanded(true)
            model.setPage(.settings)
        }
        if args.contains("--preview-volume") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                for step in [0.4, 0.5, 0.6, 0.7] {
                    model.levels.preview(.volume, level: step)
                    try? await Task.sleep(for: .milliseconds(220))
                }
            }
        }
        if args.contains("--demo-music") {
            // Sample track playing, then open and close, to watch the cover morph.
            let song = Track(source: .spotify, id: "demo", title: "Midnight City", artist: "M83", album: "Hurry Up",
                             duration: 243, position: 71, isPlaying: true, artworkURL: nil)
            model.player.setPreview(track: song, artwork: Snapshot.sampleArtwork(), holdLive: true)
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                model.demo()
            }
        }
        if args.contains("--preview-charging") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                model.power.raiseAlert()
            }
        }
        if args.contains("--motion-log") { controller?.logMotion() }
        // `--probe` prints what the sensors read on this Mac, then quits.
        if args.contains("--probe") {
            Task {
                model.battery.refresh(charging: model.power.isCharging)
                try? await Task.sleep(for: .seconds(6))
                let s = model.sensors, b = model.battery, w = model.weather
                print("mic app: \(s.micApp?.name ?? "none") | camera in use: \(s.cameraInUse) | call: \(s.call?.app.name ?? "none") | muted: \(s.isMuted)")
                print("battery: \(model.power.percent)% minutes=\(b.minutes.map(String.init) ?? "nil") health=\(b.health.map(String.init) ?? "nil") cycles=\(b.cycles.map(String.init) ?? "nil") top=\(b.topApp?.name ?? "nil")")
                print("weather: \(w.now.map { "\($0.temperature)" } ?? "nil") sunrises=\(w.sunrises.count) sunsets=\(w.sunsets.count) rain=\(w.rainStart.map { "\($0)" } ?? "none") moon=\(MoonPhase.now().name)")
                print("messages access: \(model.notes.messagesAccess)")
                exit(0)
            }
        }
        // `--test-record <seconds>` records the screen briefly and reports the file.
        if let i = args.firstIndex(of: "--test-record") {
            let seconds = i + 1 < args.count ? Double(args[i + 1]) ?? 3 : 3
            Task {
                try? await Task.sleep(for: .seconds(1))
                model.recorder.start()
                try? await Task.sleep(for: .seconds(seconds + 1.5))
                print("recording=\(model.recorder.isRecording) problem=\(model.recorder.problem ?? "none")")
                model.recorder.stop()
                try? await Task.sleep(for: .seconds(2.5))
                print("file=\(model.recorder.lastFile?.path ?? "none")")
                exit(0)
            }
        }
        // `--capture <home|shelf|settings> <file.png> [settings tab]` saves the live island.
        if let i = args.firstIndex(of: "--capture"), i + 2 < args.count {
            let page: IslandModel.Page = args[i + 1] == "shelf" ? .shelf : args[i + 1] == "apps" ? .apps : args[i + 1] == "settings" ? .settings : .home
            controller?.capture(page: page, tab: i + 3 < args.count ? args[i + 3] : nil, to: args[i + 2])
        }
        if args.contains("--demo") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                model.demo()
            }
        }
        #endif
    }

    /// Quitting: stop the VPN and give the Mac its old proxy settings back.
    func applicationWillTerminate(_ notification: Notification) {
        model.vpn.shutdown()
    }
}
