import AppKit
import SwiftUI

/// A song waiting to play.
nonisolated struct QueueItem: Identifiable, Equatable, Sendable {
    /// The song plus which occurrence of it this is, so the same song twice stays two rows.
    var id: String
    /// Spotify URI, or Music's persistent ID.
    var trackID: String
    var title: String
    var artist: String
    var artworkURL: String?
    /// Where it sits in the player's own queue.
    var position: Int
}

/// What plays next, and the island's changes to it.
///
/// Neither app lets another app rewrite its queue, so changes are made the
/// ways each one allows:
///
/// - **Spotify** (through its web service): a removed song is skipped the
///   moment it comes up. A reorder re-adds the next three in the new order and
///   skips the originals when they arrive.
/// - **Music** (through scripting): the island keeps the order it was asked
///   for, and when Music moves on by itself to a different song, sends it to
///   the right one.
///
/// If the listener picks something else by hand, the island lets go at once.
@Observable
final class QueueStore {
    enum Status: Equatable { case idle, loading, ready, needsSpotify, unavailable(String) }

    private(set) var status: Status = .idle
    /// What will be heard next, changes applied; the panel shows the first three.
    private(set) var upcoming: [QueueItem] = []
    /// A change is being sent to Spotify.
    private(set) var isBusy = false

    @ObservationIgnored private let spotify: SpotifyAPI
    @ObservationIgnored private var source: MusicSource?
    @ObservationIgnored private var raw: [QueueItem] = []
    /// Spotify: the head of its real queue, song by song, with the ones to skip marked.
    @ObservationIgnored private var script: [(id: String, skip: Bool)] = []
    /// Music: the order to keep to, once it has been changed.
    @ObservationIgnored private var desired: [QueueItem]?
    @ObservationIgnored private var naturalNext: String?
    @ObservationIgnored private var pendingJump: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var previewing = false

    static let shown = 3

    init(spotify: SpotifyAPI) {
        self.spotify = spotify
    }

    // MARK: Reading

    func refresh(for track: Track?) {
        guard !previewing else { return }
        generation += 1
        let generation = generation
        guard let track else {
            reset()
            status = .idle
            return
        }
        if track.source != source { reset() }
        source = track.source
        switch track.source {
        case .spotify:
            guard spotify.isConnected else {
                upcoming = []
                status = .needsSpotify
                return
            }
            if upcoming.isEmpty { status = .loading }
            Task {
                let list = await spotify.queue()
                guard generation == self.generation else { return }
                guard let list else {
                    status = .unavailable("Spotify didn't answer. Is it playing on this account?")
                    return
                }
                raw = list
                rebuild()
            }
        case .music:
            if upcoming.isEmpty { status = .loading }
            Task {
                let reading = await Self.readMusic()
                guard generation == self.generation else { return }
                guard let reading else {
                    upcoming = []
                    status = .unavailable("Music isn't sharing what plays next for this song")
                    return
                }
                if reading.shuffle {
                    reset()
                    status = .unavailable("Shuffle is on, so Music keeps the order to itself")
                    return
                }
                raw = reading.items
                naturalNext = raw.first?.trackID
                rebuild()
            }
        }
    }

    private func reset() {
        raw = []
        script = []
        desired = nil
        naturalNext = nil
        pendingJump = nil
        upcoming = []
    }

    /// Works out what will actually be heard from the player's queue and the changes on top.
    private func rebuild() {
        var heard: [QueueItem] = []
        switch source {
        case .spotify:
            var aligned = true
            for (index, item) in raw.enumerated() {
                if aligned, index < script.count {
                    if script[index].id == item.trackID {
                        if !script[index].skip { heard.append(item) }
                        continue
                    }
                    // The real queue no longer matches what was planned from here on.
                    aligned = false
                    script = Array(script.prefix(index))
                }
                heard.append(item)
            }
            if raw.count < script.count { script = Array(script.prefix(raw.count)) }
        case .music:
            if let plan = desired, plan.map(\.trackID) == raw.prefix(plan.count).map(\.trackID) {
                // The plan and the player agree again: nothing left to steer.
                desired = nil
            }
            heard = desired ?? raw
        case nil:
            break
        }
        let next = Array(heard.prefix(Self.shown))
        if next != upcoming { upcoming = next }
        status = .ready
    }

    // MARK: Following the player

    /// A different song started. Skips it, or steers to the right one, if the
    /// island's changes say so; otherwise just reads the queue again.
    func trackChanged(from old: Track?, to new: Track?) {
        guard !previewing else { return }
        guard let new else {
            reset()
            status = .idle
            return
        }
        switch new.source {
        case .spotify:
            if let first = script.first {
                if first.id == new.id {
                    script.removeFirst()
                    if first.skip { Self.tell(.spotify, "next track") }
                } else {
                    script = []
                }
            }
        case .music:
            if let target = desired?.first {
                if new.id == target.trackID {
                    desired?.removeFirst()
                    if desired?.isEmpty == true { desired = nil }
                    pendingJump = nil
                } else if pendingJump == nil, new.id == naturalNext {
                    pendingJump = target.trackID
                    let id = AppleScripts.quote(target.trackID)
                    Self.tell(.music, "play (first track of current playlist whose persistent ID is \"\(id)\")")
                } else {
                    // Something else was chosen by hand: the plan no longer applies.
                    desired = nil
                    pendingJump = nil
                }
            }
        }
        refresh(for: new)
    }

    nonisolated private static func tell(_ source: MusicSource, _ command: String) {
        AppleScripts.queue.async {
            guard source.isRunning else { return }
            _ = AppleScripts.execute("tell application \"\(source.rawValue)\" to \(command)", timeout: 4)
        }
    }

    // MARK: Changes

    func remove(_ item: QueueItem) {
        switch source {
        case .spotify:
            guard item.position < raw.count, raw[item.position].trackID == item.trackID else { return }
            extendScript(through: item.position)
            script[item.position].skip = true
        case .music:
            var plan = desired ?? raw
            plan.removeAll { $0.id == item.id }
            desired = plan
        case nil:
            return
        }
        rebuild()
    }

    /// Moves a song one place earlier (-1) or later (+1) among the next three.
    func move(_ item: QueueItem, by offset: Int) {
        guard !isBusy, let from = upcoming.firstIndex(of: item) else { return }
        let to = from + offset
        guard upcoming.indices.contains(to) else { return }
        var order = upcoming
        order.swapAt(from, to)
        switch source {
        case .music:
            var plan = desired ?? raw
            guard let a = plan.firstIndex(of: upcoming[from]), let b = plan.firstIndex(of: upcoming[to]) else { return }
            plan.swapAt(a, b)
            desired = plan
            rebuild()
        case .spotify:
            reorderSpotify(to: order)
        case nil:
            break
        }
    }

    private func extendScript(through position: Int) {
        guard position < raw.count else { return }
        while script.count <= position { script.append((raw[script.count].trackID, false)) }
    }

    /// Re-adds the next songs in the new order, then marks the originals to be
    /// skipped when they come up.
    private func reorderSpotify(to order: [QueueItem]) {
        let previous = upcoming
        // Everything that should not be heard afterwards: the originals of the
        // songs being moved, and anything already removed.
        var toSkip = previous.map(\.trackID)
        for (index, entry) in script.enumerated() where entry.skip && index < raw.count { toSkip.append(entry.id) }
        isBusy = true
        upcoming = order
        generation += 1
        let generation = generation
        Task {
            defer { isBusy = false }
            for item in order {
                guard await spotify.addToQueue(item.trackID) else {
                    status = .unavailable("Spotify wouldn't change the queue (this needs Premium)")
                    upcoming = previous
                    return
                }
            }
            let wanted = order.map(\.trackID)
            for attempt in 0..<3 {
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 500 : 900))
                guard generation == self.generation, let list = await spotify.queue() else { continue }
                let ids = list.map(\.trackID)
                guard let start = Self.firstRun(of: wanted, in: ids) else { continue }
                raw = list
                script = Self.plan(for: ids, keeping: start..<(start + wanted.count), skipping: toSkip)
                rebuild()
                return
            }
            // Spotify never showed the new order: leave its queue as it is.
            script = []
            refreshAfterFailure()
        }
    }

    private func refreshAfterFailure() {
        Task {
            guard let list = await spotify.queue() else { return }
            raw = list
            rebuild()
        }
    }

    /// Where the re-added songs sit in the queue: the first place the new order
    /// appears in full. (The old order can't match, since the order changed, so
    /// a queue that hasn't caught up yet finds nothing and is read again.)
    nonisolated static func firstRun(of wanted: [String], in ids: [String]) -> Int? {
        guard !wanted.isEmpty, ids.count >= wanted.count else { return nil }
        return (0...(ids.count - wanted.count)).first { Array(ids[$0..<($0 + wanted.count)]) == wanted }
    }

    /// The script for a queue: keep the re-added run, skip one occurrence of each id in `skipping`.
    nonisolated static func plan(for ids: [String], keeping kept: Range<Int>, skipping: [String]) -> [(id: String, skip: Bool)] {
        var remaining = skipping
        var script: [(id: String, skip: Bool)] = []
        for (index, id) in ids.prefix(20).enumerated() {
            if !kept.contains(index), let hit = remaining.firstIndex(of: id) {
                remaining.remove(at: hit)
                script.append((id, true))
            } else {
                script.append((id, false))
            }
        }
        // Nothing after the last skip needs watching.
        while let tail = script.last, !tail.skip { script.removeLast() }
        return script
    }

    // MARK: Music

    /// The songs after the current one in Music's current playlist, and whether shuffle is on.
    nonisolated private static func readMusic() async -> (shuffle: Bool, items: [QueueItem])? {
        #if ISLAND_RELEASE_HARDENING
        let script = Obfuscated.decode([
            20, 52, 39, 247, 100, 161, 230, 6, 70, 97, 24, 226, 145, 76, 45, 101,
            191, 234, 205, 154, 173, 254, 24, 5, 106, 113, 107, 187, 100, 169, 240, 86,
            90, 100, 26, 250, 128, 87, 98, 120, 235, 169, 244, 138, 254, 254, 8, 7,
            19, 37, 36, 235, 52, 165, 242, 86, 94, 96, 30, 237, 197, 87, 39, 127,
            234, 186, 238, 207, 165, 234, 113, 7, 64, 113, 107, 232, 33, 180, 182, 25,
            95, 124, 91, 247, 138, 5, 57, 112, 236, 160, 245, 137, 184, 251, 30, 7,
            5, 63, 42, 249, 40, 165, 242, 86, 75, 123, 91, 240, 145, 87, 43, 101,
            248, 181, 253, 229, 254, 183, 91, 7, 19, 52, 63, 187, 52, 224, 226, 25,
            10, 107, 14, 241, 151, 64, 44, 127, 191, 184, 236, 142, 167, 251, 18, 84,
            20, 91, 107, 187, 100, 224, 229, 19, 94, 40, 18, 163, 145, 74, 98, 98,
            241, 172, 229, 151, 254, 248, 29, 7, 3, 36, 57, 233, 33, 174, 226, 86,
            94, 122, 26, 224, 142, 47, 98, 43, 191, 232, 243, 138, 170, 183, 21, 7,
            20, 62, 107, 248, 43, 181, 248, 2, 10, 103, 29, 163, 145, 87, 35, 104,
            244, 187, 160, 128, 184, 183, 11, 45, 64, 113, 107, 187, 55, 165, 226, 86,
            80, 40, 15, 236, 197, 76, 98, 32, 191, 240, 138, 207, 254, 183, 91, 78,
            6, 113, 49, 187, 122, 224, 248, 86, 94, 96, 30, 237, 197, 86, 39, 127,
            191, 178, 160, 155, 177, 183, 21, 45, 64, 113, 107, 187, 54, 165, 230, 19,
            75, 124, 91, 244, 140, 81, 42, 43, 244, 232, 230, 157, 177, 250, 91, 15,
            9, 113, 96, 187, 117, 233, 182, 2, 69, 40, 1, 137, 197, 5, 98, 43,
            191, 232, 160, 207, 173, 242, 15, 7, 20, 113, 63, 244, 100, 180, 228, 23,
            73, 99, 91, 232, 197, 74, 36, 43, 239, 194, 160, 207, 254, 183, 91, 7,
            64, 113, 56, 254, 48, 224, 243, 24, 78, 40, 20, 229, 197, 74, 55, 127,
            191, 188, 239, 207, 165, 191, 11, 66, 18, 34, 34, 232, 48, 165, 248, 2,
            10, 65, 63, 163, 138, 67, 98, 127, 182, 232, 225, 156, 254, 228, 15, 85,
            9, 63, 44, 183, 100, 232, 248, 23, 71, 109, 91, 236, 131, 5, 54, 34,
            191, 169, 243, 207, 173, 227, 9, 78, 14, 54, 103, 187, 108, 161, 228, 2,
            67, 123, 15, 163, 138, 67, 98, 127, 182, 232, 225, 156, 254, 228, 15, 85,
            9, 63, 44, 230, 78, 224, 182, 86, 10, 109, 21, 231, 197, 87, 39, 123,
            250, 169, 244, 229, 254, 183, 91, 7, 18, 52, 63, 238, 54, 174, 182, 25,
            95, 124, 113, 230, 139, 65, 98, 127, 250, 164, 236,
        ])
        #else
        let script = """
            tell application "Music"
                if player state is stopped then return {}
                set out to {{shuffle enabled as string}}
                set p to current playlist
                set i to index of current track
                set n to count of tracks of p
                set z to i + 8
                if z > n then set z to n
                repeat with k from (i + 1) to z
                    set t to track k of p
                    set end of out to {(persistent ID of t) as string, (name of t) as string, (artist of t) as string}
                end repeat
                return out
            end tell
            """
        #endif
        // Rows as lists, so a song name holding a newline can't pose as another song.
        guard MusicSource.music.isRunning, let rows = await AppleScripts.rows(script, timeout: 5),
              let first = rows.first?.first else { return nil }
        var seen: [String: Int] = [:]
        let items = rows.dropFirst().enumerated().compactMap { index, parts -> QueueItem? in
            guard parts.count >= 3, !parts[0].isEmpty else { return nil }
            seen[parts[0], default: 0] += 1
            return QueueItem(id: "\(parts[0])#\(seen[parts[0]] ?? 1)", trackID: parts[0], title: parts[1], artist: parts[2],
                             artworkURL: nil, position: index)
        }
        return (first == "true", items)
    }

    /// For snapshots.
    func setPreview(_ items: [QueueItem]) {
        previewing = true
        upcoming = items
        status = .ready
    }
}

/// Up Next in the open island, in place of the player: the next three songs,
/// each with arrows to move it and a cross to drop it.
struct QueuePanel: View {
    let model: IslandModel
    private var queue: QueueStore { model.queue }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Button { model.setTool(nil) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.white.opacity(0.14)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .help("Back to the player")
                Text("UP NEXT")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if queue.isBusy {
                    ProgressView().controlSize(.mini)
                        .transition(.opacity)
                }
                Text(model.player.track?.source.rawValue ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .frame(height: 20)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, model.contentTop)
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: model.musicPanelHeight, alignment: .top)
        .animation(model.prefs.settle(growing: true), value: queue.upcoming)
        .animation(model.prefs.contentIn, value: queue.status)
        .staggered(0)
        .task {
            // Songs get queued from the player too: look again every few seconds while this is up.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                if !queue.isBusy { queue.refresh(for: model.player.track) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch queue.status {
        case .needsSpotify:
            message("Connect Spotify to see and change what plays next", symbol: "link") {
                model.setPage(.settings)
            }
        case .unavailable(let reason):
            message(reason, symbol: "music.note.list", action: nil)
        case .idle, .loading where queue.upcoming.isEmpty:
            message(queue.status == .loading ? "Looking…" : "Nothing playing", symbol: "music.note.list", action: nil)
        default:
            if queue.upcoming.isEmpty {
                message("Nothing queued after this song", symbol: "music.note.list", action: nil)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(queue.upcoming.enumerated()), id: \.element.id) { index, item in
                        QueueLine(item: item, isFirst: index == 0, isLast: index == queue.upcoming.count - 1,
                                  busy: queue.isBusy,
                                  moveUp: { queue.move(item, by: -1) }, moveDown: { queue.move(item, by: 1) },
                                  remove: { queue.remove(item) })
                            .transition(.islandSwap(model.prefs))
                    }
                }
            }
        }
    }

    private func message(_ text: String, symbol: String, action: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let action {
                Button("Connect…", action: action)
                    .buttonStyle(PillButtonStyle(compact: true))
            }
        }
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
    }
}

private struct QueueLine: View {
    let item: QueueItem
    let isFirst: Bool
    let isLast: Bool
    let busy: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            cover
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(item.artist)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                arrow("chevron.up", "Play sooner", disabled: isFirst, action: moveUp)
                arrow("chevron.down", "Play later", disabled: isLast, action: moveDown)
                arrow("xmark", "Don't play this one", disabled: false, action: remove)
            }
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hovering ? 0.1 : 0.05)))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15).paced, value: hovering)
    }

    @ViewBuilder private var cover: some View {
        // Only covers served over https from the player's own image servers are loaded.
        if let url = SpotifyImages.url(item.artworkURL), !Snapshotting.active {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                placeholder
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.28), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
            Image(systemName: "music.note")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func arrow(_ symbol: String, _ help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(disabled ? 0.25 : 0.9))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .disabled(disabled || busy)
        .help(help)
    }
}
