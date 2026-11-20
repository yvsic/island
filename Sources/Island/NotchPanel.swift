import AppKit
import SwiftUI

/// A transparent, borderless panel that sits over the notch, above the menu bar,
/// on every Space and over full-screen apps. It never takes focus.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isFloatingPanel = true
        // Set after isFloatingPanel: that setter resets the level to .floating (3), which sits under the menu bar.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        hidesOnDeactivate = false
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    /// Only while a reply is being typed does the island take the keyboard.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    // Let the panel sit over the menu bar instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Buttons work on the first click, without the panel becoming key.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSScreen {
    /// The camera housing's size, or nil on screens without one.
    var notchSize: CGSize? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
    }
}

/// Places the panel, tracks the pointer, and turns pointer position into hover.
final class NotchController {
    /// The panel is a fixed canvas; the island draws inside it and grows from the top.
    static let canvas = CGSize(width: 720, height: 520)

    private let model: IslandModel
    private let panel: NotchPanel
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?

    init(model: IslandModel) {
        self.model = model
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.canvas))
        // Measure the notch before the island first draws, so it starts at the right size.
        place()
        let host = IslandHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        panel.orderFrontRegardless()

        let mouseEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp, .leftMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouseEvents, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.trackPointer(event: event) }
            return event
        }) { monitors.append(local) }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.place() } }

        // Island changes size on its own (music starts, timer ends): re-check the pointer.
        model.onLayoutChange = { [weak self] in
            self?.trackPointer()
            self?.syncKeyboard()
        }
    }

    /// Takes the keyboard for a reply, and hands it straight back afterwards.
    private func syncKeyboard() {
        let wants = model.isReplying
        guard wants != panel.allowsKey else { return }
        panel.allowsKey = wants
        if wants {
            panel.makeKey()
        } else if panel.isKeyWindow {
            // Stepping out and back in returns the keyboard to the app in front.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    private var screen: NSScreen {
        NSScreen.screens.first { $0.notchSize != nil } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func place() {
        let screen = screen
        if let notch = screen.notchSize {
            model.notchSize = notch
            model.hasPhysicalNotch = true
        } else {
            // No camera housing: draw a slim virtual one in the menu bar.
            let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
            model.notchSize = CGSize(width: 180, height: max(24, barHeight))
            model.hasPhysicalNotch = false
        }
        let origin = NSPoint(x: screen.frame.midX - Self.canvas.width / 2,
                             y: screen.frame.maxY - Self.canvas.height)
        panel.setFrame(NSRect(origin: origin, size: Self.canvas), display: true)
    }

    /// The island's current rectangle in screen coordinates.
    private var islandRect: NSRect {
        let frame = panel.frame
        let size = model.bodySize
        var rect = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                          width: size.width, height: size.height)
        // Reach up past the screen edge so slamming the pointer to the top still counts.
        rect.size.height += 4
        if model.presentation == .expanded {
            rect = rect.insetBy(dx: -10, dy: -10)
        }
        return rect
    }

    private func trackPointer(event: NSEvent? = nil) {
        if let event {
            if event.type == .leftMouseDown { model.isPointerDown = true }
            if event.type == .leftMouseUp { model.isPointerDown = false }
        }
        // A drag that started on the island (scrubbing) keeps it open until release.
        let inside = islandRect.contains(NSEvent.mouseLocation) || model.isPointerDown
        panel.ignoresMouseEvents = !inside
        model.setHovering(inside)
    }

    /// Debug: opens the island on a page and writes what the panel really
    /// draws to a PNG, then quits.
    func capture(page: IslandModel.Page, tab: String?, to path: String) {
        if let tab { SettingsPanel.snapshotTab = SettingsPanel.Tab(rawValue: tab) }
        Task {
            try? await Task.sleep(for: .seconds(1))
            // Held open as if a drag were in progress, wherever the pointer is.
            model.isScrubbing = true
            model.setExpanded(true)
            model.setPage(page)
            // `--capture apps <file> add` shows the add-apps screen.
            if tab == "add" { try? await Task.sleep(for: .seconds(1)); model.apps.isAdding = true }
            try? await Task.sleep(for: .seconds(2))
            if let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }

    /// Debug: opens and closes the island, logging the black shape's left, right,
    /// and center at a few rows every frame, to check the motion stays centered.
    func logMotion() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard let view = panel.contentView else { return }
            model.demo()
            let start = Date()
            while Date().timeIntervalSince(start) < 2.6 {
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    var parts: [String] = []
                    for y in [2, 30, 80, 150] {
                        let py = Int(CGFloat(y) * CGFloat(rep.pixelsHigh) / view.bounds.height)
                        var left = -1, right = -1
                        for x in 0..<rep.pixelsWide {
                            guard let c = rep.colorAt(x: x, y: py), c.alphaComponent > 0.9, c.brightnessComponent < 0.05 else { continue }
                            if left < 0 { left = x }
                            right = x
                        }
                        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
                        if left >= 0 {
                            let l = CGFloat(left) / scale, r = CGFloat(right) / scale
                            parts.append(String(format: "y%d %.0f-%.0f c%.1f", y, l, r, (l + r) / 2))
                        }
                    }
                    print(String(format: "%.3f ", Date().timeIntervalSince(start)) + parts.joined(separator: " | "))
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            print("end: hovering=\(model.isHovering) presentation=\(model.presentation) size=\(model.bodySize) top=\(model.topRadius) notch=\(model.notchSize)")
            exit(0)
        }
    }
}
