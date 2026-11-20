import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Files parked in the island. The shelf remembers where each file is (it does
/// not copy it), follows it if it moves, and keeps it until it's removed, across
/// restarts. A file that has since been deleted quietly drops off.
@Observable
final class ShelfStore {
    struct Item: Identifiable, Equatable {
        let id: UUID
        var url: URL
        var bookmark: Data
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var previewing = false
    private static let key = "shelfItems"

    init() { load() }

    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            let url = url.standardizedFileURL
            guard !items.contains(where: { $0.url == url }),
                  let bookmark = try? url.bookmarkData() else { continue }
            items.append(Item(id: UUID(), url: url, bookmark: bookmark))
        }
        save()
    }

    /// Files dropped on the island.
    func add(_ providers: [NSItemProvider]) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor [weak self] in self?.add([url]) }
            }
        }
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items = []
        save()
    }

    /// For snapshots: sample files, never saved.
    func setPreview(_ urls: [URL]) {
        previewing = true
        items = urls.map { Item(id: UUID(), url: $0, bookmark: Data()) }
    }

    private func load() {
        let saved = UserDefaults.standard.array(forKey: Self.key) as? [Data] ?? []
        items = saved.compactMap { bookmark in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            let fresh = stale ? (try? url.bookmarkData()) ?? bookmark : bookmark
            return Item(id: UUID(), url: url, bookmark: fresh)
        }
    }

    private func save() {
        guard !previewing else { return }
        UserDefaults.standard.set(items.map(\.bookmark), forKey: Self.key)
    }
}

/// The shelf page: a row of files to open, drag back out, or remove.
struct ShelfPanel: View {
    let model: IslandModel
    private var shelf: ShelfStore { model.shelf }

    static let bodyHeight: CGFloat = 126

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("SHELF")
                    .foregroundStyle(.white.opacity(0.5))
                if !shelf.items.isEmpty {
                    Text("\(shelf.items.count)")
                        .foregroundStyle(.white.opacity(0.3))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer()
                if !shelf.items.isEmpty {
                    Button("Clear") { withAnimation(model.prefs.reshape) { shelf.clear() } }
                        .buttonStyle(QuietTextButtonStyle())
                        .help("Take everything off the shelf. The files themselves stay where they are.")
                        .transition(.opacity)
                }
            }
            .font(.system(size: 11, weight: .bold))
            .frame(height: 16)

            if shelf.items.isEmpty {
                emptyState
                    .transition(.page)
            } else {
                IslandScroll(axis: .horizontal) {
                    HStack(spacing: 4) {
                        ForEach(shelf.items) { item in
                            ShelfTile(item: item) {
                                withAnimation(model.prefs.settle(growing: false)) { shelf.remove(item) }
                            }
                            .transition(.islandSwap(model.prefs))
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 84)
                .transition(.page)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Perched on the top edge of the shelf, legs hanging over the tiles.
            if model.prefs.clawdShelf && model.prefs.showClawdShelf {
                let px: CGFloat = 2.2
                ClawdSprite(walking: true, pixel: px)
                    .offset(x: -70, y: 22 - ClawdSprite.bodyRows * px + 1)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .padding(.top, model.contentTop - 4)
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: model.contentTop + Self.bodyHeight, alignment: .top)
        .animation(model.prefs.settle(growing: true), value: shelf.items)
        .staggered(0)
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 15, weight: .medium))
            Text("Drop files here to keep them close")
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.4))
        .frame(maxWidth: .infinity)
        .frame(height: 84)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.14), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        )
    }
}

/// One file on the shelf: click to open, drag it out to use it somewhere, and a
/// small cross under the pointer takes it off.
struct ShelfTile: View {
    let item: ShelfStore.Item
    let remove: () -> Void
    @State private var hovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: thumbnail == nil ? 0 : 6, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            Text(item.url.lastPathComponent)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 5)
        .frame(width: 76, height: 84)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(hovering ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovering {
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
                .help("Take off the shelf")
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { NSWorkspace.shared.open(item.url) }
        .liveOnly { $0.onDrag { NSItemProvider(object: item.url as NSURL) } }
        .liveOnly { view in
            view.contextMenu {
                Button("Open") { NSWorkspace.shared.open(item.url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Divider()
                Button("Take Off Shelf", action: remove)
            }
        }
        .scaleEffect(hovering ? Preferences.shared.hoverScale : 1)
        .onHover { hovering = $0 }
        .animation(Preferences.shared.buttonSpring, value: hovering)
        .help(item.url.path)
        .task(id: item.url) { thumbnail = await Self.thumbnail(for: item.url) }
    }

    /// A real preview for pictures, PDFs and the like; nil keeps the file's icon.
    private static func thumbnail(for url: URL) async -> NSImage? {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
              type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .movie) else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 88, height: 88), scale: 2,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

/// A plain word that acts as a button: dim until the pointer is on it.
struct QuietTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietLabel(configuration: configuration)
    }

    private struct QuietLabel: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(configuration.isPressed ? 0.9 : (hovering ? 0.75 : 0.4)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15).paced, value: hovering)
        }
    }
}
