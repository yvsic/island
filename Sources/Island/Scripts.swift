import Foundation

/// Every AppleScript Island runs goes through this one queue. NSAppleScript is
/// not safe to run from two threads at once, so nothing runs side by side.
nonisolated enum AppleScripts {
    static let queue = DispatchQueue(label: "island.applescript", qos: .userInitiated)

    /// Runs a script and waits for it. Call from `queue` only.
    /// `timeout` caps how long a busy or frozen app can hold the queue up.
    static func execute(_ source: String, timeout: Int = 6) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let wrapped = "with timeout of \(max(1, timeout)) seconds\n\(source)\nend timeout"
        let result = NSAppleScript(source: wrapped)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    /// Runs a script off the main thread and hands back its text result.
    static func text(_ source: String, timeout: Int = 6) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: execute(source, timeout: timeout)?.stringValue) }
        }
    }

    /// The items of a list a script returns, as text. Lists keep every field
    /// apart however odd the text in it is (tabs, newlines, separators), so a
    /// song name or mail subject can't pose as another field. Nil when the
    /// script failed or didn't return a list. Call from `queue` only.
    static func items(of descriptor: NSAppleEventDescriptor?) -> [NSAppleEventDescriptor]? {
        guard let descriptor, descriptor.descriptorType == typeAEList else { return nil }
        guard descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }
    }

    /// A list of lists of text, run off the main thread.
    static func rows(_ source: String, timeout: Int = 6) async -> [[String]]? {
        await withCheckedContinuation { continuation in
            queue.async {
                let rows = items(of: execute(source, timeout: timeout))?.map { row in
                    (items(of: row) ?? []).map { $0.stringValue ?? "" }
                }
                continuation.resume(returning: rows)
            }
        }
    }

    /// Text made safe to sit between double quotes in a script: nothing in it
    /// can end the string early and run as script.
    static func quote(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
