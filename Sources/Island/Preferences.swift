import AppKit
import SwiftUI

/// Every user setting, saved in UserDefaults as it changes.
@Observable
final class Preferences {
    static let shared = Preferences()

    enum OpenTrigger: String, CaseIterable, Identifiable {
        case hover, click
        var id: Self { self }
        var title: String { self == .hover ? "Hover" : "Click" }
    }

    /// When a banner shows what a message or email actually says.
    enum NoteText: String, CaseIterable, Identifiable {
        case always, auto, never
        var id: Self { self }
        var title: String { switch self { case .always: "Always"; case .auto: "Auto"; case .never: "Never" } }
    }

    /// Named starting points for the two motion sliders.
    enum MotionStyle: String, CaseIterable, Identifiable {
        case subtle, natural, lively
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var bounce: Double { switch self { case .subtle: 0.06; case .natural: 0.16; case .lively: 0.26 } }
        var speed: Double { 1.0 }
    }

    /// How the island's body moves when it opens and closes.
    enum OpenStyle: String, CaseIterable, Identifiable {
        case liquid, snappy, jelly, drop
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    /// How rows and pages arrive inside the island.
    enum Entrance: String, CaseIterable, Identifiable {
        case blur, slide, pop, fade
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    enum WaveStyle: String, CaseIterable, Identifiable {
        case bars, dots, wave, mirror
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    /// What sits under the open island: nothing, a shadow, or a glow of color.
    enum Glow: String, CaseIterable, Identifiable {
        case off, shadow, album, accent
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    enum Accent: String, CaseIterable, Identifiable {
        case green, blue, purple, pink, orange, red, teal, graphite
        var id: Self { self }
        var color: Color {
            switch self {
            case .green: Color(red: 0.2, green: 0.84, blue: 0.29)
            case .blue: Color(red: 0.2, green: 0.55, blue: 1.0)
            case .purple: Color(red: 0.66, green: 0.4, blue: 1.0)
            case .pink: Color(red: 1.0, green: 0.36, blue: 0.62)
            case .orange: Color(red: 1.0, green: 0.62, blue: 0.04)
            case .red: Color(red: 1.0, green: 0.27, blue: 0.23)
            case .teal: Color(red: 0.25, green: 0.8, blue: 0.82)
            case .graphite: Color(white: 0.72)
            }
        }
    }

    enum ColorFormat: String, CaseIterable, Identifiable {
        case hex, rgb, hsl
        var id: Self { self }
        var title: String { rawValue.uppercased() }
    }

    enum SpeedUnit: String, CaseIterable, Identifiable {
        case bits, bytes
        var id: Self { self }
        var title: String { self == .bits ? "Mbps" : "MB/s" }
    }

    // General
    var openTrigger: OpenTrigger { didSet { save(openTrigger.rawValue, "openTrigger") } }
    var hoverDelay: Double { didSet { save(hoverDelay, "hoverDelay") } }
    var haptics: Bool { didSet { save(haptics, "haptics") } }
    /// The open island in Liquid Glass instead of solid black.
    var liquidGlass: Bool { didSet { save(liquidGlass, "liquidGlass") } }
    var showChargingAlert: Bool { didSet { save(showChargingAlert, "showChargingAlert") } }
    var showVolumeHUD: Bool { didSet { save(showVolumeHUD, "showVolumeHUD") } }
    var showBrightnessHUD: Bool { didSet { save(showBrightnessHUD, "showBrightnessHUD") } }
    var hideSystemHUD: Bool { didSet { save(hideSystemHUD, "hideSystemHUD") } }

    // Motion
    /// The Bounciness slider. Read `bounce` for animations: it honors Reduce Motion.
    var bounceSetting: Double { didSet { save(bounceSetting, "motionBounce") } }
    var speed: Double { didSet { save(speed, "motionSpeed") } }
    var openStyle: OpenStyle { didSet { save(openStyle.rawValue, "openStyle") } }
    var entrance: Entrance { didSet { save(entrance.rawValue, "entrance") } }
    var glow: Glow { didSet { save(glow.rawValue, "glow") } }
    var accent: Accent { didSet { save(accent.rawValue, "accent") } }
    /// Content blurs as it morphs: true for the Blur entrance.
    var blurContent: Bool { entrance == .blur }

    // Music
    var showMusicActivity: Bool { didSet { save(showMusicActivity, "showMusicActivity") } }
    var tintWaveform: Bool { didSet { save(tintWaveform, "tintWaveform") } }
    var showSongBanner: Bool { didSet { save(showSongBanner, "showSongBanner") } }
    var useSpotify: Bool { didSet { save(useSpotify, "useSpotify") } }
    var useMusic: Bool { didSet { save(useMusic, "useMusic") } }
    var waveStyle: WaveStyle { didSet { save(waveStyle.rawValue, "waveStyle") } }
    /// The Up Next button in the player.
    var showUpNext: Bool { didSet { save(showUpNext, "showUpNext") } }
    /// The Client ID of the user's own Spotify app, for Up Next and likes. Not a secret.
    var spotifyClientID: String { didSet { save(spotifyClientID, "spotifyClientID") } }
    /// A friend on the play bar. Stays false until he is met.
    var clawd: Bool { didSet { save(clawd, "clawd") } }
    /// Install updates on their own when the developer sends one.
    var autoUpdate: Bool { didSet { save(autoUpdate, "autoUpdate") } }
    var showClawd: Bool { didSet { save(showClawd, "showClawd") } }
    /// Met by typing "clawd": he sits on the shelf instead.
    var clawdShelf: Bool { didSet { save(clawdShelf, "clawdShelf") } }
    var showClawdShelf: Bool { didSet { save(showClawdShelf, "showClawdShelf") } }

    // Calendar
    var showCalendar: Bool { didSet { save(showCalendar, "showCalendar") } }
    /// How far ahead to look, in days.
    var calendarDays: Int { didSet { save(calendarDays, "calendarDays") } }
    var calendarAllDay: Bool { didSet { save(calendarAllDay, "calendarAllDay") } }
    /// With nothing playing, the open island shows the month.
    var calendarWhenIdle: Bool { didSet { save(calendarWhenIdle, "calendarWhenIdle") } }
    var showCountdowns: Bool { didSet { save(showCountdowns, "showCountdowns") } }
    /// How many days ahead a countdown starts showing beside the camera.
    var countdownLeadDays: Int { didSet { save(countdownLeadDays, "countdownLeadDays") } }
    /// Count down to birthdays and holidays from the Calendar app too.
    var countdownFromCalendar: Bool { didSet { save(countdownFromCalendar, "countdownFromCalendar") } }

    // Weather
    var showWeather: Bool { didSet { save(showWeather, "showWeather") } }
    /// A city to show instead of the Mac's location; empty means current location.
    var weatherCity: String { didSet { save(weatherCity, "weatherCity") } }
    var useFahrenheit: Bool { didSet { save(useFahrenheit, "useFahrenheit") } }

    // Timer
    var timerSound: String { didSet { save(timerSound, "timerSound") } }
    var repeatSound: Bool { didSet { save(repeatSound, "repeatSound") } }
    var timerPresets: [Int] { didSet { save(timerPresets, "timerPresets") } }
    /// Whether the preset chips are fanned out in the island.
    var showTimerPresets: Bool { didSet { save(showTimerPresets, "showTimerPresets") } }


    // Live activities, alerts and recording (each can be turned off in Settings)
    var showRecordingIndicator: Bool { didSet { save(showRecordingIndicator, "showRecordingIndicator") } }
    var showAirPods: Bool { didSet { save(showAirPods, "showAirPods") } }
    var showLowBattery: Bool { didSet { save(showLowBattery, "showLowBattery") } }
    var showPrivacyDots: Bool { didSet { save(showPrivacyDots, "showPrivacyDots") } }
    var splitActivities: Bool { didSet { save(splitActivities, "splitActivities") } }
    var showBatteryDetails: Bool { didSet { save(showBatteryDetails, "showBatteryDetails") } }
    var notifyMessages: Bool { didSet { save(notifyMessages, "notifyMessages") } }
    var notifyMail: Bool { didSet { save(notifyMail, "notifyMail") } }
    var inlineReply: Bool { didSet { save(inlineReply, "inlineReply") } }
    var noteText: NoteText { didSet { save(noteText.rawValue, "noteText") } }
    var showSunEvents: Bool { didSet { save(showSunEvents, "showSunEvents") } }
    var sunLeadMinutes: Int { didSet { save(sunLeadMinutes, "sunLeadMinutes") } }
    var showMoonPhase: Bool { didSet { save(showMoonPhase, "showMoonPhase") } }
    var showRainWarning: Bool { didSet { save(showRainWarning, "showRainWarning") } }
    var showCallControls: Bool { didSet { save(showCallControls, "showCallControls") } }
    var recFPS: Int { didSet { save(recFPS, "recFPS") } }
    var recQuality: String { didSet { save(recQuality, "recQuality") } }
    var recCodec: String { didSet { save(recCodec, "recCodec") } }
    var recFileType: String { didSet { save(recFileType, "recFileType") } }
    var recCursor: Bool { didSet { save(recCursor, "recCursor") } }
    var recAudio: Bool { didSet { save(recAudio, "recAudio") } }
    var recMic: Bool { didSet { save(recMic, "recMic") } }
    var recToShelf: Bool { didSet { save(recToShelf, "recToShelf") } }

    // Insights: what the island works out and tells you
    var showInsights: Bool { didSet { save(showInsights, "showInsights") } }
    var adviseCharging: Bool { didSet { save(adviseCharging, "adviseCharging") } }
    var warnStorm: Bool { didSet { save(warnStorm, "warnStorm") } }
    var warnOutage: Bool { didSet { save(warnOutage, "warnOutage") } }
    var warnStorage: Bool { didSet { save(warnStorage, "warnStorage") } }
    var showNetwork: Bool { didSet { save(showNetwork, "showNetwork") } }
    var speedUnit: SpeedUnit { didSet { save(speedUnit.rawValue, "speedUnit") } }

    // Tools
    var showReminders: Bool { didSet { save(showReminders, "showReminders") } }
    /// Reminders set in the island are added to the Reminders app as well.
    var remindersToApp: Bool { didSet { save(remindersToApp, "remindersToApp") } }
    var showColorPicker: Bool { didSet { save(showColorPicker, "showColorPicker") } }
    var colorFormat: ColorFormat { didSet { save(colorFormat.rawValue, "colorFormat") } }
    var showTerminal: Bool { didSet { save(showTerminal, "showTerminal") } }
    var terminalFontSize: Int { didSet { save(terminalFontSize, "terminalFontSize") } }

    static let presetChoices = [1, 2, 3, 5, 10, 15, 20, 25, 30, 45, 60, 90]
    static let maxPresets = 7

    private init() {
        let d = UserDefaults.standard
        openTrigger = OpenTrigger(rawValue: d.string(forKey: "openTrigger") ?? "") ?? .hover
        hoverDelay = d.object(forKey: "hoverDelay") as? Double ?? 0
        haptics = d.object(forKey: "haptics") as? Bool ?? true
        liquidGlass = d.object(forKey: "liquidGlass") as? Bool ?? false
        showChargingAlert = d.object(forKey: "showChargingAlert") as? Bool ?? true
        showVolumeHUD = d.object(forKey: "showVolumeHUD") as? Bool ?? true
        showBrightnessHUD = d.object(forKey: "showBrightnessHUD") as? Bool ?? true
        hideSystemHUD = d.object(forKey: "hideSystemHUD") as? Bool ?? true
        bounceSetting = d.object(forKey: "motionBounce") as? Double ?? MotionStyle.natural.bounce
        speed = d.object(forKey: "motionSpeed") as? Double ?? 1.0
        openStyle = OpenStyle(rawValue: d.string(forKey: "openStyle") ?? "") ?? .liquid
        // Older versions had a single "blur content" switch: off maps to Fade.
        let blurred = d.object(forKey: "blurContent") as? Bool ?? true
        entrance = Entrance(rawValue: d.string(forKey: "entrance") ?? "") ?? (blurred ? .blur : .fade)
        glow = Glow(rawValue: d.string(forKey: "glow") ?? "") ?? .shadow
        accent = Accent(rawValue: d.string(forKey: "accent") ?? "") ?? .green
        showMusicActivity = d.object(forKey: "showMusicActivity") as? Bool ?? true
        tintWaveform = d.object(forKey: "tintWaveform") as? Bool ?? true
        showSongBanner = d.object(forKey: "showSongBanner") as? Bool ?? true
        useSpotify = d.object(forKey: "useSpotify") as? Bool ?? true
        useMusic = d.object(forKey: "useMusic") as? Bool ?? true
        waveStyle = WaveStyle(rawValue: d.string(forKey: "waveStyle") ?? "") ?? .bars
        showUpNext = d.object(forKey: "showUpNext") as? Bool ?? true
        spotifyClientID = d.string(forKey: "spotifyClientID") ?? ""
        clawd = d.object(forKey: "clawd") as? Bool ?? false
        showClawd = d.object(forKey: "showClawd") as? Bool ?? true
        autoUpdate = d.object(forKey: "autoUpdate") as? Bool ?? true
        clawdShelf = d.object(forKey: "clawdShelf") as? Bool ?? false
        showClawdShelf = d.object(forKey: "showClawdShelf") as? Bool ?? true
        showCalendar = d.object(forKey: "showCalendar") as? Bool ?? true
        calendarDays = d.object(forKey: "calendarDays") as? Int ?? 3
        calendarAllDay = d.object(forKey: "calendarAllDay") as? Bool ?? true
        calendarWhenIdle = d.object(forKey: "calendarWhenIdle") as? Bool ?? true
        showCountdowns = d.object(forKey: "showCountdowns") as? Bool ?? true
        countdownLeadDays = d.object(forKey: "countdownLeadDays") as? Int ?? 14
        countdownFromCalendar = d.object(forKey: "countdownFromCalendar") as? Bool ?? true
        timerSound = d.string(forKey: "timerSound") ?? "Glass"
        repeatSound = d.object(forKey: "repeatSound") as? Bool ?? true
        showWeather = d.object(forKey: "showWeather") as? Bool ?? true
        weatherCity = d.string(forKey: "weatherCity") ?? ""
        useFahrenheit = d.object(forKey: "useFahrenheit") as? Bool
            ?? (Locale.current.measurementSystem == .us)
        showTimerPresets = d.object(forKey: "showTimerPresets") as? Bool ?? true
        showRecordingIndicator = d.object(forKey: "showRecordingIndicator") as? Bool ?? true
        showAirPods = d.object(forKey: "showAirPods") as? Bool ?? true
        showLowBattery = d.object(forKey: "showLowBattery") as? Bool ?? true
        showPrivacyDots = d.object(forKey: "showPrivacyDots") as? Bool ?? true
        splitActivities = d.object(forKey: "splitActivities") as? Bool ?? true
        showBatteryDetails = d.object(forKey: "showBatteryDetails") as? Bool ?? true
        notifyMessages = d.object(forKey: "notifyMessages") as? Bool ?? true
        notifyMail = d.object(forKey: "notifyMail") as? Bool ?? true
        inlineReply = d.object(forKey: "inlineReply") as? Bool ?? true
        noteText = NoteText(rawValue: d.string(forKey: "noteText") ?? "") ?? .auto
        showSunEvents = d.object(forKey: "showSunEvents") as? Bool ?? true
        sunLeadMinutes = d.object(forKey: "sunLeadMinutes") as? Int ?? 60
        showMoonPhase = d.object(forKey: "showMoonPhase") as? Bool ?? true
        showRainWarning = d.object(forKey: "showRainWarning") as? Bool ?? true
        showCallControls = d.object(forKey: "showCallControls") as? Bool ?? true
        recFPS = d.object(forKey: "recFPS") as? Int ?? 30
        recQuality = d.object(forKey: "recQuality") as? String ?? "high"
        recCodec = d.object(forKey: "recCodec") as? String ?? "h264"
        recFileType = d.object(forKey: "recFileType") as? String ?? "mp4"
        recCursor = d.object(forKey: "recCursor") as? Bool ?? true
        recAudio = d.object(forKey: "recAudio") as? Bool ?? true
        recMic = d.object(forKey: "recMic") as? Bool ?? false
        recToShelf = d.object(forKey: "recToShelf") as? Bool ?? true
        showInsights = d.object(forKey: "showInsights") as? Bool ?? true
        adviseCharging = d.object(forKey: "adviseCharging") as? Bool ?? true
        warnStorm = d.object(forKey: "warnStorm") as? Bool ?? true
        warnOutage = d.object(forKey: "warnOutage") as? Bool ?? true
        warnStorage = d.object(forKey: "warnStorage") as? Bool ?? true
        showNetwork = d.object(forKey: "showNetwork") as? Bool ?? true
        speedUnit = SpeedUnit(rawValue: d.string(forKey: "speedUnit") ?? "") ?? .bits
        showReminders = d.object(forKey: "showReminders") as? Bool ?? true
        remindersToApp = d.object(forKey: "remindersToApp") as? Bool ?? true
        showColorPicker = d.object(forKey: "showColorPicker") as? Bool ?? true
        colorFormat = ColorFormat(rawValue: d.string(forKey: "colorFormat") ?? "") ?? .hex
        showTerminal = d.object(forKey: "showTerminal") as? Bool ?? true
        terminalFontSize = min(14, max(9, d.object(forKey: "terminalFontSize") as? Int ?? 11))
        timerPresets = d.array(forKey: "timerPresets") as? [Int] ?? [1, 3, 5, 10, 15, 30, 60]
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    var motionStyle: MotionStyle? {
        MotionStyle.allCases.first { abs($0.bounce - bounceSetting) < 0.01 && abs($0.speed - speed) < 0.01 }
    }

    func apply(_ style: MotionStyle) {
        bounceSetting = style.bounce
        speed = style.speed
    }

    /// System alert sounds, for the timer.
    static let systemSounds: [String] = {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let sounds = names.map { ($0 as NSString).deletingPathExtension }.sorted()
        return sounds.isEmpty ? ["Glass"] : sounds
    }()

    // MARK: Motion

    /// System Settings › Accessibility › Display › Reduce Motion.
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Bounce for animations: none at all with Reduce Motion on.
    var bounce: Double { reduceMotion ? 0 : bounceSetting }
    /// Blur and scale flourishes are skipped with Reduce Motion on.
    var flourishes: Bool { !reduceMotion }

    /// Duration scale: higher speed, shorter springs.
    private var time: Double { 1 / max(0.5, speed) }

    /// A duration in seconds, adjusted for the Speed setting.
    func pace(_ seconds: Double) -> Double { seconds * time }

    /// Opening: quick, with a small, tidy overshoot.
    var open: Animation { .spring(duration: 0.44 * time, bounce: bounce) }
    /// Closing: a touch quicker, settling with almost no overshoot.
    var close: Animation { .spring(duration: 0.38 * time, bounce: bounce * 0.25) }

    /// Size changes beside the camera: springier than opening the whole island.
    func settle(growing: Bool) -> Animation {
        growing
            ? .spring(duration: 0.5 * time, bounce: min(0.42, bounce + 0.14))
            : .spring(duration: 0.46 * time, bounce: min(0.32, bounce + 0.08))
    }
    /// Items popping in beside the camera, after the old one has gone.
    var swapIn: Animation { .spring(duration: 0.46 * time, bounce: min(0.45, bounce + 0.18)).delay(0.12 * time) }
    var swapOut: Animation { .easeIn(duration: 0.14 * time) }

    /// The open island changing what it shows (music ↔ calendar ↔ shelf): one
    /// soft spring, shared by the body and the rows inside so they move as one.
    var reshapeResponse: Double { 0.46 * time }
    var reshapeDamping: Double { min(1, max(0.7, 0.86 - (bounce - 0.16) * 0.8)) }
    var reshape: Animation { .spring(response: reshapeResponse, dampingFraction: reshapeDamping) }

    var contentIn: Animation { .spring(duration: 0.34 * time, bounce: 0).delay(0.06 * time) }
    var contentOut: Animation { .easeOut(duration: 0.1 * time) }

    // MARK: Buttons

    /// How far a button dips when pressed: livelier motion, deeper dip.
    var pressScale: Double { 0.92 - bounce * 0.42 }
    /// How much a button grows under the pointer.
    var hoverScale: Double { 1 + bounce * 0.28 }
    /// The spring a button snaps back with.
    var buttonSpring: Animation { .spring(duration: 0.3 * time, bounce: min(0.6, 0.15 + bounce * 1.5)) }
    /// Lively enough for symbols to bounce when tapped.
    var bouncesSymbols: Bool { bounce >= 0.2 }
}

extension Animation {
    /// This animation at the user's Speed setting.
    var paced: Animation { speed(max(0.5, Preferences.shared.speed)) }
}

extension Preferences.Entrance {
    /// The scale a view starts from; `base` is what Blur uses.
    func scale(_ base: CGFloat) -> CGFloat {
        switch self {
        case .blur: base
        case .pop: max(0.5, base - 0.14)
        case .slide, .fade: 1
        }
    }
    /// How far a view travels in, in points.
    func travel(_ points: CGFloat) -> CGFloat { self == .slide ? points : 0 }
    func blur(_ radius: CGFloat) -> CGFloat { self == .blur ? radius : 0 }
}
