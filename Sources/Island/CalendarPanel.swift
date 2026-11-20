import SwiftUI

/// With nothing playing, the open island becomes a calendar like Apple's: the
/// day and its events on the left, the month on the right. Click a date to see
/// that day's events.
struct CalendarPanel: View {
    let model: IslandModel
    @State private var selected = Calendar.current.startOfDay(for: .now)

    static let bodyHeight: CGFloat = 158

    private var calendar: CalendarStore { model.calendar }
    private var prefs: Preferences { model.prefs }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            dayColumn
                .frame(width: 196, alignment: .leading)
            MonthGrid(selected: $selected, busyDays: calendar.busyDays)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, model.contentTop)
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: model.calendarPanelHeight, alignment: .top)
        .staggered(0)
    }

    private var dayColumn: some View {
        let events = calendar.events(on: selected)
        let limit = events.count > 3 ? 2 : 3
        return VStack(alignment: .leading, spacing: 0) {
            // One compact line: weekday, date, week number.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if model.calendarHasBack {
                    // Brought up over the music or a timer: a way back to it.
                    Button { model.setCalendarPinned(false) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(.white.opacity(0.14)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressStyle())
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                    .padding(.trailing, 2)
                    .help(model.hasMusic ? "Back to music" : "Back")
                }
                Text(selected.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .foregroundStyle(Color.calendarRed)
                    .contentTransition(.opacity)
                Text(selected.formatted(.dateTime.day()))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                // The week number gives way to the Back button when space is short.
                if !(model.calendarHasBack && model.showsWeatherCard) {
                    Text("W\(Calendar.current.component(.weekOfYear, from: selected))")
                        .foregroundStyle(Color.calendarRed.opacity(0.55))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 4)
                if model.showsWeatherCard, let weather = model.weather.now {
                    Button(action: model.weather.openWeatherApp) {
                        HStack(spacing: 4) {
                            Image(systemName: weather.symbol)
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: 12))
                            Text("\(Int(weather.temperature.rounded()))°")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .fixedSize()
                    }
                    .buttonStyle(PressStyle())
                    .help("\(weather.summary) · H\(Int(weather.high.rounded()))° L\(Int(weather.low.rounded()))° · \(weather.place)")
                }
            }
            .font(.system(size: 12, weight: .bold))
            .frame(height: 17)
            VStack(alignment: .leading, spacing: 4) {
                if events.isEmpty {
                    Text("No events")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.05)))
                        .transition(.opacity)
                } else {
                    ForEach(events.prefix(limit)) { event in
                        EventPill(event: event) { calendar.open(event) }
                            .transition(.islandSwap(prefs))
                    }
                    if events.count > limit {
                        Text("\(events.count - limit) more")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.leading, 2)
                    }
                }
            }
            .padding(.top, 5)
        }
        .animation(prefs.settle(growing: true), value: selected)
    }
}

/// An event as a tinted pill in its calendar's color, like Apple's widget.
struct EventPill: View {
    let event: UpcomingEvent
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Capsule().fill(event.color).frame(width: 3, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(event.color.mix(with: .white, by: 0.25))
                        .lineLimit(1)
                    Text(event.timeRange)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(event.color.mix(with: .white, by: 0.25).opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(event.color.opacity(hovering ? 0.28 : 0.18)))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15).paced, value: hovering)
        .help("Open in Calendar")
    }
}

/// This month: weekday initials, then the dates. Today is a red disc; the
/// chosen date a white one; days with events get a small dot.
struct MonthGrid: View {
    @Binding var selected: Date
    let busyDays: Set<Int>

    private let calendar = Calendar.current
    private let today = Calendar.current.startOfDay(for: .now)

    var body: some View {
        let days = monthDays()
        VStack(alignment: .trailing, spacing: 3) {
            Text(today.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.calendarRed)
                .frame(height: 17)
                .padding(.trailing, 4)
            Grid(horizontalSpacing: 0, verticalSpacing: 2) {
                GridRow {
                    ForEach(weekdaySymbols.indices, id: \.self) { i in
                        Text(weekdaySymbols[i])
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(isWeekendColumn(i) ? 0.35 : 0.8))
                            .frame(maxWidth: .infinity)
                            .frame(height: 17)
                    }
                }
                ForEach(0..<(days.count / 7), id: \.self) { row in
                    GridRow {
                        ForEach(0..<7, id: \.self) { column in
                            cell(days[row * 7 + column], column: column)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func cell(_ date: Date?, column: Int) -> some View {
        if let date {
            let day = calendar.component(.day, from: date)
            let isToday = date == today
            let isSelected = date == selected && !isToday
            Button {
                selected = date
            } label: {
                Text("\(day)")
                    .font(.system(size: 12.5, weight: isToday || isSelected ? .bold : .semibold).monospacedDigit())
                    .foregroundStyle(isToday ? .white : isSelected ? .black : .white.opacity(isWeekendColumn(column) ? 0.35 : 0.92))
                    .frame(width: 21, height: 21)
                    .background(Circle().fill(isToday ? Color.calendarRed : isSelected ? .white : .clear))
                    .overlay(alignment: .bottom) {
                        if busyDays.contains(day), !isToday, !isSelected {
                            Circle().fill(.white.opacity(0.5)).frame(width: 3, height: 3).offset(y: 2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .animation(Preferences.shared.settle(growing: true), value: isSelected)
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: 21)
        }
    }

    /// Weekday initials starting from the locale's first day of the week.
    private var weekdaySymbols: [String] {
        // One letter each, like Apple's widget (some regions give two).
        let symbols = calendar.veryShortStandaloneWeekdaySymbols.map { String($0.prefix(1)) }
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func isWeekendColumn(_ column: Int) -> Bool {
        let weekday = (calendar.firstWeekday - 1 + column) % 7 + 1 // 1 = Sunday
        return weekday == 1 || weekday == 7
    }

    /// The month's dates, padded with nils to whole weeks.
    private func monthDays() -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: today),
              let count = calendar.range(of: .day, in: .month, for: today)?.count else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let lead = (firstWeekday - calendar.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: lead)
        for offset in 0..<count {
            days.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }
}

extension Color {
    static let calendarRed = Color(red: 1.0, green: 0.27, blue: 0.27)
}
