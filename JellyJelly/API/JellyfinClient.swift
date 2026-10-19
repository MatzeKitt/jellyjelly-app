import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case http(Int, String?)
    case decoding(Error)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "The server address is not valid.")
        case .http(401, _):
            return String(localized: "The server rejected the credentials.")
        case let .http(code, message):
            if let message, !message.isEmpty {
                return String(localized: "Server error \(code): \(message)")
            }
            return String(localized: "Server error \(code).")
        case let .decoding(error):
            return String(localized: "Unexpected server response: \(error.localizedDescription)")
        case .notAuthenticated:
            return String(localized: "You are not signed in.")
        }
    }
}

struct ClientIdentity: Sendable {
    static let clientName = "JellyJelly"

    var deviceId: String
    var deviceName: String
    var version: String

    static let current: ClientIdentity = {
        let defaults = UserDefaults.standard
        let deviceId: String
        if let stored = defaults.string(forKey: "deviceId") {
            deviceId = stored
        } else {
            deviceId = UUID().uuidString.lowercased()
            defaults.set(deviceId, forKey: "deviceId")
        }
        let name = Host.current().localizedName ?? "Mac"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return ClientIdentity(deviceId: deviceId, deviceName: name, version: version)
    }()
}

/// Thin async wrapper around the Jellyfin REST API.
final class JellyfinClient: @unchecked Sendable {
    let serverURL: URL
    let identity: ClientIdentity
    private(set) var token: String?
    private(set) var userId: String?
    private let session: URLSession

    static let standardFields = [
        "Overview", "PrimaryImageAspectRatio", "DateCreated", "Genres", "ChildCount",
        "RecursiveItemCount", "Taglines", "Path",
    ]

    init(serverURL: URL, token: String? = nil, userId: String? = nil, identity: ClientIdentity = .current) {
        self.serverURL = serverURL
        self.token = token
        self.userId = userId
        self.identity = identity
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    /// Normalizes user input like `jellyfin.local:8096` into a base URL.
    static func normalizedServerURL(_ input: String) -> URL? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.lowercased().hasSuffix("/web") {
            value.removeLast(4)
        }
        guard let url = URL(string: value), url.host != nil else { return nil }
        return url
    }

    var authorizationHeader: String {
        var parts = [
            "Client=\"\(ClientIdentity.clientName)\"",
            "Device=\"\(identity.deviceName.replacingOccurrences(of: "\"", with: ""))\"",
            "DeviceId=\"\(identity.deviceId)\"",
            "Version=\"\(identity.version)\"",
        ]
        if let token {
            parts.append("Token=\"\(token)\"")
        }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    func setSession(token: String, userId: String) {
        self.token = token
        self.userId = userId
    }

    // MARK: - Request plumbing

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        let items = query.filter { $0.value != nil }
        components.queryItems = items.isEmpty ? nil : items
        // `+` is legal in a query but ASP.NET decodes it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(0, nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8))
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type = T.self) async throws -> T {
        let data = try await request("GET", path, query: query)
        return try decode(data)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil, as type: T.Type = T.self) async throws -> T {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let data = try await request(method, path, query: query, body: body)
        return try decode(data)
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws {
        _ = try await request(method, path, query: query, body: body)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JellyfinJSON.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    private var userQuery: URLQueryItem { URLQueryItem(name: "userId", value: userId) }

    // MARK: - Server & authentication

    func publicSystemInfo() async throws -> PublicSystemInfo {
        try await get("/System/Info/Public")
    }

    func publicUsers() async throws -> [UserDto] {
        try await get("/Users/Public")
    }

    func authenticate(username: String, password: String) async throws -> AuthenticationResult {
        try await send("POST", "/Users/AuthenticateByName", json: ["Username": username, "Pw": password])
    }

    func quickConnectEnabled() async -> Bool {
        (try? await get("/QuickConnect/Enabled", as: Bool.self)) ?? false
    }

    func quickConnectInitiate() async throws -> QuickConnectResult {
        try await send("POST", "/QuickConnect/Initiate", as: QuickConnectResult.self)
    }

    func quickConnectState(secret: String) async throws -> QuickConnectResult {
        try await get("/QuickConnect/Connect", query: [URLQueryItem(name: "secret", value: secret)])
    }

    func authenticateWithQuickConnect(secret: String) async throws -> AuthenticationResult {
        try await send("POST", "/Users/AuthenticateWithQuickConnect", json: ["Secret": secret])
    }

    func currentUser() async throws -> UserDto {
        try await get("/Users/Me")
    }

    func logout() async {
        try? await send("POST", "/Sessions/Logout")
    }

    func reportCapabilities() async {
        let capabilities: [String: Any] = [
            "PlayableMediaTypes": ["Video"],
            "SupportedCommands": [],
            "SupportsMediaControl": false,
            "SupportsPersistentIdentifier": true,
        ]
        let body = try? JSONSerialization.data(withJSONObject: capabilities)
        try? await send("POST", "/Sessions/Capabilities/Full", body: body)
    }

    // MARK: - Browsing

    func userViews() async throws -> [BaseItem] {
        let response: ItemsResponse = try await get("/UserViews", query: [userQuery])
        return response.items
    }

    func items(_ query: ItemQuery) async throws -> ItemsResponse {
        try await get("/Items", query: [userQuery] + query.queryItems)
    }

    /// The single-item endpoint always returns full details, including media sources and chapters.
    func item(_ id: String) async throws -> BaseItem {
        try await get("/Items/\(id)", query: [userQuery])
    }

    func resumeItems(limit: Int = 24, parentId: String? = nil) async throws -> [BaseItem] {
        let response: ItemsResponse = try await get("/UserItems/Resume", query: [
            userQuery,
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "parentId", value: parentId),
            URLQueryItem(name: "mediaTypes", value: "Video"),
            URLQueryItem(name: "fields", value: Self.standardFields.joined(separator: ",")),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "enableTotalRecordCount", value: "false"),
        ])
        return response.items
    }

    func nextUp(limit: Int = 24, seriesId: String? = nil) async throws -> [BaseItem] {
        let response: ItemsResponse = try await get("/Shows/NextUp", query: [
            userQuery,
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "seriesId", value: seriesId),
            URLQueryItem(name: "fields", value: Self.standardFields.joined(separator: ",")),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "enableResumable", value: "false"),
            URLQueryItem(name: "enableTotalRecordCount", value: "false"),
        ])
        return response.items
    }

    func latest(parentId: String, limit: Int = 20) async throws -> [BaseItem] {
        try await get("/Items/Latest", query: [
            userQuery,
            URLQueryItem(name: "parentId", value: parentId),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: Self.standardFields.joined(separator: ",")),
            URLQueryItem(name: "enableUserData", value: "true"),
        ])
    }

    func seasons(seriesId: String) async throws -> [BaseItem] {
        let response: ItemsResponse = try await get("/Shows/\(seriesId)/Seasons", query: [
            userQuery,
            URLQueryItem(name: "fields", value: "Overview,ChildCount,RecursiveItemCount"),
            URLQueryItem(name: "enableUserData", value: "true"),
        ])
        return response.items
    }

    func episodes(seriesId: String, seasonId: String? = nil) async throws -> [BaseItem] {
        let response: ItemsResponse = try await get("/Shows/\(seriesId)/Episodes", query: [
            userQuery,
            URLQueryItem(name: "seasonId", value: seasonId),
            URLQueryItem(name: "fields", value: (Self.standardFields + ["MediaStreams"]).joined(separator: ",")),
            URLQueryItem(name: "enableUserData", value: "true"),
        ])
        return response.items
    }

    func genres(parentId: String) async throws -> [BaseItem] {
        let response: ItemsResponse = try await get("/Genres", query: [
            userQuery,
            URLQueryItem(name: "parentId", value: parentId),
            URLQueryItem(name: "sortBy", value: "SortName"),
        ])
        return response.items
    }

    // MARK: - User data

    func setPlayed(_ itemId: String, played: Bool) async throws -> UserItemData {
        try await send(played ? "POST" : "DELETE", "/UserPlayedItems/\(itemId)", query: [userQuery], as: UserItemData.self)
    }

    func setFavorite(_ itemId: String, favorite: Bool) async throws -> UserItemData {
        try await send(favorite ? "POST" : "DELETE", "/UserFavoriteItems/\(itemId)", query: [userQuery], as: UserItemData.self)
    }

    func updateUserData(_ itemId: String, _ update: UserDataUpdate) async throws {
        let body = try JellyfinJSON.encoder.encode(update)
        try await send("POST", "/UserItems/\(itemId)/UserData", query: [userQuery], body: body)
    }

    // MARK: - Playback

    func playbackInfo(itemId: String, mediaSourceId: String? = nil) async throws -> PlaybackInfoResponse {
        var body: [String: Any] = [
            "UserId": userId ?? "",
            "EnableDirectPlay": true,
            "EnableDirectStream": false,
            "EnableTranscoding": false,
            "MaxStreamingBitrate": 2_000_000_000,
            "DeviceProfile": Self.directPlayProfile,
        ]
        if let mediaSourceId {
            body["MediaSourceId"] = mediaSourceId
        }
        return try await send("POST", "/Items/\(itemId)/PlaybackInfo", query: [
            userQuery,
            URLQueryItem(name: "mediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "enableDirectPlay", value: "true"),
            URLQueryItem(name: "enableDirectStream", value: "false"),
            URLQueryItem(name: "enableTranscoding", value: "false"),
            URLQueryItem(name: "autoOpenLiveStream", value: "true"),
        ], json: body)
    }

    /// A device profile that claims support for every container and codec, so the
    /// server always offers the untouched file. Decoding happens locally.
    static let directPlayProfile: [String: Any] = [
        "Name": "JellyJelly Direct Play",
        "MaxStreamingBitrate": 2_000_000_000,
        "MaxStaticBitrate": 2_000_000_000,
        "DirectPlayProfiles": [["Type": "Video"], ["Type": "Audio"]],
        "TranscodingProfiles": [],
        "ContainerProfiles": [],
        "CodecProfiles": [],
        "SubtitleProfiles": [
            ["Format": "srt", "Method": "External"],
            ["Format": "subrip", "Method": "External"],
            ["Format": "ass", "Method": "External"],
            ["Format": "ssa", "Method": "External"],
            ["Format": "vtt", "Method": "External"],
            ["Format": "webvtt", "Method": "External"],
            ["Format": "srt", "Method": "Embed"],
            ["Format": "subrip", "Method": "Embed"],
            ["Format": "ass", "Method": "Embed"],
            ["Format": "ssa", "Method": "Embed"],
            ["Format": "vtt", "Method": "Embed"],
            ["Format": "webvtt", "Method": "Embed"],
            ["Format": "mov_text", "Method": "Embed"],
            ["Format": "pgs", "Method": "Embed"],
            ["Format": "pgssub", "Method": "Embed"],
            ["Format": "dvdsub", "Method": "Embed"],
            ["Format": "dvbsub", "Method": "Embed"],
        ],
    ]

    func mediaSegments(itemId: String) async throws -> [MediaSegment] {
        let response: SegmentsResponse = try await get("/MediaSegments/\(itemId)")
        return response.items
    }

    func reportPlaybackStart(_ report: PlaybackReport) async {
        try? await send("POST", "/Sessions/Playing", body: try? JellyfinJSON.encoder.encode(report))
    }

    func reportPlaybackProgress(_ report: PlaybackReport) async {
        try? await send("POST", "/Sessions/Playing/Progress", body: try? JellyfinJSON.encoder.encode(report))
    }

    /// Returns whether the server received the report.
    @discardableResult
    func reportPlaybackStopped(_ report: PlaybackReport) async -> Bool {
        (try? await send("POST", "/Sessions/Playing/Stopped", body: try? JellyfinJSON.encoder.encode(report))) != nil
    }

    /// Sends the stop report synchronously; only for app termination.
    func reportPlaybackStoppedBlocking(_ report: PlaybackReport, timeout: TimeInterval) {
        var request = URLRequest(url: url("/Sessions/Playing/Stopped"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try? JellyfinJSON.encoder.encode(report)
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let done = DispatchSemaphore(value: 0)
        // The completion runs on the session's delegate queue, never the waiting main thread.
        session.dataTask(with: request) { _, _, _ in
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout)
    }

    /// The session the server keeps for this device, used to verify the play method.
    func ownSession() async throws -> SessionInfo? {
        let sessions: [SessionInfo] = try await get("/Sessions", query: [URLQueryItem(name: "deviceId", value: identity.deviceId)])
        return sessions.first { $0.nowPlayingItem != nil } ?? sessions.first
    }

    // MARK: - URLs

    /// The original file, served byte-for-byte. `static=true` disables any server-side processing.
    func directStreamURL(itemId: String, mediaSource: MediaSource, playSessionId: String?) -> URL {
        url("/Videos/\(itemId)/stream", query: [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: mediaSource.id),
            URLQueryItem(name: "playSessionId", value: playSessionId),
            URLQueryItem(name: "deviceId", value: identity.deviceId),
            URLQueryItem(name: "ApiKey", value: token),
        ])
    }

    /// The original file as an attachment. Requires the user's "Allow media downloading" permission.
    func downloadURL(itemId: String) -> URL {
        url("/Items/\(itemId)/Download", query: [
            URLQueryItem(name: "ApiKey", value: token),
        ])
    }

    func subtitleURL(itemId: String, mediaSourceId: String, streamIndex: Int, format: String) -> URL {
        url("/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(streamIndex)/0/Stream.\(format)", query: [
            URLQueryItem(name: "ApiKey", value: token),
        ])
    }

    func imageURL(itemId: String, type: String, tag: String?, maxWidth: Int? = nil, index: Int? = nil) -> URL {
        var path = "/Items/\(itemId)/Images/\(type)"
        if let index {
            path += "/\(index)"
        }
        return url(path, query: [
            URLQueryItem(name: "maxWidth", value: maxWidth.map(String.init)),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "tag", value: tag),
        ])
    }

    func userImageURL(userId: String, tag: String?) -> URL {
        url("/UserImage", query: [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "tag", value: tag),
        ])
    }

    func trickplayTileURL(itemId: String, mediaSourceId: String, width: Int, index: Int) -> URL {
        url("/Videos/\(itemId)/Trickplay/\(width)/\(index).jpg", query: [
            URLQueryItem(name: "mediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "ApiKey", value: token),
        ])
    }
}

/// Parameters for `GET /Items`.
struct ItemQuery: Sendable {
    var parentId: String?
    var includeItemTypes: [String] = []
    var excludeItemTypes: [String] = []
    var ids: [String] = []
    var recursive = true
    var sortBy: [String] = ["SortName"]
    var sortOrder: [String] = ["Ascending"]
    var filters: [String] = []
    var isPlayed: Bool?
    var isFavorite: Bool?
    var genres: [String] = []
    var searchTerm: String?
    var nameStartsWith: String?
    var startIndex = 0
    var limit: Int?
    var fields: [String] = JellyfinClient.standardFields
    var enableTotalRecordCount = true

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "parentId", value: parentId),
            URLQueryItem(name: "recursive", value: recursive ? "true" : "false"),
            URLQueryItem(name: "sortBy", value: sortBy.joined(separator: ",")),
            URLQueryItem(name: "sortOrder", value: sortOrder.joined(separator: ",")),
            URLQueryItem(name: "startIndex", value: String(startIndex)),
            URLQueryItem(name: "limit", value: limit.map(String.init)),
            URLQueryItem(name: "fields", value: fields.joined(separator: ",")),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "enableTotalRecordCount", value: enableTotalRecordCount ? "true" : "false"),
            URLQueryItem(name: "isPlayed", value: isPlayed.map { $0 ? "true" : "false" }),
            URLQueryItem(name: "isFavorite", value: isFavorite.map { $0 ? "true" : "false" }),
            URLQueryItem(name: "searchTerm", value: searchTerm),
            URLQueryItem(name: "nameStartsWith", value: nameStartsWith),
        ]
        if !includeItemTypes.isEmpty {
            items.append(URLQueryItem(name: "includeItemTypes", value: includeItemTypes.joined(separator: ",")))
        }
        if !excludeItemTypes.isEmpty {
            items.append(URLQueryItem(name: "excludeItemTypes", value: excludeItemTypes.joined(separator: ",")))
        }
        if !ids.isEmpty {
            items.append(URLQueryItem(name: "ids", value: ids.joined(separator: ",")))
        }
        if !filters.isEmpty {
            items.append(URLQueryItem(name: "filters", value: filters.joined(separator: ",")))
        }
        if !genres.isEmpty {
            items.append(URLQueryItem(name: "genres", value: genres.joined(separator: "|")))
        }
        return items
    }
}
