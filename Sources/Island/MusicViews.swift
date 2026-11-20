import SwiftUI

/// Expanded music player, laid out below the camera: cover with title and
/// artist beside it, waveform at the right; a thick scrubber; then shuffle,
/// back, play, forward, and the sound output.
struct MusicPanel: View {
    let model: IslandModel
    private var player: NowPlaying { model.player }
    /// Which way the next song arrives from: forward skips come in from the right.
    @State private var forward = true
    /// The pointer is over the waveform (or dragging the volume): it shows as a slider.
    @State private var hoveringVolume = false
    @State private var draggingVolume = false
    @State private var leaveTask: Task<Void, Never>?

    static let artSize: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: player.openSourceApp) {
                    ArtworkView(image: player.artwork, size: Self.artSize, radius: 13, morphID: "art")
                        // New song: the old cover slides away as the new one settles in.
                        .id(player.artworkKey)
                        .transition(.songSwipe(forward: forward, travel: 14))
                        // Paused, the cover sinks back a little, as in Apple Music.
                        .scaleEffect(player.isPlaying ? 1 : 0.86)
                        .shadow(color: .black.opacity(player.isPlaying ? 0.4 : 0), radius: 8, y: 3)
                        .animation(.spring(duration: 0.5, bounce: model.prefs.bounce + 0.14).paced, value: player.isPlaying)
                }
                .buttonStyle(PressStyle())
                .help("Open \(player.track?.source.rawValue ?? "Music")")

                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(text: player.track?.title ?? "", size: 15, weight: .bold, color: .white)
                    MarqueeText(text: player.track?.artist ?? "", size: 14, weight: .medium,
                                color: .white.opacity(0.5))
                }
                .layoutPriority(1)
                .staggered(0)
                .id(player.track?.id)
                .transition(.songSwipe(forward: forward, travel: 26))

                Spacer(minLength: 8)

                let showsVolume = hoveringVolume || draggingVolume
                ZStack(alignment: .trailing) {
                    Waveform(isPlaying: player.isPlaying, color: model.prefs.tintWaveform ? player.tint : .white, height: 18,
                             style: model.prefs.waveStyle)
                        .islandMorph("wave", properties: .position)
                        .staggered(0)
                        .opacity(showsVolume ? 0 : 1)
                        .scaleEffect(showsVolume ? 0.85 : 1, anchor: .trailing)
                        .blur(radius: showsVolume ? 3 : 0)
                    if showsVolume {
                        VolumeSlider(player: player, dragging: $draggingVolume)
                            .transition(.scale(scale: 0.85, anchor: .trailing).combined(with: .opacity).combined(with: .modifier(active: SoftBlur(radius: 3), identity: SoftBlur(radius: 0))))
                    }
                }
                .frame(width: showsVolume ? VolumeSlider.width : 40, height: Self.artSize, alignment: .trailing)
                .contentShape(Rectangle())
                .onHover { inside in
                    leaveTask?.cancel()
                    if inside {
                        hoveringVolume = true
                    } else {
                        // A short grace period, so grazing the edge doesn't flicker it shut.
                        leaveTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            guard !Task.isCancelled else { return }
                            hoveringVolume = false
                        }
                    }
                }
                .animation(.smooth(duration: 0.5).paced, value: showsVolume)
                .help("Volume")
            }
            .frame(height: Self.artSize)

            ScrubBar(model: model)
                .padding(.top, 12)
                .staggered(1)

            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    SideControl(symbol: "shuffle", active: player.track?.shuffle ?? false,
                                help: "Shuffle", action: player.toggleShuffle)
                    LikeButton(model: model)
                }
                .frame(width: 76, alignment: .leading)
                Spacer()
                HStack(spacing: 34) {
                    ControlButton(symbol: "backward.fill", size: 23, nudge: -5) {
                        forward = false
                        player.previous()
                        // Back may only restart the song: don't stay pointed backward.
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(3))
                            forward = true
                        }
                    }
                    ControlButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 31,
                                  action: player.togglePlayPause)
                    ControlButton(symbol: "forward.fill", size: 23, nudge: 5) {
                        forward = true
                        player.next()
                    }
                }
                Spacer()
                HStack(spacing: 2) {
                    if model.prefs.showUpNext {
                        SideControl(symbol: "list.bullet", active: false, help: "Up Next") { model.setTool(.queue) }
                    }
                    SideControl(symbol: AudioOutputs.current?.symbol ?? "laptopcomputer", active: false,
                                help: "Sound Output") {
                        model.isScrubbing = true
                        AudioOutputs.showMenu(from: nil, at: NSEvent.mouseLocation)
                        model.isScrubbing = false
                        model.recheckPointer()
                    }
                }
                .frame(width: 76, alignment: .trailing)
            }
            .frame(height: 44)
            .padding(.top, 6)
            .staggered(2)
        }
        .padding(.top, model.contentTop)
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: model.musicPanelHeight, alignment: .top)
        .animation(.spring(duration: 0.5, bounce: min(0.4, model.prefs.bounce + 0.12)).paced, value: player.track?.id)
        .animation(.spring(duration: 0.5, bounce: min(0.4, model.prefs.bounce + 0.12)).paced, value: player.artworkKey)
        // Songs that change on their own always move forward.
        .onChange(of: player.track?.id) { _, _ in
            Task { @MainActor in forward = true }
        }
    }
}

private struct SoftBlur: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

/// The music app's own volume: replaces the waveform while the pointer is on
/// it. A slim pill with a speaker beside it, as in Apple Music; the pill thickens
/// under the pointer. Click the speaker to mute, and again to bring it back.
struct VolumeSlider: View {
    static let width: CGFloat = 104
    let player: NowPlaying
    @Binding var dragging: Bool
    @State private var hovering = false
    @State private var volumeBeforeMute = 0.5

    private var muted: Bool { player.volume < 0.01 }

    var body: some View {
        HStack(spacing: 5) {
            Button {
                if muted {
                    player.setVolume(volumeBeforeMute)
                } else {
                    volumeBeforeMute = player.volume
                    player.setVolume(0)
                }
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: player.volume)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 17, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help(muted ? "Unmute" : "Mute")

            GeometryReader { geo in
                let active = hovering || dragging
                let height: CGFloat = active ? 7 : 4
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(.white.opacity(active ? 0.85 : 0.6))
                        .frame(width: max(height, geo.size.width * player.volume))
                }
                .frame(height: height)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragging = true
                            player.setVolume(value.location.x / max(1, geo.size.width))
                        }
                        .onEnded { _ in dragging = false }
                )
                .animation(.smooth(duration: 0.3).paced, value: active)
                .animation(.smooth(duration: 0.2), value: player.volume)
            }
            .frame(height: 22)
            .onHover { hovering = $0 }
        }
        .frame(width: Self.width)
    }
}

/// A song leaving slides off one way, blurring; the next one springs in from
/// the other side, like flicking between covers.
private struct SongSlide: ViewModifier {
    let offset: CGFloat
    let active: Bool
    func body(content: Content) -> some View {
        let lively = active && Preferences.shared.flourishes
        content
            .offset(x: lively ? offset : 0)
            .blur(radius: lively ? 6 : 0)
            .scaleEffect(lively ? 0.92 : 1)
            .opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    static func songSwipe(forward: Bool, travel: CGFloat) -> AnyTransition {
        let d: CGFloat = forward ? 1 : -1
        return .asymmetric(
            insertion: .modifier(active: SongSlide(offset: travel * d, active: true),
                                 identity: SongSlide(offset: 0, active: false)),
            removal: .modifier(active: SongSlide(offset: -travel * d, active: true),
                               identity: SongSlide(offset: 0, active: false))
        )
    }
}

/// The small controls at either end of the player row (shuffle, sound output):
/// quieter than the transport buttons, with a soft square highlight like Apple's.
struct SideControl: View {
    let symbol: String
    let active: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? .white : .white.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(active ? 0.16 : (hovering ? 0.1 : 0))))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .hoverLift(hovering)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15).paced, value: hovering)
        .animation(Preferences.shared.settle(growing: true), value: active)
        .help(help)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat
    /// Set to morph this cover with the one in the other presentation.
    var morphID: String? = nil

    var body: some View {
        // The cover fills whatever size the morph gives it, so it can grow
        // smoothly from the compact island into the open one.
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.28), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .islandMorph(morphID ?? "", properties: morphID == nil ? [] : .frame)
        .frame(width: size, height: size)
    }
}

/// The shape that dances while music plays, tinted from the album art. Four
/// looks share one set of levels: bars, dots, a flowing line, or bars mirrored
/// about the middle.
struct Waveform: View {
    let isPlaying: Bool
    let color: Color
    var height: CGFloat = 18
    var style: Preferences.WaveStyle = .bars

    private static let speeds: [Double] = [5.1, 7.3, 4.2, 6.6, 5.7, 8.1]
    private static let phases: [Double] = [0.0, 1.7, 3.1, 0.9, 2.4, 4.0]
    private var barWidth: CGFloat { max(2, height * 0.17) }
    private var spacing: CGFloat { height * 0.1 }
    private var width: CGFloat { barWidth * 6 + spacing * 5 }

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * Preferences.shared.speed
            Group {
                switch style {
                case .bars:
                    HStack(alignment: .center, spacing: spacing) {
                        ForEach(0..<6, id: \.self) { i in
                            Capsule(style: .continuous)
                                .fill(color)
                                .frame(width: barWidth, height: barHeight(i, t))
                        }
                    }
                case .mirror:
                    // Thin bars growing out both ways from a center line.
                    HStack(alignment: .center, spacing: spacing) {
                        ForEach(0..<6, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(color.opacity(0.55 + 0.45 * level(i, t)))
                                .frame(width: barWidth, height: max(barWidth, barHeight(i, t)))
                        }
                    }
                    .overlay(Rectangle().fill(.black.opacity(0.55)).frame(height: 1))
                case .dots:
                    // Dots that ride up and down instead of stretching.
                    HStack(alignment: .center, spacing: spacing) {
                        ForEach(0..<6, id: \.self) { i in
                            Circle()
                                .fill(color)
                                .frame(width: barWidth + 1, height: barWidth + 1)
                                .offset(y: isPlaying ? (0.5 - level(i, t)) * (height - barWidth - 1) : 0)
                        }
                    }
                case .wave:
                    WaveLine(levels: (0..<6).map { level($0, t) }, phase: isPlaying ? t : 0)
                        .stroke(color, style: StrokeStyle(lineWidth: max(1.6, height * 0.11), lineCap: .round, lineJoin: .round))
                        .frame(width: width)
                }
            }
            .frame(width: width, height: height)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8).paced, value: isPlaying)
    }

    /// 0...1 for one bar at one moment.
    private func level(_ i: Int, _ t: Double) -> Double {
        guard isPlaying else { return 0 }
        let a = sin(t * Self.speeds[i] + Self.phases[i])
        let b = sin(t * Self.speeds[(i + 2) % 6] * 0.53 + Self.phases[(i + 3) % 6])
        // Middle bars run taller, like a voice in the mix.
        let shape = [0.55, 0.8, 1.0, 0.95, 0.75, 0.5][i]
        return max(0, min(1, (0.5 + 0.5 * a) * (0.6 + 0.4 * b) * shape))
    }

    private func barHeight(_ i: Int, _ t: Double) -> CGFloat {
        let floor = max(2.5, height * 0.2)
        return floor + (height - floor) * CGFloat(level(i, t))
    }
}

/// A line that ripples through the six levels: a string being plucked.
private nonisolated struct WaveLine: Shape {
    var levels: [Double]
    var phase: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 28
        for step in 0...steps {
            let x = Double(step) / Double(steps)
            // Blend between neighbouring levels so the swell moves along the line.
            let position = x * Double(levels.count - 1)
            let index = min(levels.count - 2, Int(position))
            let mix = position - Double(index)
            let amplitude = levels[index] * (1 - mix) + levels[index + 1] * mix
            // Pinned at both ends, like a string.
            let envelope = sin(x * .pi)
            let y = sin(x * 9 + phase * 5) * (0.12 + amplitude * 0.88) * envelope
            let point = CGPoint(x: rect.minX + rect.width * x, y: rect.midY + rect.height * 0.46 * y)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// The heart beside shuffle: likes the song in Spotify, or favorites it in Music.
struct LikeButton: View {
    let model: IslandModel
    @State private var hovering = false
    @State private var beats = 0
    @State private var needsSpotify = false
    private var liked: Bool { model.player.track?.liked ?? false }

    var body: some View {
        Button {
            model.player.toggleLike(spotify: model.spotify) {
                // Spotify isn't connected yet: say so, and offer the way there.
                needsSpotify = true
            }
            if !liked { beats += 1 }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(liked ? Color(red: 1.0, green: 0.3, blue: 0.45) : .white.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .speed(1.3 * Preferences.shared.speed),
                              value: Preferences.shared.flourishes ? beats : 0)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hovering ? 0.1 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .hoverLift(hovering)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15).paced, value: hovering)
        .help(needsSpotify ? "Connect Spotify in Settings › Music to like songs" : (liked ? "Remove from Liked" : "Like"))
        .onChange(of: needsSpotify) { _, needs in
            guard needs else { return }
            needsSpotify = false
            SettingsPanel.requestedTab = .music
            model.setPage(.settings)
        }
    }
}

/// Elapsed time, a thick draggable progress pill, and time remaining. The pill
/// swells under the pointer and stretches like rubber when dragged past an end.
struct ScrubBar: View {
    let model: IslandModel
    @State private var dragFraction: Double?
    @State private var hovering = false
    /// How far past an end the pointer has been pulled, in points (signed).
    @State private var pull: CGFloat = 0
    /// The secret knock: how far along it the taps are, and when the last one landed.
    @State private var knock = 0
    @State private var lastKnock = Date.distantPast
    private var prefs: Preferences { Preferences.shared }

    private var player: NowPlaying { model.player }

    /// Left time, right time, left, right, left, left, right. Each within two seconds of the last.
    private static let secret: [Bool] = [true, false, true, false, true, true, false]

    private func tap(left: Bool) {
        let now = Date()
        if now.timeIntervalSince(lastKnock) > 2 { knock = 0 }
        lastKnock = now
        if Self.secret[knock] == left { knock += 1 } else { knock = left == Self.secret[0] ? 1 : 0 }
        if knock == Self.secret.count {
            knock = 0
            withAnimation(.spring(duration: 0.7, bounce: 0.5)) {
                prefs.clawd = true
                prefs.showClawd = true
            }
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let duration = max(player.track?.duration ?? 0, 1)
            let fraction = dragFraction ?? min(1, player.position(at: context.date) / duration)
            let elapsed = fraction * duration

            HStack(spacing: 10) {
                Text(Self.format(elapsed))
                    .frame(width: 40, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { tap(left: true) }
                GeometryReader { geo in
                    let active = hovering || dragFraction != nil
                    let barHeight: CGFloat = active ? 13 : 10
                    // Rubber band: the further past the end, the less it gives.
                    let give = Preferences.shared.flourishes ? 14 * (1 - 1 / (abs(pull) / 60 + 1)) : 0
                    let stretch = 1 + give / max(1, geo.size.width)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(.white.opacity(active ? 0.9 : 0.5))
                            .frame(width: max(barHeight, geo.size.width * fraction))
                    }
                    .frame(height: barHeight)
                    .scaleEffect(x: stretch, y: 1 / (stretch * stretch), anchor: pull < 0 ? .trailing : .leading)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        if prefs.clawd && prefs.showClawd {
                            let px: CGFloat = 2.2
                            // Sits on the right end of the bar, his legs hanging off the edge.
                            let x = geo.size.width - ClawdSprite.legColumn * px
                            ClawdSprite(walking: dragFraction == nil && player.isPlaying, pixel: px)
                                .offset(x: x, y: (18 - barHeight) / 2 - ClawdSprite.bodyRows * px + 1 - (dragFraction != nil ? 5 : 0))
                                .animation(.spring(duration: 0.3, bounce: 0.4), value: dragFraction != nil)
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                model.isScrubbing = true
                                let x = value.location.x
                                dragFraction = min(1, max(0, x / geo.size.width))
                                pull = x < 0 ? x : max(0, x - geo.size.width)
                            }
                            .onEnded { _ in
                                if let f = dragFraction { player.seek(to: f * duration) }
                                dragFraction = nil
                                model.isScrubbing = false
                                withAnimation(.spring(duration: 0.5, bounce: 0.45).paced) { pull = 0 }
                            }
                    )
                    .animation(.spring(response: 0.3, dampingFraction: 0.68).paced, value: active)
                }
                .frame(height: 18)
                .onHover { hovering = $0 }
                Text("-" + Self.format(max(0, duration - elapsed)))
                    .frame(width: 40, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture { tap(left: false) }
            }
            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A borderless symbol that glows on hover and dips when pressed. Skip buttons
/// lunge the way they point and spring back; in livelier motion settings the
/// symbol bounces as well.
struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    /// How far the symbol lunges sideways when pressed, in points.
    var nudge: CGFloat = 0
    let action: () -> Void
    @State private var hovering = false
    @State private var taps = 0
    private var prefs: Preferences { Preferences.shared }

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.86))
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce.down, options: .speed(1.4 * Preferences.shared.speed), value: prefs.bouncesSymbols && nudge == 0 ? taps : 0)
                .keyframeAnimator(initialValue: CGFloat(0), trigger: taps) { view, x in
                    view.offset(x: x)
                } keyframes: { _ in
                    SpringKeyframe(prefs.flourishes ? nudge : 0, duration: prefs.pace(0.1), spring: .snappy)
                    SpringKeyframe(0, duration: prefs.pace(0.5), spring: .bouncy(extraBounce: 0.12))
                }
                .frame(width: size * 1.6, height: size * 1.6)
                .background(Circle().fill(.white.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .hoverLift(hovering)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15).paced, value: hovering)
    }
}

/// Scales a control up slightly under the pointer, more in livelier settings.
private struct HoverLift: ViewModifier {
    let hovering: Bool
    func body(content: Content) -> some View {
        let prefs = Preferences.shared
        content
            .scaleEffect(hovering ? prefs.hoverScale : 1)
            .animation(prefs.buttonSpring, value: hovering)
    }
}

extension View {
    func hoverLift(_ hovering: Bool) -> some View { modifier(HoverLift(hovering: hovering)) }
}

/// Dips on press and springs back; depth and spring follow the motion setting.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let prefs = Preferences.shared
        configuration.label
            .scaleEffect(configuration.isPressed ? prefs.pressScale : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(configuration.isPressed ? .spring(duration: 0.18, bounce: 0).paced : prefs.buttonSpring,
                       value: configuration.isPressed)
    }
}
