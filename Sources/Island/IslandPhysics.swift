import AppKit
import QuartzCore
import SwiftUI

/// The island's body, simulated rather than tweened.
///
/// Apple describes the Dynamic Island as feeling "like a living organism, with a
/// deliberate elasticity". A single SwiftUI spring moves every edge in lockstep,
/// which reads as a rectangle being resized. Here each dimension is its own
/// damped spring with its own tension, and the springs talk to each other:
///
/// - **Width leads, height follows** when opening, so the island first spreads
///   along the screen edge and then pours down. Closing reverses it: it draws up
///   first, then pulls in its sides.
/// - **Volume is (roughly) kept.** While the island drops fast it gets a little
///   narrower, and while it is sucked back up it bulges a little wider, the way a
///   drop of liquid behaves. Fast sideways growth flattens it a touch.
/// - **Speed rounds it.** The bottom corners soften as the body moves and firm up
///   as it comes to rest, and the shoulders flex with sideways motion.
/// - **Velocity carries over.** Retargeting mid-flight (hover off while opening)
///   keeps every spring's momentum, so the shape changes its mind organically
///   instead of snapping into a new curve.
///
/// The simulation runs on the display's own refresh (120 Hz on ProMotion) and
/// stops completely when the body is at rest.
@Observable
final class IslandMotion: NSObject {
    enum Kind { case open, close, settle(growing: Bool), reshape }

    /// What the island is drawn as this frame: the springs plus the stretch.
    private(set) var current: IslandGeometry
    /// How far the body is from where it's going, vertically, in points.
    /// Content rides along with this so it feels carried by the body.
    private(set) var overshoot: CGFloat = 0
    /// How far the second activity's bubble has pulled away: 0 is still part of
    /// the body, 1 is its own drop beside it. It overshoots a little on the way out.
    private(set) var bubble: Double = 0
    @ObservationIgnored private var drop = Spring(0)
    @ObservationIgnored private var dropLeaving = false

    /// How big the body is next to where it's going (1 = arrived), per axis.
    /// Open content stretches by a share of this, so it reads as printed on an
    /// elastic body rather than laid over a resizing rectangle.
    private(set) var fit = CGSize(width: 1, height: 1)

    @ObservationIgnored private var width: Spring
    @ObservationIgnored private var height: Spring
    @ObservationIgnored private var top: Spring
    @ObservationIgnored private var bottom: Spring
    @ObservationIgnored private var kind: Kind = .settle(growing: true)
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var lastTime: CFTimeInterval?

    init(_ geometry: IslandGeometry) {
        current = geometry
        width = Spring(geometry.width)
        height = Spring(geometry.height)
        top = Spring(geometry.topRadius)
        bottom = Spring(geometry.bottomRadius)
        super.init()
    }

    /// Jump straight to a shape with no motion (first draw, snapshots).
    func reset(to geometry: IslandGeometry) {
        width = Spring(geometry.width)
        height = Spring(geometry.height)
        top = Spring(geometry.topRadius)
        bottom = Spring(geometry.bottomRadius)
        overshoot = 0
        fit = CGSize(width: 1, height: 1)
        current = geometry
        stop()
    }

    /// Pinch a bubble off the body, or draw it back in. The body recoils as the
    /// drop leaves and swallows with a small bulge when it returns.
    func setBubble(_ apart: Bool, animated: Bool = true) {
        dropLeaving = apart
        drop.target = apart ? 100 : 0
        guard animated, !Preferences.shared.reduceMotion else {
            drop.snap()
            bubble = apart ? 1 : 0
            return
        }
        width.velocity += apart ? -150 : 130
        start()
    }

    /// A small shove that leaves the target alone: the body jiggles and settles
    /// back, as if something inside it moved (a new song, a key press).
    func kick(width dw: Double = 0, height dh: Double = 0) {
        guard !Preferences.shared.reduceMotion else { return }
        let lively = 0.6 + Preferences.shared.bounce * 2.5
        width.velocity += dw * lively
        height.velocity += dh * lively
        start()
    }

    /// Head for a new shape, keeping whatever momentum the body already has.
    func move(to geometry: IslandGeometry, _ kind: Kind) {
        self.kind = kind
        width.target = geometry.width
        height.target = geometry.height
        top.target = geometry.topRadius
        bottom.target = geometry.bottomRadius
        if Preferences.shared.reduceMotion {
            // No physics at all: a quick, plain cross to the new shape.
            reset(to: geometry)
            return
        }
        start()
    }

    // MARK: Tuning

    /// Per-dimension (response, damping) for the current kind of move.
    /// Response is the spring's period in seconds; damping 1 means no overshoot.
    private var tuning: (width: Tune, height: Tune, top: Tune, bottom: Tune) {
        let prefs = Preferences.shared
        // The Bounciness slider shifts every spring together; 0.16 is "Natural".
        let extra = (prefs.bounce - 0.16) * 1.3
        func t(_ response: Double, _ damping: Double) -> Tune {
            Tune(response: prefs.pace(response), damping: min(1, max(0.42, damping - extra)))
        }
        switch kind {
        case .open:
            // Spreads first, then pours down with a soft, deliberate overshoot.
            return (t(0.40, 0.70), t(0.50, 0.73), t(0.46, 0.62), t(0.52, 0.80))
        case .close:
            // Draws up quickly with almost no bounce, then the sides tuck in.
            return (t(0.40, 0.84), t(0.32, 0.93), t(0.30, 0.95), t(0.32, 0.95))
        case .reshape:
            // Already open, changing what it shows: every edge on the same soft
            // spring the content uses, so nothing races anything else.
            let tune = Tune(response: prefs.reshapeResponse, damping: prefs.reshapeDamping)
            return (tune, tune, tune, tune)
        case .settle(let growing):
            // Live activities beside the camera: springier, it's a small move.
            return growing
                ? (t(0.44, 0.60), t(0.40, 0.62), t(0.40, 0.65), t(0.42, 0.75))
                : (t(0.40, 0.70), t(0.36, 0.76), t(0.36, 0.80), t(0.38, 0.85))
        }
    }

    // MARK: Simulation

    private func start() {
        guard link == nil else { return }
        let screen = NSScreen.screens.first { $0.notchSize != nil } ?? NSScreen.main
        guard let screen else { return }
        let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTime = nil
    }

    private func stop() {
        link?.invalidate()
        link = nil
        lastTime = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = min(1.0 / 30, max(1.0 / 480, now - (lastTime ?? (now - 1.0 / 120))))
        lastTime = now

        let tune = tuning
        // Fixed small steps keep stiff springs stable at any refresh rate.
        let steps = max(1, Int((dt / (1.0 / 480)).rounded(.up)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            width.step(h, tune.width)
            height.step(h, tune.height)
            top.step(h, tune.top)
            bottom.step(h, tune.bottom)
            // Leaving: slow and elastic, like a drop letting go. Returning: quick, no wobble.
            drop.step(h, dropLeaving ? Tune(response: Preferences.shared.pace(0.62), damping: 0.56)
                                     : Tune(response: Preferences.shared.pace(0.38), damping: 0.92))
        }

        let resting = [width, height, top, bottom, drop].allSatisfy(\.isResting)
        if resting {
            drop.snap()
            for i in [\IslandMotion.width, \.height, \.top, \.bottom] { self[keyPath: i].snap() }
        }
        publish()
        if resting { stop() }
    }

    /// Turns spring state into the drawn shape, adding the stretch.
    private func publish() {
        let vw = width.velocity, vh = height.velocity
        // Dropping fast: a little narrower. Drawing up fast: a little wider.
        let squeeze = clamp(-vh * 0.0055, -10, 12)
        // Spreading fast flattens it slightly; pulling in lets it hang a touch lower.
        let flatten = clamp(-vw * 0.0028, -5, 4)
        // Speed softens the bottom corners and flexes the shoulders.
        let soften = clamp(abs(vh) * 0.006, 0, 9)
        let flex = clamp(abs(vw) * 0.004, 0, 6)

        var g = IslandGeometry(width: max(0, width.value + squeeze),
                               height: max(0, height.value + flatten),
                               topRadius: max(0, top.value + flex),
                               bottomRadius: max(0, bottom.value + soften))
        // Never let the body grow corners wider than itself mid-flight.
        g.bottomRadius = min(g.bottomRadius, g.width / 2, max(0, g.height - g.topRadius))
        current = g
        overshoot = height.value - height.target
        bubble = drop.value / 100
        fit = CGSize(width: width.target > 1 ? width.value / width.target : 1,
                     height: height.target > 1 ? height.value / height.target : 1)
    }

    private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }
}

/// Response and damping for one spring.
struct Tune {
    var response: Double
    var damping: Double
}

/// One damped harmonic oscillator.
private struct Spring {
    var value: Double
    var velocity: Double = 0
    var target: Double

    init(_ value: Double) {
        self.value = value
        target = value
    }

    mutating func step(_ dt: Double, _ tune: Tune) {
        let omega = 2 * Double.pi / max(0.05, tune.response)
        let stiffness = omega * omega
        let friction = 2 * tune.damping * omega
        // Semi-implicit Euler: stable for springs at small steps.
        let acceleration = -stiffness * (value - target) - friction * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }

    var isResting: Bool { abs(value - target) < 0.08 && abs(velocity) < 2 }

    mutating func snap() {
        value = target
        velocity = 0
    }
}

// MARK: - Views that follow the simulation

/// The parts of the island that read the simulation every frame are kept in
/// their own small views, so only they redraw at display rate, never the content.
struct LiveIslandBody: View {
    let motion: IslandMotion
    let glass: Bool

    var body: some View {
        IslandBody(geometry: motion.current, glass: glass)
            .contentShape(IslandOutline(geometry: motion.current))
    }
}

struct LiveIslandShadow: View {
    let motion: IslandMotion
    let visible: Bool

    var body: some View {
        IslandShadow(visible: visible, size: CGSize(width: motion.current.width, height: motion.current.height))
    }
}

/// Clips content to the body as it is this frame.
struct LiveIslandMask: View {
    let motion: IslandMotion

    var body: some View {
        IslandOutline(geometry: motion.current.withoutFlares)
    }
}

/// Lets open content ride the body's overshoot a little, so rows feel carried
/// by the island rather than pinned to the screen while it wobbles.
struct RideAlong<Content: View>: View {
    let motion: IslandMotion
    let active: Bool
    @ViewBuilder let content: Content

    var body: some View {
        // Past the target: carried down with it. Still far short (just opening):
        // stay put, the rows bring their own entrance. Close below: ease in.
        let o = motion.overshoot
        let ride = !active ? 0 : (o > 0 ? min(6, o * 0.2) : o * 0.2 * max(0, 1 + o / 24))
        // Content also stretches with the body: slightly small while the body is
        // still growing, a hair past full size on the overshoot, then true.
        let fit = motion.fit
        content
            .scaleEffect(x: active ? Self.share(fit.width) : 1, y: active ? Self.share(fit.height) : 1, anchor: .top)
            .offset(y: ride)
    }

    /// The share of the body's stretch that content takes on.
    private static func share(_ ratio: CGFloat) -> CGFloat {
        min(1.05, max(0.9, 1 + (ratio - 1) * 0.6))
    }
}

/// The bubble that splits off the island for a second activity. It is drawn as
/// liquid: the island's edge and the drop are blurred together and cut back to
/// a hard edge, so while they are close a neck of black joins them, thins, and
/// snaps, the way a drop pinches off.
struct LiveBubble<Glyph: View>: View {
    let motion: IslandMotion
    let notchHeight: CGFloat
    @ViewBuilder let glyph: Glyph

    var body: some View {
        let s = CGFloat(motion.bubble)
        let d = max(18, notchHeight - 8), r = d / 2
        let edge = motion.current.width / 2
        // Tucked inside the island's edge when merged; a clear gap away when apart.
        let cx = edge - r - 2 + (d + 12) * s
        let grow = min(1, max(0, s * 1.7))
        let cy = notchHeight / 2
        ZStack(alignment: .top) {
            Canvas { context, size in
                guard s > 0.01 else { return }
                let mid = size.width / 2
                context.addFilter(.alphaThreshold(min: 0.5, color: .black))
                context.addFilter(.blur(radius: 5))
                context.drawLayer { layer in
                    // The island's side, kept clear of its top flare.
                    layer.fill(Path(roundedRect: CGRect(x: mid + edge - 30, y: 6, width: 30, height: notchHeight - 12),
                                    cornerRadius: 9), with: .color(.black))
                    let rr = r * grow
                    layer.fill(Path(ellipseIn: CGRect(x: mid + cx - rr, y: cy - rr, width: rr * 2, height: rr * 2)),
                               with: .color(.black))
                }
            }
            .frame(height: notchHeight + 12)
            // A crisp disc over the liquid one keeps the drop's edge smooth.
            Circle()
                .fill(.black)
                .frame(width: d * grow, height: d * grow)
                .frame(width: d, height: d)
                .offset(x: cx, y: (notchHeight - d) / 2)
                .opacity(s > 0.01 ? 1 : 0)
            glyph
                .frame(width: d, height: d)
                .scaleEffect(0.5 + 0.5 * min(1, s))
                .opacity(Double(min(1, max(0, (s - 0.6) / 0.3))))
                .offset(x: cx, y: (notchHeight - d) / 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}
