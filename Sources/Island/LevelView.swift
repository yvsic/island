import SwiftUI

/// Volume or brightness: the symbol by the camera on the left, a level bar on
/// the right. The bar glides as the keys are pressed.
struct LevelContent: View {
    let model: IslandModel
    private var levels: LevelMonitor { model.levels }

    static let barWidth: CGFloat = 92

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                symbol
                    .frame(width: 22)
                Text(levels.kind == .volume ? "Sound" : "Brightness")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: model.notchSize.width + Layout.notchGap * 2)
            LevelBar(level: levels.level, dimmed: levels.kind == .volume && levels.isMuted,
                     nudge: levels.nudge, nudgedUp: levels.nudgedUp)
                .frame(width: Self.barWidth)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, model.compactEdge)
        .frame(height: model.notchSize.height)
    }

    @ViewBuilder private var symbol: some View {
        Group {
            switch levels.kind {
            case .volume:
                let silent = levels.isMuted || levels.level < 0.001
                Image(systemName: silent ? "speaker.slash.fill" : "speaker.wave.3.fill",
                      variableValue: levels.level)
            case .brightness:
                Image(systemName: levels.level < 0.5 ? "sun.min.fill" : "sun.max.fill")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .contentTransition(.symbolEffect(.replace, options: .speed(Preferences.shared.speed)))
        .animation(.spring(duration: 0.3, bounce: 0.2).paced, value: levels.isMuted)
        .animation(.spring(duration: 0.3, bounce: 0.2).paced, value: levels.level < 0.5)
    }
}

struct LevelBar: View {
    let level: Double
    var dimmed = false
    var nudge = 0
    var nudgedUp = true

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule()
                    .fill(.white.opacity(dimmed ? 0.35 : 1))
                    .frame(width: max(level > 0.001 ? 6 : 0, geo.size.width * level))
            }
        }
        .frame(height: 6)
        .animation(.spring(duration: 0.32, bounce: 0.18).paced, value: level)
        .animation(.easeOut(duration: 0.2).paced, value: dimmed)
        // Pushing past the end stretches the bar a touch, then it snaps back.
        .keyframeAnimator(initialValue: CGFloat(1), trigger: nudge) { view, stretch in
            view.scaleEffect(x: stretch, y: 1 / sqrt(stretch), anchor: nudgedUp ? .leading : .trailing)
        } keyframes: { _ in
            SpringKeyframe(Preferences.shared.flourishes ? 1.09 : 1, duration: Preferences.shared.pace(0.12), spring: .snappy)
            SpringKeyframe(1, duration: Preferences.shared.pace(0.45), spring: .bouncy(extraBounce: 0.1))
        }
    }
}
