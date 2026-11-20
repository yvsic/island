import AppKit
import SQLite3
import SwiftUI

/// Watches for new messages and email. macOS gives apps no way to read another
/// app's notifications, so this goes to the sources: the Messages database
/// (which needs Full Disk Access) and Mail itself (through automation).
@Observable
final class NotificationWatcher {
    enum Access: Equatable { case unknown, allowed, needsFullDiskAccess }

    private(set) var messagesAccess: Access = .unknown
    @ObservationIgnored var onNote: ((IslandNote) -> Void)?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var lastRow: Int64?
    @ObservationIgnored private var seenMail: Set<Int>?
    @ObservationIgnored private var ticks = 0

    private var prefs: Preferences { Preferences.shared }
    nonisolated private static var database: String { NSHomeDirectory() + "/Library/Messages/chat.db" }

    func start() {
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func poll() {
        ticks += 1
        if prefs.notifyMessages { checkMessages() }
        // Mail is asked less often: every half minute, and only while it's open.
        if prefs.notifyMail, ticks % 10 == 1 { checkMail() }
    }

    // MARK: Messages

    private func checkMessages() {
        let since = lastRow
        Task { [weak self] in
            let result = await Task.detached { Self.readMessages(after: since) }.value
            guard let self else { return }
            guard let result else {
                self.messagesAccess = .needsFullDiskAccess
                return
            }
            self.messagesAccess = .allowed
            self.lastRow = result.lastRow
            // The first look only finds where the conversation history ends.
            guard since != nil, !Self.isFrontmost("com.apple.MobileSMS") else { return }
            for note in result.notes.suffix(1) { self.onNote?(note) }
        }
    }

    /// New incoming messages after a row, and the newest row. Nil means the
    /// database can't be opened (no Full Disk Access).
    nonisolated private static func readMessages(after row: Int64?) -> (notes: [IslandNote], lastRow: Int64)? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)

        var statement: OpaquePointer?
        guard let row else {
            guard sqlite3_prepare_v2(db, "SELECT IFNULL(MAX(ROWID), 0) FROM message", -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? ([], sqlite3_column_int64(statement, 0)) : nil
        }
        #if ISLAND_RELEASE_HARDENING
        let sql = Obfuscated.decode([
            51, 20, 7, 222, 7, 148, 182, 27, 4, 90, 52, 212, 172, 97, 110, 43,
            242, 230, 244, 138, 166, 227, 87, 7, 13, 127, 42, 239, 48, 178, 255, 20,
            95, 124, 30, 231, 167, 74, 38, 114, 179, 232, 232, 193, 183, 243, 87, 7,
            3, 127, 44, 238, 45, 164, 186, 86, 73, 38, 31, 234, 150, 85, 46, 106,
            230, 151, 238, 142, 179, 242, 113, 97, 50, 30, 6, 187, 41, 165, 229, 5,
            75, 111, 30, 163, 136, 47, 14, 78, 217, 156, 160, 165, 145, 222, 53, 7,
            8, 48, 37, 255, 40, 165, 182, 30, 10, 71, 53, 163, 141, 11, 16, 68,
            200, 129, 196, 207, 227, 183, 22, 9, 8, 48, 37, 255, 40, 165, 201, 31,
            78, 2, 55, 198, 163, 113, 98, 65, 208, 129, 206, 207, 189, 255, 26, 83,
            63, 60, 46, 232, 55, 161, 241, 19, 117, 98, 20, 234, 139, 5, 40, 43,
            208, 134, 160, 133, 240, 250, 30, 84, 19, 48, 44, 254, 27, 169, 242, 86,
            23, 40, 22, 173, 183, 106, 21, 66, 219, 194, 204, 170, 152, 195, 91, 109,
            47, 24, 5, 187, 39, 168, 247, 2, 10, 107, 91, 204, 171, 5, 33, 37,
            205, 135, 215, 166, 154, 183, 70, 7, 10, 127, 40, 243, 37, 180, 201, 31,
            78, 2, 44, 203, 160, 119, 7, 43, 242, 230, 210, 160, 137, 222, 63, 7,
            94, 113, 116, 187, 5, 142, 210, 86, 71, 38, 18, 240, 186, 67, 48, 100,
            242, 151, 237, 138, 254, 170, 91, 23, 64, 16, 5, 223, 100, 173, 184, 23,
            89, 123, 20, 224, 140, 68, 54, 110, 251, 151, 237, 138, 173, 228, 26, 64,
            5, 14, 63, 226, 52, 165, 182, 75, 10, 56, 113, 204, 183, 97, 7, 89,
            191, 138, 217, 207, 179, 185, 41, 104, 55, 24, 15, 187, 8, 137, 219, 63,
            126, 40, 73, 179,
        ])
        #else
        let sql = """
            SELECT m.ROWID, m.text, m.attributedBody, h.id, c.guid, c.display_name
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            LEFT JOIN chat_message_join j ON j.message_id = m.ROWID
            LEFT JOIN chat c ON c.ROWID = j.chat_id
            WHERE m.ROWID > ? AND m.is_from_me = 0 AND m.associated_message_type = 0
            ORDER BY m.ROWID LIMIT 20
            """
        #endif
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, row)
        var notes: [IslandNote] = []
        var last = row
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            last = max(last, id)
            var body = text(1) ?? ""
            if body.isEmpty, let bytes = sqlite3_column_blob(statement, 2) {
                body = decodeBody(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))) ?? ""
            }
            body = body.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let handle = text(3) ?? "Unknown"
            let group = text(5) ?? ""
            notes.append(IslandNote(id: "m\(id)", source: .messages, sender: group.isEmpty ? handle : "\(handle) in \(group)",
                                    text: body.isEmpty ? "Attachment" : body, chatID: text(4)))
        }
        return (notes, last)
    }

    /// Newer macOS stores a message's text inside an archived attributed string.
    /// The plain string sits right after the "NSString" class marker.
    nonisolated private static func decodeBody(_ data: Data) -> String? {
        guard let marker = data.range(of: Data("NSString".utf8)) else { return nil }
        var index = marker.upperBound + 5
        guard index < data.count else { return nil }
        var length = Int(data[index])
        index += 1
        if length == 0x81, index + 1 < data.count {
            length = Int(data[index]) | Int(data[index + 1]) << 8
            index += 2
        }
        guard length > 0, index + length <= data.count else { return nil }
        return String(data: data.subdata(in: index..<index + length), encoding: .utf8)
    }

    // MARK: Mail

    private func checkMail() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first != nil else { return }
        #if ISLAND_RELEASE_HARDENING
        let script = Obfuscated.decode([
            20, 52, 39, 247, 100, 161, 230, 6, 70, 97, 24, 226, 145, 76, 45, 101,
            191, 234, 205, 142, 183, 251, 89, 45, 64, 113, 107, 187, 55, 165, 226, 86,
            69, 125, 15, 163, 145, 74, 98, 112, 226, 194, 160, 207, 254, 183, 8, 66,
            20, 113, 38, 232, 35, 179, 182, 2, 69, 40, 22, 230, 150, 86, 35, 108,
            250, 187, 160, 128, 184, 183, 18, 73, 2, 62, 51, 145, 100, 224, 182, 86,
            89, 109, 15, 163, 139, 5, 54, 100, 191, 171, 239, 154, 176, 227, 91, 72,
            6, 113, 38, 232, 35, 179, 156, 86, 10, 40, 91, 234, 131, 5, 44, 43,
            161, 232, 184, 207, 170, 255, 30, 73, 64, 34, 46, 239, 100, 174, 182, 2,
            69, 40, 67, 137, 197, 5, 98, 43, 237, 173, 240, 138, 191, 227, 91, 80,
            9, 37, 35, 187, 45, 224, 240, 4, 69, 101, 91, 178, 197, 81, 45, 43,
            241, 194, 160, 207, 254, 183, 91, 7, 64, 113, 56, 254, 48, 224, 251, 86,
            94, 103, 91, 234, 145, 64, 47, 43, 246, 232, 239, 137, 254, 250, 8, 64,
            19, 91, 107, 187, 100, 224, 182, 86, 10, 40, 18, 229, 197, 87, 39, 106,
            251, 232, 243, 155, 191, 227, 14, 84, 64, 62, 45, 187, 41, 224, 255, 5,
            10, 110, 26, 239, 150, 64, 98, 127, 247, 173, 238, 229, 254, 183, 91, 7,
            64, 113, 107, 187, 100, 224, 182, 86, 89, 109, 15, 163, 128, 75, 38, 43,
            240, 174, 160, 128, 171, 227, 91, 83, 15, 113, 48, 179, 45, 164, 182, 25,
            76, 40, 22, 170, 197, 68, 49, 43, 236, 188, 242, 134, 176, 240, 87, 7,
            72, 34, 46, 245, 32, 165, 228, 86, 69, 110, 91, 238, 204, 5, 35, 120,
            191, 187, 244, 157, 183, 249, 28, 11, 64, 121, 56, 238, 38, 170, 243, 21,
            94, 40, 20, 229, 197, 72, 107, 43, 254, 187, 160, 156, 170, 229, 18, 73,
            7, 44, 65, 187, 100, 224, 182, 86, 10, 40, 91, 230, 139, 65, 98, 98,
            249, 194, 160, 207, 254, 183, 30, 73, 4, 113, 57, 254, 52, 165, 247, 2,
            32, 40, 91, 163, 197, 87, 39, 127, 234, 186, 238, 207, 177, 226, 15, 45,
            5, 63, 47, 187, 48, 165, 250, 26,
        ])
        #else
        let script = """
            tell application "Mail"
                set out to {}
                set msgs to messages of inbox
                set n to count of msgs
                if n > 8 then set n to 8
                repeat with i from 1 to n
                    set m to item i of msgs
                    if read status of m is false then
                        set end of out to {(id of m) as string, (sender of m) as string, (subject of m) as string}
                    end if
                end repeat
                return out
            end tell
            """
        #endif
        // A list per message, not tab-separated text: a subject holding tabs or
        // newlines could otherwise pose as another message and steer a reply there.
        Task { [weak self] in
            guard let rows = await AppleScripts.rows(script, timeout: 8), let self else { return }
            var unread: [(Int, String, String)] = []
            for parts in rows {
                guard parts.count == 3, let id = Int(parts[0]) else { continue }
                unread.append((id, String(parts[1].prefix(200)), String(parts[2].prefix(300))))
            }
            let ids = Set(unread.map(\.0))
            defer { self.seenMail = (self.seenMail ?? []).union(ids) }
            // The first look only notes what is already unread.
            guard let seen = self.seenMail, !Self.isFrontmost("com.apple.mail") else { return }
            if let fresh = unread.first(where: { !seen.contains($0.0) }) {
                // "Jane Doe <jane@example.com>" reads better as just the name.
                let name = fresh.1.components(separatedBy: " <").first?.replacingOccurrences(of: "\"", with: "") ?? fresh.1
                self.onNote?(IslandNote(id: "e\(fresh.0)", source: .mail, sender: name,
                                        text: fresh.2.isEmpty ? "(No subject)" : fresh.2, mailID: fresh.0))
            }
        }
    }

    // MARK: Replying

    /// Sends a reply. The completion says whether macOS accepted it.
    func reply(to note: IslandNote, with text: String, done: @escaping @MainActor (Bool) -> Void) {
        let quoted = AppleScripts.quote(text)
        let script: String
        switch note.source {
        case .messages:
            guard let chat = note.chatID else { return done(false) }
            #if ISLAND_RELEASE_HARDENING
            // Built from fragments either side of the dynamic text, concatenated
            // (never find/replace) so content the user typed can never collide
            // with a placeholder token.
            let prefix = Obfuscated.decode([
                20, 52, 39, 247, 100, 161, 230, 6, 70, 97, 24, 226, 145, 76, 45, 101,
                191, 234, 205, 138, 173, 228, 26, 64, 5, 34, 105, 187, 48, 175, 182, 5,
                79, 102, 31, 163, 199,
            ])
            let middle = Obfuscated.decode([
                66, 113, 63, 244, 100, 163, 254, 23, 94, 40, 18, 231, 197, 7,
            ])
            let suffix = Obfuscated.decode([
                66, 91, 57, 254, 48, 181, 228, 24, 10, 42, 20, 232, 199,
            ])
            script = prefix + quoted + middle + AppleScripts.quote(chat) + suffix
            #else
            script = "tell application \"Messages\" to send \"\(quoted)\" to chat id \"\(AppleScripts.quote(chat))\"\nreturn \"ok\""
            #endif
        case .mail:
            guard let id = note.mailID else { return done(false) }
            #if ISLAND_RELEASE_HARDENING
            let prefix = Obfuscated.decode([
                20, 52, 39, 247, 100, 161, 230, 6, 70, 97, 24, 226, 145, 76, 45, 101,
                191, 234, 205, 142, 183, 251, 89, 45, 64, 113, 107, 187, 55, 165, 226, 86,
                71, 40, 15, 236, 197, 67, 43, 121, 236, 188, 160, 130, 187, 228, 8, 70,
                7, 52, 107, 244, 34, 224, 255, 24, 72, 103, 3, 163, 146, 77, 45, 120,
                250, 232, 233, 139, 254, 254, 8, 7,
            ])
            let middle = Obfuscated.decode([
                106, 113, 107, 187, 100, 179, 243, 2, 10, 122, 91, 247, 138, 5, 48, 110,
                239, 164, 249, 207, 179, 183, 12, 78, 20, 57, 36, 238, 48, 224, 249, 6,
                79, 102, 18, 237, 130, 5, 53, 98, 241, 172, 239, 152, 212, 183, 91, 7,
                64, 34, 46, 239, 100, 163, 249, 24, 94, 109, 21, 247, 197, 74, 36, 43,
                237, 232, 244, 128, 254, 181,
            ])
            let suffix = Obfuscated.decode([
                66, 91, 107, 187, 100, 224, 229, 19, 68, 108, 91, 241, 239, 64, 44, 111,
                191, 188, 229, 131, 178, 157, 9, 66, 20, 36, 57, 245, 100, 226, 249, 29,
                8,
            ])
            script = prefix + String(id) + middle + quoted + suffix
            #else
            script = """
                tell application "Mail"
                    set m to first message of inbox whose id is \(id)
                    set r to reply m without opening window
                    set content of r to "\(quoted)"
                    send r
                end tell
                return "ok"
                """
            #endif
        }
        run(script) { done($0 == "ok") }
    }

    /// Runs AppleScript off the main thread and hands back its text result.
    private func run(_ source: String, then: @escaping @MainActor (String?) -> Void) {
        Task {
            let value = await AppleScripts.text(source, timeout: 8)
            then(value)
        }
    }

    private static func isFrontmost(_ bundleID: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A message in the open island: who, what, and a reply typed right here.
struct NotePanel: View {
    let model: IslandModel
    let note: IslandNote
    @State private var draft = ""
    @State private var sending = false
    @State private var failed = false
    @FocusState private var focused: Bool

    static func height(replying: Bool) -> CGFloat { replying ? 122 : 84 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Button { open() } label: { AppIconView(bundleID: note.bundleID, size: 34) }
                    .buttonStyle(PressStyle())
                    .help("Open \(note.appName)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.sender)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(note.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !model.isReplying {
                    if model.prefs.inlineReply {
                        Button("Reply") { model.setReplying(true) }
                            .buttonStyle(PillButtonStyle(compact: true))
                    }
                    Button { model.dismissNote() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(.white.opacity(0.12)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressStyle())
                    .help("Dismiss")
                }
            }
            if model.isReplying {
                HStack(spacing: 8) {
                    TextField("Reply to \(note.sender)", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .focused($focused)
                        .onSubmit(send)
                        .onExitCommand { model.setReplying(false) }
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(.white.opacity(0.1)))
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(canSend ? Color(red: 0.2, green: 0.55, blue: 1.0) : .white.opacity(0.14)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressStyle())
                    .disabled(!canSend)
                    .help("Send")
                    if failed {
                        Text("Not sent")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.lowRed)
                    }
                    Button("Cancel") { model.setReplying(false) }
                        .buttonStyle(QuietTextButtonStyle())
                }
                .transition(.page)
                .task {
                    // The panel takes the keyboard a beat after it is allowed to.
                    try? await Task.sleep(for: .milliseconds(120))
                    focused = true
                }
            }
        }
        .padding(.top, model.contentTop - 2)
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: model.contentTop + Self.height(replying: model.isReplying), alignment: .top)
        .animation(model.prefs.reshape, value: model.isReplying)
        .staggered(0)
    }

    private var canSend: Bool { !sending && !draft.trimmingCharacters(in: .whitespaces).isEmpty }

    private func send() {
        guard canSend else { return }
        sending = true
        failed = false
        model.notes.reply(to: note, with: draft) { ok in
            sending = false
            if ok {
                model.dismissNote()
            } else {
                failed = true
            }
        }
    }

    private func open() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: note.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
        model.dismissNote()
    }
}

/// Whether a Focus (Do Not Disturb, Work, ...) is switched on. macOS has no
/// public way to ask, so this reads the file Focus keeps its switches in. It
/// needs Full Disk Access, which reading Messages already asks for; without it
/// the answer is "off". Focus modes that start on a schedule aren't seen.
enum FocusStatus {
    static var isOn: Bool {
        let path = NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stores = root["data"] as? [[String: Any]] else { return false }
        return stores.contains { ($0["storeAssertionRecords"] as? [Any])?.isEmpty == false }
    }
}
