import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(UIKit)
import UIKit
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

/// Bounded in-memory LRU cache.
struct BoundedLRUCache<Key: Hashable, Value> {
    let capacity: Int
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { storage.count }

    mutating func value(for key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        if order.last != key {
            order.removeAll { $0 == key }
            order.append(key)
        }
        return value
    }

    mutating func set(_ value: Value, for key: Key) {
        storage[key] = value
        order.removeAll { $0 == key }
        order.append(key)
        while storage.count > capacity, !order.isEmpty {
            let evicted = order.removeFirst()
            storage.removeValue(forKey: evicted)
        }
    }

    mutating func removeAll() {
        storage.removeAll()
        order.removeAll()
    }
}

/// Stale-while-revalidate on-disk catalog cache stored under `Caches/BruTVCatalogCache/<profileId>/`.
final class CatalogDiskCache: @unchecked Sendable {
    enum Lookup<T: Sendable>: Sendable {
        case miss
        case fresh(T)
        case stale(T)
    }

    private struct Envelope<T: Codable>: Codable {
        let savedAt: TimeInterval
        let payload: T
    }

    let baseDirectory: URL
    let freshTTL: TimeInterval
    let staleTTL: TimeInterval

    init(
        baseDirectory: URL? = nil,
        freshTTL: TimeInterval = 900,
        staleTTL: TimeInterval = 86_400
    ) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            self.baseDirectory = caches.appendingPathComponent("BruTVCatalogCache", isDirectory: true)
        } else {
            self.baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("BruTVCatalogCache", isDirectory: true)
        }
        self.freshTTL = max(0, freshTTL)
        self.staleTTL = max(freshTTL, staleTTL)
    }

    private func profileDirectory(for profileID: UUID) -> URL {
        baseDirectory.appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    private func fileURL(profileID: UUID, key: String) -> URL {
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return profileDirectory(for: profileID).appendingPathComponent("\(safeKey).json")
    }

    func read<T: Codable & Sendable>(
        _ type: T.Type,
        profileID: UUID,
        key: String,
        now: Date = Date()
    ) -> Lookup<T> {
        let url = fileURL(profileID: profileID, key: key)
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            return .miss
        }
        let age = now.timeIntervalSince1970 - envelope.savedAt
        if age < 0 || age <= freshTTL {
            return .fresh(envelope.payload)
        }
        if age <= staleTTL {
            return .stale(envelope.payload)
        }
        return .miss
    }

    func write<T: Codable>(
        _ value: T,
        profileID: UUID,
        key: String,
        now: Date = Date()
    ) {
        let dir = profileDirectory(for: profileID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let envelope = Envelope(savedAt: now.timeIntervalSince1970, payload: value)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        let url = fileURL(profileID: profileID, key: key)
        try? data.write(to: url, options: .atomic)
    }

    func clear(profileID: UUID) {
        try? FileManager.default.removeItem(at: profileDirectory(for: profileID))
    }
}

/// Per-key singleflight coalescer so concurrent callers share one underlying network request
/// without one caller's cancellation aborting other waiters.
private final class InFlightCoalescer: @unchecked Sendable {
    private final class Entry {
        let task: Task<Any, Error>
        var waiters: Int = 0

        init(task: Task<Any, Error>) {
            self.task = task
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func run<T: Sendable>(
        key: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let entry = acquireEntry(key: key, operation: operation)
        let raw: Any = try await withTaskCancellationHandler {
            try await entry.task.value
        } onCancel: {
            self.releaseWaiter(key: key, entry: entry)
        }
        releaseWaiter(key: key, entry: entry, didComplete: true)
        return raw as! T
    }

    private func acquireEntry<T: Sendable>(
        key: String,
        operation: @escaping @Sendable () async throws -> T
    ) -> Entry {
        lock.lock()
        defer { lock.unlock() }
        if let existing = entries[key] {
            existing.waiters += 1
            return existing
        }
        let sharedTask = Task<Any, Error> {
            defer { self.finish(key: key) }
            return try await operation()
        }
        let created = Entry(task: sharedTask)
        created.waiters = 1
        entries[key] = created
        return created
    }

    func cancelAll() {
        lock.lock()
        let tasks = entries.values.map(\.task)
        entries.removeAll()
        lock.unlock()
        for task in tasks {
            task.cancel()
        }
    }

    private func finish(key: String) {
        lock.lock()
        entries.removeValue(forKey: key)
        lock.unlock()
    }

    private func releaseWaiter(key: String, entry: Entry, didComplete: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard entries[key] === entry else { return }
        if !didComplete {
            entry.waiters = max(0, entry.waiters - 1)
            if entry.waiters == 0 {
                entries.removeValue(forKey: key)
                entry.task.cancel()
            }
        }
    }
}

public final class XtreamCodesClient: @unchecked Sendable {
    private struct SourceSnapshot: Sendable {
        let revision: UInt64
        let serverURLString: String
        let username: String
        let password: String
        let playlistURLString: String?
        let cacheProfileID: UUID?
    }

    private struct CachedEPGEntry {
        let listings: [EPGListing]
        let fetchedAt: TimeInterval
    }

    private struct AdoptedState {
        let serverURLString: String
        let username: String
        let password: String
        let playlistURLString: String?
        let cacheProfileID: UUID?
        let cachedLiveCategories: [LiveCategory]?
        let cachedLiveStreams: [String: [LiveStream]]
        let cachedAllLiveStreams: [LiveStream]?
        let cachedLiveStreamByID: [Int: LiveStream]?
        let hasIndexedAllLive: Bool
        let cachedVODCategories: [VODCategory]?
        let cachedVODStreams: [String: [VODStream]]
        let cachedAllVODStreams: [VODStream]?
        let hasIndexedAllVOD: Bool
        let cachedSeriesCategories: [SeriesCategory]?
        let cachedSeries: [String: [SeriesItem]]
        let cachedAllSeries: [SeriesItem]?
        let hasIndexedAllSeries: Bool
        let cachedVODDetails: BoundedLRUCache<Int, VODDetails>
        let cachedSeriesDetails: BoundedLRUCache<Int, SeriesDetails>
        let cachedPlaylistChannels: [LiveStream]?
        let cachedPlaylistByCategory: [String: [LiveStream]]
    }

    private let lock = NSLock()
    private let coalescer = InFlightCoalescer()
    private var sourceRevision: UInt64 = 0
    private var _serverURLString: String
    private var _username: String
    private var _password: String
    private var _cacheProfileID: UUID?
    private var diskCache: CatalogDiskCache
    private var memoryWarningObserver: NSObjectProtocol?

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

    public static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }

    private static let defaultSession = makeDefaultSession()
    private static let maxTransientRetries = 2
    private static let epgCacheTTL: TimeInterval = 60
    private static let retryDateFormatterLock = NSLock()
    private static let retryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private let session: URLSession
    private let retrySleep: @Sendable (Int, TimeInterval?) async throws -> Void
    private var cachedLiveCategories: [LiveCategory]?
    private var cachedLiveStreams: [String: [LiveStream]] = [:] // category_id -> streams
    private var cachedAllLiveStreams: [LiveStream]?
    private var cachedLiveStreamByID: [Int: LiveStream]?
    private var hasIndexedAllLive = false
    private var cachedVODCategories: [VODCategory]?
    private var cachedVODStreams: [String: [VODStream]] = [:]
    private var cachedAllVODStreams: [VODStream]?
    private var hasIndexedAllVOD = false
    private var cachedSeriesCategories: [SeriesCategory]?
    private var cachedSeries: [String: [SeriesItem]] = [:]
    private var cachedAllSeries: [SeriesItem]?
    private var hasIndexedAllSeries = false
    private var cachedVODDetails = BoundedLRUCache<Int, VODDetails>(capacity: 50)
    private var cachedSeriesDetails = BoundedLRUCache<Int, SeriesDetails>(capacity: 50)
    private var cachedShortEPG = BoundedLRUCache<Int, CachedEPGEntry>(capacity: 100)

    // M3U playlist mode. When set, live channels come from the playlist and VOD/series are empty.
    private var _playlistURLString: String?
    private var cachedPlaylistChannels: [LiveStream]?
    private var cachedPlaylistByCategory: [String: [LiveStream]] = [:]

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
        session: URLSession? = nil
    ) {
        self._serverURLString = serverURLString
        self._username = username
        self._password = password
        self.session = session ?? Self.defaultSession
        self.retrySleep = { try await Self.defaultRetrySleep(attempt: $0, overrideDelay: $1) }
        self.diskCache = CatalogDiskCache()
        installMemoryWarningObserver()
    }

    init(
        serverURLString: String = "",
        username: String = "",
        password: String = "",
        session: URLSession? = nil,
        retrySleep: @escaping @Sendable (Int) async throws -> Void
    ) {
        self._serverURLString = serverURLString
        self._username = username
        self._password = password
        self.session = session ?? Self.defaultSession
        self.retrySleep = { attempt, _ in try await retrySleep(attempt) }
        self.diskCache = CatalogDiskCache()
        installMemoryWarningObserver()
    }

    init(
        serverURLString: String = "",
        username: String = "",
        password: String = "",
        session: URLSession? = nil,
        retrySleepWithDelay: @escaping @Sendable (Int, TimeInterval?) async throws -> Void
    ) {
        self._serverURLString = serverURLString
        self._username = username
        self._password = password
        self.session = session ?? Self.defaultSession
        self.retrySleep = retrySleepWithDelay
        self.diskCache = CatalogDiskCache()
        installMemoryWarningObserver()
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func installMemoryWarningObserver() {
        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.clearMemoryCaches()
        }
        #endif
    }

    /// Configures per-profile stale-while-revalidate disk caching in `Caches/BruTVCatalogCache/<profileId>/`.
    public func configureDiskCache(
        profileID: UUID?,
        baseDirectory: URL? = nil,
        freshTTL: TimeInterval = 900,
        staleTTL: TimeInterval = 86_400
    ) {
        lock.lock()
        _cacheProfileID = profileID
        if let baseDirectory {
            diskCache = CatalogDiskCache(baseDirectory: baseDirectory, freshTTL: freshTTL, staleTTL: staleTTL)
        } else if freshTTL != 900 || staleTTL != 86_400 {
            diskCache = CatalogDiskCache(baseDirectory: nil, freshTTL: freshTTL, staleTTL: staleTTL)
        }
        lock.unlock()
    }

    public func clearDiskCache(for profileID: UUID) {
        lock.lock()
        let cache = diskCache
        lock.unlock()
        cache.clear(profileID: profileID)
    }

    private static func defaultRetrySleep(attempt: Int, overrideDelay: TimeInterval? = nil) async throws {
        let delay: TimeInterval
        if let overrideDelay {
            delay = max(0, overrideDelay)
        } else {
            // Bounded exponential backoff with +/- 25% jitter (attempt 1: ~0.5s, attempt 2: ~1.0s).
            let base = 0.5 * pow(2.0, Double(max(0, attempt - 1)))
            let jitter = Double.random(in: 0.75...1.25)
            delay = min(3.0, base * jitter)
        }
        guard delay > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    /// Creates a profile-editing client with no source credentials but the same transport session.
    func makeIndependentClient() -> XtreamCodesClient {
        XtreamCodesClient(session: session, retrySleepWithDelay: retrySleep)
    }

    /// Replaces this client's active source and cache with a candidate source as one locked update.
    /// A candidate's already-loaded playlist is reused, avoiding a second large download.
    func adoptSource(from candidate: XtreamCodesClient) {
        guard candidate !== self else { return }
        let adopted = candidate.adoptedState()
        lock.lock()
        sourceRevision &+= 1
        _serverURLString = adopted.serverURLString
        _username = adopted.username
        _password = adopted.password
        _playlistURLString = adopted.playlistURLString
        if let profileID = adopted.cacheProfileID {
            _cacheProfileID = profileID
        }
        cachedLiveCategories = adopted.cachedLiveCategories
        cachedLiveStreams = adopted.cachedLiveStreams
        cachedAllLiveStreams = adopted.cachedAllLiveStreams
        cachedLiveStreamByID = adopted.cachedLiveStreamByID
        hasIndexedAllLive = adopted.hasIndexedAllLive
        cachedVODCategories = adopted.cachedVODCategories
        cachedVODStreams = adopted.cachedVODStreams
        cachedAllVODStreams = adopted.cachedAllVODStreams
        hasIndexedAllVOD = adopted.hasIndexedAllVOD
        cachedSeriesCategories = adopted.cachedSeriesCategories
        cachedSeries = adopted.cachedSeries
        cachedAllSeries = adopted.cachedAllSeries
        hasIndexedAllSeries = adopted.hasIndexedAllSeries
        cachedVODDetails = adopted.cachedVODDetails
        cachedSeriesDetails = adopted.cachedSeriesDetails
        cachedShortEPG.removeAll()
        cachedPlaylistChannels = adopted.cachedPlaylistChannels
        cachedPlaylistByCategory = adopted.cachedPlaylistByCategory
        lock.unlock()
        coalescer.cancelAll()
    }

    private func adoptedState() -> AdoptedState {
        lock.lock()
        defer { lock.unlock() }
        return AdoptedState(
            serverURLString: _serverURLString,
            username: _username,
            password: _password,
            playlistURLString: _playlistURLString,
            cacheProfileID: _cacheProfileID,
            cachedLiveCategories: cachedLiveCategories,
            cachedLiveStreams: cachedLiveStreams,
            cachedAllLiveStreams: cachedAllLiveStreams,
            cachedLiveStreamByID: cachedLiveStreamByID,
            hasIndexedAllLive: hasIndexedAllLive,
            cachedVODCategories: cachedVODCategories,
            cachedVODStreams: cachedVODStreams,
            cachedAllVODStreams: cachedAllVODStreams,
            hasIndexedAllVOD: hasIndexedAllVOD,
            cachedSeriesCategories: cachedSeriesCategories,
            cachedSeries: cachedSeries,
            cachedAllSeries: cachedAllSeries,
            hasIndexedAllSeries: hasIndexedAllSeries,
            cachedVODDetails: cachedVODDetails,
            cachedSeriesDetails: cachedSeriesDetails,
            cachedPlaylistChannels: cachedPlaylistChannels,
            cachedPlaylistByCategory: cachedPlaylistByCategory
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
        sourceRevision &+= 1
        _serverURLString = cleanURL
        _username = user.trimmingCharacters(in: .whitespacesAndNewlines)
        _password = pass.trimmingCharacters(in: .whitespacesAndNewlines)
        _playlistURLString = nil
        resetCachesLocked()
        lock.unlock()
        coalescer.cancelAll()
    }

    /// Switches to M3U playlist mode. Call `loadPlaylist()` to download and validate it.
    public func updatePlaylist(url: String) {
        lock.lock()
        sourceRevision &+= 1
        _playlistURLString = url.trimmingCharacters(in: .whitespacesAndNewlines)
        _serverURLString = ""
        _username = ""
        _password = ""
        resetCachesLocked()
        lock.unlock()
        coalescer.cancelAll()
    }

    private func snapshot() -> SourceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return SourceSnapshot(
            revision: sourceRevision,
            serverURLString: _serverURLString,
            username: _username,
            password: _password,
            playlistURLString: _playlistURLString,
            cacheProfileID: _cacheProfileID
        )
    }

    private func currentDiskCache() -> CatalogDiskCache {
        lock.lock()
        defer { lock.unlock() }
        return diskCache
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
        cachedLiveStreamByID = nil
        hasIndexedAllLive = false
        cachedVODCategories = nil
        cachedVODStreams.removeAll()
        cachedAllVODStreams = nil
        hasIndexedAllVOD = false
        cachedSeriesCategories = nil
        cachedSeries.removeAll()
        cachedAllSeries = nil
        hasIndexedAllSeries = false
        cachedVODDetails.removeAll()
        cachedSeriesDetails.removeAll()
        cachedShortEPG.removeAll()
        cachedPlaylistChannels = nil
        cachedPlaylistByCategory.removeAll()
    }

    /// Pre-indexes `[categoryId: [Item]]` outside `NSLock`.
    private static func groupByCategory<T>(_ items: [T], categoryID: KeyPath<T, String>) -> [String: [T]] {
        var grouped: [String: [T]] = [:]
        for item in items {
            grouped[item[keyPath: categoryID], default: []].append(item)
        }
        return grouped
    }

    /// Pre-indexes `[Int: LiveStream]` outside `NSLock` for O(1) recent/favorite resolution.
    private static func indexLiveByID(_ items: [LiveStream]) -> [Int: LiveStream] {
        var map: [Int: LiveStream] = [:]
        map.reserveCapacity(items.count)
        for item in items {
            map[item.id] = item
        }
        return map
    }

    // MARK: - M3U playlist

    /// Downloads and parses the playlist. Throws if it has no playable channels or is an HLS media manifest.
    @discardableResult
    public func loadPlaylist() async throws -> [LiveStream] {
        try await loadPlaylist(using: snapshot())
    }

    private func loadPlaylist(using source: SourceSnapshot) async throws -> [LiveStream] {
        if let cached = cachedValue(for: source, { cachedPlaylistChannels }) { return cached }

        if let profileID = source.cacheProfileID {
            let disk = currentDiskCache()
            switch disk.read([LiveStream].self, profileID: profileID, key: "m3u_playlist") {
            case .fresh(let channels):
                let byCategory = Self.groupByCategory(channels, categoryID: \.categoryId)
                let byID = Self.indexLiveByID(channels)
                commitCache(for: source) {
                    cachedPlaylistChannels = channels
                    cachedPlaylistByCategory = byCategory
                    cachedLiveStreamByID = byID
                }
                return channels
            case .stale(let channels):
                let byCategory = Self.groupByCategory(channels, categoryID: \.categoryId)
                let byID = Self.indexLiveByID(channels)
                commitCache(for: source) {
                    cachedPlaylistChannels = channels
                    cachedPlaylistByCategory = byCategory
                    cachedLiveStreamByID = byID
                }
                Task.detached(priority: .utility) { [weak self] in
                    _ = try? await self?.fetchPlaylistFromNetwork(using: source)
                }
                return channels
            case .miss:
                break
            }
        }

        return try await fetchPlaylistFromNetwork(using: source)
    }

    private func fetchPlaylistFromNetwork(using source: SourceSnapshot) async throws -> [LiveStream] {
        try await coalescer.run(key: "\(source.revision):m3u_playlist") { [self] in
            guard let urlString = source.playlistURLString,
                  let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else {
                throw XtreamError.invalidURL
            }

            let data = try await performRequestWithRetry(createRequest(url: url, timeout: 60.0))

            let channels: [LiveStream]
            do {
                channels = try M3UPlaylistParser.parseLiveStreamsValidated(data)
            } catch let error as M3UPlaylistError {
                throw XtreamError.decodingError(error.localizedDescription)
            }
            guard !channels.isEmpty else {
                throw XtreamError.decodingError("The playlist has no channels. Check that the link points to an M3U file.")
            }

            let byCategory = Self.groupByCategory(channels, categoryID: \.categoryId)
            let byID = Self.indexLiveByID(channels)
            try Task.checkCancellation()
            commitCache(for: source) {
                cachedPlaylistChannels = channels
                cachedPlaylistByCategory = byCategory
                cachedLiveStreamByID = byID
            }
            if let profileID = source.cacheProfileID {
                currentDiskCache().write(channels, profileID: profileID, key: "m3u_playlist")
            }
            return channels
        }
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
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("IPTVSmartersPro/1.1.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    static func parseRetryAfter(
        _ headerValue: String?,
        now: Date = Date(),
        maxDelay: TimeInterval = 10.0
    ) -> TimeInterval? {
        guard let raw = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let clampedMax = max(0, maxDelay)
        if let seconds = Int(raw) {
            guard seconds >= 0 else { return nil }
            return min(clampedMax, TimeInterval(seconds))
        }
        Self.retryDateFormatterLock.lock()
        let date = Self.retryDateFormatter.date(from: raw)
        Self.retryDateFormatterLock.unlock()
        if let date {
            return max(0, min(clampedMax, date.timeIntervalSince(now)))
        }
        return nil
    }

    static func isRetryableNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private func performRequestWithRetry(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                    if attempt < Self.maxTransientRetries, Self.isRetryableHTTPStatus(httpResponse.statusCode) {
                        attempt += 1
                        let retryAfter = Self.parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))
                        try await retrySleep(attempt, retryAfter)
                        continue
                    }
                    throw XtreamError.serverError(httpResponse.statusCode)
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as XtreamError {
                throw error
            } catch {
                if attempt < Self.maxTransientRetries, Self.isRetryableNetworkError(error) {
                    attempt += 1
                    try await retrySleep(attempt, nil)
                    continue
                }
                throw error
            }
        }
    }

    private func requestData(
        for source: SourceSnapshot,
        action: String? = nil,
        queryParams: [String: String] = [:],
        timeout: TimeInterval = 15.0
    ) async throws -> Data {
        let url = try apiEndpointURL(source: source, action: action, queryParams: queryParams)
        return try await performRequestWithRetry(createRequest(url: url, timeout: timeout))
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

    // MARK: - Live TV

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

        if let profileID = source.cacheProfileID {
            let disk = currentDiskCache()
            switch disk.read([LiveCategory].self, profileID: profileID, key: "live_categories") {
            case .fresh(let categories):
                commitCache(for: source) { cachedLiveCategories = categories }
                return categories
            case .stale(let categories):
                commitCache(for: source) { cachedLiveCategories = categories }
                Task.detached(priority: .utility) { [weak self] in
                    _ = try? await self?.fetchLiveCategoriesFromNetwork(using: source)
                }
                return categories
            case .miss:
                break
            }
        }

        return try await fetchLiveCategoriesFromNetwork(using: source)
    }

    private func fetchLiveCategoriesFromNetwork(using source: SourceSnapshot) async throws -> [LiveCategory] {
        try await coalescer.run(key: "\(source.revision):live_categories") { [self] in
            let data = try await requestData(for: source, action: "get_live_categories")
            do {
                let decoded = try LiveCategory.decodeArray(from: data)
                var seen = Set<String>()
                let categories = decoded.compactMap { category -> LiveCategory? in
                    guard let id = normalizedCategoryID(category.id), seen.insert(id).inserted else { return nil }
                    return LiveCategory(id: id, name: category.name, parentId: category.parentId)
                }
                try Task.checkCancellation()
                commitCache(for: source) { cachedLiveCategories = categories }
                if let profileID = source.cacheProfileID {
                    currentDiskCache().write(categories, profileID: profileID, key: "live_categories")
                }
                return categories
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw XtreamError.decodingError(error.localizedDescription)
            }
        }
    }

    public func fetchLiveStreams(categoryID: String? = nil) async throws -> [LiveStream] {
        let source = snapshot()
        let effectiveCategoryID = categoryID.flatMap { $0.isEmpty || $0 == "ALL" ? nil : $0 }

        if source.playlistURLString != nil {
            let channels = try await loadPlaylist(using: source)
            guard let effectiveCategoryID else { return channels }
            if let indexed = cachedValue(for: source, { cachedPlaylistByCategory[effectiveCategoryID] }) {
                return indexed
            }
            return []
        }

        if let cached = cachedValue(for: source, { () -> [LiveStream]? in
            if let effectiveCategoryID {
                if let catCached = cachedLiveStreams[effectiveCategoryID] { return catCached }
                if hasIndexedAllLive { return [] }
                return nil
            }
            return cachedAllLiveStreams
        }) { return cached }

        // Check disk cache for full catalog (which satisfies both ALL and any category in O(1))
        if let profileID = source.cacheProfileID {
            let disk = currentDiskCache()
            let diskLookup = disk.read([LiveStream].self, profileID: profileID, key: "live_streams_all")
            switch diskLookup {
            case .fresh(let allStreams):
                let byCategory = Self.groupByCategory(allStreams, categoryID: \.categoryId)
                let byID = Self.indexLiveByID(allStreams)
                commitCache(for: source) {
                    cachedAllLiveStreams = allStreams
                    cachedLiveStreams = byCategory
                    cachedLiveStreamByID = byID
                    hasIndexedAllLive = true
                }
                return effectiveCategoryID.map { byCategory[$0] ?? [] } ?? allStreams
            case .stale(let allStreams):
                let byCategory = Self.groupByCategory(allStreams, categoryID: \.categoryId)
                let byID = Self.indexLiveByID(allStreams)
                commitCache(for: source) {
                    cachedAllLiveStreams = allStreams
                    cachedLiveStreams = byCategory
                    cachedLiveStreamByID = byID
                    hasIndexedAllLive = true
                }
                Task.detached(priority: .utility) { [weak self] in
                    _ = try? await self?.fetchLiveStreamsFromNetwork(using: source, effectiveCategoryID: nil)
                }
                return effectiveCategoryID.map { byCategory[$0] ?? [] } ?? allStreams
            case .miss:
                break
            }
        }

        return try await fetchLiveStreamsFromNetwork(using: source, effectiveCategoryID: effectiveCategoryID)
    }

    private func fetchLiveStreamsFromNetwork(
        using source: SourceSnapshot,
        effectiveCategoryID: String?
    ) async throws -> [LiveStream] {
        let key = effectiveCategoryID.map { "live_streams_cat_\($0)" } ?? "live_streams_all"
        return try await coalescer.run(key: "\(source.revision):\(key)") { [self] in
            var query: [String: String] = [:]
            if let effectiveCategoryID { query["category_id"] = effectiveCategoryID }
            let data = try await requestData(for: source, action: "get_live_streams", queryParams: query, timeout: 25.0)
            do {
                let decoded = try LiveStream.decodeArray(from: data)
                let streams = uniqueByID(decoded.filter { $0.id > 0 }, id: \LiveStream.id)
                let byCategory = effectiveCategoryID == nil ? Self.groupByCategory(streams, categoryID: \.categoryId) : nil
                let byID = effectiveCategoryID == nil ? Self.indexLiveByID(streams) : nil
                try Task.checkCancellation()
                commitCache(for: source) {
                    if let effectiveCategoryID {
                        cachedLiveStreams[effectiveCategoryID] = streams
                    } else {
                        cachedAllLiveStreams = streams
                        if let byCategory { cachedLiveStreams = byCategory }
                        if let byID { cachedLiveStreamByID = byID }
                        hasIndexedAllLive = true
                    }
                }
                if effectiveCategoryID == nil, let profileID = source.cacheProfileID {
                    currentDiskCache().write(streams, profileID: profileID, key: "live_streams_all")
                }
                return streams
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw XtreamError.decodingError(error.localizedDescription)
            }
        }
    }

    /// Returns a pre-indexed `[Int: LiveStream]` lookup table for O(K) favorite/recent resolution.
    public func liveStreamIndex() async throws -> [Int: LiveStream] {
        let source = snapshot()
        if let existing = cachedValue(for: source, { cachedLiveStreamByID }) {
            return existing
        }
        let all = try await fetchLiveStreams()
        if let existing = cachedValue(for: source, { cachedLiveStreamByID }) {
            return existing
        }
        let byID = Self.indexLiveByID(all)
        commitCache(for: source) { cachedLiveStreamByID = byID }
        return byID
    }

    // MARK: - VOD

    public func fetchVODCategories() async throws -> [VODCategory] {
        let source = snapshot()
        if source.playlistURLString != nil { return [] }
        if let cached = cachedValue(for: source, { cachedVODCategories }) { return cached }

        if let profileID = source.cacheProfileID {
            let disk = currentDiskCache()
            switch disk.read([VODCategory].self, profileID: profileID, key: "vod_categories") {
            case .fresh(let categories):
                commitCache(for: source) { cachedVODCategories = categories }
                return categories
            case .stale(let categories):
                commitCache(for: source) { cachedVODCategories = categories }
                Task.detached(priority: .utility) { [weak self] in
                    _ = try? await self?.fetchVODCategoriesFromNetwork(using: source)
                }
                return categories
            case .miss:
                break
            }
        }

        return try await fetchVODCategoriesFromNetwork(using: source)
    }

    private func fetchVODCategoriesFromNetwork(using source: SourceSnapshot) async throws -> [VODCategory] {
        try await coalescer.run(key: "\(source.revision):vod_categories") { [self] in
            let data = try await requestData(for: source, action: "get_vod_categories")
            do {
                let decoded = try VODCategory.decodeArray(from: data)
                var seen = Set<String>()
                let categories = decoded.compactMap { category -> VODCategory? in
                    guard let id = normalizedCategoryID(category.id), seen.insert(id).inserted else { return nil }
                    return VODCategory(id: id, name: category.name, parentId: category.parentId)
                }
                try Task.checkCancellation()
                commitCache(for: source) { cachedVODCategories = categories }
                if let profileID = source.cacheProfileID {
                    currentDiskCache().write(categories, profileID: profileID, key: "vod_categories")
                }
                return categories
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw XtreamError.decodingError(error.localizedDescription)
            }
        }
    }

    public func fetchVODStreams(categoryID: String? = nil) async throws -> [VODStream] {
        let source = snapshot()
        if source.playlistURLString != nil { return [] }
        let effectiveCategoryID = categoryID.flatMap { $0.isEmpty || $0.lowercased() == "all" ? nil : $0 }
        if let cached = cachedValue(for: source, { () -> [VODStream]? in
            if let effectiveCategoryID {
                if let catCached = cachedVODStreams[effectiveCategoryID] { return catCached }
                if hasIndexedAllVOD { return [] }
                return nil
            }
            return cachedAllVODStreams
        }) { return cached }

        if let profileID = source.cacheProfileID {
            let disk = currentDiskCache()
            switch disk.read([VODStream].self, profileID: profileID, key: "vod_streams_all") {
            case .fresh(let allStreams):
                let byCategory = Self.groupByCategory(allStreams, categoryID: \.categoryId)
                commitCache(for: source) {
                    cachedAllVODStreams = allStreams
                    cachedVODStreams = byCategory
                    hasIndexedAllVOD = true
                }
                return effectiveCategoryID.map { byCategory[$0] ?? [] } ?? allStreams
            case .stale(let allStreams):
                let byCategory = Self.groupByCategory(allStreams, categoryID: \.categoryId)
                commitCache(for: source) {
                    cachedAllVODStreams = allStreams
                    cachedVODStreams = byCategory
                    hasIndexedAllVOD = true
                }
                Task.detached(priority: .utility) { [weak self] in
                    _ = try? await self?.fetchVODStreamsFromNetwork(using: source, effectiveCategoryID: nil)
                }
                return effectiveCategoryID.map { byCategory[$0] ?? [] } ?? allStreams
            case .miss:
                break
            }
        }

        return try await fetchVODStreamsFromNetwork(using: source, effectiveCategoryID: effectiveCategoryID)
    }

    private func fetchVODStreamsFromNetwork(
        using source: SourceSnapshot,
        effectiveCategoryID: String?
    ) async throws -> [VODStream] {
        let key = effectiveCategoryID.map { "vod_streams_cat_\($0)" } ?? "vod_streams_all"
        return try await coalescer.run(key: "\(source.revision):\(key)") { [self] in
            var query: [String: String] = [:]
            if let effectiveCategoryID { query["category_id"] = effectiveCategoryID }
            let data = try await requestData(for: source, action: "get_vod_streams", queryParams: query, timeout: 20.0)
            do {
                let decoded = try VODStream.decodeArray(from: data)
                let streams = uniqueByID(decoded.filter { $0.id > 0 }, id: \VODStream.id)
                let byCategory = effectiveCategoryID == nil ? Self.groupByCategory(streams, categoryID: \.categoryId) : nil
                try Task.checkCancellation()
                commitCache(for: source) {
                    if let effectiveCategoryID {
                        cachedVODStreams[effectiveCategoryID] = streams
                    } else {
                        cachedAllVODStreams = streams
                        if let byCategory { cachedVODStreams = byCategory }
                        hasIndexedAllVOD = true
                    }
                }
                if effectiveCategoryID == nil, let profileID = source.cacheProfileID {
                    currentDiskCache().write(streams, profileID: profileID, key: "vod_streams_all")
                }
                return streams
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw XtreamError.decodingError(error.localizedDescription)
            }
        }
    }

    // MARK: - Series

    public func fetchSeriesCategories() async throws -> [SeriesCategory] {
        let source = snapshot()
        if source.playlistURLString != nil { return [] }
        if let cached = cachedValue(for: source, { cachedSeriesCategories }) { return cached }

        if let profileID = source.cacheProfileID {
            let disk = currentDiskCache()
            switch disk.read([SeriesCategory].self, profileID: profileID, key: "series_categories") {
            case .fresh(let categories):
                commitCache(for: source) { cachedSeriesCategories = categories }
                return categories
            case .stale(let categories):
                commitCache(for: source) { cachedSeriesCategories = categories }
                Task.detached(priority: .utility) { [weak self] in
                    _ = try? await self?.fetchSeriesCategoriesFromNetwork(using: source)
                }
                return categories
            case .miss:
                break
            }
        }

        return try await fetchSeriesCategoriesFromNetwork(using: source)
    }

    private func fetchSeriesCategoriesFromNetwork(using source: SourceSnapshot) async throws -> [SeriesCategory] {
        try await coalescer.run(key: "\(source.revision):series_categories") { [self] in
            let data = try await requestData(for: source, action: "get_series_categories")
            do {
                let decoded = try SeriesCategory.decodeArray(from: data)
                var seen = Set<String>()
                let categories = decoded.compactMap { category -> SeriesCategory? in
                    guard let id = normalizedCategoryID(category.id), seen.insert(id).inserted else { return nil }
                    return SeriesCategory(id: id, name: category.name, parentId: category.parentId)
                }
                try Task.checkCancellation()
                commitCache(for: source) { cachedSeriesCategories = categories }
                if let profileID = source.cacheProfileID {
                    currentDiskCache().write(categories, profileID: profileID, key: "series_categories")
                }
                return categories
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw XtreamError.decodingError(error.localizedDescription)
            }
        }
    }

    public func fetchSeries(categoryID: String? = nil) async throws -> [SeriesItem] {
        let source = snapshot()
        if source.playlistURLString != nil { return [] }
        let effectiveCategoryID = categoryID.flatMap { $0.isEmpty || $0.lowercased() == "all" ? nil : $0 }
        if let cached = cachedValue(for: source, { () -> [SeriesItem]? in
            if let effectiveCategoryID {
                if let catCached = cachedSeries[effectiveCategoryID] { return catCached }
                if hasIndexedAllSeries { return [] }
                return nil
            }
            return cachedAllSeries
        }) { return cached }

        if let profileID = source.cacheProfileID {
            let disk = currentDiskCache()
            switch disk.read([SeriesItem].self, profileID: profileID, key: "series_all") {
            case .fresh(let allSeries):
                let byCategory = Self.groupByCategory(allSeries, categoryID: \.categoryId)
                commitCache(for: source) {
                    cachedAllSeries = allSeries
                    cachedSeries = byCategory
                    hasIndexedAllSeries = true
                }
                return effectiveCategoryID.map { byCategory[$0] ?? [] } ?? allSeries
            case .stale(let allSeries):
                let byCategory = Self.groupByCategory(allSeries, categoryID: \.categoryId)
                commitCache(for: source) {
                    cachedAllSeries = allSeries
                    cachedSeries = byCategory
                    hasIndexedAllSeries = true
                }
                Task.detached(priority: .utility) { [weak self] in
                    _ = try? await self?.fetchSeriesFromNetwork(using: source, effectiveCategoryID: nil)
                }
                return effectiveCategoryID.map { byCategory[$0] ?? [] } ?? allSeries
            case .miss:
                break
            }
        }

        return try await fetchSeriesFromNetwork(using: source, effectiveCategoryID: effectiveCategoryID)
    }

    private func fetchSeriesFromNetwork(
        using source: SourceSnapshot,
        effectiveCategoryID: String?
    ) async throws -> [SeriesItem] {
        let key = effectiveCategoryID.map { "series_cat_\($0)" } ?? "series_all"
        return try await coalescer.run(key: "\(source.revision):\(key)") { [self] in
            var query: [String: String] = [:]
            if let effectiveCategoryID { query["category_id"] = effectiveCategoryID }
            let data = try await requestData(for: source, action: "get_series", queryParams: query, timeout: 20.0)
            do {
                let decoded = try SeriesItem.decodeArray(from: data)
                let items = uniqueByID(decoded.filter { $0.id > 0 }, id: \SeriesItem.id)
                let byCategory = effectiveCategoryID == nil ? Self.groupByCategory(items, categoryID: \.categoryId) : nil
                try Task.checkCancellation()
                commitCache(for: source) {
                    if let effectiveCategoryID {
                        cachedSeries[effectiveCategoryID] = items
                    } else {
                        cachedAllSeries = items
                        if let byCategory { cachedSeries = byCategory }
                        hasIndexedAllSeries = true
                    }
                }
                if effectiveCategoryID == nil, let profileID = source.cacheProfileID {
                    currentDiskCache().write(items, profileID: profileID, key: "series_all")
                }
                return items
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw XtreamError.decodingError(error.localizedDescription)
            }
        }
    }

    // MARK: - Details & Short EPG

    public func fetchSeriesDetails(seriesID: Int) async throws -> SeriesDetails {
        let source = snapshot()
        if source.playlistURLString != nil { return SeriesDetails(info: nil, episodes: [:]) }
        guard seriesID > 0 else { throw XtreamError.networkError("Invalid series ID") }
        if let cached = cachedValue(for: source, { cachedSeriesDetails.value(for: seriesID) }) { return cached }
        return try await coalescer.run(key: "\(source.revision):series_details_\(seriesID)") { [self] in
            let data = try await requestData(for: source, action: "get_series_info", queryParams: ["series_id": "\(seriesID)"], timeout: 25.0)
            do {
                let details = try JSONDecoder().decode(SeriesDetails.self, from: data)
                try Task.checkCancellation()
                commitCache(for: source) { cachedSeriesDetails.set(details, for: seriesID) }
                return details
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw XtreamError.decodingError(error.localizedDescription)
            }
        }
    }

    public func fetchVODDetails(vodID: Int) async throws -> VODDetails {
        let source = snapshot()
        if source.playlistURLString != nil { return VODDetails(info: nil) }
        guard vodID > 0 else { throw XtreamError.networkError("Invalid VOD ID") }
        if let cached = cachedValue(for: source, { cachedVODDetails.value(for: vodID) }) { return cached }
        return try await coalescer.run(key: "\(source.revision):vod_details_\(vodID)") { [self] in
            let data = try await requestData(for: source, action: "get_vod_info", queryParams: ["vod_id": "\(vodID)"], timeout: 20.0)
            do {
                let details = try JSONDecoder().decode(VODDetails.self, from: data)
                try Task.checkCancellation()
                commitCache(for: source) { cachedVODDetails.set(details, for: vodID) }
                return details
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw XtreamError.decodingError(error.localizedDescription)
            }
        }
    }

    /// Fetches short EPG listings (Now / Next) for an Xtream live channel, cached briefly in RAM.
    public func fetchShortEPG(streamID: Int, limit: Int = 4) async throws -> [EPGListing] {
        let source = snapshot()
        if source.playlistURLString != nil { return [] }
        guard streamID > 0 else { return [] }
        let now = Date().timeIntervalSinceReferenceDate
        if let cached = cachedValue(for: source, { () -> [EPGListing]? in
            guard let entry = cachedShortEPG.value(for: streamID),
                  now - entry.fetchedAt < Self.epgCacheTTL else { return nil }
            return entry.listings
        }) {
            return cached
        }
        let clampedLimit = max(1, min(limit, 12))
        return try await coalescer.run(key: "\(source.revision):short_epg_\(streamID)_\(clampedLimit)") { [self] in
            let data = try await requestData(
                for: source,
                action: "get_short_epg",
                queryParams: ["stream_id": "\(streamID)", "limit": "\(clampedLimit)"],
                timeout: 10.0
            )
            do {
                let decoded = try JSONDecoder().decode(ShortEPGResponse.self, from: data)
                let listings = decoded.epgListings.filter { !$0.title.isEmpty }
                try Task.checkCancellation()
                commitCache(for: source) {
                    cachedShortEPG.set(
                        CachedEPGEntry(listings: listings, fetchedAt: Date().timeIntervalSinceReferenceDate),
                        for: streamID
                    )
                }
                return listings
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw XtreamError.decodingError(error.localizedDescription)
            }
        }
    }

    private func normalizedCategoryID(_ rawID: String) -> String? {
        guard let id = Int(rawID), id > 0 else { return nil }
        return String(id)
    }

    private func uniqueByID<Element, ID: Hashable>(_ elements: [Element], id: KeyPath<Element, ID>) -> [Element] {
        var seen = Set<ID>()
        seen.reserveCapacity(elements.count)
        return elements.filter { seen.insert($0[keyPath: id]).inserted }
    }

    /// Evicts in-memory RAM caches (preserving on-disk cache) on memory pressure.
    public func clearMemoryCaches() {
        lock.lock()
        resetCachesLocked()
        lock.unlock()
    }

    /// Invalidates RAM caches and (by default) on-disk catalog cache for the active profile.
    public func clearCache(includeDisk: Bool = true) {
        lock.lock()
        sourceRevision &+= 1
        let profileID = _cacheProfileID
        let cache = diskCache
        resetCachesLocked()
        lock.unlock()
        coalescer.cancelAll()
        if includeDisk, let profileID {
            cache.clear(profileID: profileID)
        }
    }
}
