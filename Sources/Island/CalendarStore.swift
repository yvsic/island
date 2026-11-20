import AppKit
import EventKit
import SwiftUI

struct UpcomingEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
}

/// Upcoming events from the user's calendars, within the window set in Settings.
@Observable
final class CalendarStore {
    enum Access { case notAsked, granted, denied }

    private(set) var events: [UpcomingEvent] = []
    /// Day numbers in this month that have at least one event, for the dots in the grid.
    private(set) var busyDays: Set<Int> = []
    private(set) var access: Access = .notAsked
    /// Birthdays and public holidays in the next two months, for countdowns.
    private(set) var specialDays: [SpecialDay] = []
    @ObservationIgnored private var specialReadAt = Date.distantPast

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var refresher: Task<Void, Never>?
    @ObservationIgnored private var previewing = false

    func start() {
        updateAccess()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Times like "in 5 min" go stale, and events pass: refresh every minute.
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func requestAccess() {
        Task {
            _ = try? await store.requestFullAccessToEvents()
            updateAccess()
            refresh()
            if access == .denied, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .notAsked
        default: access = .denied
        }
    }

    func refresh() {
        let prefs = Preferences.shared
        readSpecialDays()
        guard prefs.showCalendar, access == .granted else {
            if !events.isEmpty { events = []; onChange?() }
            return
        }
        let now = Date.now
        let end = Calendar.current.date(byAdding: .day, value: prefs.calendarDays, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let found = store.events(matching: predicate)
            .filter { $0.endDate > now && (prefs.calendarAllDay || !$0.isAllDay) && $0.status != .canceled }
            .sorted { ($0.isAllDay ? 1 : 0, $0.startDate) < ($1.isAllDay ? 1 : 0, $1.startDate) }
            .map { event in
                UpcomingEvent(id: event.calendarItemIdentifier,
                              title: event.title?.isEmpty == false ? event.title : "Untitled Event",
                              start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                              color: Color(nsColor: event.calendar.color ?? .systemBlue))
            }
        busyDays = monthBusyDays()
        let hadEvents = !events.isEmpty
        if found != events { events = found }
        if hadEvents != !found.isEmpty { onChange?() }
    }

    /// Every event on one day, all-day ones first, for the calendar panel.
    func events(on day: Date) -> [UpcomingEvent] {
        guard access == .granted, !previewing else { return previewDayEvents(on: day) }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { (Preferences.shared.calendarAllDay || !$0.isAllDay) && $0.status != .canceled }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map(Self.upcoming)
    }

    /// Birthdays (from Contacts' calendar) and holiday calendars. Read at most
    /// every half hour: they don't move.
    private func readSpecialDays() {
        guard !previewing else { return }
        guard access == .granted, Preferences.shared.showCountdowns, Preferences.shared.countdownFromCalendar else {
            if !specialDays.isEmpty { specialDays = [] }
            specialReadAt = .distantPast
            return
        }
        guard Date.now.timeIntervalSince(specialReadAt) > 30 * 60 else { return }
        specialReadAt = .now
        let calendars = store.calendars(for: .event).filter {
            $0.type == .birthday || $0.title.localizedCaseInsensitiveContains("holiday")
        }
        guard !calendars.isEmpty else {
            specialDays = []
            return
        }
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 60, to: start) ?? start
        let found = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
            .filter { $0.status != .canceled }
            .prefix(40)
            .map { SpecialDay(title: $0.title?.isEmpty == false ? $0.title : "Event", date: $0.startDate,
                              kind: $0.calendar.type == .birthday ? .birthday : .holiday) }
        if Array(found) != specialDays { specialDays = Array(found) }
    }

    private func monthBusyDays() -> Set<Int> {
        let calendar = Calendar.current
        guard let month = calendar.dateInterval(of: .month, for: .now) else { return [] }
        let found = store.events(matching: store.predicateForEvents(withStart: month.start, end: month.end, calendars: nil))
        var days = Set<Int>()
        for event in found where event.status != .canceled {
            var day = max(event.startDate, month.start)
            while day < min(event.endDate, month.end) {
                days.insert(calendar.component(.day, from: day))
                guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { break }
                day = next
            }
        }
        return days
    }

    private static func upcoming(_ event: EKEvent) -> UpcomingEvent {
        UpcomingEvent(id: event.calendarItemIdentifier,
                      title: event.title?.isEmpty == false ? event.title : "Untitled Event",
                      start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                      color: Color(nsColor: event.calendar.color ?? .systemBlue))
    }

    private func previewDayEvents(on day: Date) -> [UpcomingEvent] {
        events.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
    }

    func open(_ event: UpcomingEvent) {
        let url = URL(string: "ical://ekevent/\(event.id)?method=show&options=more")
        if let url, NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    /// For snapshots: no Up Next row.
    func setPreviewHidden() { access = .denied }

    /// For snapshots.
    func setPreview(special: [SpecialDay]) {
        previewing = true
        specialDays = special
    }

    /// For snapshots.
    func setPreview(_ events: [UpcomingEvent]) {
        access = .granted
        previewing = true
        self.events = events
        busyDays = Set(events.map { Calendar.current.component(.day, from: $0.start) })
    }
}

extension UpcomingEvent {
    /// "Now", "In 15 min", "Today 3:00 PM", "Tomorrow 9:00 AM", "Wed 9:00 AM", or "… · All Day".
    func whenText(now: Date = .now) -> String {
        let calendar = Calendar.current
        let time = start.formatted(date: .omitted, time: .shortened)
        let day: String
        if calendar.isDateInToday(start) || (isAllDay && start <= now) {
            day = "Today"
        } else if calendar.isDateInTomorrow(start) {
            day = "Tomorrow"
        } else {
            day = start.formatted(.dateTime.weekday(.abbreviated))
        }
        if isAllDay { return "\(day) · All Day" }
        if start <= now { return "Now · until \(end.formatted(date: .omitted, time: .shortened))" }
        let minutes = Int(start.timeIntervalSince(now) / 60)
        if minutes < 60 { return minutes <= 1 ? "Starting now" : "In \(minutes) min" }
        return "\(day) \(time)"
    }

    var isHappeningNow: Bool { !isAllDay && start <= .now && end > .now }
}

extension UpcomingEvent {
    /// "9:00 – 11:00", or "All Day".
    var timeRange: String {
        if isAllDay { return "All Day" }
        let style = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(start.formatted(style)) – \(end.formatted(style))"
    }
}
