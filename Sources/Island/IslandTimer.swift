import AppKit
import Foundation

/// A countdown timer that can pause, resume, and ring.
@Observable
final class IslandTimer {
    enum State: Equatable {
        case idle
        case running(end: Date, total: TimeInterval)
        case paused(remaining: TimeInterval, total: TimeInterval)
        case ringing
    }

    static func presetLabel(_ minutes: Int, long: Bool = false) -> String {
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return long ? "\(hours) Hour\(hours == 1 ? "" : "s")" : "\(hours)h"
        }
        return long ? "\(minutes) Minute\(minutes == 1 ? "" : "s")" : "\(minutes)m"
    }

    private(set) var state: State = .idle
    /// Bumped every second while running so views re-read the remaining time.
    private(set) var tick = 0
    /// The length of the last timer started, for Repeat.
    private(set) var lastMinutes = 5

    @ObservationIgnored var onRing: (() -> Void)?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var sound: NSSound?
    @ObservationIgnored private var ringLimit: Task<Void, Never>?

    var isActive: Bool {
        switch state { case .running, .paused: true; default: false }
    }
    var isRunning: Bool { if case .running = state { true } else { false } }
    var isRinging: Bool { state == .ringing }

    func remaining(at date: Date = .now) -> TimeInterval {
        switch state {
        case .running(let end, _): max(0, end.timeIntervalSince(date))
        case .paused(let remaining, _): remaining
        default: 0
        }
    }

    /// 0...1 of the countdown still left.
    func fraction(at date: Date = .now) -> Double {
        switch state {
        case .running(_, let total), .paused(_, let total): total > 0 ? remaining(at: date) / total : 0
        default: 0
        }
    }

    var remainingText: String { Self.format(remaining()) }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    // MARK: Actions

    func start(minutes: Int) {
        stopSound()
        lastMinutes = minutes
        let total = TimeInterval(minutes * 60)
        state = .running(end: .now + total, total: total)
        startTicking()
    }

    func pause() {
        guard case .running(_, let total) = state else { return }
        state = .paused(remaining: remaining(), total: total)
        ticker?.cancel()
    }

    func resume() {
        guard case .paused(let remaining, let total) = state else { return }
        state = .running(end: .now + remaining, total: total)
        startTicking()
    }

    func togglePause() { isRunning ? pause() : resume() }

    func cancel() {
        ticker?.cancel()
        stopSound()
        state = .idle
    }

    /// For snapshots.
    func setPreview(_ state: State) { state == .idle ? cancel() : (self.state = state) }

    // MARK: Ticking

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let left = self.remaining()
                if left <= 0 { self.ring(); return }
                // Wake on the whole second so the display flips exactly on time.
                let untilNext = left - floor(left - 0.0001)
                try? await Task.sleep(for: .seconds(min(max(untilNext, 0.02), 1)))
                self.tick &+= 1
            }
        }
    }

    private func ring() {
        state = .ringing
        let prefs = Preferences.shared
        let sound = NSSound(named: prefs.timerSound) ?? NSSound(named: "Glass")
        sound?.loops = prefs.repeatSound
        sound?.play()
        self.sound = sound
        onRing?()
        // Stop ringing on its own after a minute.
        ringLimit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, self?.isRinging == true else { return }
            self?.cancel()
        }
    }

    private func stopSound() {
        ringLimit?.cancel()
        ringLimit = nil
        sound?.stop()
        sound = nil
    }
}
