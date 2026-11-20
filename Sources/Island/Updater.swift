import AppKit
import CryptoKit
import Foundation

/// Keeps Island up to date. It reads a small version note from the update site,
/// and when a newer build is listed it downloads the dmg, checks the SHA-256 and
/// the signature (only the owner's private key can make one), then swaps the app
/// in place and reopens it. Nothing unsigned is ever installed.
@Observable
final class Updater {
    static let shared = Updater()
    nonisolated static let feed = URL(string: "https://island-notch-updates-390.netlify.app/latest.json")!
    nonisolated static let publicKey = "ddR3BLs/Mb13GL3tM3nKCdFDnRfHr/idxxXJMcXXl8I="

    var status = "Up to date"
    var busy = false
    private var started = false

    nonisolated struct Manifest: Decodable, Sendable {
        let build: Int
        let version: String
        let url: String
        let sha256: String
        let signature: String
    }

    nonisolated static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// Checks shortly after launch, then every six hours.
    func start() {
        guard !started else { return }
        started = true
        Task {
            try? await Task.sleep(for: .seconds(20))
            while true {
                if Preferences.shared.autoUpdate { await check(manual: false) }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func check(manual: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if manual { status = "Checking…" }
        do {
            guard let staged = try await Task.detached(operation: { try await Self.stage() }).value else {
                status = "Up to date"
                return
            }
            status = "Installing \(staged.version)…"
            try install(staged.app, work: staged.work)
        } catch {
            status = manual ? "Update failed: \(error.localizedDescription)" : "Up to date"
        }
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Downloads, verifies and unpacks a newer build. Nil when there isn't one.
    private nonisolated static func stage() async throws -> (version: String, app: URL, work: URL)? {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (note, _) = try await URLSession.shared.data(for: request)
        let manifest = try JSONDecoder().decode(Manifest.self, from: note)
        guard manifest.build > currentBuild else { return nil }

        guard let url = URL(string: manifest.url, relativeTo: feed)?.absoluteURL,
              url.scheme == "https", url.host == feed.host else { throw UpdateError("bad download address") }
        let (file, _) = try await URLSession.shared.download(from: url)
        let dmg = try Data(contentsOf: file)
        guard SHA256.hash(data: dmg).map({ String(format: "%02x", $0) }).joined() == manifest.sha256.lowercased() else {
            throw UpdateError("the download is damaged")
        }
        guard let keyData = Data(base64Encoded: publicKey), let sig = Data(base64Encoded: manifest.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(sig, for: dmg) else { throw UpdateError("the update isn't signed by the developer") }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("island-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmgPath = work.appendingPathComponent("Island.dmg")
        try dmg.write(to: dmgPath)
        let mount = work.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmgPath.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let app = work.appendingPathComponent("Island.app")
        try run("/usr/bin/ditto", [mount.appendingPathComponent("Island.app").path, app.path])
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let info = Bundle(url: app)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              Int(info?["CFBundleVersion"] as? String ?? "") == manifest.build else {
            throw UpdateError("the update doesn't match its note")
        }
        return (manifest.version, app, work)
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\((tool as NSString).lastPathComponent) failed") }
        return p.terminationStatus
    }

    /// Hands the swap to a tiny script that waits for Island to quit, replaces the
    /// app (keeping the old one until the new one is in place), and opens it again.
    private func install(_ staged: URL, work: URL) throws {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError("can't write to \(parent.path)")
        }
        let script = work.appendingPathComponent("swap.sh")
        try """
        #!/bin/sh
        while kill -0 "$1" 2>/dev/null; do sleep 0.3; done
        ditto "$3" "$2.new" && rm -rf "$2" && mv "$2.new" "$2" && xattr -cr "$2"
        open "$2"
        rm -rf "$4"
        """.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/sh", script.path, String(ProcessInfo.processInfo.processIdentifier), target.path, staged.path, work.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        NSApp.terminate(nil)
    }
}
