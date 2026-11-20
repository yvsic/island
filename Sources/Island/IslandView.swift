import SwiftUI

/// The island: one black shape that morphs between idle, compact, and expanded,
/// with each state's content blurring in and out as it grows.
///
/// The outline is drawn in a fixed, full-width canvas around a fixed center, and
/// its size and corners animate as one value on one spring. Nothing about the
/// island's position is left to layout, so it can never drift to one side.
struct IslandView: View {
    let model: IslandModel
    private var prefs: Preferences { model.prefs }

    /// The body's shape, simulated: see `IslandMotion`.
    @State private var motion: IslandMotion
    @State private var pressed = false
    @State private var dropTargeted = false
    /// Swapping pages while open: content keeps its size instead of stretching.
    @State private var reshaping = false
    @Namespace private var morph

    init(model: IslandModel) {
        self.model = model
        _motion = State(initialValue: IslandMotion(IslandGeometry(model)))
    }

    var body: some View {
        let expanded = model.presentation == .expanded

        ZStack(alignment: .top) {
            LiveIslandShadow(motion: motion, visible: expanded)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // The second activity's drop, drawn under the body so the neck joins it cleanly.
            LiveBubble(motion: motion, notchHeight: model.notchSize.height) {
                if let activity = model.bubbleActivity {
                    BubbleGlyph(model: model, activity: activity, size: max(18, model.notchSize.height - 8))
                        .transition(.islandSwap(prefs))
                }
            }
            .animation(prefs.swapIn, value: model.bubbleActivity)

            LiveIslandBody(motion: motion, glass: expanded && prefs.liquidGlass)
                // Pressing the island's body gives it a small, springy squeeze.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !pressed { pressed = true } }
                        .onEnded { value in
                            pressed = false
                            if abs(value.translation.width) + abs(value.translation.height) < 6 {
                                model.islandClicked()
                            }
                        }
                )
                .contextMenu { IslandContextMenu(model: model) }

            RideAlong(motion: motion, active: expanded && !reshaping) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .mask { LiveIslandMask(motion: motion) }
                .animation(expanded ? prefs.contentIn : prefs.contentOut, value: model.presentation)
                .animation(prefs.contentIn, value: model.power.showsChargingAlert)
                .animation(prefs.contentIn, value: model.levels.isShowing)
                .animation(prefs.contentIn, value: model.alertID)
        }
        .scaleEffect(x: pressed ? 0.965 : 1, y: pressed ? 0.95 : 1, anchor: .top)
        .animation(pressed ? .spring(duration: 0.22, bounce: 0).paced
                           : .spring(duration: 0.45, bounce: min(0.5, prefs.bounce + 0.28)).paced, value: pressed)
        .keyframeAnimator(initialValue: 1.0, repeating: model.timer.isRinging) { view, scale in
            view.scaleEffect(scale, anchor: .top)
        } keyframes: { _ in
            // A soft pulse while the timer rings.
            SpringKeyframe(1.025, duration: Preferences.shared.pace(0.2), spring: .smooth)
            SpringKeyframe(1.0, duration: Preferences.shared.pace(0.35), spring: .smooth)
            CubicKeyframe(1.0, duration: Preferences.shared.pace(0.85))
        }
        .environment(\.colorScheme, .dark)
        .environment(\.islandMorphNamespace, morph)
        .onAppear {
            motion.reset(to: IslandGeometry(model))
            motion.setBubble(model.bubbleActivity != nil, animated: false)
        }
        .onChange(of: model.bubbleActivity != nil) { _, apart in motion.setBubble(apart) }
        .onChange(of: IslandGeometry(model)) { old, new in
            let growing = new.height > old.height + 1 || new.width > old.width + 1
            // Changes beside the camera (charging, music, timer) settle with a little
            // more spring; opening and closing the full island have their own feel.
            let barHeight = model.notchSize.height + 4
            let beside = old.height <= barHeight && new.height <= barHeight
            let stayingOpen = old.height > barHeight + 30 && new.height > barHeight + 30
            let kind: IslandMotion.Kind = beside ? .settle(growing: growing)
                : stayingOpen ? .reshape
                : (new.height > old.height ? .open : .close)
            if case .reshape = kind { reshaping = true } else { reshaping = false }
            motion.move(to: new, kind)
        }
        // Files dragged onto the island land on the shelf.
        .liveOnly { view in
            view.onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                model.shelf.add(providers)
                return true
            }
        }
        .onChange(of: dropTargeted) { _, targeted in
            if targeted { model.openShelfForDrop() }
        }
        // A new song lands with a small jiggle of the whole body.
        .onChange(of: model.player.track?.id) { old, new in
            guard old != nil, new != nil else { return }
            motion.kick(width: 110, height: model.presentation == .expanded ? 60 : 0)
        }
        // Volume and brightness keys nudge it too.
        .onChange(of: model.levels.nudge) { _, _ in motion.kick(width: 70) }
    }

    @ViewBuilder private var content: some View {
        let transition = AnyTransition.island(blur: prefs.blurContent)
        let swap = AnyTransition.islandSwap(prefs)
        switch model.presentation {
        case .idle:
            Color.clear.frame(width: 1, height: 1)
        case .compact:
            if model.levels.isShowing {
                LevelContent(model: model)
                    .frame(width: model.compactContentWidth)
                    .id(model.levels.kind == .volume ? "volume" : "brightness")
                    .transition(swap)
            } else if let alert = model.alert {
                AlertContent(model: model, alert: alert)
                    .frame(width: model.compactContentWidth)
                    .id(model.alertID)
                    .transition(swap)
            } else if model.showsChargingView {
                ChargingContent(model: model)
                    .frame(width: model.compactContentWidth)
                    .id(model.power.alertID)
                    .transition(swap)
            } else {
                CompactContent(model: model)
                    .frame(width: model.compactContentWidth)
                    // Wings widen with the outline when the battery joins the music.
                    .animation(prefs.settle(growing: true), value: model.compactContentWidth)
                    .transition(swap)
            }
        case .expanded:
            // Rows bring their own staggered entrance; the container just fades.
            ExpandedContent(model: model)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.12).paced),
                                        removal: transition))
        }
    }
}

/// The island's fill: solid black, or Liquid Glass while open. Beside the camera
/// it always stays black so the hardware notch blends in; the glass fades in
/// as the island opens.
struct IslandBody: View {
    let geometry: IslandGeometry
    let glass: Bool

    var body: some View {
        ZStack {
            if Preferences.shared.liquidGlass {
                Color.clear
                    .glassEffect(.regular.tint(.black.opacity(0.32)), in: IslandOutline(geometry: geometry))
            }
            IslandOutline(geometry: geometry)
                .fill(.black)
                .opacity(glass ? 0 : 1)
        }
        .animation(.easeInOut(duration: glass ? 0.35 : 0.2).paced, value: glass)
    }
}

/// The island's size and corners as one animatable value.
struct IslandGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    init(width: CGFloat, height: CGFloat, topRadius: CGFloat, bottomRadius: CGFloat) {
        self.width = width
        self.height = height
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    init(_ model: IslandModel) {
        let size = model.bodySize
        self.init(width: size.width, height: size.height, topRadius: model.topRadius, bottomRadius: model.bottomRadius)
    }

    var withoutFlares: IslandGeometry {
        var g = self
        g.topRadius = 0
        return g
    }
}

/// The outline: rounded at the bottom, with small concave flares at the top so it
/// reads as part of the screen's edge rather than a floating pill. Always centered
/// horizontally in the rect it's given, hanging from the top edge.
nonisolated struct IslandOutline: Shape {
    var geometry: IslandGeometry

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(AnimatablePair(geometry.width, geometry.height),
                           AnimatablePair(geometry.topRadius, geometry.bottomRadius))
        }
        set {
            geometry.width = newValue.first.first
            geometry.height = newValue.first.second
            geometry.topRadius = newValue.second.first
            geometry.bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = max(0, geometry.topRadius)
        let body = max(0, geometry.width)
        let h = max(0, geometry.height)
        let w = body + 2 * t
        let minX = rect.midX - w / 2, minY = rect.minY
        let b = max(0, min(geometry.bottomRadius, body / 2, h - t))
        // Continuous-corner control distance (closer to Apple's squircle than a circle).
        let k: CGFloat = 0.58
        var p = Path()
        p.move(to: CGPoint(x: minX, y: minY))
        p.addCurve(to: CGPoint(x: minX + t, y: minY + t),
                   control1: CGPoint(x: minX + t * k, y: minY),
                   control2: CGPoint(x: minX + t, y: minY + t * (1 - k)))
        p.addLine(to: CGPoint(x: minX + t, y: minY + h - b))
        p.addCurve(to: CGPoint(x: minX + t + b, y: minY + h),
                   control1: CGPoint(x: minX + t, y: minY + h - b * (1 - k)),
                   control2: CGPoint(x: minX + t + b * (1 - k), y: minY + h))
        p.addLine(to: CGPoint(x: minX + w - t - b, y: minY + h))
        p.addCurve(to: CGPoint(x: minX + w - t, y: minY + h - b),
                   control1: CGPoint(x: minX + w - t - b * (1 - k), y: minY + h),
                   control2: CGPoint(x: minX + w - t, y: minY + h - b * (1 - k)))
        p.addLine(to: CGPoint(x: minX + w - t, y: minY + t))
        p.addCurve(to: CGPoint(x: minX + w, y: minY),
                   control1: CGPoint(x: minX + w - t, y: minY + t * (1 - k)),
                   control2: CGPoint(x: minX + w - t * k, y: minY))
        p.closeSubpath()
        return p
    }
}

/// Right-click menu on the island, so settings stay reachable with the menu bar icon hidden.
struct IslandContextMenu: View {
    let model: IslandModel

    var body: some View {
        Menu("Start Timer") {
            ForEach(model.prefs.timerPresets, id: \.self) { minutes in
                Button(IslandTimer.presetLabel(minutes, long: true)) { model.timer.start(minutes: minutes) }
            }
        }
        Divider()
        Button(model.recorder.isRecording ? "Stop Recording" : "Record Screen") { model.recorder.toggle() }
        Button("File Shelf") { model.setExpanded(true); model.setPage(.shelf) }
        Button("Settings…") { model.setExpanded(true); model.setPage(.settings) }
        Button("Quit Island") { NSApp.terminate(nil) }
    }
}

/// A soft shadow under the open island. It is a nine-slice image, so it stretches
/// with the island every frame at no cost instead of being re-blurred.
struct IslandShadow: View {
    let visible: Bool
    let size: CGSize

    private static let blur: CGFloat = 24
    private static let image: NSImage = {
        let pad = blur * 2, corner: CGFloat = 34, body: CGFloat = 120
        let side = body + pad * 2
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let shadow = NSShadow()
            shadow.shadowBlurRadius = blur
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowOffset = NSSize(width: 10_000, height: 0)
            shadow.set()
            // Draw the shape far off-canvas so only its shadow lands here.
            let rect = NSRect(x: pad - 10_000, y: pad, width: body, height: body)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
            return true
        }
    }()

    var body: some View {
        let inset = Self.blur * 2 + 40
        Image(nsImage: Self.image)
            .resizable(capInsets: EdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset))
            .frame(width: size.width + Self.blur * 4, height: size.height + Self.blur * 3)
            .offset(y: 10 - Self.blur * 1.5)
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: visible ? 0.3 : 0.12).paced, value: visible)
            .allowsHitTesting(false)
    }
}

// MARK: - Transition

/// Content blurs, shrinks toward the top, and fades: the Dynamic Island look.
private struct IslandMorph: ViewModifier {
    let active: Bool
    let blur: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active && blur && Preferences.shared.flourishes ? 16 : 0)
            .scaleEffect(active && Preferences.shared.flourishes ? 0.86 : 1, anchor: .top)
            .opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    static func island(blur: Bool = true) -> AnyTransition {
        .modifier(active: IslandMorph(active: true, blur: blur), identity: IslandMorph(active: false, blur: blur))
    }
    static var island: AnyTransition { island() }

    /// Swapping things beside the camera (charging ↔ music ↔ timer): the old item
    /// shrinks and fades quickly, then the new one pops in with a small spring, so
    /// the two never overlap into a muddle.
    static func islandSwap(_ prefs: Preferences) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SwapPop(active: true, scale: 0.55), identity: SwapPop(active: false, scale: 0.55))
                .animation(prefs.swapIn),
            removal: .modifier(active: SwapPop(active: true, scale: 0.8), identity: SwapPop(active: false, scale: 0.8))
                .animation(prefs.swapOut)
        )
    }
}

/// One page of the open island giving way to another: the old one softens and
/// fades in place, and the new one comes into focus just behind it. Nothing
/// slides or scales far, so the swap reads as one surface changing its mind.
private struct PageFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        let lively = active && Preferences.shared.flourishes
        content
            .blur(radius: lively && Preferences.shared.blurContent ? 9 : 0)
            .scaleEffect(lively ? 0.975 : 1, anchor: .top)
            .opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    static var page: AnyTransition {
        let prefs = Preferences.shared
        return .asymmetric(
            insertion: .modifier(active: PageFade(active: true), identity: PageFade(active: false))
                .animation(.spring(response: prefs.reshapeResponse, dampingFraction: 1).delay(prefs.pace(0.07))),
            removal: .modifier(active: PageFade(active: true), identity: PageFade(active: false))
                .animation(.easeOut(duration: prefs.pace(0.17)))
        )
    }
}

/// Three quiet glyphs in the wing beside the camera: the usual island, the
/// file shelf, settings. Dim until the pointer is on them.
struct PageSwitcher: View {
    let model: IslandModel

    var body: some View {
        HStack(spacing: 1) {
            glyph("house.fill", .home, "Island")
            glyph("tray.fill", .shelf, model.shelf.items.isEmpty ? "File Shelf" : "File Shelf (\(model.shelf.items.count))")
            glyph("smallcircle.filled.circle", .record, model.recorder.isRecording ? "Recording" : "Record Screen")
            glyph(model.vpn.isOn ? "lock.shield.fill" : "shield.fill", .vpn, model.vpn.isOn ? "VPN: Connected" : "VPN")
            glyph("gearshape.fill", .settings, "Settings")
        }
        .padding(.trailing, 18)
        .frame(height: model.notchSize.height)
        .staggered(1)
    }

    private func glyph(_ symbol: String, _ page: IslandModel.Page, _ help: String) -> some View {
        PageGlyph(symbol: symbol, active: model.page == page) { model.setPage(page) }
            .help(help)
    }
}

private struct PageGlyph: View {
    let symbol: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(active ? 0.8 : (hovering ? 0.65 : 0.24)))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15).paced, value: hovering)
        .animation(.easeOut(duration: 0.2).paced, value: active)
    }
}

private struct SwapPop: ViewModifier {
    let active: Bool
    let scale: CGFloat
    func body(content: Content) -> some View {
        content
            .scaleEffect(active && Preferences.shared.flourishes ? scale : 1)
            .blur(radius: active && Preferences.shared.flourishes ? 5 : 0)
            .opacity(active ? 0 : 1)
    }
}

// MARK: - Compact

/// The live activity beside the camera: leading and trailing wings.
struct CompactContent: View {
    let model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: model.notchSize.width + Layout.notchGap * 2)
                trailing
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, model.compactEdge)
            .frame(height: model.notchSize.height)

            if model.showsSongBanner {
                // A new song: its name under the cover for a moment.
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.bannerText)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: model.bannerTextWidth)
                .frame(height: Layout.bannerHeight, alignment: .top)
                .padding(.top, 2)
                .transition(.islandSwap(model.prefs))
            }
        }
        .animation(model.prefs.settle(growing: true), value: model.showsSongBanner)
        .animation(model.prefs.settle(growing: true), value: model.primaryActivity)
        .animation(model.prefs.settle(growing: true), value: model.power.showsChargingAlert)
    }

    @ViewBuilder private var leading: some View {
        switch model.primaryActivity {
        case .music:
            ArtworkView(image: model.player.artwork, size: 22, radius: model.compactArtRadius, morphID: "art")
                .id(model.player.artworkKey)
                .transition(.islandSwap(model.prefs))
                .animation(model.prefs.swapIn, value: model.player.artworkKey)
        case .timer:
            TimerRing(timer: model.timer)
                .transition(.islandSwap(model.prefs))
        case .recording:
            RecordDot()
                .frame(width: 16)
                .transition(.islandSwap(model.prefs))
        case .call:
            CallBadge(model: model)
                .transition(.islandSwap(model.prefs))
        case .privacy:
            PrivacyDot(model: model)
                .frame(width: 12)
                .transition(.islandSwap(model.prefs))
        case .countdown:
            Image(systemName: "timer")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .transition(.islandSwap(model.prefs))
        case .vpn:
            VPNWing(model: model)
                .frame(width: 18)
                .transition(.islandSwap(model.prefs))
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        if model.power.showsChargingAlert {
            // Plugged in mid-activity: the battery takes the trailing wing for a moment.
            ChargeIndicator(percent: model.power.percent)
                .id(model.power.alertID)
                .transition(.islandSwap(model.prefs))
        } else {
            switch model.primaryActivity {
            case .music:
                Waveform(isPlaying: model.player.isPlaying, color: model.prefs.tintWaveform ? model.player.tint : .white, height: 14,
                         style: model.prefs.waveStyle)
                    .islandMorph("wave", properties: .position)
                    .transition(.islandSwap(model.prefs))
            case .timer:
                TimerText(timer: model.timer, size: 14, weight: .semibold)
                    .transition(.islandSwap(model.prefs))
            case .recording:
                ElapsedText(start: model.recorder.startedAt, color: .lowRed)
                    .transition(.islandSwap(model.prefs))
            case .call:
                ElapsedText(start: model.sensors.call?.started, color: .chargeGreen)
                    .transition(.islandSwap(model.prefs))
            case .privacy:
                Group {
                    if let app = model.sensors.micApp {
                        AppIconView(bundleID: app.bundleID, size: 18)
                    } else {
                        Image(systemName: model.sensors.cameraInUse ? "video.fill" : "mic.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(width: 20)
                .transition(.islandSwap(model.prefs))
            case .countdown:
                if let next = model.nextCountdown {
                    Text(next.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.8))
                        .transition(.islandSwap(model.prefs))
                }
            case .vpn:
                Text(VPNWing.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.vpn.isOn ? Color.chargeGreen : Color.timerOrange)
                    .fixedSize()
                    .transition(.islandSwap(model.prefs))
            case nil:
                EmptyView()
            }
        }
    }
}

// MARK: - Expanded

struct ExpandedContent: View {
    let model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            if model.timer.isRinging {
                TimerRow(model: model, placement: .top)
                    .staggered(0)
            } else if model.page == .shelf {
                ShelfPanel(model: model)
                    .transition(.page)
            } else if model.page == .apps {
                AppsPanel(model: model)
                    .transition(.page)
            } else if model.page == .record {
                RecordPanel(model: model)
                    .transition(.page)
            } else if model.page == .vpn {
                VPNPanel(model: model)
                    .transition(.page)
            } else if model.page == .home, let note = model.note {
                NotePanel(model: model, note: note)
                    .id(note.id)
                    .transition(.page)
            } else if model.page == .settings {
                SettingsPanel(model: model)
                    .transition(.page)
            } else {
                if model.showsCalendarPanel {
                    CalendarPanel(model: model)
                        .transition(.page)
                } else if model.hasMusic {
                    MusicPanel(model: model)
                        .transition(.page)
                } else if model.showsTimerRow {
                    TimerRow(model: model, placement: .top)
                        .staggered(0)
                } else {
                    NothingPlayingHeader(notch: model.notchSize)
                }
                if model.showsCallRow {
                    CallRow(model: model)
                        .staggered(2)
                        .transition(.island)
                }
                if model.showsRecordingRow {
                    RecordingRow(model: model)
                        .staggered(2)
                        .transition(.island)
                }
                if model.showsInfoRow {
                    InfoRow(model: model)
                        .staggered(model.hasMusic ? 3 : 1)
                        .transition(.island)
                }
                if model.showsBatteryRow {
                    BatteryRow(model: model)
                        .staggered(model.hasMusic ? 4 : 2)
                        .transition(.island)
                }
                if model.showsTimerRow {
                    if model.hasMusic || model.showsCalendarPanel {
                        TimerRow(model: model, placement: .below)
                            .staggered(4)
                            .transition(.island)
                    }
                } else {
                    PresetRow(timer: model.timer) { model.setPage(.apps) }
                        .staggered(model.hasMusic ? 4 : 2)
                        .transition(.island)
                }
            }
        }
        .frame(width: IslandModel.expandedWidth, alignment: .top)
        .overlay(alignment: .topTrailing) {
            if model.showsPageSwitcher {
                PageSwitcher(model: model)
                    .transition(.opacity)
            }
        }
        .animation(model.prefs.reshape, value: model.page)
        .animation(model.prefs.reshape, value: model.note)
        .animation(model.prefs.contentIn, value: model.showsCallRow)
        .animation(model.prefs.contentIn, value: model.showsRecordingRow)
        .animation(model.prefs.contentIn, value: model.showsTimerRow)
        .animation(model.prefs.contentIn, value: model.hasMusic)
        .animation(model.prefs.contentIn, value: model.showsInfoRow)
        .animation(model.prefs.reshape, value: model.showsCalendarPanel)
    }
}

/// With nothing playing, the wings beside the camera say so quietly.
struct NothingPlayingHeader: View {
    let notch: CGSize

    var body: some View {
        HStack {
            HStack(spacing: 7) {
                Image(systemName: "music.note")
                    .font(.system(size: 12, weight: .semibold))
                Text("Not Playing")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.42))
            Spacer()
        }
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: Layout.emptyHeaderHeight)
        .staggered(0)
    }
}

extension Color {
    /// The orange iOS uses for Clock's timer.
    static let timerOrange = Color(red: 1.0, green: 0.62, blue: 0.04)
}
