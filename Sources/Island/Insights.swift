import AppKit
import SwiftUI

/// One thing worth knowing right now, worked out from what the island already
/// watches: when to plug in, a storm on the way, a full disk, a day coming up.
struct Insight: Identifiable, Equatable {
    enum Action: Equatable { case none, weather, calendar, reminders, storage }

    var id: String
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    /// Lower comes first.
    var rank: Int
    var action: Action = .none
}

extension IslandModel {
    /// Everything worth saying, most pressing first.
    var insights: [Insight] {
        var list: [Insight] = []
        let now = Date.now
        let outlook = prefs.showWeather ? weather.outlook : nil
        let risk = prefs.warnOutage ? outlook?.outageRisk(now) : nil

        // Charging: when to plug in, or when it will be full.
        if prefs.adviseCharging, power.hasBattery {
            if !power.isPluggedIn {
                if let risk, risk.date.timeIntervalSince(now) < 6 * 3600, power.percent < 90 {
                    list.append(Insight(id: "charge-storm", symbol: "bolt.badge.clock.fill", tint: .timerOrange,
                                        title: "Charge before the storm",
                                        detail: "\(risk.reason) \(Self.around(risk.date, now: now)), at \(power.percent)% now", rank: 1))
                } else if power.percent <= 20 {
                    let left = battery.minutes.map { " · about \(Self.span($0)) left" } ?? ""
                    list.append(Insight(id: "charge-now", symbol: "battery.25percent", tint: .lowRed,
                                        title: "Charge now", detail: "\(power.percent)%\(left)", rank: 0))
                } else if let left = minutesUntilLowBattery {
                    let by = now + Double(left) * 60
                    list.append(Insight(id: "charge-by", symbol: "powerplug.fill",
                                        tint: left <= 30 ? .timerOrange : .chargeGreen,
                                        title: "Plug in by \(by.formatted(date: .omitted, time: .shortened))",
                                        detail: "20% in about \(Self.span(left))", rank: left <= 30 ? 1 : 5))
                }
            } else if power.isCharging, power.percent < 100, let minutes = battery.minutes, minutes > 0 {
                let at = now + Double(minutes) * 60
                list.append(Insight(id: "charge-full", symbol: "bolt.fill", tint: .chargeGreen,
                                    title: "Full by \(at.formatted(date: .omitted, time: .shortened))",
                                    detail: "\(Self.span(minutes)) to go", rank: 8))
            }
        }

        // Weather worth planning around.
        if let outlook {
            if prefs.warnStorm, let storm = outlook.storm(now) {
                let soon = storm.date.timeIntervalSince(now) < 3 * 3600
                list.append(Insight(id: "storm", symbol: "cloud.bolt.rain.fill", tint: Color(red: 1.0, green: 0.84, blue: 0.3),
                                    title: storm.date <= now ? "Thunderstorm now" : "Thunderstorm \(Self.around(storm.date, now: now))",
                                    detail: prefs.warnOutage ? "Power cuts are possible" : "Lightning nearby",
                                    rank: soon ? 1 : 2, action: .weather))
            }
            if let gale = outlook.gale(now) {
                let strong = gale.gust >= 75
                if strong ? prefs.warnOutage || prefs.warnStorm : prefs.warnStorm {
                    list.append(Insight(id: "wind", symbol: "wind", tint: Color(red: 0.6, green: 0.85, blue: 1.0),
                                        title: "\(strong ? "Strong winds" : "Windy") \(Self.around(gale.date, now: now))",
                                        detail: "Gusts to \(Self.speed(gale.gust, imperial: outlook.fahrenheit))"
                                            + (strong && prefs.warnOutage ? " · power cuts possible" : ""),
                                        rank: strong ? 2 : 6, action: .weather))
                }
            }
            if prefs.warnStorm {
                if let ice = outlook.freezingRain(now) {
                    list.append(Insight(id: "ice", symbol: "cloud.sleet.fill", tint: Color(red: 0.7, green: 0.9, blue: 1.0),
                                        title: "Freezing rain \(Self.around(ice.date, now: now))",
                                        detail: prefs.warnOutage ? "Ice can bring lines down" : "Icy outside", rank: 3, action: .weather))
                } else if let snow = outlook.snow(now) {
                    list.append(Insight(id: "snow", symbol: "cloud.snow.fill", tint: .white,
                                        title: "Snow \(Self.around(snow.date, now: now))", detail: "Wrap up", rank: 5, action: .weather))
                } else if outlook.storm(now) == nil, let rain = outlook.heavyRain(now) {
                    list.append(Insight(id: "rain", symbol: "cloud.heavyrain.fill", tint: Color(red: 0.45, green: 0.75, blue: 1.0),
                                        title: "Heavy rain \(Self.around(rain.date, now: now))",
                                        detail: String(format: "%.0f mm in the hour", max(1, rain.rain)), rank: 5, action: .weather))
                }
                if let frost = outlook.frost(now) {
                    list.append(Insight(id: "frost", symbol: "thermometer.snowflake", tint: Color(red: 0.7, green: 0.9, blue: 1.0),
                                        title: "Frost \(Self.around(frost.date, now: now))",
                                        detail: "Down to \(Int(frost.temperature.rounded()))°", rank: 7, action: .weather))
                }
                if let heat = outlook.heat(now) {
                    list.append(Insight(id: "heat", symbol: "thermometer.sun.fill", tint: .timerOrange,
                                        title: "Hot \(Self.around(heat.date, now: now))",
                                        detail: "Up to \(Int(heat.temperature.rounded()))°", rank: 6, action: .weather))
                }
                if let sun = outlook.strongSun(now) {
                    list.append(Insight(id: "uv", symbol: "sun.max.trianglebadge.exclamationmark.fill",
                                        tint: Color(red: 1.0, green: 0.8, blue: 0.2),
                                        title: "UV \(Int(sun.uv.rounded())) \(Self.around(sun.date, now: now))",
                                        detail: sun.uv >= 11 ? "Extreme" : "Very high", rank: 7, action: .weather))
                }
            }
        }

        // A disk with no room left makes everything else go wrong.
        if prefs.warnStorage, let free = freeDiskSpace, free < 10_000_000_000 {
            list.append(Insight(id: "disk", symbol: "internaldrive.fill", tint: free < 3_000_000_000 ? .lowRed : .timerOrange,
                                title: "Storage almost full",
                                detail: "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free",
                                rank: free < 3_000_000_000 ? 1 : 4, action: .storage))
        }

        // The next reminder, and days being counted down to.
        if prefs.showReminders, let next = reminders.next {
            let minutes = max(0, Int(next.due.timeIntervalSince(now) / 60))
            list.append(Insight(id: "reminder", symbol: "bell.fill", tint: .timerOrange, title: next.title,
                                detail: minutes < 1 ? "now" : "in \(Self.span(minutes))", rank: minutes <= 15 ? 3 : 8,
                                action: .reminders))
        }
        if prefs.showCountdowns {
            for item in upcomingCountdowns.prefix(2) where item.days <= max(prefs.countdownLeadDays, 30) {
                list.append(Insight(id: "count-\(item.id)", symbol: item.symbol, tint: item.tint, title: item.title,
                                    detail: item.daysText, rank: item.days == 0 ? 3 : 9, action: .calendar))
            }
        }
        return list.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }
    }

    func act(on insight: Insight) {
        switch insight.action {
        case .none: break
        case .weather: weather.openWeatherApp()
        case .calendar: setTool(.calendar)
        case .reminders: setTool(.reminders)
        case .storage:
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") { NSWorkspace.shared.open(url) }
        }
    }

    /// "1h 20m" or "35 min".
    static func span(_ minutes: Int) -> String {
        minutes >= 60 ? (minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m") : "\(minutes) min"
    }

    /// "now", "around 6 PM", "tonight around 11 PM" or "tomorrow around 6 AM".
    static func around(_ date: Date, now: Date) -> String {
        if date.timeIntervalSince(now) < 20 * 60 { return "now" }
        let hour = date.formatted(.dateTime.hour())
        return Calendar.current.isDate(date, inSameDayAs: now) ? "around \(hour)" : "tomorrow around \(hour)"
    }

    static func speed(_ kmh: Double, imperial: Bool) -> String {
        imperial ? "\(Int((kmh * 0.621).rounded())) mph" : "\(Int(kmh.rounded())) km/h"
    }
}

/// A row of small cards in the open island, one per insight, most pressing
/// first. It scrolls sideways when there are more than fit.
struct InsightsRow: View {
    let model: IslandModel

    var body: some View {
        let insights = model.insights
        IslandScroll(axis: .horizontal) {
            HStack(spacing: 6) {
                ForEach(insights) { insight in
                    InsightChip(insight: insight) { model.act(on: insight) }
                        .transition(.islandSwap(model.prefs))
                }
            }
            .padding(.horizontal, Layout.sidePadding)
        }
        .frame(height: 30)
        .frame(height: Layout.insightRowHeight, alignment: .top)
        .animation(model.prefs.settle(growing: true), value: insights.map(\.id))
    }
}

private struct InsightChip: View {
    let insight: Insight
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: insight.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(insight.tint)
                Text(insight.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(insight.detail)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(insight.tint.opacity(hovering ? 0.2 : 0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15).paced, value: hovering)
        .help("\(insight.title) · \(insight.detail)")
    }
}
