import SwiftUI

/// The dot macOS puts in the menu bar: green for the camera, orange for the microphone.
struct PrivacyDot: View {
    let model: IslandModel
    var size: CGFloat = 9

    var body: some View {
        let camera = model.sensors.cameraInUse
        Circle()
            .fill(camera ? Color.chargeGreen : Color.timerOrange)
            .frame(width: size, height: size)
            .shadow(color: (camera ? Color.chargeGreen : Color.timerOrange).opacity(0.6), radius: 3)
            .animation(.easeInOut(duration: 0.25).paced, value: camera)
    }
}

/// The app on a call, with a small slash when the mic is muted.
struct CallBadge: View {
    let model: IslandModel
    var size: CGFloat = 20

    var body: some View {
        AppIconView(bundleID: model.sensors.call?.app.bundleID ?? "com.apple.FaceTime", size: size)
            .overlay(alignment: .bottomTrailing) {
                if model.sensors.isMuted {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: size * 0.4, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Circle().fill(Color.lowRed))
                        .offset(x: 4, y: 3)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(Preferences.shared.buttonSpring, value: model.sensors.isMuted)
    }
}

/// What rides in the bubble that splits off the island: the second activity,
/// boiled down to one glyph.
struct BubbleGlyph: View {
    let model: IslandModel
    let activity: IslandModel.Activity
    let size: CGFloat

    var body: some View {
        switch activity {
        case .music:
            ArtworkView(image: model.player.artwork, size: size - 6, radius: (size - 6) / 2)
        case .timer:
            TimerRing(timer: model.timer, size: size - 11, lineWidth: 2.4)
        case .recording:
            RecordDot(size: 10)
        case .call:
            CallBadge(model: model, size: size - 9)
        case .privacy:
            PrivacyDot(model: model, size: 10)
        case .countdown:
            Image(systemName: "timer")
                .font(.system(size: size - 12, weight: .bold))
                .foregroundStyle(.white)
        case .vpn:
            VPNWing(model: model, size: size - 12)
        @unknown default:
            EmptyView()
        }
    }
}

/// During a call: who it's with, how long it's been, and mute and leave in reach.
struct CallRow: View {
    let model: IslandModel
    @State private var couldNotLeave = false
    private var sensors: SystemSensors { model.sensors }

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(bundleID: sensors.call?.app.bundleID ?? "", size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(sensors.call?.app.name ?? "Call")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(couldNotLeave ? "Hang up in the app" : (sensors.isMuted ? "Muted" : "On a call"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(sensors.isMuted && !couldNotLeave ? Color.lowRed : .white.opacity(0.5))
                    .contentTransition(.opacity)
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            ElapsedText(start: sensors.call?.started, size: 20, color: .chargeGreen)
                .padding(.trailing, 4)
            RoundButton(symbol: sensors.isMuted ? "mic.slash.fill" : "mic.fill",
                        tint: sensors.isMuted ? .black : .white,
                        fill: sensors.isMuted ? .white : .white.opacity(0.18), size: 40) {
                sensors.setMuted(!sensors.isMuted)
            }
            .help(sensors.isMuted ? "Unmute the microphone" : "Mute the microphone")
            RoundButton(symbol: "phone.down.fill", tint: .white, fill: .lowRed, size: 40) {
                Task {
                    if await sensors.leaveCall() { return }
                    // Couldn't find the app's own button: bring the app forward instead.
                    couldNotLeave = true
                    if let pid = sensors.call?.app.pid { NSRunningApplication(processIdentifier: pid)?.activate() }
                }
            }
            .help("Leave the call")
        }
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: Layout.callRowHeight)
        .animation(model.prefs.contentIn, value: sensors.isMuted)
    }
}
