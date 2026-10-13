import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
    private struct SourceSnapshot {
        let revision: UInt64
        let serverURLString: String
        let username: String
        let password: String
        let playlistURLString: String?
    }

    private struct AdoptedState {
        let serverURLString: String
        let username: String
        let password: String
        let playlistURLString: String?
        let cachedLiveCategories: [LiveCategory]?
        let cachedLiveStreams: [String: [LiveStream]]
        let cachedAllLiveStreams: [LiveStream]?
        let cachedVODCategories: [VODCategory]?
        let cachedVODStreams: [String: [VODStream]]
        let cachedAllVODStreams: [VODStream]?
        let cachedSeriesCategories: [SeriesCategory]?
        let cachedSeries: [String: [SeriesItem]]
        let cachedAllSeries: [SeriesItem]?
        let cachedVODDetails: [Int: VODDetails]
        let cachedSeriesDetails: [Int: SeriesDetails]
        let cachedPlaylistChannels: [LiveStream]?
    }

    private let lock = NSLock()
    private var sourceRevision: UInt64 = 0
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
    private var cachedVODStreams: [String: [VODStream]] = [:]
    private var cachedAllVODStreams: [VODStream]?
    private var cachedSeriesCategories: [SeriesCategory]?
    private var cachedSeries: [String: [SeriesItem]] = [:]
    private var cachedAllSeries: [SeriesItem]?
    private var cachedVODDetails: [Int: VODDetails] = [:]
    private var cachedSeriesDetails: [Int: SeriesDetails] = [:]

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

    /// Creates a profile-editing client with no source credentials but the same transport session.
    func makeIndependentClient() -> XtreamCodesClient {
        XtreamCodesClient(session: session)
    }

    /// Replaces this client's active source and cache with a candidate source as one locked update.
    /// A candidate's already-loaded playlist is reused, avoiding a second large download.
    func adoptSource(from candidate: XtreamCodesClient) {
        guard candidate !== self else { return }
        let adopted = candidate.adoptedState()
        lock.lock()
        defer { lock.unlock() }
        sourceRevision &+= 1
        _serverURLString = adopted.serverURLString
        _username = adopted.username
        _password = adopted.password
        _playlistURLString = adopted.playlistURLString
        cachedLiveCategories = adopted.cachedLiveCategories
        cachedLiveStreams = adopted.cachedLiveStreams
        cachedAllLiveStreams = adopted.cachedAllLiveStreams
        cachedVODCategories = adopted.cachedVODCategories
        cachedVODStreams = adopted.cachedVODStreams
        cachedAllVODStreams = adopted.cachedAllVODStreams
        cachedSeriesCategories = adopted.cachedSeriesCategories
        cachedSeries = adopted.cachedSeries
        cachedAllSeries = adopted.cachedAllSeries
        cachedVODDetails = adopted.cachedVODDetails
        cachedSeriesDetails = adopted.cachedSeriesDetails
        cachedPlaylistChannels = adopted.cachedPlaylistChannels
    }

    private func adoptedState() -> AdoptedState {
        lock.lock()
        defer { lock.unlock() }
        return AdoptedState(
            serverURLString: _serverURLString,
            username: _username,
            password: _password,
            playlistURLString: _playlistURLString,
            cachedLiveCategories: cachedLiveCategories,
            cachedLiveStreams: cachedLiveStreams,
            cachedAllLiveStreams: cachedAllLiveStreams,
            cachedVODCategories: cachedVODCategories,
            cachedVODStreams: cachedVODStreams,
            cachedAllVODStreams: cachedAllVODStreams,
            cachedSeriesCategories: cachedSeriesCategories,
            cachedSeries: cachedSeries,
            cachedAllSeries: cachedAllSeries,
            cachedVODDetails: cachedVODDetails,
            cachedSeriesDetails: cachedSeriesDetails,
            cachedPlaylistChannels: cachedPlaylistChannels
        )
    }

    public func updateCredentials(serverURL: String, user: String, pass: String) {
        var cleanURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanURL.lowercased().hasPrefix("http://") && !cleanURL.lowercased().hasPrefix("https://") {
            cleanURL = "http://" + cleanURL
        }
        while cleanURL.hasSuffix("/") {
            cleanURL.removeLast()
        }
        lock.lock()
        defer { lock.unlock() }
        sourceRevision &+= 1
        _serverURLString = cleanURL
        _username = user.trimmingCharacters(in: .whitespacesAndNewlines)
        _password = pass.trimmingCharacters(in: .whitespacesAndNewlines)
        _playlistURLString = nil
        resetCachesLocked()
    }

    /// Switches to M3U playlist mode. Call `loadPlaylist()` to download and validate it.
    public func updatePlaylist(url: String) {
        lock.lock()
        defer { lock.unlock() }
        sourceRevision &+= 1
        _playlistURLString = url.trimmingCharacters(in: .whitespacesAndNewlines)
        _serverURLString = ""
        _username = ""
        _password = ""
        resetCachesLocked()
    }

    private func snapshot() -> SourceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return SourceSnapshot(
            revision: sourceRevision,
            serverURLString: _serverURLString,
            username: _username,
            password: _password,
            playlistURLString: _playlistURLString
        )
    }

    private func cachedValue<T>(for source: SourceSnapshot, _ read: () -> T?) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard sourceRevision == source.revision else { return nil }
        return read()
    }

    private func commitCache(for source: SourceSnapshot, _ write: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard sourceRevision == source.revision else { return }
        write()
    }

    private func resetCachesLocked() {
        cachedLiveCategories = nil
        cachedLiveStreams.removeAll()
        cachedAllLiveStreams = nil
        cachedVODCategories = nil
        cachedVODStreams.removeAll()
        cachedAllVODStreams = nil
        cachedSeriesCategories = nil
        cachedSeries.removeAll()
        cachedAllSeries = nil
        cachedVODDetails.removeAll()
        cachedSeriesDetails.removeAll()
        cachedPlaylistChannels = nil
    }

    // MARK: - M3U playlist

    /// Downloads and parses the playlist. Throws if it has no playable channels or is an HLS media manifest.
    @discardableResult
    public func loadPlaylist() async throws -> [LiveStream] {
        try await loadPlaylist(using: snapshot())
    }

    private func loadPlaylist(using source: SourceSnapshot) async throws -> [LiveStream] {
        if let cached = cachedValue(for: source, { cachedPlaylistChannels }) { return cached }
        guard let urlString = source.playlistURLString,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            throw XtreamError.invalidURL
        }

        let (data, response) = try await session.data(for: createRequest(url: url, timeout: 60.0))
        try Task.checkCancellation()
        try validateHTTPResponse(response)

        let entries: [M3UEntry]
        do {
            entries = try M3UPlaylistParser.parseValidated(data)
        } catch let error as M3UPlaylistError {
            throw XtreamError.decodingError(error.localizedDescription)
        }
        let live = entries.filter { !$0.isVOD }
        // Some playlists contain only VOD items. Show them rather than nothing.
        let sourceEntries = live.isEmpty ? entries : live
        guard !sourceEntries.isEmpty else {
            throw XtreamError.decodingError("The playlist has no channels. Check that the link points to an M3U file.")
        }

        var seen = Set<Int>()
        var channels: [LiveStream] = []
        channels.reserveCapacity(sourceEntries.count)
        for (index, entry) in sourceEntries.enumerated() {
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

        try Task.checkCancellation()
        commitCache(for: source) { cachedPlaylistChannels = channels }
        return channels
    }

    // MARK: - URL Generation

    private static let unreservedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private func apiEndpointURL(
        source: SourceSnapshot,
        action: String? = nil,
        queryParams: [String: String] = [:]
    ) throws -> URL {
        guard var components = URLComponents(string: source.serverURLString),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host != nil
        else {
            throw XtreamError.invalidURL
        }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path + "/player_api.php"

        var parameters = ["username": source.username, "password": source.password]
        if let action { parameters["action"] = action }
        for (key, value) in queryParams { parameters[key] = value }
        let orderedKeys = ["username", "password", "action"] + queryParams.keys.sorted()
        var emitted = Set<String>()
        let query = orderedKeys.compactMap { key -> String? in
            guard let value = parameters[key], emitted.insert(key).inserted,
                  let encodedKey = key.addingPercentEncoding(withAllowedCharacters: Self.unreservedCharacters),
                  let encodedValue = value.addingPercentEncoding(withAllowedCharacters: Self.unreservedCharacters)
            else { return nil }
            return "\(encodedKey)=\(encodedValue)"
        }
        components.percentEncodedQuery = query.joined(separator: "&")
        guard let fullURL = components.url else { throw XtreamError.invalidURL }
        return fullURL
    }

    private func streamURL(source: SourceSnapshot, kind: String, streamID: Int, containerExtension: String) -> URL? {
        guard streamID > 0,
              !source.serverURLString.isEmpty,
              !source.username.isEmpty,
              !source.password.isEmpty,
              var components = URLComponents(string: source.serverURLString),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host != nil,
              let encodedUsername = source.username.addingPercentEncoding(withAllowedCharacters: Self.unreservedCharacters),
              let encodedPassword = source.password.addingPercentEncoding(withAllowedCharacters: Self.unreservedCharacters),
              let encodedExtension = (containerExtension.isEmpty ? "mp4" : containerExtension)
                .addingPercentEncoding(withAllowedCharacters: Self.unreservedCharacters)
        else { return nil }

        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = "\(basePath)/\(kind)/\(encodedUsername)/\(encodedPassword)/\(streamID).\(encodedExtension)"
        components.percentEncodedQuery = nil
        components.fragment = nil
        return components.url
    }

    public func liveStreamURL(streamID: Int, format: StreamFormatPreference = .hls) -> URL? {
        let source = snapshot()
        let ext = format == .hls ? "m3u8" : "ts"
        return streamURL(source: source, kind: "live", streamID: streamID, containerExtension: ext)
    }

    public func vodStreamURL(streamID: Int, containerExtension: String = "mp4") -> URL? {
        streamURL(source: snapshot(), kind: "movie", streamID: streamID, containerExtension: containerExtension)
    }

    public func seriesStreamURL(streamID: Int, containerExtension: String = "mp4") -> URL? {
        streamURL(source: snapshot(), kind: "series", streamID: streamID, containerExtension: containerExtension)
    }

    // MARK: - API Calls

    private func createRequest(url: URL, timeout: TimeInterval = 15.0) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("IPTVSmartersPro/1.1.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw XtreamError.serverError(httpResponse.statusCode)
        }
    }

    private func requestData(
        for source: SourceSnapshot,
        action: String? = nil,
        queryParams: [String: String] = [:],
        timeout: TimeInterval = 15.0
    ) async throws -> Data {
        let url = try apiEndpointURL(source: source, action: action, queryParams: queryParams)
        let (data, response) = try await session.data(for: createRequest(url: url, timeout: timeout))
        try Task.checkCancellation()
        try validateHTTPResponse(response)
        return data
    }

    public func authenticate() async throws -> AuthResponse {
        let source = snapshot()
        let data = try await requestData(for: source)
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
        let source = snapshot()
        if source.playlistURLString != nil {
            let channels = try await loadPlaylist(using: source)
            var seen = Set<String>()
            return channels.compactMap { channel in
                seen.insert(channel.categoryId).inserted ? LiveCategory(id: channel.categoryId, name: channel.categoryId) : nil
            }
        }

        if let cached = cachedValue(for: source, { cachedLiveCategories }) { return cached }
        let data = try await requestData(for: source, action: "get_live_categories")
        do {
            let decoded = try JSONDecoder().decode([LiveCategory].self, from: data)
            var seen = Set<String>()
            let categories = decoded.compactMap { category -> LiveCategory? in
                guard let id = normalizedCategoryID(category.id), seen.insert(id).inserted else { return nil }
                return LiveCategory(id: id, name: category.name, parentId: category.parentId)
            }
            try Task.checkCancellation()
            commitCache(for: source) { cachedLiveCategories = categories }
            return categories
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw XtreamError.decodingError(error.localizedDescription)
        }
    }

    public func fetchLiveStreams(categoryID: String? = nil) async throws -> [LiveStream] {
        let source = snapshot()
        if source.playlistURLString != nil {
            let channels = try await loadPlaylist(using: source)
            guard let categoryID, !categoryID.isEmpty, categoryID != "ALL" else { return channels }
            return channels.filter { $0.categoryId == categoryID }
        }

        let effectiveCategoryID = categoryID.flatMap { $0.isEmpty || $0 == "ALL" ? nil : $0 }
        if let cached = cachedValue(for: source, {
            if let effectiveCategoryID { return cachedLiveStreams[effectiveCategoryID] }
            return cachedAllLiveStreams
        }) { return cached }

        var query: [String: String] = [:]
        if let effectiveCategoryID { query["category_id"] = effectiveCategoryID }
        let data = try await requestData(for: source, action: "get_live_streams", queryParams: query, timeout: 25.0)
        do {
            let decoded = try JSONDecoder().decode([LiveStream].self, from: data)
            let streams = uniqueByID(decoded.filter { $0.id > 0 }, id: \LiveStream.id)
            try Task.checkCancellation()
            commitCache(for: source) {
                if let effectiveCategoryID {
                    cachedLiveStreams[effectiveCategoryID] = streams
                } else {
                    cachedAllLiveStreams = streams
                }
            }
            return streams
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw XtreamError.decodingError(error.localizedDescription)
        }
    }

    public func fetchVODCategories() async throws -> [VODCategory] {
        let source = snapshot()
        if source.playlistURLString != nil { return [] }
        if let cached = cachedValue(for: source, { cachedVODCategories }) { return cached }
        let data = try await requestData(for: source, action: "get_vod_categories")
        do {
            let decoded = try JSONDecoder().decode([VODCategory].self, from: data)
            var seen = Set<String>()
            let categories = decoded.compactMap { category -> VODCategory? in
                guard let id = normalizedCategoryID(category.id), seen.insert(id).inserted else { return nil }
                return VODCategory(id: id, name: category.name, parentId: category.parentId)
            }
            try Task.checkCancellation()
            commitCache(for: source) { cachedVODCategories = categories }
            return categories
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw XtreamError.decodingError(error.localizedDescription)
        }
    }

    public func fetchVODStreams(categoryID: String? = nil) async throws -> [VODStream] {
        let source = snapshot()
        if source.playlistURLString != nil { return [] }
        let effectiveCategoryID = categoryID.flatMap { $0.isEmpty || $0.lowercased() == "all" ? nil : $0 }
        if let cached = cachedValue(for: source, {
            if let effectiveCategoryID {
                if let catCached = cachedVODStreams[effectiveCategoryID] { return catCached }
                if let allCached = cachedAllVODStreams { return allCached.filter { $0.categoryId == effectiveCategoryID } }
                return nil
            }
            return cachedAllVODStreams
        }) { return cached }

        var query: [String: String] = [:]
        if let effectiveCategoryID { query["category_id"] = effectiveCategoryID }
        let data = try await requestData(for: source, action: "get_vod_streams", queryParams: query, timeout: 20.0)
        do {
            let decoded = try JSONDecoder().decode([VODStream].self, from: data)
            let streams = uniqueByID(decoded.filter { $0.id > 0 }, id: \VODStream.id)
            try Task.checkCancellation()
            commitCache(for: source) {
                if let effectiveCategoryID {
                    cachedVODStreams[effectiveCategoryID] = streams
                } else {
                    cachedAllVODStreams = streams
                }
            }
            return streams
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw XtreamError.decodingError(error.localizedDescription)
        }
    }

    public func fetchSeriesCategories() async throws -> [SeriesCategory] {
        let source = snapshot()
        if source.playlistURLString != nil { return [] }
        if let cached = cachedValue(for: source, { cachedSeriesCategories }) { return cached }
        let data = try await requestData(for: source, action: "get_series_categories")
        do {
            let decoded = try JSONDecoder().decode([SeriesCategory].self, from: data)
            var seen = Set<String>()
            let categories = decoded.compactMap { category -> SeriesCategory? in
                guard let id = normalizedCategoryID(category.id), seen.insert(id).inserted else { return nil }
                return SeriesCategory(id: id, name: category.name, parentId: category.parentId)
            }
            try Task.checkCancellation()
            commitCache(for: source) { cachedSeriesCategories = categories }
            return categories
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw XtreamError.decodingError(error.localizedDescription)
        }
    }

    public func fetchSeries(categoryID: String? = nil) async throws -> [SeriesItem] {
        let source = snapshot()
        if source.playlistURLString != nil { return [] }
        let effectiveCategoryID = categoryID.flatMap { $0.isEmpty || $0.lowercased() == "all" ? nil : $0 }
        if let cached = cachedValue(for: source, {
            if let effectiveCategoryID {
                if let catCached = cachedSeries[effectiveCategoryID] { return catCached }
                if let allCached = cachedAllSeries { return allCached.filter { $0.categoryId == effectiveCategoryID } }
                return nil
            }
            return cachedAllSeries
        }) { return cached }

        var query: [String: String] = [:]
        if let effectiveCategoryID { query["category_id"] = effectiveCategoryID }
        let data = try await requestData(for: source, action: "get_series", queryParams: query, timeout: 20.0)
        do {
            let decoded = try JSONDecoder().decode([SeriesItem].self, from: data)
            let items = uniqueByID(decoded.filter { $0.id > 0 }, id: \SeriesItem.id)
            try Task.checkCancellation()
            commitCache(for: source) {
                if let effectiveCategoryID {
                    cachedSeries[effectiveCategoryID] = items
                } else {
                    cachedAllSeries = items
                }
            }
            return items
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw XtreamError.decodingError(error.localizedDescription)
        }
    }

    public func fetchSeriesDetails(seriesID: Int) async throws -> SeriesDetails {
        let source = snapshot()
        if source.playlistURLString != nil { return SeriesDetails(info: nil, episodes: [:]) }
        guard seriesID > 0 else { throw XtreamError.networkError("Invalid series ID") }
        if let cached = cachedValue(for: source, { cachedSeriesDetails[seriesID] }) { return cached }
        let data = try await requestData(for: source, action: "get_series_info", queryParams: ["series_id": "\(seriesID)"], timeout: 25.0)
        do {
            let details = try JSONDecoder().decode(SeriesDetails.self, from: data)
            try Task.checkCancellation()
            commitCache(for: source) { cachedSeriesDetails[seriesID] = details }
            return details
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw XtreamError.decodingError(error.localizedDescription)
        }
    }

    public func fetchVODDetails(vodID: Int) async throws -> VODDetails {
        let source = snapshot()
        if source.playlistURLString != nil { return VODDetails(info: nil) }
        guard vodID > 0 else { throw XtreamError.networkError("Invalid VOD ID") }
        if let cached = cachedValue(for: source, { cachedVODDetails[vodID] }) { return cached }
        let data = try await requestData(for: source, action: "get_vod_info", queryParams: ["vod_id": "\(vodID)"], timeout: 20.0)
        do {
            let details = try JSONDecoder().decode(VODDetails.self, from: data)
            try Task.checkCancellation()
            commitCache(for: source) { cachedVODDetails[vodID] = details }
            return details
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw XtreamError.decodingError(error.localizedDescription)
        }
    }

    private func normalizedCategoryID(_ rawID: String) -> String? {
        guard let id = Int(rawID), id > 0 else { return nil }
        return String(id)
    }

    private func uniqueByID<Element, ID: Hashable>(_ elements: [Element], id: KeyPath<Element, ID>) -> [Element] {
        var seen = Set<ID>()
        return elements.filter { seen.insert($0[keyPath: id]).inserted }
    }

    public func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        sourceRevision &+= 1
        resetCachesLocked()
    }
}
