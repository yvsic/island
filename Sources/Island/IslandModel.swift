import AppKit
import SwiftUI

/// What the island shows and how big it is. All sizes are for the island's body;
/// the drawn shape adds the small flared "ears" where it meets the top of the screen.
@Observable
final class IslandModel {
    enum Presentation: Hashable { case idle, compact, expanded }
    /// What the open island is showing: the usual player and calendar, the
    /// file shelf, or settings.
    enum Page: Hashable { case home, shelf, apps, record, vpn, settings }
    /// What the usual page has been asked to show in place of the player:
    /// the month, what plays next, reminders, or the last picked color.
    enum Tool: Hashable { case calendar, queue, reminders, color }
    /// Things that live beside the camera for as long as they last, most
    /// important first. The first owns the island; the second splits off as a bubble.
    enum Activity: Hashable { case call, recording, timer, music, privacy, countdown, vpn }

    let player = NowPlaying()
    let timer = IslandTimer()
    let power = PowerMonitor()
    let levels = LevelMonitor()
    let calendar = CalendarStore()
    let weather = WeatherStore()
    let shelf = ShelfStore()
    let sensors = SystemSensors()
    let recorder = ScreenRecorder()
    let notes = NotificationWatcher()
    let battery = BatteryDetails()
    let network = NetworkMonitor()
    let reminders = ReminderStore()
    let countdowns = CountdownStore()
    let colors = ColorStore()
    let spotify = SpotifyAPI()
    let apps = QuickApps()
    let vpn = VPNController()
    var queue: QueueStore
    /// A short moment beside the camera (low battery, headphones, rain, a message).
    private(set) var alert: IslandAlert?
    /// Changes each time an alert is raised, to replay its entrance.
    private(set) var alertID = 0
    /// The message on show, kept while the island is open so it can be answered.
    private(set) var note: IslandNote?
    /// Typing a reply: the island holds the keyboard and stays open.
    private(set) var isReplying = false
    /// The reminder field or the terminal has the keyboard: the island stays
    /// open until a click lands somewhere else.
    private(set) var isTyping = false
    var wantsKeyboard: Bool { isReplying || isTyping }
    private(set) var tool: Tool?
    /// The month that shows by itself with nothing playing was put away by hand.
    private(set) var calendarDismissed = false
    /// Free space on the startup disk in bytes, checked now and then.
    private(set) var freeDiskSpace: Int64?
    @ObservationIgnored private var housekeeping: Task<Void, Never>?
    @ObservationIgnored private var chargeWarned = false
    @ObservationIgnored private var unpluggedAt = Date.distantPast
    @ObservationIgnored private var wentOfflineAt = Date.distantPast
    @ObservationIgnored private var powerCutRaisedAt = Date.distantPast
    @ObservationIgnored private var sampler: NSColorSampler?
    @ObservationIgnored private var alertTask: Task<Void, Never>?
    private(set) var page: Page = .home
    @ObservationIgnored private(set) var keys: MediaKeys?
    let prefs = Preferences.shared

    var notchSize = CGSize(width: 185, height: 32)
    var hasPhysicalNotch = true
    private(set) var isExpanded = false
    private(set) var isHovering = false
    var isPointerDown = false
    var isScrubbing = false

    @ObservationIgnored var onLayoutChange: (() -> Void)?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var demoTask: Task<Void, Never>?

    init() {
        // A third, independent call: see AntiTamper.harden().
        #if ISLAND_RELEASE_HARDENING
        AntiTamper.harden()
        #endif
        ClawdKeys.shared.start()
        Updater.shared.start()
        self.queue = QueueStore(spotify: spotify)
        self.keys = MediaKeys(levels: levels)
        timer.onRing = { [weak self] in self?.layoutChanged() }
        player.onChange = { [weak self] in self?.layoutChanged() }
        power.onChange = { [weak self] in self?.layoutChanged() }
        levels.onChange = { [weak self] in self?.layoutChanged() }
        calendar.onChange = { [weak self] in self?.layoutChanged() }
        weather.onChange = { [weak self] in self?.layoutChanged() }
        sensors.onChange = { [weak self] in self?.layoutChanged() }
        recorder.onChange = { [weak self] in self?.layoutChanged() }
        vpn.onChange = { [weak self] in self?.layoutChanged() }
        vpn.onEvent = { [weak self] event in self?.raise(event) }
        recorder.onFinished = { [weak self] url in
            if Preferences.shared.recToShelf { self?.shelf.add([url]) }
        }
        sensors.onHeadphones = { [weak self] status in
            if Preferences.shared.showAirPods { self?.raise(.headphones(status)) }
        }
        power.onLow = { [weak self] percent in
            if Preferences.shared.showLowBattery { self?.raise(.lowBattery(percent)) }
        }
        weather.onRain = { [weak self] start in
            guard Preferences.shared.showRainWarning else { return }
            self?.raise(.rain(minutes: max(1, Int((start.timeIntervalSinceNow / 60).rounded()))))
        }
        notes.onNote = { [weak self] note in
            guard let self else { return }
            self.raise(.note(self.shielded(note)))
        }
        weather.onStorm = { [weak self] start in
            guard let self, self.prefs.warnStorm else { return }
            self.raise(.storm(minutes: max(1, Int((start.timeIntervalSinceNow / 60).rounded())),
                              outage: self.prefs.warnOutage))
        }
        power.onUnplugged = { [weak self] in
            self?.unpluggedAt = .now
            self?.checkPowerCut(after: 6)
        }
        network.onOffline = { [weak self] in
            self?.wentOfflineAt = .now
            self?.checkPowerCut(after: 1)
        }
        reminders.onDue = { [weak self] reminder in
            NSSound(named: Preferences.shared.timerSound)?.play()
            self?.raise(.reminder(reminder.title))
        }
        player.onTrackChange = { [weak self] old, new in
            guard let self else { return }
            self.queue.trackChanged(from: old, to: new)
            self.spotify.checkLiked(new) { [weak self] liked in self?.player.setLiked(liked, for: new) }
        }
    }

    /// The parts that run for the whole life of the app, started once at launch.
    func startExtras() {
        network.start()
        reminders.start()
        housekeeping = Task { [weak self] in
            var minute = 0
            while !Task.isCancelled {
                self?.tick(minute)
                minute += 1
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Once a minute: keep the slow facts fresh and say what needs saying.
    private func tick(_ minute: Int) {
        battery.refreshEstimate(charging: power.isCharging)
        if minute % 10 == 0 { freeDiskSpace = Self.readFreeDiskSpace() }
        guard prefs.adviseCharging, power.hasBattery else { return }
        if power.isPluggedIn {
            chargeWarned = false
        } else if let left = minutesUntilLowBattery {
            if left <= 15, power.percent > 20, !chargeWarned {
                chargeWarned = true
                raise(.chargeSoon(minutes: max(1, left), percent: power.percent))
            } else if left > 30 {
                chargeWarned = false
            }
        }
    }

    /// Minutes until the charge reaches 20%, from macOS's own estimate.
    var minutesUntilLowBattery: Int? {
        guard power.hasBattery, !power.isPluggedIn, power.percent > 20,
              let minutes = battery.minutes, minutes > 0 else { return nil }
        return Int(Double(minutes) * Double(power.percent - 20) / Double(power.percent))
    }

    private static func readFreeDiskSpace() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The charger came out and the network went down within moments of each
    /// other: that looks like the power going, not someone unplugging a cable.
    private func checkPowerCut(after seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.prefs.warnOutage, self.power.hasBattery, !self.power.isPluggedIn,
                  !self.network.isOnline,
                  abs(self.unpluggedAt.timeIntervalSince(self.wentOfflineAt)) < 20,
                  Date.now.timeIntervalSince(self.powerCutRaisedAt) > 300 else { return }
            self.powerCutRaisedAt = .now
            self.raise(.powerCut(percent: self.power.percent))
        }
    }

    // MARK: State

    var presentation: Presentation {
        if isExpanded || timer.isRinging { return .expanded }
        if levels.isShowing || power.showsChargingAlert || alert != nil { return .compact }
        if !activities.isEmpty { return .compact }
        return .idle
    }

    var activities: [Activity] {
        var list: [Activity] = []
        if prefs.showCallControls, sensors.call != nil { list.append(.call) }
        if prefs.showRecordingIndicator, recorder.isRecording { list.append(.recording) }
        // A dropped VPN is holding traffic: that outranks music and timers.
        if vpn.needsAttention { list.append(.vpn) }
        if timer.isActive { list.append(.timer) }
        if showsMusicActivity { list.append(.music) }
        // A call already says the mic is live; the dot is for everything else.
        if prefs.showPrivacyDots, sensors.cameraInUse || sensors.micApp != nil,
           !(list.contains(.call) && !sensors.cameraInUse) { list.append(.privacy) }
        // A countdown keeps the camera company only when nothing else is there.
        if list.isEmpty, nextCountdown != nil { list.append(.countdown) }
        if vpn.showInNotch, vpn.isOn { list.append(.vpn) }
        return list
    }
    var primaryActivity: Activity? { activities.first }
    /// The second activity, pinched off into its own bubble beside the island.
    var bubbleActivity: Activity? {
        guard prefs.splitActivities, presentation == .compact else { return nil }
        return activities.dropFirst().first
    }

    /// The alert on show; volume and brightness briefly cover it.
    var shownAlert: IslandAlert? { levels.isShowing ? nil : alert }
    /// Height of whatever hangs below the camera row in the compact island.
    var compactDrawerHeight: CGFloat {
        if levels.isShowing { return 0 }
        if let alert { return alert.metrics.drawerHeight > 0 ? alert.metrics.drawerHeight + 6 : 0 }
        return showsSongBanner ? Layout.bannerHeight : 0
    }

    func raise(_ alert: IslandAlert) {
        self.alert = alert
        alertID &+= 1
        if case .note(let note) = alert { self.note = note }
        alertTask?.cancel()
        alertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(alert.duration))
            guard !Task.isCancelled, let self else { return }
            self.alert = nil
            if !self.isExpanded {
                self.note = nil
                self.tool = nil
            }
            self.layoutChanged()
        }
        layoutChanged()
    }

    /// A banner without what the message says, when others might be watching:
    /// a live mic or camera (a call, which may be sharing the screen) or a Focus.
    private func shielded(_ note: IslandNote) -> IslandNote {
        let hide = switch prefs.noteText {
        case .always: false
        case .never: true
        case .auto: sensors.micApp != nil || sensors.cameraInUse || FocusStatus.isOn
        }
        guard hide else { return note }
        var quiet = note
        quiet.text = note.source == .messages ? "New message" : "New email"
        return quiet
    }

    /// Settings' Preview buttons: close the island and show the alert.
    func preview(_ alert: IslandAlert) {
        setExpanded(false)
        raise(alert)
    }

    func setReplying(_ replying: Bool) {
        guard replying != isReplying else { return }
        isReplying = replying
        layoutChanged()
    }

    func dismissNote() {
        note = nil
        isReplying = false
        if case .note = alert { alert = nil }
        layoutChanged()
    }

    var showsCallRow: Bool { prefs.showCallControls && sensors.call != nil }
    var showsRecordingRow: Bool { recorder.isRecording }
    var showsBatteryRow: Bool { prefs.showBatteryDetails && power.hasBattery }

    /// Music counts as a live activity while playing, like on iPhone.
    var showsMusicActivity: Bool { prefs.showMusicActivity && player.track != nil && player.isPlaying }
    var hasMusic: Bool { player.track != nil }
    var showsTimerRow: Bool { timer.isActive || timer.isRinging }
    /// Events to list, or the one-time prompt to connect Calendar. Nothing to
    /// show means no calendar part at all, not an empty note.
    var showsCalendarContent: Bool {
        guard prefs.showCalendar else { return false }
        return calendar.access == .notAsked || (calendar.access == .granted && !calendar.events.isEmpty)
    }
    var showsWeatherCard: Bool { prefs.showWeather && weather.now != nil }
    /// The month opens only when asked for: a click on an event (or the calendar
    /// button) brings it up, until the island closes or Back is pressed. With
    /// nothing playing, the island stays the small home page.
    var showsCalendarPanel: Bool {
        prefs.showCalendar && tool == .calendar
    }
    /// The calendar panel was asked for by hand, in place of what was there.
    var calendarPinned: Bool { tool == .calendar }
    /// Whether the calendar panel is covering something to go back to.
    var calendarHasBack: Bool { calendarPinned && (hasMusic || showsTimerRow) }

    func setCalendarPinned(_ pinned: Bool) {
        guard pinned != calendarPinned else { return }
        setTool(pinned ? .calendar : nil)
    }

    /// The calendar button: bring the month up, or put it away again.
    func toggleCalendar() {
        if showsCalendarPanel {
            calendarDismissed = true
            setTool(nil)
        } else {
            calendarDismissed = false
            setTool(.calendar)
        }
        layoutChanged()
    }

    func setTool(_ tool: Tool?) {
        guard tool != self.tool else { return }
        self.tool = tool
        if tool == .queue { queue.refresh(for: player.track) }
        // The reminder field takes the keyboard as soon as it shows.
        setTyping(tool == .reminders)
        if tool != nil, prefs.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        layoutChanged()
    }

    func toggleTool(_ tool: Tool) { setTool(self.tool == tool ? nil : tool) }

    var showsQueuePanel: Bool { tool == .queue && hasMusic && note == nil }
    /// Reminders and the color panel take the whole page, like a message does.
    var focusedTool: Tool? {
        guard note == nil, tool == .reminders || tool == .color else { return nil }
        return tool
    }

    func setTyping(_ typing: Bool) {
        guard typing != isTyping else { return }
        isTyping = typing
        layoutChanged()
    }

    /// A click somewhere that isn't the island: give the keyboard back and close.
    func clickedOutside() {
        guard isTyping else { return }
        setTyping(false)
        if !isHovering { setExpanded(false) }
    }

    // MARK: Color picker

    /// Closes the island and hands the pointer a loupe; the color under the
    /// click is copied and shown beside the camera.
    func pickColor() {
        setExpanded(false)
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { [weak self] color in
            guard let self else { return }
            self.sampler = nil
            guard let color, let picked = PickedColor(color) else { return }
            self.colors.add(picked)
            self.colors.copy(picked.text(self.prefs.colorFormat))
            self.tool = .color
            self.raise(.color(picked))
        }
    }

    // MARK: Countdowns

    /// The nearest day being counted down to, once it is close enough to show.
    var nextCountdown: CountdownItem? {
        guard prefs.showCountdowns else { return nil }
        let _ = sensors.clock
        return upcomingCountdowns.first { $0.days <= prefs.countdownLeadDays }
    }

    var upcomingCountdowns: [CountdownItem] {
        countdowns.upcoming(special: prefs.countdownFromCalendar ? calendar.specialDays : [])
    }

    var showsInsightsRow: Bool { prefs.showInsights && !insights.isEmpty }
    var showsNetworkRow: Bool { prefs.showNetwork }
    /// The switcher of tools in the wing left of the camera.
    var showsToolStrip: Bool { page == .home && showsPageSwitcher && note == nil }

    var calendarPanelHeight: CGFloat {
        contentTop + (weeksInMonth > 5 ? CalendarPanel.bodyHeight + 23 : CalendarPanel.bodyHeight) + 6
    }
    private var weeksInMonth: Int {
        Calendar.current.range(of: .weekOfMonth, in: .month, for: .now)?.count ?? 5
    }
    /// The weather-and-events row, present only when either has something.
    /// The calendar panel shows both itself, so the row steps aside for it.
    var showsInfoRow: Bool { !showsCalendarPanel && (showsCalendarContent || showsWeatherCard) }

    /// Everything that changes the island's shape; animating on this keeps
    /// progress ticks and clock updates from animating the frame.
    var layoutKey: some Hashable {
        [presentation.hashValue, isHovering ? 1 : 0, hasMusic ? 1 : 0, showsTimerRow ? 1 : 0,
         timer.isRinging ? 1 : 0, showsMusicActivity ? 1 : 0, Int(notchSize.width), Int(notchSize.height),
         tool.hashValue, page.hashValue]
    }

    // MARK: Geometry

    static let expandedWidth: CGFloat = 500
    static let terminalWidth: CGFloat = 640
    /// The open island's width: the terminal gets more room for its columns.
    var openWidth: CGFloat { Self.expandedWidth }

    var bodySize: CGSize {
        let notch = notchSize
        switch presentation {
        case .idle:
            // A gentle swell under the pointer says "I'm interactive".
            return isHovering ? CGSize(width: notch.width + 10, height: notch.height + 2) : notch
        case .compact:
            // Swell a touch under the pointer, just before it opens.
            let swell: CGFloat = isHovering ? 8 : 0
            let banner = compactDrawerHeight
            return CGSize(width: compactContentWidth + swell, height: notch.height + banner + swell * 0.25)
        case .expanded:
            return CGSize(width: openWidth, height: expandedHeight)
        }
    }

    /// The compact island's width, without the hover swell, so the content never
    /// shifts while the outline breathes around it. Each wing is sized from what
    /// it actually holds, plus a clear gap from the camera, so nothing slides
    /// under the notch. Both wings match, keeping the island centered.
    var compactContentWidth: CGFloat {
        if let alert = shownAlert, alert.metrics.drawerHeight > 0 {
            let wing = max(compactLeadingWidth, compactTrailingWidth) + compactEdge + Layout.notchGap
            return max(notchSize.width + wing * 2, alert.metrics.drawerWidth + Layout.sidePadding * 2)
        }
        if showsSongBanner {
            let wing = max(compactLeadingWidth, compactTrailingWidth) + compactEdge + Layout.notchGap
            return max(notchSize.width + wing * 2, bannerTextWidth + Layout.sidePadding * 2)
        }
        let wing = max(compactLeadingWidth, compactTrailingWidth) + compactEdge + Layout.notchGap
        return notchSize.width + wing * 2
    }

    /// Where open content starts: just below the camera, as in Apple's layout.
    var contentTop: CGFloat { notchSize.height + 10 }

    /// The open music player: cover row, scrubber, and controls below the camera.
    var musicPanelHeight: CGFloat {
        contentTop + MusicPanel.artSize + 12 + 18 + 6 + 44 + 6
    }

    func recheckPointer() { layoutChanged() }

    /// Side margin in the compact island, equal to the margin above and below a
    /// 22 pt item, so content sits concentric in the pill, as Apple's guidance asks.
    var compactEdge: CGFloat { max(6, (notchSize.height - 22) / 2) }

    /// The small cover's corner radius, concentric with the compact island's ends.
    var compactArtRadius: CGFloat { max(4, (notchSize.height / 2 - 2) - compactEdge) }

    /// A new song's name under the cover for a few seconds, as on Apple's island.
    var showsSongBanner: Bool {
        player.showsBanner && primaryActivity == .music && !levels.isShowing && !power.showsChargingAlert && alert == nil
    }

    var bannerText: String {
        guard let track = player.track else { return "" }
        return track.artist.isEmpty ? track.title : "\(track.title) · \(track.artist)"
    }

    /// Room for the banner's note symbol and text, capped so long names truncate.
    var bannerTextWidth: CGFloat {
        min(400, 14 + 6 + TextWidth.of(bannerText, size: 13, weight: .medium))
    }

    /// Whether the full "Charging" view shows (no music to share the island with).
    var showsChargingView: Bool {
        power.showsChargingAlert && primaryActivity == nil && !levels.isShowing && alert == nil
    }

    var compactLeadingWidth: CGFloat {
        if levels.isShowing {
            return 22 + 7 + TextWidth.of(levels.kind == .volume ? "Sound" : "Brightness", size: 13, weight: .semibold)
        }
        if let shownAlert { return shownAlert.metrics.leading }
        if showsChargingView { return ChargeMetrics.labelWidth }
        switch primaryActivity {
        case .music, .call: return 22
        case .timer: return 18
        case .recording: return 16
        case .privacy: return 12
        case .vpn: return 18
        case .countdown: return CountdownWing.leadingWidth(nextCountdown)
        case nil: return 0
        }
    }

    var compactTrailingWidth: CGFloat {
        if levels.isShowing { return LevelContent.barWidth }
        if let shownAlert { return shownAlert.metrics.trailing }
        if power.showsChargingAlert { return ChargeMetrics.indicatorWidth(percent: power.percent) }
        // A running clock is measured again each minute, in case it gained a digit.
        let _ = sensors.clock
        switch primaryActivity {
        case .music: return 22
        case .timer: return TextWidth.timer(timer.remainingText, size: 14)
        case .recording: return TextWidth.timer((recorder.startedAt ?? .now).elapsedText(), size: 14)
        case .call: return TextWidth.timer((sensors.call?.started ?? .now).elapsedText(), size: 14)
        case .privacy: return 20
        case .vpn: return TextWidth.of(VPNWing.label, size: 12, weight: .semibold)
        case .countdown: return CountdownWing.trailingWidth(nextCountdown)
        case nil: return 0
        }
    }

    /// The switcher sits in the wing beside the camera, so it steps aside
    /// when a timer has that space to itself.
    var showsPageSwitcher: Bool {
        if timer.isRinging { return false }
        return !(page == .home && showsTimerRow && !hasMusic && !showsCalendarPanel)
    }

    func setPage(_ page: Page) {
        guard page != self.page else { return }
        self.page = page
        setTyping(page == .home && tool == .reminders)
        if prefs.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        layoutChanged()
    }

    /// Something is being dragged over the island: open it on the shelf.
    func openShelfForDrop() {
        setExpanded(true)
        setPage(.shelf)
    }

    var expandedHeight: CGFloat {
        if timer.isRinging { return Layout.timerHeight }
        switch page {
        case .shelf: return contentTop + ShelfPanel.bodyHeight
        // As tall as the home page, so the pointer stays inside the island
        // after pressing the apps button in the bottom row.
        case .apps: return max(homeHeight, AppsPanel.height(apps: apps.items.count, adding: apps.isAdding, contentTop: contentTop))
        case .record: return contentTop + RecordPanel.bodyHeight
        case .vpn: return contentTop + VPNPanel.bodyHeight
        case .settings: return contentTop + SettingsPanel.bodyHeight
        case .home: return homeHeight
        }
    }

    private var homeHeight: CGFloat {
        if note != nil { return contentTop + NotePanel.height(replying: isReplying) }
        if focusedTool == .reminders { return contentTop + RemindersPanel.bodyHeight(rows: reminders.items.count) }
        if focusedTool == .color { return contentTop + ColorPanel.bodyHeight }
        var height: CGFloat = 0
        if showsQueuePanel { height += musicPanelHeight }
        else if showsCalendarPanel { height += calendarPanelHeight }
        else if hasMusic { height += musicPanelHeight }
        else { height += Layout.emptyHeaderHeight }
        if showsCallRow { height += Layout.callRowHeight }
        if showsRecordingRow { height += Layout.recordingRowHeight }
        if showsInfoRow { height += Layout.calendarRowHeight }
        if showsBatteryRow { height += Layout.batteryRowHeight }
        if showsTimerRow {
            height += hasMusic || showsCalendarPanel ? Layout.timerRowHeight : Layout.timerHeight - Layout.emptyHeaderHeight
        } else {
            height += Layout.presetRowHeight
        }
        return max(height, notchSize.height + 40)
    }

    /// Corner radius at the bottom of the island.
    var bottomRadius: CGFloat {
        switch presentation {
        case .idle: hasPhysicalNotch ? 9 : notchSize.height / 2
        case .compact: compactDrawerHeight > 0 ? 22 : notchSize.height / 2 - 2
        case .expanded: 36
        }
    }

    /// Radius of the concave flare joining the island to the screen edge.
    var topRadius: CGFloat {
        switch presentation {
        case .idle: isHovering ? 6 : (hasPhysicalNotch ? 0 : 0)
        case .compact: 8
        // Broad, soft shoulders where the open island meets the screen edge.
        case .expanded: 24
        }
    }

    // MARK: Hover

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        hoverTask?.cancel()
        if hovering {
            guard prefs.openTrigger == .hover else { return }
            // No delay set: open on this very event, not on a later tick.
            guard prefs.hoverDelay >= 0.01 else { setExpanded(true); return }
            hoverTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.prefs.hoverDelay))
                guard !Task.isCancelled, self.isHovering else { return }
                self.setExpanded(true)
            }
        } else {
            // Close a beat after the pointer leaves (a scrub or a reply holds it open).
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self, !self.isHovering, !self.isScrubbing, !self.wantsKeyboard else { return }
                self.setExpanded(false)
            }
        }
    }

    /// A click on the island's body (in Click mode) opens or closes it.
    func islandClicked() {
        guard prefs.openTrigger == .click else { return }
        setExpanded(!isExpanded)
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        if !expanded {
            tool = nil
            calendarDismissed = false
            note = nil
            isReplying = false
            isTyping = false
            if case .note = alert { alert = nil }
            if case .color = alert { alert = nil }
        }
        if expanded {
            // Each opening starts on the usual page; the reset waits until now so
            // the closing island doesn't flash back to it on the way out.
            page = .home
            calendar.refresh()
            weather.refresh()
            if showsBatteryRow { battery.refresh(charging: power.isCharging) }
            freeDiskSpace = Self.readFreeDiskSpace()
        }
        // The network is only sampled while there is someone to read it.
        network.setLive(expanded && prefs.showNetwork)
        if expanded, prefs.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        layoutChanged()
    }

    /// Settings' "Try It": open, hold, close, so the motion can be judged.
    func demo() {
        demoTask?.cancel()
        demoTask = Task { [weak self] in
            self?.setExpanded(true)
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, let self, !self.isHovering else { return }
            self.setExpanded(false)
        }
    }

    /// For snapshots: force a presentation without a pointer.
    func setPreview(expanded: Bool, hovering: Bool = false, page: Page = .home, tool: Tool? = nil) {
        self.page = page
        self.tool = tool
        isExpanded = expanded
        isHovering = hovering
    }

    private func layoutChanged() {
        // Let SwiftUI publish the new size first, then re-check the pointer.
        Task { @MainActor [weak self] in self?.onLayoutChange?() }
    }
}

enum Layout {
    static let musicHeight: CGFloat = 166
    static let emptyHeaderHeight: CGFloat = 50
    static let timerRowHeight: CGFloat = 70
    static let timerHeight: CGFloat = 84
    static let presetRowHeight: CGFloat = 44
    static let calendarRowHeight: CGFloat = 58
    static let bannerHeight: CGFloat = 30
    static let callRowHeight: CGFloat = 58
    static let recordingRowHeight: CGFloat = 44
    static let batteryRowHeight: CGFloat = 38
    static let insightRowHeight: CGFloat = 38
    static let networkRowHeight: CGFloat = 38
    static let sidePadding: CGFloat = 24
    /// Clear space between anything in the island and the camera housing:
    /// snug, as Apple asks, but never touching it.
    static let notchGap: CGFloat = 8
}

/// Measures text the way the island draws it, to size the wings.
enum TextWidth {
    static func of(_ text: String, size: CGFloat, weight: NSFont.Weight, digits: Bool = false) -> CGFloat {
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                          : NSFont.systemFont(ofSize: size, weight: weight)
        // A little slack: SwiftUI's text layout runs a hair wider than AppKit's measure.
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 3
    }

    /// A countdown's width. All digits are the same width, so measuring with
    /// zeros keeps the island from twitching every second.
    static func timer(_ text: String, size: CGFloat, weight: NSFont.Weight = .semibold) -> CGFloat {
        let template = String(text.map { $0.isNumber ? "0" : $0 })
        return of(template, size: size, weight: weight, digits: true) + 2
    }
}

enum ChargeMetrics {
    static let boltWidth: CGFloat = 12
    static let batteryWidth: CGFloat = 25 + 1.5 + 1.8
    static var labelWidth: CGFloat {
        boltWidth + 5 + TextWidth.of("Charging", size: 13, weight: .semibold)
    }
    static func indicatorWidth(percent: Int) -> CGFloat {
        TextWidth.of("\(percent)%", size: 13, weight: .semibold, digits: true) + 6 + batteryWidth
    }
}
