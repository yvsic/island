import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The apps pinned to the quick-open page. They are remembered by where they
/// live on disk, so a pin keeps working if the app is renamed in the Dock.
@Observable
final class QuickApps {
    nonisolated struct Item: Identifiable, Equatable, Sendable {
        let url: URL
        let name: String
        var id: URL { url }
        init(url: URL, name: String? = nil) {
            self.url = url
            self.name = name ?? Self.displayName(url)
        }
        static func == (a: Item, b: Item) -> Bool { a.url == b.url }
        nonisolated static func displayName(_ url: URL) -> String {
            FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
    }

    private(set) var items: [Item] = []
    /// Every app on the Mac, for the add screen. Filled in the background.
    private(set) var installed: [Item] = []
    /// The add screen is showing in place of the pinned apps.
    var isAdding = false
    private static let key = "quickApps"
    private static let starters = [
        "com.apple.Safari", "com.apple.finder", "com.apple.MobileSMS", "com.apple.mail",
        "com.apple.Notes", "com.apple.iCal", "com.apple.Music", "com.apple.systempreferences",
    ]

    init() {
        let defaults = UserDefaults.standard
        let paths: [String]
        if let saved = defaults.stringArray(forKey: Self.key) {
            paths = saved
        } else {
            // First run: pin the usual suspects that are installed.
            paths = Self.starters.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
        }
        items = paths.map { Item(url: URL(fileURLWithPath: $0)) }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
        save()
    }

    /// The apps that can still be pinned.
    var unpinned: [Item] {
        let pinned = Set(items.map(\.url))
        return installed.filter { !pinned.contains($0.url) }
    }

    /// Looks through the usual app folders (one level down, for Utilities and the like).
    func scanInstalled() {
        guard installed.isEmpty else { return }
        Task {
            // Find every app, name it and draw its icon off the main thread, so
            // opening the add screen and scrolling it only show finished things.
            let found = await Task.detached(priority: .userInitiated) { () -> ([Item], [URL: PinnedIcons.Ready]) in
                let items = Self.appURLs().map { Item(url: $0, name: Item.displayName($0)) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                var icons: [URL: PinnedIcons.Ready] = [:]
                for item in items { icons[item.url] = PinnedIcons.render(item.url) }
                return (items, icons)
            }.value
            PinnedIcons.shared.store(found.1)
            installed = found.0
        }
    }

    private nonisolated static func appURLs() -> [URL] {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        var found: [URL] = []
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                if entry.pathExtension == "app" {
                    found.append(entry)
                } else if entry.hasDirectoryPath,
                          let inner = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles]) {
                    found += inner.filter { $0.pathExtension == "app" }
                }
            }
        }
        return Array(Set(found))
    }

    func add(_ url: URL) {
        guard url.pathExtension == "app", !items.contains(where: { $0.url == url }) else { return }
        items.append(Item(url: url))
        save()
    }

    /// The pinned app being dragged to a new place.
    var dragged: Item?

    /// Puts `item` where `target` is, the others making room.
    func move(_ item: Item, to target: Item) {
        guard let from = items.firstIndex(of: item), let to = items.firstIndex(of: target), from != to else { return }
        items.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0 == item }
        save()
    }

    func open(_ item: Item) {
        // Already running: just bring it forward, no launch round trip.
        if let id = Bundle(url: item.url)?.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
           !running.isTerminated {
            if running.activate(from: NSRunningApplication.current, options: [.activateAllWindows]) { return }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        config.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: item.url, configuration: config)
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: Self.key)
    }
}

/// Finished app icons, drawn once at the size the grid shows them. Looking an
/// icon up while scrolling is a dictionary read, not a trip to the file system.
@MainActor
final class PinnedIcons {
    static let shared = PinnedIcons()
    /// A drawn icon on its way from the background to the main thread.
    struct Ready: @unchecked Sendable { let image: CGImage? }
    private var cache: [URL: NSImage] = [:]

    nonisolated static func render(_ url: URL) -> Ready {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        var rect = NSRect(x: 0, y: 0, width: 88, height: 88)
        return Ready(image: icon.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    }

    func store(_ ready: [URL: Ready]) {
        for (url, item) in ready {
            if let cg = item.image { cache[url] = NSImage(cgImage: cg, size: NSSize(width: 44, height: 44)) }
        }
    }

    func icon(for url: URL) -> NSImage {
        if let hit = cache[url] { return hit }
        if let cg = Self.render(url).image { store([url: Ready(image: cg)]) }
        return cache[url] ?? NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// The apps page: a grid of icons to click. Add pins another app; the cross
/// under the pointer unpins one. Opened from the round button in the timer row.
struct AppsPanel: View {
    let model: IslandModel
    private var apps: QuickApps { model.apps }

    static let columns = 5
    /// The page grows to show more rows of apps, but never past this many.
    static let maxRows = 3

    /// How tall the page should be for this many apps: the header, the rows
    /// that fit (up to the limit), and a little room under the last one.
    static func height(apps: Int, adding: Bool, contentTop: CGFloat) -> CGFloat {
        let rows = adding ? maxRows : min(maxRows, max(1, (apps + columns - 1) / columns))
        return contentTop - 4 + 22 + CGFloat(rows) * 84 + CGFloat(rows - 1) * 4 + 18
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(apps.isAdding ? "ADD APPS" : "APPS")
                    .foregroundStyle(.white.opacity(0.5))
                    .contentTransition(.opacity)
                Spacer()
                Button(apps.isAdding ? "Done" : "Add…") {
                    withAnimation(model.prefs.reshape) { apps.isAdding.toggle() }
                    model.recheckPointer()
                }
                .buttonStyle(QuietTextButtonStyle())
                .help(apps.isAdding ? "Back to your apps" : "Pin another app")
            }
            .font(.system(size: 11, weight: .bold))
            .frame(height: 16)

            if apps.isAdding {
                grid {
                    ForEach(apps.unpinned) { item in
                        AppTile(item: item, mode: .add, open: {
                            withAnimation(model.prefs.settle(growing: false)) { apps.add(item.url) }
                        }, remove: {})
                        .transition(.islandSwap(model.prefs))
                    }
                }
                .transition(.page)
            } else if apps.items.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 15, weight: .medium))
                    Text("Pin the apps you open most")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity)
                .frame(height: 84)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                )
                .transition(.page)
            } else {
                grid {
                    ForEach(apps.items) { item in
                        AppTile(item: item, mode: .open, open: { apps.open(item) }) {
                            withAnimation(model.prefs.settle(growing: false)) { apps.remove(item) }
                        }
                        .opacity(apps.dragged == item ? 0.35 : 1)
                        .liveOnly { tile in
                            tile.onDrag {
                                apps.dragged = item
                                return NSItemProvider(object: item.url.lastPathComponent as NSString)
                            }
                        }
                        .onDrop(of: [.plainText], delegate: AppReorder(item: item, apps: apps, animation: model.prefs.settle(growing: true)))
                        .transition(.islandSwap(model.prefs))
                    }
                }
                .transition(.page)
            }
        }
        .padding(.top, model.contentTop - 4)
        .padding(.horizontal, Layout.sidePadding)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(model.prefs.settle(growing: true), value: apps.items)
        .staggered(0)
        .onAppear { apps.scanInstalled() }
        .onDisappear { apps.isAdding = false }
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        IslandScroll(axis: .vertical) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 4), count: Self.columns), spacing: 4) {
                content()
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
        // Letting go between icons ends the drag too.
        .onDrop(of: [.plainText], delegate: AppDragEnd(apps: apps))
    }
}

/// Dragging a pinned app over another swaps them as you go, so the row
/// shows where it will land.
struct AppReorder: DropDelegate {
    let item: QuickApps.Item
    let apps: QuickApps
    let animation: Animation

    func dropEntered(info: DropInfo) {
        guard let dragged = apps.dragged, dragged != item else { return }
        withAnimation(animation) { apps.move(dragged, to: item) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        apps.dragged = nil
        return true
    }
}

struct AppDragEnd: DropDelegate {
    let apps: QuickApps
    func performDrop(info: DropInfo) -> Bool {
        apps.dragged = nil
        return true
    }
}

/// One pinned app: click to open it; a small cross under the pointer unpins it.
struct AppTile: View {
    enum Mode { case open, add }
    let item: QuickApps.Item
    var mode: Mode = .open
    let open: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: PinnedIcons.shared.icon(for: item.url))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(mode == .add ? 0 : 0.4), radius: 3, y: 1)
            Text(item.name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 5)
        .frame(width: 76, height: 84)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(hovering ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovering, mode == .add {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.accentColor))
                    .padding(4)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color(white: 0.32)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .padding(4)
                .help("Unpin")
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: open)
        .scaleEffect(hovering ? Preferences.shared.hoverScale : 1)
        .onHover { hovering = $0 }
        .animation(Preferences.shared.buttonSpring, value: hovering)
        .help(mode == .add ? "Pin \(item.name)" : "Open \(item.name)")
    }
}
