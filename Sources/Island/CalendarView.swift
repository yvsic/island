import SwiftUI

/// The info row in the open island: today's weather, then the next events as
/// small cards in their calendars' colors. Each part shows only when it has
/// something to say; with neither, the row isn't there at all.
struct InfoRow: View {
    let model: IslandModel
    private var calendar: CalendarStore { model.calendar }
    private var prefs: Preferences { model.prefs }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 8) {
                if model.showsWeatherCard, let now = model.weather.now {
                    WeatherCard(weather: now, wide: !model.showsCalendarContent,
                                sky: SkyNote.current(model: model, at: context.date)) { model.weather.openWeatherApp() }
                        .transition(.islandSwap(prefs))
                }
                if model.showsCalendarContent {
                    if calendar.access == .notAsked {
                        connectPrompt
                    } else {
                        let limit = model.showsWeatherCard ? 1 : 2
                        ForEach(calendar.events.prefix(limit)) { event in
                            EventCard(event: event, now: context.date) { model.setCalendarPinned(true) }
                                .transition(.islandSwap(prefs))
                        }
                        if calendar.events.count > limit {
                            moreBadge(calendar.events.count - limit)
                        }
                    }
                }
            }
            .animation(prefs.settle(growing: true), value: calendar.events.map(\.id))
            .animation(prefs.settle(growing: true), value: model.showsWeatherCard)
        }
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: Layout.calendarRowHeight)
    }

    private func moreBadge(_ count: Int) -> some View {
        Text("+\(count)")
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: 34, height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture { model.setCalendarPinned(true) }
            .help("\(count) more in the next \(prefs.calendarDays) days")
            .transition(.islandSwap(prefs))
    }

    private var connectPrompt: some View {
        HStack(spacing: 8) {
            if !model.showsWeatherCard {
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text("See what's coming up")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            Button("Connect Calendar") { calendar.requestAccess() }
                .buttonStyle(PillButtonStyle())
        }
    }
}

/// Current conditions: the condition's symbol in color, the temperature, and
/// today's high and low. Click to open Weather.
struct WeatherCard: View {
    let weather: WeatherNow
    /// Alone in the row, the card spans it and names the conditions and place.
    var wide = false
    /// A sunrise or sunset coming up, or tonight's moon, in place of high and low.
    var sky: SkyNote?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: weather.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 20))
                    .frame(width: 26)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Int(weather.temperature.rounded()))°")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(value: weather.temperature))
                    if let sky {
                        HStack(spacing: 3) {
                            Image(systemName: sky.symbol)
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: 10, weight: .semibold))
                            Text(wide ? sky.long : sky.short)
                        }
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(sky.tint.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .transition(.opacity)
                    } else {
                        Text("H\(Int(weather.high.rounded()))°  L\(Int(weather.low.rounded()))°")
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .fixedSize()
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
                if wide {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(weather.summary)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(weather.place)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .lineLimit(1)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: wide ? nil : 128, height: 44)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(hovering ? 0.11 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .hoverLift(hovering)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15).paced, value: hovering)
        .animation(Preferences.shared.settle(growing: true), value: weather)
        .help("\(weather.summary) · \(weather.place)")
    }
}

struct EventCard: View {
    let event: UpcomingEvent
    let now: Date
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let soon = event.isHappeningNow || (!event.isAllDay && event.start.timeIntervalSince(now) < 15 * 60)
        Button(action: action) {
            HStack(spacing: 9) {
                Capsule()
                    .fill(event.color)
                    .frame(width: 3.5, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(event.color.mix(with: .white, by: 0.25))
                        .lineLimit(1)
                    Text(event.whenText(now: now))
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        // Starting soon or happening now: the calendar's color draws the eye.
                        .foregroundStyle(event.color.mix(with: .white, by: 0.25).opacity(soon ? 1 : 0.7))
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
            // Tinted in the calendar's color, like Apple's calendar widget.
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(event.color.opacity(hovering ? 0.28 : 0.18)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .hoverLift(hovering)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15).paced, value: hovering)
        .help("Show calendar")
    }
}

/// What the sky is about to do, for the weather card.
struct SkyNote: Equatable {
    var symbol: String
    var short: String
    var long: String
    var tint: Color

    static func current(model: IslandModel, at date: Date) -> SkyNote? {
        let prefs = model.prefs
        if prefs.showSunEvents, let event = model.weather.sunEvent(at: date, lead: prefs.sunLeadMinutes) {
            let minutes = max(1, Int((event.date.timeIntervalSince(date) / 60).rounded()))
            let name = event.isSunrise ? "Sunrise" : "Sunset"
            return SkyNote(symbol: event.isSunrise ? "sunrise.fill" : "sunset.fill",
                           short: "\(name) \(minutes)m", long: "\(name) in \(minutes) min",
                           tint: Color(red: 1.0, green: 0.72, blue: 0.3))
        }
        if prefs.showMoonPhase, let now = model.weather.now, !now.isDay {
            let moon = MoonPhase.now(date)
            return SkyNote(symbol: moon.symbol, short: moon.name, long: moon.name,
                           tint: Color(red: 0.8, green: 0.84, blue: 1.0))
        }
        return nil
    }
}

/// A small capsule button for inline actions in the island.
struct PillButtonStyle: ButtonStyle {
    /// A shorter pill, for rows of settings.
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, compact ? 10 : 12)
            .frame(height: compact ? 22 : 26)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.24 : 0.14)))
            .scaleEffect(configuration.isPressed ? Preferences.shared.pressScale : 1)
            .animation(Preferences.shared.buttonSpring, value: configuration.isPressed)
    }
}
