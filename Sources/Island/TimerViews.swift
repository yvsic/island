import SwiftUI

/// Countdown digits that roll like iOS when a second changes.
struct TimerText: View {
    let timer: IslandTimer
    var size: CGFloat
    var weight: Font.Weight = .semibold
    /// Shrink to fit the space given instead of keeping full size.
    var scalesToFit = false

    var body: some View {
        let _ = timer.tick
        Text(timer.isRinging ? "0:00" : timer.remainingText)
            .font(.system(size: size, weight: weight).monospacedDigit())
            .foregroundStyle(Color.timerOrange)
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy(duration: 0.3).paced, value: timer.remainingText)
            .lineLimit(1)
            .minimumScaleFactor(scalesToFit ? 0.55 : 1)
            .fixedSize(horizontal: !scalesToFit, vertical: true)
    }
}

/// iOS timer activity: round buttons on the left, big orange digits on the right.
struct TimerRow: View {
    enum Placement { case top, below }

    let model: IslandModel
    let placement: Placement
    private var timer: IslandTimer { model.timer }

    var body: some View {
        VStack(spacing: 0) {
            if placement == .below {
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(height: 0.5)
                    .padding(.horizontal, Layout.sidePadding)
            }
            HStack(alignment: .center, spacing: 0) {
                buttons
                    .frame(width: placement == .top ? wingWidth : nil, alignment: .leading)
                if placement == .top {
                    // The camera sits between the wings: keep everything clear of it.
                    Color.clear.frame(width: model.notchSize.width + Layout.notchGap * 2)
                } else {
                    Spacer()
                }
                VStack(alignment: .trailing, spacing: -1) {
                    HStack(spacing: 4) {
                        if timer.isRinging {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .symbolEffect(.wiggle, options: .repeat(.periodic(delay: Preferences.shared.pace(0.5))).speed(Preferences.shared.speed),
                                              isActive: Preferences.shared.flourishes)
                                .transition(.scale.combined(with: .opacity))
                        }
                        Text(timer.isRinging ? "Timer Done" : "Timer")
                            .contentTransition(.opacity)
                            .lineLimit(1)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.timerOrange)
                    TimerText(timer: timer, size: placement == .top ? 36 : 30, weight: .semibold, scalesToFit: true)
                        .phaseAnimator(timer.isRinging ? [1.0, 0.45] : [1.0]) { view, opacity in
                            view.opacity(opacity)
                        } animation: { _ in .easeInOut(duration: 0.6).paced }
                }
                .frame(maxWidth: placement == .top ? .infinity : nil, alignment: .trailing)
            }
            .padding(.horizontal, Layout.sidePadding)
            .frame(maxHeight: .infinity)
        }
        .frame(height: placement == .top ? Layout.timerHeight : Layout.timerRowHeight)
    }

    /// Room on each side of the camera in the open island.
    private var wingWidth: CGFloat {
        (IslandModel.expandedWidth - model.notchSize.width) / 2 - Layout.notchGap - Layout.sidePadding
    }

    /// Buttons shrink a little if the wing is narrow, rather than reach under the camera.
    private var buttonSize: CGFloat {
        placement == .top ? min(46, (wingWidth - buttonSpacing) / 2) : 46
    }
    private let buttonSpacing: CGFloat = 10

    @ViewBuilder private var buttons: some View {
        HStack(spacing: buttonSpacing) {
            if timer.isRinging {
                RoundButton(symbol: "arrow.counterclockwise", tint: .white, fill: .white.opacity(0.18), size: buttonSize) {
                    timer.cancel()
                    timer.start(minutes: lastMinutes)
                }
                .help("Repeat")
                RoundButton(symbol: "xmark", tint: .black, fill: Color.timerOrange, size: buttonSize) { timer.cancel() }
                    .help("Stop")
            } else {
                RoundButton(symbol: timer.isRunning ? "pause.fill" : "play.fill",
                            tint: Color.timerOrange, fill: Color.timerOrange.opacity(0.24), size: buttonSize) {
                    timer.togglePause()
                }
                .help(timer.isRunning ? "Pause" : "Resume")
                RoundButton(symbol: "xmark", tint: .white, fill: .white.opacity(0.18), size: buttonSize) { timer.cancel() }
                    .help("Cancel")
            }
        }
    }

    private var lastMinutes: Int { max(1, timer.lastMinutes) }
}

struct RoundButton: View {
    let symbol: String
    let tint: Color
    let fill: Color
    var size: CGFloat = 46
    let action: () -> Void
    @State private var hovering = false
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.37, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce.down, options: .speed(1.4 * Preferences.shared.speed),
                              value: Preferences.shared.bouncesSymbols ? taps : 0)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .overlay(Circle().fill(.white.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .hoverLift(hovering)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15).paced, value: hovering)
    }
}

/// One-tap timers. The timer button folds the options away or fans them back out.
struct PresetRow: View {
    let timer: IslandTimer
    /// Opens the quick-open apps menu, the round button at the far end.
    let openApps: () -> Void
    @Bindable private var prefs = Preferences.shared

    /// Snapshots set this instead of touching the saved setting.
    nonisolated(unsafe) static var snapshotOpen: Bool?
    private var isOpen: Bool { Self.snapshotOpen ?? prefs.showTimerPresets }

    var body: some View {
        let presets = prefs.timerPresets
        HStack(spacing: 7) {
            TimerToggleButton(isOpen: isOpen) {
                withAnimation(prefs.settle(growing: !prefs.showTimerPresets)) {
                    prefs.showTimerPresets.toggle()
                }
            }
            if isOpen {
                ForEach(Array(presets.enumerated()), id: \.element) { index, minutes in
                    PresetChip(label: IslandTimer.presetLabel(minutes)) {
                        if prefs.haptics {
                            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                        }
                        timer.start(minutes: minutes)
                    }
                    .transition(.chipFan(index: index, count: presets.count))
                }
            } else {
                Text("Timer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.timerOrange.opacity(0.8))
                    .transition(.opacity.combined(with: .offset(x: -6)).animation(prefs.contentIn))
                Spacer(minLength: 0)
            }
            AppsMenuButton(action: openApps)
        }
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: Layout.presetRowHeight, alignment: .top)
    }
}

/// The round apps button at the end of the preset row: the same size and
/// look as the timer button, and it opens the quick-open menu.
struct AppsMenuButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.12)))
                .overlay(Circle().fill(.white.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .hoverLift(hovering)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15).paced, value: hovering)
        .help("Open an app")
    }
}

/// The round timer button at the start of the preset row, styled like the
/// island's other round controls: tinted when the options are out.
struct TimerToggleButton: View {
    let isOpen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOpen ? Color.timerOrange : .white.opacity(0.85))
                .symbolEffect(.bounce, options: .speed(Preferences.shared.speed),
                              value: Preferences.shared.flourishes ? isOpen : false)
                .frame(width: 28, height: 28)
                .background(Circle().fill(isOpen ? Color.timerOrange.opacity(0.26) : .white.opacity(0.12)))
                .overlay(Circle().fill(.white.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .hoverLift(hovering)
        .onHover { hovering = $0 }
        .animation(Preferences.shared.settle(growing: true), value: isOpen)
        .animation(.easeOut(duration: 0.15).paced, value: hovering)
        .help(isOpen ? "Hide timer options" : "Show timer options")
    }
}

extension AnyTransition {
    /// Timer options fan out from the button one after another, and fold back
    /// in the reverse order, nearest the button last.
    static func chipFan(index: Int, count: Int) -> AnyTransition {
        let prefs = Preferences.shared
        let shrink = prefs.flourishes ? 0.5 : 1
        return .asymmetric(
            insertion: .scale(scale: shrink, anchor: .leading).combined(with: .opacity)
                .animation(prefs.swapIn.delay(prefs.pace(Double(index) * 0.03))),
            removal: .scale(scale: shrink, anchor: .leading).combined(with: .opacity)
                .animation(prefs.swapOut.delay(prefs.pace(Double(count - 1 - index) * 0.02)))
        )
    }
}

struct PresetChip: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(hovering ? .black : Color.timerOrange)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(Capsule().fill(hovering ? Color.timerOrange : Color.timerOrange.opacity(0.16)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .hoverLift(hovering)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14).paced, value: hovering)
    }
}
