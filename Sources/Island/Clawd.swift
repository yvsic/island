import AppKit
import SwiftUI

/// Clawd, the small orange pixel crab from the Claude Code terminal: a wide flat
/// body, two tall black eyes, little arm nubs and stubby legs. Drawn from a
/// grid, so there is no image to ship. Here he sits with his legs hanging down,
/// kicking while music plays, waving an arm, and blinking now and then.
struct ClawdSprite: View {
    var walking: Bool
    var pixel: CGFloat = 2.2

    // 13 wide, 11 tall. X body, E eye, L leg. Arms are drawn separately.
    // A plain, friendly face: two dark eyes and nothing else.
    private static let rows = [
        "..XXXXXXXXX..",
        ".XXXXXXXXXXX.",
        ".XXXEXXXEXXX.",
        ".XXXEXXXEXXX.",
        ".XXXXXXXXXXX.",
        ".XXXXXXXXXXX.",
        ".XXXXXXXXXXX.",
        "..XXXXXXXXX..",
        ".......LL.LL.",
        ".......LL.LL.",
        ".......LL.LL.",
    ]
    /// Where the legs start, in grid columns, and how tall the body is.
    static let legColumn: CGFloat = 7
    static let bodyRows: CGFloat = 8
    static let size = CGSize(width: 13, height: 11)

    private static let body = Color(red: 215 / 255, green: 119 / 255, blue: 87 / 255)
    private static let shade = Color(red: 190 / 255, green: 98 / 255, blue: 68 / 255)
    private static let eye = Color(red: 0.12, green: 0.08, blue: 0.07)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let blink = t.truncatingRemainder(dividingBy: 4.3) < 0.14
            let step = walking ? Int(t * 4) % 2 : 0
            // A slow arm wave: one arm lifts a row, then the other.
            let wave = walking ? Int(t * 2) % 2 : -1
            Canvas { gc, _ in
                func cell(_ x: Int, _ y: Int, _ color: Color) {
                    gc.fill(Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel,
                                        width: pixel + 0.2, height: pixel + 0.2)), with: .color(color))
                }
                // Arms first, so the body sits over them.
                for (x, side) in [(0, 0), (12, 1)] {
                    let lift = wave == side ? 1 : 0
                    cell(x, 3 - lift, Self.body)
                    cell(x, 4 - lift, Self.body)
                    cell(x, 5 - lift, Self.body)
                }
                for (y, row) in Self.rows.enumerated() {
                    for (x, ch) in row.enumerated() {
                        switch ch {
                        case "X": cell(x, y, Self.body)
                        case "E": cell(x, y, blink ? Self.shade : Self.eye)
                        case "L":
                            // The legs kick in turn: the last row of one lifts away.
                            let kicked = walking && y == 10 && (x < 9 ? step == 1 : step == 0)
                            if !kicked { cell(x, y, Self.shade) }
                        default: break
                        }
                    }
                }
            }
            .frame(width: Self.size.width * pixel, height: Self.size.height * pixel)
        }
    }
}


/// The other way to meet him: typing "clawd". Only the last five letters are
/// kept in memory, nothing is stored or logged, and the global listener runs
/// only if Island already has Accessibility access (it never asks for more).
@MainActor
final class ClawdKeys {
    static let shared = ClawdKeys()
    private var recent = ""
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.see(event)
            return event
        }
        if AXIsProcessTrusted() {
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                Task { @MainActor in self?.see(event) }
            }
        }
    }

    private func see(_ event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let ch = event.charactersIgnoringModifiers?.lowercased(), ch.count == 1 else { return }
        recent = String((recent + ch).suffix(5))
        if recent == "clawd" {
            recent = ""
            let prefs = Preferences.shared
            withAnimation(.spring(duration: 0.7, bounce: 0.5)) {
                prefs.clawdShelf = true
                prefs.showClawdShelf = true
            }
        }
    }
}
