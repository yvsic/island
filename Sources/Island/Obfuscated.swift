import Foundation

#if ISLAND_RELEASE_HARDENING

/// Masks the AppleScript and SQL text that spells out exactly what Island
/// automates — reading Mail, replying to iMessages, reaching into Music and
/// Spotify — so it isn't sitting in the shipped binary as a plain string
/// `strings` can dump with zero disassembly. This is XOR, not real
/// encryption: anyone who finds `decode` below recovers the key and every
/// string at once. The point isn't secrecy against someone who finds the
/// decoder — it's removing the free, no-effort leak of "the content with a
/// clean read." Only in release builds; debug builds keep the plain literals
/// so the source stays readable while working on it.
nonisolated enum Obfuscated {
    static func decode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.enumerated().map { $0.element ^ key[$0.offset % key.count] }, as: UTF8.self)
    }

    private static let key: [UInt8] = [
        96, 81, 75, 155, 68, 192, 150, 118, 42, 8, 123, 131, 229, 37, 66, 11,
        159, 200, 128, 239, 222, 151, 123, 39,
    ]
}

#endif
