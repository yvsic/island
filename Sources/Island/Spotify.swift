import AppKit
import CryptoKit
import Network
import Security

/// Spotify's web service, for the two things its Mac app won't do through
/// scripting: say what is queued, and like a song.
///
/// Spotify only lets a registered app in, so the user creates their own (free)
/// app at developer.spotify.com and gives Island its Client ID. Sign-in is the
/// standard browser flow with PKCE: no client secret exists anywhere, the
/// answer comes back to a listener on this Mac only (127.0.0.1), and the one
/// long-lived token is kept in the Keychain.
@Observable
final class SpotifyAPI {
    enum State: Equatable { case disconnected, connecting, connected, failed(String) }

    private(set) var state: State = .disconnected
    var isConnected: Bool { state == .connected }

    static let port: UInt16 = 43821
    static let redirectURI = "http://127.0.0.1:\(port)/callback"
    private static let scopes = "user-read-currently-playing user-read-playback-state user-modify-playback-state user-library-read user-library-modify"

    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var expires = Date.distantPast
    @ObservationIgnored private var refreshToken: String?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var verifier = ""
    @ObservationIgnored private var expectedState = ""
    @ObservationIgnored private var giveUp: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<String?, Never>?
    /// No cookies, no cache: tokens never touch the disk outside the Keychain.
    @ObservationIgnored private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private var clientID: String { Preferences.shared.spotifyClientID }

    init() {
        refreshToken = Keychain.read()
        if refreshToken != nil, Self.isClientID(clientID) { state = .connected }
    }

    /// Spotify Client IDs are 32 hexadecimal characters; nothing else is sent anywhere.
    static func isClientID(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { $0.isHexDigit }
    }

    // MARK: Signing in

    /// Opens Spotify's sign-in page in the browser and waits for the answer.
    func connect(clientID id: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isClientID(id) else {
            state = .failed("That doesn't look like a Client ID (32 letters and digits)")
            return
        }
        Preferences.shared.spotifyClientID = id
        verifier = Self.random(64)
        expectedState = Self.random(24)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL

        guard listen() else {
            state = .failed("Port \(Self.port) is in use, so Spotify's answer can't be received")
            return
        }
        var parts = URLComponents(string: "https://accounts.spotify.com/authorize")!
        parts.queryItems = [
            .init(name: "client_id", value: id),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: Self.scopes),
            .init(name: "state", value: expectedState),
        ]
        guard let url = parts.url else { return }
        state = .connecting
        NSWorkspace.shared.open(url)
        // An abandoned sign-in doesn't leave the listener open.
        giveUp?.cancel()
        giveUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, let self, self.state == .connecting else { return }
            self.stopListening()
            self.state = .failed("Sign-in timed out")
        }
    }

    func disconnect() {
        stopListening()
        giveUp?.cancel()
        Keychain.delete()
        refreshToken = nil
        accessToken = nil
        expires = .distantPast
        state = .disconnected
    }

    /// Listens on this Mac's loopback address only, for one request.
    private func listen() -> Bool {
        stopListening()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        // No port sharing: no other program can listen alongside and catch the answer.
        parameters.allowLocalEndpointReuse = false
        guard let listener = try? NWListener(using: parameters) else { return false }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let query = Self.callbackQuery(in: request)
                // The page says the same thing whatever was sent: nothing from the request is echoed back.
                let body = "<html><body style=\"font:16px -apple-system;background:#111;color:#eee;text-align:center;padding-top:20vh\">"
                    + (query == nil ? "Not found." : "You can close this tab and go back to Island.") + "</body></html>"
                let response = "HTTP/1.1 \(query == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                guard let query else { return }
                Task { @MainActor in self?.received(query) }
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        return true
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
    }

    /// The query of "GET /callback?… HTTP/1.1", or nil for any other request.
    nonisolated static func callbackQuery(in request: String) -> [String: String]? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let words = line.split(separator: " ")
        guard words.count >= 2, words[0] == "GET", words[1].hasPrefix("/callback?"),
              let parts = URLComponents(string: "http://127.0.0.1" + words[1]) else { return nil }
        var query: [String: String] = [:]
        for item in parts.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return query
    }

    private func received(_ query: [String: String]) {
        // Only the answer to the sign-in this app started is accepted.
        guard state == .connecting, !expectedState.isEmpty, query["state"] == expectedState else { return }
        stopListening()
        giveUp?.cancel()
        expectedState = ""
        guard let code = query["code"], !code.isEmpty else {
            state = .failed(query["error"] == "access_denied" ? "Sign-in was cancelled" : "Spotify didn't sign in")
            return
        }
        Task {
            let ok = await token(["grant_type": "authorization_code", "code": code,
                                  "redirect_uri": Self.redirectURI, "client_id": clientID, "code_verifier": verifier])
            verifier = ""
            state = ok ? .connected : .failed("Spotify refused the sign-in")
        }
    }

    // MARK: Tokens

    private func token(_ form: [String: String]) async -> Bool {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else { return false }
        accessToken = access
        expires = .now + ((json["expires_in"] as? Double) ?? 3600) - 60
        if let refresh = json["refresh_token"] as? String, !refresh.isEmpty {
            refreshToken = refresh
            Keychain.save(refresh)
        }
        return true
    }

    /// A token that is good right now, refreshed if it has run out.
    private func validToken() async -> String? {
        if let accessToken, Date.now < expires { return accessToken }
        if let refreshing { return await refreshing.value }
        guard let refreshToken, Self.isClientID(clientID) else { return nil }
        let task = Task { () -> String? in
            let ok = await token(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID])
            return ok ? accessToken : nil
        }
        refreshing = task
        let value = await task.value
        refreshing = nil
        return value
    }

    // MARK: Requests

    private func send(_ method: String, _ path: String, _ query: [URLQueryItem] = []) async -> (status: Int, data: Data)? {
        guard isConnected, let token = await validToken() else { return nil }
        var parts = URLComponents(string: "https://api.spotify.com/v1" + path)!
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 401 {
            // The token was revoked or has gone stale: ask for a new one next time.
            accessToken = nil
            expires = .distantPast
        }
        return (http.statusCode, data)
    }

    /// What Spotify will play next, in order (up to twenty).
    func queue() async -> [QueueItem]? {
        guard let reply = await send("GET", "/me/player/queue"), reply.status == 200 else { return nil }
        return Self.parseQueue(reply.data)
    }

    nonisolated static func parseQueue(_ data: Data) -> [QueueItem]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["queue"] as? [[String: Any]] else { return nil }
        var seen: [String: Int] = [:]
        return list.prefix(20).enumerated().compactMap { index, entry in
            guard let uri = entry["uri"] as? String, let name = entry["name"] as? String else { return nil }
            let artists = (entry["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ")
                ?? ((entry["show"] as? [String: Any])?["name"] as? String) ?? ""
            let images = ((entry["album"] as? [String: Any])?["images"] as? [[String: Any]]) ?? []
            // The smallest cover is plenty for a row.
            let art = images.min { (($0["height"] as? Int) ?? 0) < (($1["height"] as? Int) ?? 0) }?["url"] as? String
            seen[uri, default: 0] += 1
            return QueueItem(id: "\(uri)#\(seen[uri] ?? 1)", trackID: uri, title: String(name.prefix(200)),
                             artist: String(artists.prefix(200)), artworkURL: art, position: index)
        }
    }

    /// Adds a song to the end of Spotify's "Next in queue".
    func addToQueue(_ uri: String) async -> Bool {
        guard let reply = await send("POST", "/me/player/queue", [.init(name: "uri", value: uri)]) else { return false }
        return (200..<300).contains(reply.status)
    }

    func setLiked(_ liked: Bool, uri: String, completion: @escaping @MainActor (Bool) -> Void) {
        Task {
            let reply = await send(liked ? "PUT" : "DELETE", "/me/library", [.init(name: "uris", value: uri)])
            completion(reply.map { (200..<300).contains($0.status) } ?? false)
        }
    }

    /// Asks whether a Spotify song is in the library. Nil means "can't say".
    func checkLiked(_ track: Track?, completion: @escaping @MainActor (Bool?) -> Void) {
        guard isConnected, let uri = track?.spotifyURI else { return }
        Task {
            guard let reply = await send("GET", "/me/library/contains", [.init(name: "uris", value: uri)]),
                  reply.status == 200,
                  let list = try? JSONSerialization.jsonObject(with: reply.data) as? [Bool] else { return completion(nil) }
            completion(list.first)
        }
    }

    // MARK: Helpers

    /// Random text for the sign-in's one-time secrets, from the system's secure generator.
    private static func random(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// The Spotify refresh token, in the login keychain.
private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.local.island.spotify",
        kSecAttrAccount as String: "refresh-token",
    ]

    static func read() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        delete()
        var query = query
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
