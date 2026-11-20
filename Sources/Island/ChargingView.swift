import SwiftUI

extension Color {
    static let chargeGreen = Color(red: 0.2, green: 0.84, blue: 0.29)
}

/// The moment after plugging in: "Charging" by the camera on the left, the
/// battery filling up to its level on the right, the way iPhone does it.
struct ChargingContent: View {
    let model: IslandModel
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.chargeGreen)
                    .symbolEffect(.bounce.up, options: .nonRepeating.speed(Preferences.shared.speed), value: appeared)
                Text("Charging")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: model.notchSize.width + Layout.notchGap * 2)

            ChargeIndicator(percent: model.power.percent)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, model.compactEdge)
        .frame(height: model.notchSize.height)
        .task {
            try? await Task.sleep(for: .seconds(Preferences.shared.pace(0.32)))
            appeared = true
        }
    }
}

/// Percentage and battery that count and fill up to the charge level on appear.
struct ChargeIndicator: View {
    let percent: Int
    var showsPercent = true
    @State private var shownPercent: Int
    @State private var fill: Double

    /// Snapshots can't run the fill-up animation, so they start full.
    static var startsFilled = false

    init(percent: Int, showsPercent: Bool = true) {
        self.percent = percent
        self.showsPercent = showsPercent
        let start = Self.startsFilled ? percent : 0
        _shownPercent = State(initialValue: start)
        _fill = State(initialValue: Double(start) / 100)
    }

    var body: some View {
        HStack(spacing: 6) {
            if showsPercent {
                Text("\(shownPercent)%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.chargeGreen)
                    .contentTransition(.numericText(value: Double(shownPercent)))
                    .lineLimit(1)
                    .fixedSize()
            }
            BatteryGlyph(fill: fill)
        }
        .onAppear {
            // Count up and fill once the island has opened out.
            withAnimation(.spring(duration: 0.9, bounce: 0.1).delay(0.32).paced) {
                fill = Double(percent) / 100
                shownPercent = percent
            }
        }
    }
}

/// A battery outline whose green fill slides up to the charge level, with a soft
/// light sweeping across it while it charges.
struct BatteryGlyph: View {
    var fill: Double
    var color: Color = .chargeGreen
    /// The drifting highlight is for charging only.
    var sheen = true

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1.2)
                GeometryReader { geo in
                    let width = max(0, (geo.size.width) * fill)
                    RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                        .fill(color)
                        .frame(width: width)
                        .overlay(alignment: .leading) {
                            if sheen, color == .chargeGreen { ChargeSheen().frame(width: width).clipped() }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2.2, style: .continuous))
                }
                .padding(2.2)
            }
            .frame(width: 25, height: 12.5)
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 1.8, height: 4.5)
        }
    }
}

/// A highlight that drifts across the battery fill.
private struct ChargeSheen: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let period = Preferences.shared.pace(1.6)
            let phase = (t.truncatingRemainder(dividingBy: period)) / period
            GeometryReader { geo in
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 10)
                    .offset(x: -10 + (geo.size.width + 20) * phase)
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}
