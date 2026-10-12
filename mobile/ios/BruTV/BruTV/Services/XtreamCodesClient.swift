import Foundation

public enum XtreamError: LocalizedError, Sendable {
    case invalidURL
    case authenticationFailed(String)
    case serverError(Int)
    case decodingError(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The server URL provided is invalid. Please check the address."
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        case .serverError(let code):
            return "Server returned an error status code: \(code)."
        case .decodingError(let details):
            return "Failed to parse data from server: \(details)"
        case .networkError(let details):
            return "Network connection error: \(details)"
        }
    }
}

public final class XtreamCodesClient: @unchecked Sendable {
    private let lock = NSLock()
    private var _serverURLString: String
    private var _username: String
    private var _password: String

    public var serverURLString: String {
        lock.lock()
        defer { lock.unlock() }
        return _serverURLString
    }

    public var username: String {
        lock.lock()
        defer { lock.unlock() }
        return _username
    }

    public var password: String {
        lock.lock()
        defer { lock.unlock() }
        return _password
    }

    private let session: URLSession
    private var cachedLiveCategories: [LiveCategory]?
    private var cachedLiveStreams: [String: [LiveStream]] = [:] // category_id -> streams
    private var cachedAllLiveStreams: [LiveStream]?
    private var cachedVODCategories: [VODCategory]?
    private var cachedSeriesCategories: [SeriesCategory]?

    // M3U playlist mode. When set, live channels come from the playlist and VOD/series are empty.
    private var _playlistURLString: String?
    private var cachedPlaylistChannels: [LiveStream]?

    public var playlistURLString: String? {
        lock.lock()
        defer { lock.unlock() }
        return _playlistURLString
    }

    public var isPlaylistMode: Bool { playlistURLString != nil }

    public init(
        serverURLString: String = "",
        username: String = "",
        password: String = "",
        session: URLSession = .shared
    ) {
        self._serverURLString = serverURLString
        self._username = username
        self._password = password
        self.session = session
    }

    public func updateCredentials(serverURL: String, user: String, pass: String) {
        var cleanURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanURL.lowercased().hasPrefix("http://") && !cleanURL.lowercased().hasPrefix("https://") {
            cleanURL = "http://" + cleanURL
        }
        if cleanURL.hasSuffix("/") {
            cleanURL = String(cleanURL.dropLast())
        }
        lock.lock()
        defer { lock.unlock() }
        self._serverURLString = cleanURL
        self._username = user.trimmingCharacters(in: .whitespacesAndNewlines)
        self._password = pass.trimmingCharacters(in: .whitespacesAndNewlines)
        self._playlistURLString = nil
        resetCachesLocked()
    }

    /// Switches to M3U playlist mode. Call `loadPlaylist()` to download and validate it.
    public func updatePlaylist(url: String) {
        lock.lock()
        defer { lock.unlock() }
        self._playlistURLString = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self._serverURLString = ""
        self._username = ""
        self._password = ""
        resetCachesLocked()
    }

    private func resetCachesLocked() {
        self.cachedLiveCategories = nil
        self.cachedLiveStreams.removeAll()
        self.cachedAllLiveStreams = nil
        self.cachedVODCategories = nil
        self.cachedSeriesCategories = nil
        self.cachedPlaylistChannels = nil
    }

    // MARK: - M3U playlist

    /// Downloads and parses the playlist. Throws if it has no playable channels.
    @discardableResult
    public func loadPlaylist() async throws -> [LiveStream] {
        lock.lock()
        let cached = cachedPlaylistChannels
        let urlString = _playlistURLString
        lock.unlock()

        if let cached { return cached }
        guard let urlString, let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            throw XtreamError.invalidURL
        }

        let request = createRequest(url: url, timeout: 60.0)
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw XtreamError.serverError(httpResponse.statusCode)
        }

        let entries = M3UPlaylistParser.parse(data)
        let live = entries.filter { !$0.isVOD }
        // Some playlists contain only VOD items. Show them rather than nothing.
        let source = live.isEmpty ? entries : live
        guard !source.isEmpty else {
            throw XtreamError.decodingError("The playlist has no channels. Check that the link points to an M3U file.")
        }

        var seen = Set<Int>()
        var channels: [LiveStream] = []
        channels.reserveCapacity(source.count)
        for (index, entry) in source.enumerated() {
            let id = M3UPlaylistParser.stableID(for: entry.url)
            guard seen.insert(id).inserted else { continue }
            channels.append(
                LiveStream(
                    id: id,
                    num: index + 1,
                    name: entry.name,
                    iconURLString: entry.logo,
                    epgChannelId: entry.tvgID,
                    categoryId: entry.group,
                    directURLString: entry.url
                )
            )
        }

        lock.lock()
        cachedPlaylistChannels = channels
        lock.unlock()
        return channels
    }

    // MARK: - URL Generation

    private func baseURL() throws -> URL {
        guard let url = URL(string: serverURLString) else {
            throw XtreamError.invalidURL
        }
        return url
    }

    private func apiEndpointURL(action: String? = nil, queryParams: [String: String] = [:]) throws -> URL {
        let base = try baseURL()
        guard var components = URLComponents(url: base.appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false) else {
            throw XtreamError.invalidURL
        }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password)
        ]

        if let action {
            items.append(URLQueryItem(name: "action", value: action))
        }

        for (k, v) in queryParams {
            items.append(URLQueryItem(name: k, value: v))
        }

        components.queryItems = items
        guard let fullURL = components.url else {
            throw XtreamError.invalidURL
        }
        return fullURL
    }

    public func liveStreamURL(streamID: Int, format: StreamFormatPreference = .hls) -> URL? {
        guard !serverURLString.isEmpty, !username.isEmpty, !password.isEmpty else { return nil }
        let ext = format == .hls ? "m3u8" : "ts"
        let path = "\(serverURLString)/live/\(username)/\(password)/\(streamID).\(ext)"
        return URL(string: path)
    }

    public func vodStreamURL(streamID: Int, containerExtension: String = "mp4") -> URL? {
        guard !serverURLString.isEmpty, !username.isEmpty, !password.isEmpty else { return nil }
        let ext = containerExtension.isEmpty ? "mp4" : containerExtension
        let path = "\(serverURLString)/movie/\(username)/\(password)/\(streamID).\(ext)"
        return URL(string: path)
    }

    public func seriesStreamURL(streamID: Int, containerExtension: String = "mp4") -> URL? {
        guard !serverURLString.isEmpty, !username.isEmpty, !password.isEmpty else { return nil }
        let ext = containerExtension.isEmpty ? "mp4" : containerExtension
        let path = "\(serverURLString)/series/\(username)/\(password)/\(streamID).\(ext)"
        return URL(string: path)
    }

    // MARK: - API Calls

    private func createRequest(url: URL, timeout: TimeInterval = 15.0) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("IPTVSmartersPro/1.1.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    public func authenticate() async throws -> AuthResponse {
        let url = try apiEndpointURL()
        let request = createRequest(url: url, timeout: 15.0)

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw XtreamError.serverError(httpResponse.statusCode)
        }

        do {
            let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
            if authResponse.userInfo.auth == 0 || authResponse.userInfo.status.lowercased() == "disabled" {
                throw XtreamError.authenticationFailed(authResponse.userInfo.message ?? "Invalid username or password.")
            }
            return authResponse
        } catch let err as XtreamError {
            throw err
        } catch {
            throw XtreamError.decodingError(error.localizedDescription)
        }
    }

    public func fetchLiveCategories() async throws -> [LiveCategory] {
        if isPlaylistMode {
            // Categories are the playlist's group-title values, in playlist order.
            let channels = try await loadPlaylist()
            var seen = Set<String>()
            return channels.compactMap { channel in
                seen.insert(channel.categoryId).inserted ? LiveCategory(id: channel.categoryId, name: channel.categoryId) : nil
            }
        }

        if let cached = cachedLiveCategories, !cached.isEmpty {
            return cached
        }

        let url = try apiEndpointURL(action: "get_live_categories")
        let request = createRequest(url: url, timeout: 15.0)

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw XtreamError.serverError(httpResponse.statusCode)
        }

        do {
            let categories = try JSONDecoder().decode([LiveCategory].self, from: data)
            self.cachedLiveCategories = categories
            return categories
        } catch {
            throw XtreamError.decodingError(error.localizedDescription)
        }
    }

    public func fetchLiveStreams(categoryID: String? = nil) async throws -> [LiveStream] {
        if isPlaylistMode {
            let channels = try await loadPlaylist()
            guard let categoryID, !categoryID.isEmpty, categoryID != "ALL" else { return channels }
            return channels.filter { $0.categoryId == categoryID }
        }

        if let categoryID, let cached = cachedLiveStreams[categoryID] {
            return cached
        }
        if categoryID == nil, let cached = cachedAllLiveStreams {
            return cached
        }

        var params: [String: String] = [:]
        if let categoryID, !categoryID.isEmpty, categoryID != "ALL" {
            params["category_id"] = categoryID
        }

        let url = try apiEndpointURL(action: "get_live_streams", queryParams: params)
        let request = createRequest(url: url, timeout: 25.0)

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw XtreamError.serverError(httpResponse.statusCode)
        }

        do {
            let streams = try JSONDecoder().decode([LiveStream].self, from: data)
            if let categoryID, !categoryID.isEmpty, categoryID != "ALL" {
                self.cachedLiveStreams[categoryID] = streams
            } else {
                self.cachedAllLiveStreams = streams
            }
            return streams
        } catch {
            throw XtreamError.decodingError(error.localizedDescription)
        }
    }

    public func fetchVODCategories() async throws -> [VODCategory] {
        if isPlaylistMode { return [] }
        if let cached = cachedVODCategories {
            return cached
        }
        let url = try apiEndpointURL(action: "get_vod_categories")
        let request = createRequest(url: url, timeout: 15.0)
        let (data, _) = try await session.data(for: request)
        let categories = try JSONDecoder().decode([VODCategory].self, from: data)
        self.cachedVODCategories = categories
        return categories
    }

    public func fetchVODStreams(categoryID: String? = nil) async throws -> [VODStream] {
        if isPlaylistMode { return [] }
        var params: [String: String] = [:]
        if let categoryID, !categoryID.isEmpty {
            params["category_id"] = categoryID
        }
        let url = try apiEndpointURL(action: "get_vod_streams", queryParams: params)
        let request = createRequest(url: url, timeout: 20.0)
        let (data, _) = try await session.data(for: request)
        let streams = try JSONDecoder().decode([VODStream].self, from: data)
        return streams
    }

    public func fetchSeriesCategories() async throws -> [SeriesCategory] {
        if isPlaylistMode { return [] }
        if let cached = cachedSeriesCategories {
            return cached
        }
        let url = try apiEndpointURL(action: "get_series_categories")
        let request = createRequest(url: url, timeout: 15.0)
        let (data, _) = try await session.data(for: request)
        let categories = try JSONDecoder().decode([SeriesCategory].self, from: data)
        self.cachedSeriesCategories = categories
        return categories
    }

    public func fetchSeries(categoryID: String? = nil) async throws -> [SeriesItem] {
        if isPlaylistMode { return [] }
        var params: [String: String] = [:]
        if let categoryID, !categoryID.isEmpty {
            params["category_id"] = categoryID
        }
        let url = try apiEndpointURL(action: "get_series", queryParams: params)
        let request = createRequest(url: url, timeout: 20.0)
        let (data, _) = try await session.data(for: request)
        let series = try JSONDecoder().decode([SeriesItem].self, from: data)
        return series
    }

    public func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        resetCachesLocked()
    }
}
