import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

/// Records the screen, or one window, to a movie file. macOS writes the file
/// itself (ScreenCaptureKit's recording output), so there is no encoder to
/// manage here: Island picks what to capture and how.
@Observable
final class ScreenRecorder: NSObject {
    enum Source: Equatable {
        case display
        case window(id: CGWindowID, title: String)

        var title: String {
            switch self {
            case .display: "Entire Screen"
            case .window(_, let title): title
            }
        }
    }

    private(set) var isRecording = false
    private(set) var isStarting = false
    private(set) var startedAt: Date?
    private(set) var lastFile: URL?
    private(set) var problem: String?
    var source: Source = .display

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onFinished: ((URL) -> Void)?
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: SCRecordingOutput?
    @ObservationIgnored private var file: URL?

    private var prefs: Preferences { Preferences.shared }

    static var folder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Island Recordings")
    }

    /// Windows that can be recorded, front to back, as (id, label).
    func windows() async -> [(id: CGWindowID, title: String)] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            problem = "Allow Island in Privacy & Security › Screen & System Audio Recording"
            return []
        }
        let me = Bundle.main.bundleIdentifier
        return content.windows.compactMap { window in
            guard window.windowLayer == 0, window.frame.width > 120, window.frame.height > 80,
                  let app = window.owningApplication, app.bundleIdentifier != me else { return nil }
            let title = (window.title ?? "").trimmingCharacters(in: .whitespaces)
            return (window.windowID, title.isEmpty ? app.applicationName : "\(app.applicationName): \(title)")
        }
    }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        problem = nil
        Task {
            do {
                try await begin()
            } catch {
                problem = (error as NSError).code == -3801
                    ? "Allow Island in Privacy & Security › Screen & System Audio Recording"
                    : "Couldn't start recording: \(error.localizedDescription)"
                stream = nil
                output = nil
            }
            isStarting = false
            onChange?()
        }
    }

    private func begin() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let scale: CGFloat = switch prefs.recQuality { case "low": 0.5; case "medium": 1; default: 2 }
        let filter: SCContentFilter
        var size: CGSize
        switch source {
        case .window(let id, _):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                source = .display
                throw NSError(domain: "Island", code: 1, userInfo: [NSLocalizedDescriptionKey: "That window is gone."])
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = window.frame.size
        case .display:
            let screen = NSScreen.screens.first { $0.notchSize != nil } ?? NSScreen.main
            let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == number }) ?? content.displays.first else {
                throw NSError(domain: "Island", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display to record."])
            }
            // Island has one window, the island itself: excluding "Island's own
            // app" excluded the whole island from the recording, not just some
            // separate indicator. Record it like anything else on screen.
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            size = CGSize(width: display.width, height: display.height)
        }
        // Encoders want even pixel sizes.
        size = CGSize(width: (size.width * scale / 2).rounded() * 2, height: (size.height * scale / 2).rounded() * 2)

        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(prefs.recFPS))
        config.showsCursor = prefs.recCursor
        config.capturesAudio = prefs.recAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = prefs.recMic
        config.queueDepth = 6

        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)) + " at "
            + Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .replacingOccurrences(of: ":", with: ".")
        // Only the two known file types: a stray saved value can't change the folder or name.
        let url = Self.folder.appendingPathComponent("Recording \(stamp).\(prefs.recFileType == "mov" ? "mov" : "mp4")")

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.videoCodecType = prefs.recCodec == "hevc" ? .hevc : .h264
        recording.outputFileType = prefs.recFileType == "mov" ? .mov : .mp4

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        self.stream = stream
        self.output = output
        file = url
        startedAt = .now
        isRecording = true
    }

    func stop() {
        guard isRecording, let stream else { return }
        isRecording = false
        startedAt = nil
        onChange?()
        Task {
            try? await stream.stopCapture()
            self.stream = nil
            output = nil
            finish()
        }
    }

    private func finish() {
        guard let url = file else { return }
        file = nil
        if FileManager.default.fileExists(atPath: url.path) {
            lastFile = url
            onFinished?(url)
        }
        onChange?()
    }

    /// For snapshots.
    func setPreview(recordingFor seconds: TimeInterval?) {
        isRecording = seconds != nil
        startedAt = seconds.map { Date.now - $0 }
    }
}

extension ScreenRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            // The window closed, the display slept, or the user stopped it from the menu bar.
            guard self.isRecording else { return }
            self.isRecording = false
            self.startedAt = nil
            self.stream = nil
            self.output = nil
            self.finish()
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.problem = "Recording stopped: \(message)" }
    }
}

// MARK: - Views

/// The red dot that breathes while recording.
struct RecordDot: View {
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(Color.lowRed)
            .frame(width: size, height: size)
            .phaseAnimator(Preferences.shared.flourishes ? [1.0, 0.35] : [1.0]) { view, level in
                view.opacity(level)
                    .scaleEffect(0.85 + 0.15 * level)
                    .shadow(color: Color.lowRed.opacity(0.7 * level), radius: 4)
            } animation: { _ in .easeInOut(duration: 0.85) }
    }
}

/// Time since `start`, ticking, in digits that don't jitter.
struct ElapsedText: View {
    let start: Date?
    var size: CGFloat = 14
    var color: Color = .white

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text((start ?? context.date).elapsedText(at: context.date))
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3).paced, value: Int(context.date.timeIntervalSince(start ?? context.date)))
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// The recording page: what to capture, a big record button, and where the last one went.
struct RecordPanel: View {
    let model: IslandModel
    private var recorder: ScreenRecorder { model.recorder }
    private var prefs: Preferences { model.prefs }

    static let bodyHeight: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECORD")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(height: 16)

            HStack(spacing: 12) {
                Button(action: recorder.toggle) {
                    ZStack {
                        Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2.5)
                        RoundedRectangle(cornerRadius: recorder.isRecording ? 5 : 17, style: .continuous)
                            .fill(Color.lowRed)
                            .frame(width: recorder.isRecording ? 17 : 34, height: recorder.isRecording ? 17 : 34)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .opacity(recorder.isStarting ? 0.5 : 1)
                }
                .buttonStyle(PressStyle())
                .animation(.spring(duration: 0.4, bounce: 0.3).paced, value: recorder.isRecording)
                .help(recorder.isRecording ? "Stop recording" : "Start recording")

                VStack(alignment: .leading, spacing: 3) {
                    if recorder.isRecording {
                        HStack(spacing: 7) {
                            RecordDot(size: 8)
                            ElapsedText(start: recorder.startedAt, size: 20)
                        }
                        Text(recorder.source.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    } else {
                        Button(action: chooseSource) {
                            HStack(spacing: 5) {
                                Image(systemName: recorder.source == .display ? "display" : "macwindow")
                                Text(recorder.source.title).lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.5)
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .frame(height: 26)
                            .background(Capsule().fill(.white.opacity(0.14)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(PressStyle())
                        .help("Choose the screen or a window to record")
                        Text(summary)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let file = recorder.lastFile, !recorder.isRecording {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: {
                        Label("Show Last", systemImage: "folder")
                    }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .help(file.lastPathComponent)
                    .transition(.opacity)
                }
            }

            if let problem = recorder.problem {
                Text(problem)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.lowRed.opacity(0.9))
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(.top, model.contentTop - 4)
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: model.contentTop + Self.bodyHeight, alignment: .top)
        .animation(prefs.contentIn, value: recorder.isRecording)
        .animation(prefs.contentIn, value: recorder.problem)
        .staggered(0)
    }

    /// The chosen recording settings in a line; the full set is in Settings › Recording.
    private var summary: String {
        let quality = ["low": "Half size", "medium": "Standard", "high": "Retina"][prefs.recQuality] ?? "Retina"
        var parts = ["\(prefs.recFPS) fps", quality, prefs.recCodec == "hevc" ? "HEVC" : "H.264", ".\(prefs.recFileType)"]
        if prefs.recAudio { parts.append("sound") }
        if prefs.recMic { parts.append("mic") }
        return parts.joined(separator: " · ")
    }

    private func chooseSource() {
        Task {
            let windows = await recorder.windows()
            let titles = ["Entire Screen"] + windows.map(\.title)
            let current = titles.firstIndex(of: recorder.source.title) ?? 0
            guard let picked = IslandMenu.chooseIndex(from: titles, current: current, model: model) else { return }
            recorder.source = picked == 0 ? .display : .window(id: windows[picked - 1].id, title: windows[picked - 1].title)
        }
    }
}

/// While recording, a slim row on the island's usual page with Stop in reach.
struct RecordingRow: View {
    let model: IslandModel

    var body: some View {
        HStack(spacing: 9) {
            RecordDot(size: 9)
            Text("Recording")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(model.recorder.source.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 6)
            ElapsedText(start: model.recorder.startedAt, size: 14, color: .lowRed)
            Button("Stop") { model.recorder.stop() }
                .buttonStyle(PillButtonStyle(compact: true))
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.lowRed.opacity(0.14)))
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: Layout.recordingRowHeight, alignment: .top)
    }
}
