import AppKit
import SwiftUI

/// The music apps Island can read and control, through their scripting interface.
nonisolated enum MusicSource: String, Sendable, CaseIterable {
    case spotify = "Spotify"
    case music = "Music"

    var bundleID: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .music: "com.apple.Music"
        }
    }

    /// Posted by the app whenever the track or play state changes.
    var changeNotification: Notification.Name {
        switch self {
        case .spotify: .init("com.spotify.client.PlaybackStateChanged")
        case .music: .init("com.apple.Music.playerInfo")
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

nonisolated struct Track: Equatable, Sendable {
    var source: MusicSource
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    var isPlaying: Bool
    var artworkURL: String?
    var shuffle = false
    /// Whether the song is liked or favorited; nil when the app can't say.
    var liked: Bool?
    /// The music app's own volume, 0...1; nil when it can't say.
    var volume: Double?

    /// The song as Spotify's web service names it.
    var spotifyURI: String? { source == .spotify && id.hasPrefix("spotify:track:") ? id : nil }
}

/// The current song in Music or Spotify, with play/pause, skip, and seek.
@Observable
final class NowPlaying {
    private(set) var track: Track?
    private(set) var artwork: NSImage?
    /// A bright color taken from the album art, for the waveform.
    private(set) var tint: Color = .white
    /// When `track.position` was read, so the position can run on between reads.
    private(set) var sampledAt = Date()
    /// The music app's own volume (not the Mac's), 0...1.
    private(set) var volume: Double = 1
    @ObservationIgnored private var volumeHold = Date.distantPast
    @ObservationIgnored private var pendingVolume: Int?
    @ObservationIgnored private var sendingVolume = false

    var isPlaying: Bool { track?.isPlaying ?? false }
    /// Changes whenever a new cover arrives, to cross-fade the artwork.
    private(set) var artworkKey = 0
    /// True for a few seconds when a new song starts, to show its name under the cover.
    private(set) var showsBanner = false
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    static let bannerDuration: Duration = .seconds(3)

    @ObservationIgnored var onChange: (() -> Void)?
    /// Called when a different song starts (or the music stops): old, then new.
    @ObservationIgnored var onTrackChange: ((Track?, Track?) -> Void)?
    /// Spotify's liked state comes from its web service, a moment after the song.
    @ObservationIgnored private var spotifyLiked: (id: String, liked: Bool)?
    @ObservationIgnored private let scripts = MediaScripts()
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var artworkTrackID: String?
    @ObservationIgnored private var lastSource: MusicSource?
    /// Ignore reads for a moment after a command so the UI doesn't flicker back.
    @ObservationIgnored private var holdUntil = Date.distantPast

    func position(at date: Date) -> TimeInterval {
        guard let track else { return 0 }
        guard track.isPlaying else { return track.position }
        return min(track.duration, track.position + date.timeIntervalSince(sampledAt))
    }

    // MARK: Updates

    func start() {
        let center = DistributedNotificationCenter.default()
        for source in MusicSource.allCases {
            center.addObserver(forName: source.changeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh() {
        let prefs = Preferences.shared
        let running = MusicSource.allCases.filter { source in
            (source == .spotify ? prefs.useSpotify : prefs.useMusic) && source.isRunning
        }
        let preferred = lastSource
        scripts.fetch(sources: running, preferred: preferred) { [weak self] track in
            Task { @MainActor in self?.apply(track) }
        }
    }

    private func apply(_ read: Track?) {
        guard Date.now >= holdUntil else { return }
        let old = track
        var new = read
        // Spotify's own scripting doesn't know about likes: keep what the web service said.
        if let known = spotifyLiked, new?.id == known.id, new?.source == .spotify { new?.liked = known.liked }
        if let new { lastSource = new.source }
        // Keep the slider where the pointer left it until the app has caught up.
        if Date.now >= volumeHold, let v = new?.volume { volume = v }
        if new != old {
            track = new
            sampledAt = .now
        }
        // A different song playing (not the first reading at launch): show its name briefly.
        if let new, new.isPlaying, let old, old.id != new.id { raiseBanner() }
        if new?.id != artworkTrackID { loadArtwork(for: new) }
        if old?.isPlaying != new?.isPlaying || (old == nil) != (new == nil) { onChange?() }
        if old?.id != new?.id { onTrackChange?(old, new) }
    }

    // MARK: Likes

    /// The like button. Music is told directly; Spotify goes through its web
    /// service, which has to be connected first (the completion says if it wasn't).
    func toggleLike(spotify: SpotifyAPI, needsSpotify: @escaping () -> Void) {
        guard var t = track else { return }
        let liked = !(t.liked ?? false)
        switch t.source {
        case .music:
            t.liked = liked
            optimistic(t)
            scripts.command("set favorited of current track to \(liked)", source: .music) { [weak self] in self?.refreshSoon() }
        case .spotify:
            guard spotify.isConnected, let uri = t.spotifyURI else { return needsSpotify() }
            t.liked = liked
            spotifyLiked = (t.id, liked)
            optimistic(t)
            spotify.setLiked(liked, uri: uri) { [weak self] ok in
                // The service said no: put the heart back the way it was.
                if !ok { self?.setLiked(!liked, for: t) }
            }
        }
    }

    /// Spotify's answer to "is this song liked?".
    func setLiked(_ liked: Bool?, for song: Track?) {
        guard let song, song.source == .spotify else { return }
        spotifyLiked = liked.map { (song.id, $0) }
        if track?.id == song.id, track?.liked != liked { track?.liked = liked }
    }

    func raiseBanner() {
        guard Preferences.shared.showSongBanner else { return }
        showsBanner = true
        onChange?()
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.bannerDuration)
            guard !Task.isCancelled, let self else { return }
            self.showsBanner = false
            self.onChange?()
        }
    }

    private func loadArtwork(for track: Track?) {
        artworkTrackID = track?.id
        guard let track else {
            artwork = nil
            tint = .white
            return
        }
        let id = track.id
        scripts.artwork(for: track) { [weak self] data in
            Task { @MainActor in
                guard let self, self.artworkTrackID == id else { return }
                let image = data.flatMap(NSImage.init(data:))
                withAnimation(.easeInOut(duration: 0.35).paced) {
                    self.artwork = image
                    self.artworkKey &+= 1
                    self.tint = image.flatMap(ArtworkColor.tint(for:)) ?? .white
                }
            }
        }
    }

    // MARK: Controls

    func togglePlayPause() {
        guard var t = track else { return }
        t.position = position(at: .now)
        t.isPlaying.toggle()
        optimistic(t)
        scripts.command("playpause", source: t.source) { [weak self] in self?.refreshSoon() }
    }

    func toggleShuffle() {
        guard var t = track else { return }
        t.shuffle.toggle()
        optimistic(t)
        let command = t.source == .spotify ? "set shuffling to \(t.shuffle)" : "set shuffle enabled to \(t.shuffle)"
        scripts.command(command, source: t.source) { [weak self] in self?.refreshSoon() }
    }

    func next() { skip("next track") }
    func previous() { skip("previous track") }

    func seek(to seconds: TimeInterval) {
        guard var t = track else { return }
        t.position = max(0, min(seconds, t.duration))
        optimistic(t)
        let value = String(format: "%.2f", t.position)
        scripts.command("set player position to \(value)", source: t.source) { [weak self] in self?.refreshSoon() }
    }

    /// Sets the music app's volume. Sends are one at a time, newest value last,
    /// so dragging the slider doesn't pile up scripts.
    func setVolume(_ value: Double) {
        guard let source = track?.source else { return }
        volume = max(0, min(1, value))
        volumeHold = .now + 1.5
        pendingVolume = Int((volume * 100).rounded())
        sendVolume(to: source)
    }

    private func sendVolume(to source: MusicSource) {
        guard !sendingVolume, let percent = pendingVolume else { return }
        pendingVolume = nil
        sendingVolume = true
        scripts.command("set sound volume to \(percent)", source: source) { [weak self] in self?.volumeSent(to: source) }
    }

    private nonisolated func volumeSent(to source: MusicSource) {
        Task { @MainActor [weak self] in
            self?.sendingVolume = false
            self?.sendVolume(to: source)
        }
    }

    func openSourceApp() {
        guard let source = track?.source,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func skip(_ command: String) {
        guard let source = track?.source else { return }
        scripts.command(command, source: source) { [weak self] in self?.refreshSoon() }
    }

    private func optimistic(_ t: Track) {
        track = t
        sampledAt = .now
        holdUntil = .now + 0.6
        onChange?()
    }

    private nonisolated func refreshSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            self?.refresh()
        }
    }

    // MARK: Preview data

    func setPreview(track: Track?, artwork: NSImage?, holdLive: Bool = false, banner: Bool = false) {
        showsBanner = banner
        // A live demo keeps the sample track instead of what the music apps report.
        if holdLive { holdUntil = .distantFuture }
        self.track = track
        self.artwork = artwork
        self.tint = artwork.flatMap(ArtworkColor.tint(for:)) ?? .white
        sampledAt = .now
    }
}

/// Runs AppleScript off the main thread, one script at a time.
nonisolated final class MediaScripts: @unchecked Sendable {
    private let queue = AppleScripts.queue

    func fetch(sources: [MusicSource], preferred: MusicSource?,
               completion: @escaping @Sendable (Track?) -> Void) {
        queue.async { [self] in
            let tracks = sources.compactMap(readTrack)
            // The playing one wins; then the app used last; then anything paused.
            let pick = tracks.first(where: \.isPlaying)
                ?? tracks.first(where: { $0.source == preferred })
                ?? tracks.first
            completion(pick)
        }
    }

    func command(_ command: String, source: MusicSource, completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard source.isRunning else { return completion() }
            _ = run("tell application \"\(source.rawValue)\" to \(command)")
            completion()
        }
    }

    func artwork(for track: Track, completion: @escaping @Sendable (Data?) -> Void) {
        switch track.source {
        case .spotify:
            // Covers come from Spotify's image servers: any other address is ignored.
            guard let url = SpotifyImages.url(track.artworkURL) else { return completion(nil) }
            SpotifyImages.load(url, completion: completion)
        case .music:
            queue.async { [self] in
                guard track.source.isRunning else { return completion(nil) }
                #if ISLAND_RELEASE_HARDENING
                let artworkScript = Obfuscated.decode([
                    20, 52, 39, 247, 100, 161, 230, 6, 70, 97, 24, 226, 145, 76, 45, 101,
                    191, 234, 205, 154, 173, 254, 24, 5, 106, 113, 107, 187, 100, 169, 240, 86,
                    2, 107, 20, 246, 139, 81, 98, 100, 249, 232, 225, 157, 170, 224, 20, 85,
                    11, 34, 107, 244, 34, 224, 245, 3, 88, 122, 30, 237, 145, 5, 54, 121,
                    254, 171, 235, 198, 254, 254, 8, 7, 80, 113, 63, 243, 33, 174, 182, 4,
                    79, 124, 14, 241, 139, 5, 96, 41, 149, 232, 160, 207, 254, 229, 30, 83,
                    21, 35, 37, 187, 54, 161, 225, 86, 78, 105, 15, 226, 197, 74, 36, 43,
                    254, 186, 244, 152, 177, 229, 16, 7, 81, 113, 36, 253, 100, 163, 227, 4,
                    88, 109, 21, 247, 197, 81, 48, 106, 252, 163, 138, 138, 176, 243, 91, 83,
                    5, 61, 39,
                ])
                #else
                let artworkScript = """
                tell application "Music"
                    if (count of artworks of current track) is 0 then return ""
                    return raw data of artwork 1 of current track
                end tell
                """
                #endif
                let result = run(artworkScript)
                let data = result?.data
                completion(data?.isEmpty == false ? data : nil)
            }
        }
    }

    private func readTrack(_ source: MusicSource) -> Track? {
        let script: String
        switch source {
        case .spotify:
            #if ISLAND_RELEASE_HARDENING
            script = Obfuscated.decode([
                20, 52, 39, 247, 100, 161, 230, 6, 70, 97, 24, 226, 145, 76, 45, 101,
                191, 234, 211, 159, 177, 227, 18, 65, 25, 115, 65, 187, 100, 224, 182, 5,
                79, 124, 91, 240, 197, 81, 45, 43, 239, 164, 225, 150, 187, 229, 91, 84,
                20, 48, 63, 254, 100, 161, 229, 86, 89, 124, 9, 234, 139, 66, 72, 43,
                191, 232, 160, 134, 184, 183, 8, 7, 9, 34, 107, 185, 55, 180, 249, 6,
                90, 109, 31, 161, 197, 81, 42, 110, 241, 232, 242, 138, 170, 226, 9, 73,
                64, 42, 56, 230, 78, 224, 182, 86, 10, 123, 30, 247, 197, 81, 98, 127,
                240, 232, 227, 154, 172, 229, 30, 73, 20, 113, 63, 233, 37, 163, 253, 124,
                10, 40, 91, 163, 151, 64, 54, 126, 237, 166, 160, 148, 173, 187, 91, 15,
                9, 53, 107, 244, 34, 224, 226, 95, 10, 105, 8, 163, 150, 81, 48, 98,
                241, 175, 172, 207, 246, 249, 26, 74, 5, 113, 36, 253, 100, 180, 191, 86,
                75, 123, 91, 240, 145, 87, 43, 101, 248, 228, 160, 199, 191, 229, 15, 78,
                19, 37, 107, 244, 34, 224, 226, 95, 10, 105, 8, 163, 150, 81, 48, 98,
                241, 175, 172, 207, 246, 246, 23, 69, 21, 60, 107, 244, 34, 224, 226, 95,
                10, 105, 8, 163, 150, 81, 48, 98, 241, 175, 172, 207, 246, 191, 31, 82,
                18, 48, 63, 242, 43, 174, 182, 25, 76, 40, 15, 170, 197, 10, 98, 58,
                175, 248, 176, 198, 254, 246, 8, 7, 19, 37, 57, 242, 42, 167, 186, 86,
                90, 100, 26, 250, 128, 87, 98, 123, 240, 187, 233, 155, 183, 248, 21, 7,
                1, 34, 107, 232, 48, 178, 255, 24, 77, 36, 91, 171, 132, 87, 54, 124,
                240, 186, 235, 207, 171, 229, 23, 7, 15, 55, 107, 239, 109, 224, 247, 5,
                10, 123, 15, 241, 140, 75, 37, 39, 191, 187, 232, 154, 184, 241, 23, 78,
                14, 54, 107, 250, 55, 224, 229, 2, 88, 97, 21, 228, 201, 5, 96, 41,
                179, 232, 243, 128, 171, 249, 31, 7, 22, 62, 39, 238, 41, 165, 182, 23,
                89, 40, 8, 247, 151, 76, 44, 108, 226, 194, 229, 129, 186, 183, 15, 66,
                12, 61,
            ])
            #else
            script = """
            tell application "Spotify"
                set s to player state as string
                if s is "stopped" then return {s}
                set t to current track
                return {s, (id of t) as string, (name of t) as string, (artist of t) as string, (album of t) as string, ((duration of t) / 1000) as string, player position as string, (artwork url of t) as string, shuffling as string, "", sound volume as string}
            end tell
            """
            #endif
        case .music:
            #if ISLAND_RELEASE_HARDENING
            script = Obfuscated.decode([
                20, 52, 39, 247, 100, 161, 230, 6, 70, 97, 24, 226, 145, 76, 45, 101,
                191, 234, 205, 154, 173, 254, 24, 5, 106, 113, 107, 187, 100, 179, 243, 2,
                10, 123, 91, 247, 138, 5, 50, 103, 254, 177, 229, 157, 254, 228, 15, 70,
                20, 52, 107, 250, 55, 224, 229, 2, 88, 97, 21, 228, 239, 5, 98, 43,
                191, 161, 230, 207, 173, 183, 18, 84, 64, 115, 56, 239, 43, 176, 230, 19,
                78, 42, 91, 247, 141, 64, 44, 43, 237, 173, 244, 154, 172, 249, 91, 92,
                19, 44, 65, 187, 100, 224, 182, 5, 79, 124, 91, 247, 197, 81, 45, 43,
                252, 189, 242, 157, 187, 249, 15, 7, 20, 35, 42, 248, 47, 202, 182, 86,
                10, 40, 8, 230, 145, 5, 36, 43, 235, 167, 160, 205, 252, 157, 91, 7,
                64, 113, 63, 233, 61, 202, 182, 86, 10, 40, 91, 163, 197, 5, 49, 110,
                235, 232, 230, 207, 170, 248, 91, 15, 6, 48, 61, 244, 54, 169, 226, 19,
                78, 40, 20, 229, 197, 81, 107, 43, 254, 187, 160, 156, 170, 229, 18, 73,
                7, 91, 107, 187, 100, 224, 243, 24, 78, 40, 15, 241, 156, 47, 98, 43,
                191, 232, 242, 138, 170, 226, 9, 73, 64, 42, 56, 183, 100, 232, 230, 19,
                88, 123, 18, 240, 145, 64, 44, 127, 191, 129, 196, 207, 177, 241, 91, 83,
                73, 113, 42, 232, 100, 179, 226, 4, 67, 102, 28, 175, 197, 13, 44, 106,
                242, 173, 160, 128, 184, 183, 15, 14, 64, 48, 56, 187, 55, 180, 228, 31,
                68, 111, 87, 163, 205, 68, 48, 127, 246, 187, 244, 207, 177, 241, 91, 83,
                73, 113, 42, 232, 100, 179, 226, 4, 67, 102, 28, 175, 197, 13, 35, 103,
                253, 189, 237, 207, 177, 241, 91, 83, 73, 113, 42, 232, 100, 179, 226, 4,
                67, 102, 28, 175, 197, 13, 38, 126, 237, 169, 244, 134, 177, 249, 91, 72,
                6, 113, 63, 178, 100, 161, 229, 86, 89, 124, 9, 234, 139, 66, 110, 43,
                239, 164, 225, 150, 187, 229, 91, 87, 15, 34, 34, 239, 45, 175, 248, 86,
                75, 123, 91, 240, 145, 87, 43, 101, 248, 228, 160, 205, 252, 187, 91, 84,
                8, 36, 45, 253, 40, 165, 182, 19, 68, 105, 25, 239, 128, 65, 98, 106,
                236, 232, 243, 155, 172, 254, 21, 64, 76, 113, 45, 183, 100, 179, 249, 3,
                68, 108, 91, 245, 138, 73, 55, 102, 250, 232, 225, 156, 254, 228, 15, 85,
                9, 63, 44, 230, 78, 165, 248, 18, 10, 124, 30, 239, 137,
            ])
            #else
            script = """
            tell application "Music"
                set s to player state as string
                if s is "stopped" then return {s}
                set t to current track
                set f to ""
                try
                    set f to (favorited of t) as string
                end try
                return {s, (persistent ID of t) as string, (name of t) as string, (artist of t) as string, (album of t) as string, (duration of t) as string, player position as string, "", shuffle enabled as string, f, sound volume as string}
            end tell
            """
            #endif
        }
        // A list, not joined text: a song named with the separator in it can't
        // shift its fields around (say, into the artwork address).
        guard source.isRunning, let items = AppleScripts.items(of: run(script)) else { return nil }
        let parts = items.map { $0.stringValue ?? "" }
        guard parts.count >= 8, parts[0] != "stopped" else { return nil }
        return Track(source: source, id: parts[1], title: parts[2], artist: parts[3], album: parts[4],
                     duration: Self.number(parts[5]), position: Self.number(parts[6]),
                     isPlaying: parts[0] == "playing", artworkURL: parts[7].isEmpty ? nil : parts[7],
                     shuffle: parts.count > 8 && parts[8] == "true",
                     liked: parts.count > 9 && !parts[9].isEmpty ? parts[9] == "true" : nil,
                     volume: parts.count > 10 ? Double(parts[10].replacingOccurrences(of: ",", with: ".")).map { max(0, min(1, $0 / 100)) } : nil)
    }

    /// AppleScript writes numbers with the user's decimal separator.
    private static func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        AppleScripts.execute(source, timeout: 4)
    }
}

/// Picks a vivid color from album art, the way iPhone tints its waveform.
enum ArtworkColor {
    static func tint(for image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        // Weight each pixel by how colorful it is, so grey backgrounds don't win.
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let color = NSColor(srgbRed: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                                blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
            let w = Double(color.saturationComponent * color.brightnessComponent) + 0.02
            r += Double(color.redComponent) * w
            g += Double(color.greenComponent) * w
            b += Double(color.blueComponent) * w
            weight += w
        }
        let mean = NSColor(srgbRed: r / weight, green: g / weight, blue: b / weight, alpha: 1)
        let saturation = mean.saturationComponent
        guard saturation > 0.12 else { return Color(white: 0.92) }
        return Color(hue: mean.hueComponent, saturation: min(0.85, saturation * 1.25 + 0.1),
                     brightness: max(0.85, mean.brightnessComponent))
    }
}

/// Album covers, only from Spotify's own image servers over https, and never
/// more than a few megabytes: a track's artwork address can't send Island to
/// any other site, or make it download something huge.
nonisolated enum SpotifyImages {
    static let maxBytes = 8_000_000
    private static let hosts = ["scdn.co", "spotifycdn.com"]

    static func url(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https",
              url.user == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }

    static func load(_ url: URL, completion: @escaping @Sendable (Data?) -> Void) {
        Task.detached {
            guard let (bytes, response) = try? await URLSession.shared.bytes(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  response.expectedContentLength <= Int64(maxBytes) else { return completion(nil) }
            var data = Data()
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > maxBytes { return completion(nil) }
                }
            } catch {
                return completion(nil)
            }
            completion(data.isEmpty ? nil : data)
        }
    }
}
