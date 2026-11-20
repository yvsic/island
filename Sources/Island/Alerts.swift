import SwiftUI

/// A message or email that arrived, shown as a banner and open to a reply.
struct IslandNote: Equatable, Identifiable {
    enum Source: Equatable { case messages, mail }

    var id: String
    var source: Source
    var sender: String
    var text: String
    /// Messages: the conversation to reply into.
    var chatID: String?
    /// Mail: the message to reply to.
    var mailID: Int?

    var bundleID: String { source == .messages ? "com.apple.MobileSMS" : "com.apple.mail" }
    var appName: String { source == .messages ? "Messages" : "Mail" }
}

/// Something that takes over the island beside the camera for a few seconds,
/// then tucks away: the same family as the charging moment.
enum IslandAlert: Equatable {
    case lowBattery(Int)
    case headphones(AirPodsStatus)
    case rain(minutes: Int)
    case note(IslandNote)
    /// About to reach 20%: time to find the charger.
    case chargeSoon(minutes: Int, percent: Int)
    case storm(minutes: Int, outage: Bool)
    /// The charger and the network went at the same moment.
    case powerCut(percent: Int)
    case reminder(String)
    case color(PickedColor)
    case vpn(VPNEvent)

    enum VPNEvent: Equatable {
        case on(String), off, dropped
        var title: String { switch self { case .on: "VPN On"; case .off: "VPN Off"; case .dropped: "VPN Dropped" } }
        var detail: String {
            switch self {
            case .on(let server): server
            case .off: "Your traffic goes direct again"
            case .dropped: "Reconnecting…"
            }
        }
    }

    /// How long it stays up, in seconds.
    var duration: Double {
        switch self {
        case .lowBattery: 3.6
        case .headphones: 4.5
        case .rain: 5
        case .note: 6
        case .chargeSoon: 5
        case .storm: 6
        case .powerCut: 7
        case .reminder: 9
        case .color: 5
        case .vpn: 3.5
        }
    }

    /// Room each part needs: the two wings beside the camera and, for most,
    /// a drawer that drops below it.
    var metrics: (leading: CGFloat, trailing: CGFloat, drawerHeight: CGFloat, drawerWidth: CGFloat) {
        switch self {
        case .lowBattery(let percent):
            return (ChargeMetrics.batteryWidth + 6 + TextWidth.of("Low Battery", size: 13, weight: .semibold),
                    TextWidth.of("\(percent)%", size: 13, weight: .semibold, digits: true), 0, 0)
        case .headphones(let status):
            let name = TextWidth.of(status.name, size: 13, weight: .semibold)
            let parts = CGFloat(HeadphoneLevels.parts(status).count)
            return (22, TextWidth.of("Connected", size: 12, weight: .semibold),
                    status.hasLevels ? 60 : 30, min(380, max(name, parts * 84 + (parts - 1) * 8)))
        case .rain(let minutes):
            return (22, TextWidth.of("\(minutes) min", size: 13, weight: .semibold, digits: true), 30,
                    22 + TextWidth.of(Self.rainText(minutes), size: 13, weight: .medium))
        case .note(let note):
            return (20, TextWidth.of("now", size: 12, weight: .medium), 48,
                    min(380, max(TextWidth.of(note.sender, size: 13, weight: .semibold),
                                 TextWidth.of(note.text, size: 13, weight: .regular))))
        case .chargeSoon(let minutes, let percent):
            return (ChargeMetrics.batteryWidth + 6 + TextWidth.of("Charge Soon", size: 13, weight: .semibold),
                    TextWidth.of("\(percent)%", size: 13, weight: .semibold, digits: true), 30,
                    TextWidth.of(Self.chargeText(minutes), size: 13, weight: .medium))
        case .storm(let minutes, let outage):
            return (22, TextWidth.of(Self.shortTime(minutes), size: 13, weight: .semibold, digits: true), outage ? 46 : 30,
                    22 + max(TextWidth.of(Self.stormText(minutes), size: 13, weight: .medium),
                             outage ? TextWidth.of(Self.outageText, size: 12, weight: .medium) : 0))
        case .powerCut(let percent):
            return (22 + 6 + TextWidth.of("Power Cut?", size: 13, weight: .semibold),
                    TextWidth.of("\(percent)%", size: 13, weight: .semibold, digits: true), 30,
                    TextWidth.of(Self.powerCutText, size: 13, weight: .medium))
        case .reminder(let title):
            return (22, TextWidth.of("now", size: 12, weight: .medium), 30,
                    min(380, 20 + TextWidth.of(title, size: 13, weight: .semibold)))
        case .color(let color):
            return (20, TextWidth.of("Copied", size: 12, weight: .semibold), 30,
                    TextWidth.of(color.hex, size: 13, weight: .semibold, digits: true) + 14
                        + TextWidth.of(color.rgb, size: 12, weight: .medium, digits: true))
        case .vpn(let event):
            return (22 + 6 + TextWidth.of(event.title, size: 13, weight: .semibold), 0, 30,
                    min(380, TextWidth.of(event.detail, size: 13, weight: .medium)))
        }
    }

    static func rainText(_ minutes: Int) -> String { "Rain starting in \(minutes) min" }
    static func chargeText(_ minutes: Int) -> String { "About \(minutes) min until 20%: plug in soon" }
    static func stormText(_ minutes: Int) -> String {
        minutes <= 5 ? "Thunderstorm arriving now" : "Thunderstorm in about \(shortTime(minutes))"
    }
    static let outageText = "Power cuts are possible: keep your Mac charged"
    static let powerCutText = "Charger and network went together"
    static func shortTime(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }
}

/// An alert beside the camera: wings in the notch row, and its drawer below.
struct AlertContent: View {
    let model: IslandModel
    let alert: IslandAlert

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading.frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: model.notchSize.width + Layout.notchGap * 2)
                trailing.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, model.compactEdge)
            .frame(height: model.notchSize.height)

            if alert.metrics.drawerHeight > 0 {
                drawer
                    .frame(maxWidth: alert.metrics.drawerWidth)
                    .frame(height: alert.metrics.drawerHeight, alignment: .top)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private var leading: some View {
        switch alert {
        case .lowBattery(let percent):
            HStack(spacing: 6) {
                PulseOnce { BatteryGlyph(fill: max(0.12, Double(percent) / 100), color: .lowRed, sheen: false) }
                Text("Low Battery")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
        case .headphones(let status):
            Image(systemName: status.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 22)
                .symbolEffect(.bounce, options: .nonRepeating)
        case .rain:
            Image(systemName: "cloud.rain.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 15))
                .frame(width: 22)
                .symbolEffect(.bounce, options: .nonRepeating)
        case .note(let note):
            AppIconView(bundleID: note.bundleID, size: 20)
        case .chargeSoon(_, let percent):
            HStack(spacing: 6) {
                PulseOnce { BatteryGlyph(fill: max(0.12, Double(percent) / 100), color: .timerOrange, sheen: false) }
                Text("Charge Soon")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
        case .storm:
            Image(systemName: "cloud.bolt.rain.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 15))
                .frame(width: 22)
                .symbolEffect(.bounce, options: .nonRepeating)
        case .powerCut:
            HStack(spacing: 6) {
                Image(systemName: "powerplug.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.timerOrange)
                    .frame(width: 22)
                    .symbolEffect(.bounce, options: .nonRepeating)
                Text("Power Cut?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
        case .reminder:
            Image(systemName: "bell.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.timerOrange)
                .frame(width: 22)
                .symbolEffect(.wiggle, options: .nonRepeating)
        case .color(let color):
            Circle()
                .fill(color.color)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .frame(width: 16, height: 16)
                .frame(width: 20)
        case .vpn(let event):
            HStack(spacing: 6) {
                Image(systemName: event == .off ? "shield.slash.fill" : event == .dropped ? "exclamationmark.shield.fill" : "lock.shield.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(event == .off ? .white.opacity(0.6) : event == .dropped ? Color.timerOrange : Color.chargeGreen)
                    .frame(width: 22)
                    .symbolEffect(.bounce, options: .nonRepeating)
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch alert {
        case .lowBattery(let percent):
            Text("\(percent)%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.lowRed)
                .fixedSize()
        case .headphones:
            Text("Connected")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.chargeGreen)
                .fixedSize()
        case .rain(let minutes):
            Text("\(minutes) min")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1.0))
                .fixedSize()
        case .note, .reminder:
            Text("now")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize()
        case .chargeSoon(_, let percent):
            Text("\(percent)%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.timerOrange)
                .fixedSize()
        case .storm(let minutes, _):
            Text(IslandAlert.shortTime(minutes))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.3))
                .fixedSize()
        case .powerCut(let percent):
            Text("\(percent)%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize()
        case .color:
            Text("Copied")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.chargeGreen)
                .fixedSize()
        case .vpn:
            EmptyView()
        }
    }

    @ViewBuilder private var drawer: some View {
        switch alert {
        case .lowBattery:
            EmptyView()
        case .headphones(let status):
            VStack(spacing: 6) {
                Text(status.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                if status.hasLevels { HeadphoneLevels(status: status) }
            }
        case .rain(let minutes):
            Text(IslandAlert.rainText(minutes))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        case .note(let note):
            VStack(alignment: .leading, spacing: 1) {
                Text(note.sender)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(note.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .chargeSoon(let minutes, _):
            line(IslandAlert.chargeText(minutes))
        case .storm(let minutes, let outage):
            VStack(spacing: 2) {
                line(IslandAlert.stormText(minutes))
                if outage {
                    Text(IslandAlert.outageText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
        case .powerCut:
            line(IslandAlert.powerCutText)
        case .reminder(let title):
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        case .color(let color):
            HStack(spacing: 14) {
                Text(color.hex)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text(color.rgb)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            .fixedSize()
        case .vpn(let event):
            line(event.detail)
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
            .lineLimit(1)
    }
}

/// Each bud's and the case's charge, side by side.
struct HeadphoneLevels: View {
    let status: AirPodsStatus

    static func parts(_ status: AirPodsStatus) -> [(String, Int)] {
        var parts: [(String, Int)] = []
        if let left = status.left { parts.append(("L", left)) }
        if let right = status.right { parts.append(("R", right)) }
        if let level = status.caseLevel { parts.append(("Case", level)) }
        if parts.isEmpty, let main = status.main { parts.append(("Battery", main)) }
        return parts
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.parts(status), id: \.0) { part in
                HStack(spacing: 5) {
                    Text(part.0)
                        .foregroundStyle(.white.opacity(0.5))
                    BatteryGlyph(fill: Double(part.1) / 100, color: part.1 <= 20 ? .lowRed : .chargeGreen, sheen: false)
                        .scaleEffect(0.8)
                        .frame(width: 23)
                    Text("\(part.1)%")
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                .font(.system(size: 11.5, weight: .semibold))
                .fixedSize()
                .frame(width: 84)
            }
        }
    }
}

/// Swells once with a soft red glow, then rests: "look here", said once.
struct PulseOnce<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var fired = false

    var body: some View {
        content
            .keyframeAnimator(initialValue: CGFloat(1), trigger: fired) { view, scale in
                view
                    .scaleEffect(scale)
                    .shadow(color: Color.lowRed.opacity(Double(scale - 1) * 4), radius: 6)
            } keyframes: { _ in
                SpringKeyframe(Preferences.shared.flourishes ? 1.22 : 1, duration: Preferences.shared.pace(0.28), spring: .snappy)
                SpringKeyframe(1, duration: Preferences.shared.pace(0.6), spring: .bouncy(extraBounce: 0.1))
            }
            .task {
                try? await Task.sleep(for: .seconds(Preferences.shared.pace(0.35)))
                fired = true
            }
    }
}

/// An app's icon, or a plain rounded square if it can't be found.
struct AppIconView: View {
    let bundleID: String
    var size: CGFloat = 20

    var body: some View {
        if let icon = AppIcons.icon(bundleID: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(.white.opacity(0.2))
                .frame(width: size, height: size)
        }
    }
}
