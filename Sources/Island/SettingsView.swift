import AppKit
import ServiceManagement
import SwiftUI

/// Settings, inside the island: a strip of sections under the camera and a
/// short scrolling list of rows for the chosen one. Island has no window and no
/// menu bar item, so everything is drawn with its own small dark controls.
struct SettingsPanel: View {
    let model: IslandModel
    @State private var tab = SettingsPanel.snapshotTab ?? SettingsPanel.requestedTab ?? .general

    static let bodyHeight: CGFloat = 250
    /// Snapshots pick the section to render.
    nonisolated(unsafe) static var snapshotTab: Tab?
    /// Another page can ask for a section to open first.
    nonisolated(unsafe) static var requestedTab: Tab?

    enum Tab: String, CaseIterable, Identifiable {
        case general, motion, live, recording, music, timer, calendar, weather
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .motion: "wand.and.stars"
            case .live: "dot.radiowaves.left.and.right"
            case .recording: "smallcircle.filled.circle"
            case .music: "music.note"
            case .timer: "timer"
            case .calendar: "calendar"
            case .weather: "cloud.sun.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Tab.allCases) { item in
                    TabChip(tab: item, selected: tab == item) {
                        withAnimation(model.prefs.settle(growing: true)) { tab = item }
                    }
                }
            }
            IslandScroll(axis: .vertical) {
                VStack(spacing: 0) {
                    switch tab {
                    case .general: GeneralSettings(model: model)
                    case .motion: MotionSettings()
                    case .live: LiveSettings(model: model)
                    case .recording: RecordingSettings(model: model)
                    case .music: MusicSettings()
                    case .timer: TimerSettings(model: model)
                    case .calendar: CalendarSettings(model: model)
                    case .weather: WeatherSettings(model: model)
                    }
                }
                .padding(.bottom, 14)
                .id(tab)
                .transition(.page)
            }
            // Rows fade out under the island's rounded bottom instead of being cut.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.88),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        }
        .padding(.top, model.contentTop - 4)
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: model.contentTop + Self.bodyHeight - 10, alignment: .top)
        .frame(height: model.contentTop + Self.bodyHeight, alignment: .top)
        .staggered(0)
    }
}

private struct TabChip: View {
    let tab: SettingsPanel.Tab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                if selected {
                    Text(tab.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .foregroundStyle(.white.opacity(selected ? 1 : (hovering ? 0.8 : 0.5)))
            .padding(.horizontal, selected ? 12 : 0)
            .frame(minWidth: 30, maxWidth: selected ? nil : .infinity)
            .frame(height: 28)
            // The open tab keeps all the room its name needs; the others share the rest.
            .fixedSize(horizontal: selected, vertical: false)
            .background(Capsule().fill(.white.opacity(selected ? 0.16 : (hovering ? 0.09 : 0.05))))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .layoutPriority(selected ? 1 : 0)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15).paced, value: hovering)
        .help(tab.title)
    }
}

// MARK: - Controls

/// One setting: its name on the left, its control on the right.
private struct Row<Control: View>: View {
    let title: String
    var enabled = true
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
            Spacer(minLength: 8)
            control
        }
        .frame(height: 32)
        .opacity(enabled ? 1 : 0.35)
        .allowsHitTesting(enabled)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5)
        }
    }
}

/// A small note under a group of rows.
private struct Note: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.4))
        .padding(.vertical, 7)
    }
}

/// A switch whose knob slides over with a little spring.
struct Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? Color.chargeGreen : .white.opacity(0.18))
                .frame(width: 32, height: 19)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .animation(.spring(duration: 0.3, bounce: 0.25).paced, value: isOn)
        .accessibilityAddTraits(.isToggle)
    }
}

/// A row with a switch.
private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var enabled = true

    init(_ title: String, isOn: Binding<Bool>, enabled: Bool = true) {
        self.title = title
        _isOn = isOn
        self.enabled = enabled
    }

    var body: some View {
        Row(title: title, enabled: enabled) { Switch(isOn: $isOn) }
    }
}

/// A few choices side by side; the chosen one is a light pill that slides.
private struct Choice<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].1 == selection
                Button { selection = options[i].1 } label: {
                    Text(options[i].0)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(on ? .black : .white.opacity(0.7))
                        .padding(.horizontal, 10)
                        .frame(height: 20)
                        .background {
                            if on {
                                Capsule().fill(.white.opacity(0.92))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.1)))
        .animation(.spring(duration: 0.32, bounce: 0.2).paced, value: selection)
    }
}

/// A thin level to drag, like the island's other bars.
private struct Level: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var width: CGFloat = 150
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let active = dragging || hovering
            let height: CGFloat = active ? 9 : 6
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule().fill(.white.opacity(active ? 0.95 : 0.7))
                    .frame(width: max(height, geo.size.width * fraction))
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        let f = min(1, max(0, drag.location.x / geo.size.width))
                        value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in dragging = false }
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7).paced, value: active)
        }
        .frame(width: width, height: 20)
        .onHover { hovering = $0 }
    }
}

/// The value shown beside a level or stepper.
private struct ValueText: View {
    let text: String
    var width: CGFloat = 48
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: width, alignment: .trailing)
            .contentTransition(.numericText())
    }
}

/// A small capsule button for row actions.
private struct RowButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
    var body: some View {
        Button(title, action: action)
            .buttonStyle(PillButtonStyle(compact: true))
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let model: IslandModel
    @Bindable private var prefs = Preferences.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var updater: Updater { Updater.shared }

    var body: some View {
        Row(title: "Open island style") {
            Choice(options: [("Black", false), ("Liquid Glass", true)], selection: $prefs.liquidGlass)
        }
        Row(title: "Open the island on") {
            Choice(options: Preferences.OpenTrigger.allCases.map { ($0.title, $0) }, selection: $prefs.openTrigger)
        }
        Row(title: "Hover delay", enabled: prefs.openTrigger == .hover) {
            Level(value: $prefs.hoverDelay, range: 0...0.5)
            ValueText(text: prefs.hoverDelay < 0.01 ? "None" : "\(Int(prefs.hoverDelay * 1000)) ms")
        }
        ToggleRow("Haptic feedback when it opens", isOn: $prefs.haptics)
        Row(title: "Update automatically") {
            ValueText(text: updater.status)
            RowButton("Check now") { Task { await updater.check(manual: true) } }
            Switch(isOn: $prefs.autoUpdate)
        }
        Row(title: "Charging animation") {
            RowButton("Preview") { model.setExpanded(false); model.power.raiseAlert() }
            Switch(isOn: $prefs.showChargingAlert)
        }
        Row(title: "Volume") {
            RowButton("Preview") { model.setExpanded(false); model.levels.preview(.volume, level: 0.6) }
            Switch(isOn: $prefs.showVolumeHUD)
        }
        Row(title: "Brightness") {
            RowButton("Preview") { model.setExpanded(false); model.levels.preview(.brightness, level: 0.7) }
            Switch(isOn: $prefs.showBrightnessHUD)
        }
        ToggleRow("Replace the macOS volume and brightness pop-ups", isOn: $prefs.hideSystemHUD)
            .onChange(of: prefs.hideSystemHUD) {
                model.keys?.update()
                if prefs.hideSystemHUD, model.keys?.isTrusted == false { model.keys?.requestPermission() }
            }
        if prefs.hideSystemHUD, model.keys?.isTrusted == false {
            Row(title: "Needs Accessibility access for the keys") {
                RowButton("Allow…") { model.keys?.requestPermission() }
            }
        }
        Row(title: "Open at login") {
            Switch(isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
        }
        Row(title: "Island") {
            RowButton("Quit") { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Motion

private struct MotionSettings: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        Row(title: "Style") {
            Choice(options: Preferences.MotionStyle.allCases.map { ($0.title, Optional($0)) },
                   selection: Binding(get: { prefs.motionStyle },
                                      set: { if let style = $0 { prefs.apply(style) } }))
        }
        Row(title: "Bounciness") {
            Level(value: $prefs.bounceSetting, range: 0...0.35)
            ValueText(text: prefs.bounceSetting < 0.1 ? "Calm" : prefs.bounceSetting > 0.22 ? "Lively" : "Natural")
        }
        Row(title: "Speed") {
            Level(value: $prefs.speed, range: 0.7...1.4)
            ValueText(text: String(format: "%.1f×", prefs.speed))
        }
        ToggleRow("Blur content as it morphs", isOn: Binding(get: { prefs.blurContent }, set: { _ in }))
        Note(text: "Close and reopen the island to feel a change.")
    }
}

// MARK: - Live activities and alerts

private struct LiveSettings: View {
    let model: IslandModel
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        Group {
            ToggleRow("Split a second activity into its own bubble", isOn: $prefs.splitActivities)
            ToggleRow("Red dot and time while recording the screen", isOn: $prefs.showRecordingIndicator)
            ToggleRow("Camera and microphone dots", isOn: $prefs.showPrivacyDots)
            ToggleRow("Call controls and call time", isOn: $prefs.showCallControls)
            if prefs.showCallControls, model.keys?.isTrusted == false {
                Row(title: "Leaving a call needs Accessibility access") {
                    RowButton("Allow…") { model.keys?.requestPermission() }
                }
            }
            Row(title: "Headphones connecting") {
                RowButton("Preview") {
                    model.preview(.headphones(AirPodsStatus(name: "AirPods Pro", symbol: "airpodspro",
                                                            left: 82, right: 79, caseLevel: 64)))
                }
                Switch(isOn: $prefs.showAirPods)
            }
            Row(title: "Low battery at 20% and 10%") {
                RowButton("Preview") { model.preview(.lowBattery(20)) }
                Switch(isOn: $prefs.showLowBattery)
            }
            ToggleRow("Battery details in the open island", isOn: $prefs.showBatteryDetails)
        }
        Group {
            Row(title: "Messages banners") {
                RowButton("Preview") {
                    model.preview(.note(IslandNote(id: "preview", source: .messages, sender: "Sam",
                                                   text: "Are we still on for lunch?")))
                }
                Switch(isOn: $prefs.notifyMessages)
            }
            if prefs.notifyMessages, model.notes.messagesAccess == .needsFullDiskAccess {
                Row(title: "Reading Messages needs Full Disk Access") {
                    RowButton("Open Settings…") { NotificationWatcher.openFullDiskAccessSettings() }
                }
            }
            ToggleRow("Mail banners", isOn: $prefs.notifyMail)
            ToggleRow("Reply from the island", isOn: $prefs.inlineReply, enabled: prefs.notifyMessages || prefs.notifyMail)
            Row(title: "Show what messages say", enabled: prefs.notifyMessages || prefs.notifyMail) {
                Choice(options: Preferences.NoteText.allCases.map { ($0.title, $0) }, selection: $prefs.noteText)
            }
            Note(text: "Auto hides what a message says while the mic or camera is on (a call, maybe sharing your screen) or a Focus is on: the banner just says who it's from. macOS keeps its own camera and microphone dots in the menu bar; apps can't hide them. Mail banners work while Mail is open.")
        }
    }
}

// MARK: - Recording

private struct RecordingSettings: View {
    let model: IslandModel
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        Row(title: "Frame rate") {
            Choice(options: [15, 24, 30, 60].map { ("\($0)", $0) }, selection: $prefs.recFPS)
        }
        Row(title: "Quality") {
            Choice(options: [("Half Size", "low"), ("Standard", "medium"), ("Retina", "high")], selection: $prefs.recQuality)
        }
        Row(title: "Codec") {
            Choice(options: [("H.264", "h264"), ("HEVC", "hevc")], selection: $prefs.recCodec)
        }
        Row(title: "File type") {
            Choice(options: [("MP4", "mp4"), ("MOV", "mov")], selection: $prefs.recFileType)
        }
        ToggleRow("Show the pointer", isOn: $prefs.recCursor)
        ToggleRow("Record the Mac's sound", isOn: $prefs.recAudio)
        ToggleRow("Record the microphone", isOn: $prefs.recMic)
        ToggleRow("Put finished recordings on the shelf", isOn: $prefs.recToShelf)
        Row(title: "Recordings folder") {
            RowButton("Show in Finder") {
                try? FileManager.default.createDirectory(at: ScreenRecorder.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(ScreenRecorder.folder)
            }
        }
        Note(text: "Pick the screen or a single window on the Record page. Changes apply to the next recording.")
    }
}

// MARK: - Music

private struct MusicSettings: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        ToggleRow("Album art and waveform while playing", isOn: $prefs.showMusicActivity)
        ToggleRow("Tint the waveform with album colors", isOn: $prefs.tintWaveform)
        ToggleRow("Show a new song's name for a moment", isOn: $prefs.showSongBanner)
        ToggleRow("Spotify", isOn: $prefs.useSpotify)
        ToggleRow("Apple Music", isOn: $prefs.useMusic)
        if prefs.clawd { ToggleRow("Clawd on the play bar", isOn: $prefs.showClawd) }
        if prefs.clawdShelf { ToggleRow("Clawd on the shelf", isOn: $prefs.showClawdShelf) }
    }
}

// MARK: - Timer

private struct TimerSettings: View {
    let model: IslandModel
    @Bindable private var prefs = Preferences.shared
    @State private var previewSound: NSSound?

    var body: some View {
        Row(title: "Sound") {
            RowButton(prefs.timerSound) {
                if let sound = IslandMenu.choose(from: Preferences.systemSounds, current: prefs.timerSound, model: model) {
                    prefs.timerSound = sound
                    play()
                }
            }
            Button(action: play) {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .help("Play sound")
        }
        ToggleRow("Keep ringing until stopped", isOn: $prefs.repeatSound)
        VStack(alignment: .leading, spacing: 7) {
            Text("Quick timers")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
            PresetPicker(selection: $prefs.timerPresets)
        }
        .padding(.top, 9)
        Note(text: "Pick up to \(Preferences.maxPresets). They show in the open island and its right-click menu.")
    }

    private func play() {
        previewSound?.stop()
        previewSound = NSSound(named: prefs.timerSound)
        previewSound?.play()
    }
}

private struct PresetPicker: View {
    @Binding var selection: [Int]

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Preferences.presetChoices, id: \.self) { minutes in
                let on = selection.contains(minutes)
                let full = selection.count >= Preferences.maxPresets
                Button {
                    if on {
                        if selection.count > 1 { selection.removeAll { $0 == minutes } }
                    } else if !full {
                        selection = (selection + [minutes]).sorted()
                    }
                } label: {
                    Text(IslandTimer.presetLabel(minutes))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .foregroundStyle(on ? .black : Color.timerOrange)
                        .background(Capsule().fill(on ? Color.timerOrange : Color.timerOrange.opacity(0.16)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .opacity(!on && full ? 0.4 : 1)
                .animation(.spring(duration: 0.25, bounce: 0.3).paced, value: on)
            }
        }
    }
}

// MARK: - Calendar

private struct CalendarSettings: View {
    let model: IslandModel
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        Group {
            ToggleRow("Show upcoming events", isOn: $prefs.showCalendar)
            Row(title: "Look ahead", enabled: prefs.showCalendar) {
                ValueText(text: prefs.calendarDays == 1 ? "Today only" : "\(prefs.calendarDays) days", width: 70)
                StepButton(symbol: "minus") { prefs.calendarDays = max(1, prefs.calendarDays - 1) }
                StepButton(symbol: "plus") { prefs.calendarDays = min(14, prefs.calendarDays + 1) }
            }
            ToggleRow("Include all-day events", isOn: $prefs.calendarAllDay, enabled: prefs.showCalendar)
            Row(title: "Calendar access") {
                switch model.calendar.access {
                case .granted:
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.chargeGreen)
                case .notAsked:
                    RowButton("Allow…") { model.calendar.requestAccess() }
                case .denied:
                    RowButton("Open Privacy Settings…") { model.calendar.requestAccess() }
                }
            }
            Note(text: "Click an event under the music to see the whole month.")
        }
        .onChange(of: prefs.calendarDays) { model.calendar.refresh() }
        .onChange(of: prefs.calendarAllDay) { model.calendar.refresh() }
        .onChange(of: prefs.showCalendar) { model.calendar.refresh() }
        .animation(.snappy(duration: 0.25).paced, value: prefs.calendarDays)
    }
}

private struct StepButton: View {
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - Weather

private struct WeatherSettings: View {
    let model: IslandModel
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        Group {
            ToggleRow("Show the weather", isOn: $prefs.showWeather)
            Row(title: "Units", enabled: prefs.showWeather) {
                Choice(options: [("°C", false), ("°F", true)], selection: $prefs.useFahrenheit)
            }
            Row(title: "Weather for", enabled: prefs.showWeather) {
                if !prefs.weatherCity.isEmpty {
                    RowButton("My Location") {
                        prefs.weatherCity = ""
                        model.weather.refresh(force: true)
                    }
                }
                RowButton(prefs.weatherCity.isEmpty ? "Choose a City…" : prefs.weatherCity, action: askForCity)
            }
            Row(title: "Rain warning beside the camera", enabled: prefs.showWeather) {
                RowButton("Preview") { model.preview(.rain(minutes: 12)) }
                Switch(isOn: $prefs.showRainWarning)
            }
            ToggleRow("Sunrise and sunset in the weather card", isOn: $prefs.showSunEvents, enabled: prefs.showWeather)
            Row(title: "Show them this long before", enabled: prefs.showWeather && prefs.showSunEvents) {
                Choice(options: [("30 min", 30), ("45 min", 45), ("1 hour", 60)], selection: $prefs.sunLeadMinutes)
            }
            ToggleRow("Moon phase at night", isOn: $prefs.showMoonPhase, enabled: prefs.showWeather)
            if prefs.weatherCity.isEmpty, model.weather.locationState == .denied {
                Note(text: "Island can't see your location. Allow it in Privacy & Security › Location Services, or choose a city.",
                     symbol: "location.slash")
            }
            if let error = model.weather.lastError {
                Note(text: error, symbol: "exclamationmark.triangle")
            }
        }
        .onChange(of: prefs.useFahrenheit) { model.weather.refresh(force: true) }
        .onChange(of: prefs.showWeather) { model.weather.refresh(force: true) }
    }

    /// The island never takes the keyboard, so typing a city happens in a
    /// small system prompt.
    private func askForCity() {
        let alert = NSAlert()
        alert.messageText = "Weather for which city?"
        alert.informativeText = "Island shows this city's weather instead of your location's."
        let field = NSTextField(string: prefs.weatherCity)
        field.placeholderString = "e.g. Sydney"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Use City")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let city = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !city.isEmpty else { return }
        prefs.weatherCity = city
        model.weather.refresh(force: true)
    }
}

// MARK: - Menus

/// A pop-up list for settings with too many choices for a row. It blocks until
/// dismissed and keeps the island open while it's up.
enum IslandMenu {
    static func choose(from options: [String], current: String, model: IslandModel) -> String? {
        chooseIndex(from: options, current: options.firstIndex(of: current) ?? -1, model: model).map { options[$0] }
    }

    /// The same, by position, for lists whose names may repeat.
    static func chooseIndex(from options: [String], current: Int, model: IslandModel) -> Int? {
        let menu = NSMenu()
        let target = MenuTarget()
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: option, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.tag = index
            item.state = index == current ? .on : .off
            menu.addItem(item)
        }
        model.isScrubbing = true
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        model.isScrubbing = false
        model.recheckPointer()
        return target.picked
    }

    private final class MenuTarget: NSObject {
        var picked: Int?
        @objc func pick(_ item: NSMenuItem) { picked = item.tag }
    }
}
