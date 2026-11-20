import SwiftUI

/// Rows of the open island arrive one after another, top to bottom: each
/// fades up from a slight blur a beat after the one above it.
private struct StaggeredEntrance: ViewModifier {
    let index: Int
    @State private var shown = StaggeredEntrance.skip

    /// Snapshots render a single frame, so they skip the entrance.
    nonisolated(unsafe) static var skip = false

    func body(content: Content) -> some View {
        let prefs = Preferences.shared
        let hidden = !shown && prefs.flourishes
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: hidden ? 5 : 0)
            .offset(y: hidden ? -4 : 0)
            .scaleEffect(hidden ? 0.97 : 1, anchor: .top)
            .onAppear {
                guard !shown else { return }
                withAnimation(.spring(duration: 0.5, bounce: prefs.bounce * 0.6)
                    .delay(0.05 + Double(index) * 0.028).paced) {
                    shown = true
                }
            }
    }
}

extension View {
    /// Fades in after the rows above it; `index` 0 is the top row.
    func staggered(_ index: Int) -> some View { modifier(StaggeredEntrance(index: index)) }
}

enum Snapshotting {
    /// True while rendering still images, which can't draw scroll views or
    /// drop targets: those fall back to plain views.
    nonisolated(unsafe) static var active = false

    static func begin() {
        active = true
        StaggeredEntrance.skip = true
    }
}

/// A scroll view in the app; in snapshots, just its content, clipped.
struct IslandScroll<Content: View>: View {
    let axis: Axis.Set
    @ViewBuilder let content: Content

    var body: some View {
        if Snapshotting.active {
            Color.clear
                .overlay(alignment: .topLeading) { content }
                .clipped()
        } else {
            ScrollView(axis, showsIndicators: false) { content }
        }
    }
}

extension View {
    /// Applies a modifier only in the running app, not in snapshots.
    @ViewBuilder func liveOnly<V: View>(_ transform: (Self) -> V) -> some View {
        if Snapshotting.active { self } else { transform(self) }
    }
}

/// A single line that scrolls sideways when it's too long to fit, pausing at
/// the start, with soft fades at the edges, like titles on iPhone.
struct MarqueeText: View {
    let text: String
    let size: CGFloat
    let weight: Font.Weight
    let color: Color

    private let gap: CGFloat = 32
    private var pause: Double { Preferences.shared.pace(2.2) }
    private var speed: Double { 28 * Preferences.shared.speed } // points per second

    var body: some View {
        let textWidth = TextWidth.of(text, size: size, weight: weight.nsWeight)
        GeometryReader { geo in
            let overflow = textWidth > geo.size.width + 1
            Group {
                if overflow, !Preferences.shared.reduceMotion {
                    TimelineView(.animation) { context in
                        let travel = Double(textWidth + gap) / speed
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: pause + travel)
                        let x = phase < pause ? 0 : -CGFloat((phase - pause) * speed)
                        // The left edge only fades while text is sliding under it.
                        let leftFade = min(0.05, Double(-x) / Double(geo.size.width) * 0.6)
                        HStack(spacing: gap) { label; label }
                            .offset(x: x)
                            .frame(width: geo.size.width, alignment: .leading)
                            .clipped()
                            .mask(
                                LinearGradient(stops: [.init(color: leftFade > 0.001 ? .clear : .black, location: 0),
                                                       .init(color: .black, location: max(0.001, leftFade)),
                                                       .init(color: .black, location: 0.9),
                                                       .init(color: .clear, location: 1)],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                    }
                } else {
                    label.frame(width: geo.size.width, alignment: .leading)
                }
            }
        }
        .frame(height: size * 1.3)
    }

    private var label: some View {
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

extension Font.Weight {
    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

/// The circular countdown iPhone shows beside the camera for a running timer.
struct TimerRing: View {
    let timer: IslandTimer
    var size: CGFloat = 17
    var lineWidth: CGFloat = 2.6

    var body: some View {
        let _ = timer.tick
        let fraction = timer.fraction()
        ZStack {
            Circle().stroke(Color.timerOrange.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.timerOrange, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Glide between seconds instead of ticking.
                .animation(timer.isRunning ? .linear(duration: 1) : .spring(duration: 0.3).paced, value: fraction)
        }
        .frame(width: size, height: size)
        .opacity(timer.isRunning ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.25).paced, value: timer.isRunning)
    }
}

// MARK: - Morphing between compact and open

/// Shared space for elements that live in both the compact and the open island,
/// so they travel and resize between the two instead of cross-fading, the way
/// the album art grows out of the compact island on iPhone.
private struct IslandMorphNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var islandMorphNamespace: Namespace.ID? {
        get { self[IslandMorphNamespaceKey.self] }
        set { self[IslandMorphNamespaceKey.self] = newValue }
    }
}

private struct IslandMorph: ViewModifier {
    let id: String
    let properties: MatchedGeometryProperties
    @Environment(\.islandMorphNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace, !id.isEmpty {
            content.matchedGeometryEffect(id: id, in: namespace, properties: properties)
        } else {
            content
        }
    }
}

extension View {
    /// Pairs this view with the view of the same `id` in the other presentation.
    func islandMorph(_ id: String, properties: MatchedGeometryProperties = .frame) -> some View {
        modifier(IslandMorph(id: id, properties: properties))
    }
}
