import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LiveTimeshiftLimits: Sendable {
    var seconds: Double = 600
    var bytes: Int = 256 * 1024 * 1024
    var manifestBytes: Int = 1024 * 1024
    var segmentBytes: Int = 32 * 1024 * 1024
    var segmentCount: Int = 2000
}

enum LiveTimeshiftError: Error, LocalizedError, Equatable {
    case unsupported(String)
    case invalidPlaylist
    case tooLarge
    case network(Int)
    case startupTimeout
    case bufferLimit
    case stopped

    var errorDescription: String? {
        switch self {
        case .unsupported(let reason): return reason
        case .invalidPlaylist: return "This provider does not offer a supported live HLS playlist."
        case .tooLarge: return "A provider response exceeded the temporary-buffer limit."
        case .network: return "The provider could not supply the live buffer."
        case .startupTimeout: return "The temporary live buffer took too long to start."
        case .bufferLimit: return "The stream is too large for the temporary-buffer limit."
        case .stopped: return "The live buffer was stopped."
        }
    }
}

struct RecordedHLSSegment: Sendable, Equatable {
    let sequence: Int64
    let discontinuity: Int64
    let duration: Double
    let url: URL
    let programDateTime: String?
    let gap: Bool
}

struct LiveHLSPlaylist: Sendable {
    let targetDuration: Double
    let segments: [RecordedHLSSegment]
    let ended: Bool
}

enum LiveHLSManifest: Sendable {
    case variant(URL)
    case media(LiveHLSPlaylist)
}

enum LiveHLSParser {
    static func parse(_ data: Data, baseURL: URL, limit: Int = 1024 * 1024, segmentLimit: Int = 2000) throws -> LiveHLSManifest {
        guard data.count <= limit else { throw LiveTimeshiftError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw LiveTimeshiftError.invalidPlaylist }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first == "#EXTM3U" else { throw LiveTimeshiftError.invalidPlaylist }
        var variants: [(URL, Int)] = []
        var variantAttributes: [String: String]?
        var target: Double = 0
        var sequence: Int64 = 0
        var discontinuity: Int64 = 0
        var duration: Double?
        var date: String?
        var gap = false
        var segments: [RecordedHLSSegment] = []
        var ended = false
        for line in lines.dropFirst() where !line.isEmpty {
            if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = try attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                guard attrs["METHOD"] == "NONE" else {
                    throw LiveTimeshiftError.unsupported("Encrypted streams play directly without a temporary rewind buffer.")
                }
            } else if line.hasPrefix("#EXT-X-SESSION-KEY:") {
                throw LiveTimeshiftError.unsupported("Protected streams play directly without a temporary rewind buffer.")
            } else if line.hasPrefix("#EXT-X-MAP:") {
                throw LiveTimeshiftError.unsupported("Fragmented MP4 streams currently play directly without a temporary rewind buffer.")
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                throw LiveTimeshiftError.unsupported("Byte-range streams currently play directly without a temporary rewind buffer.")
            } else if line.hasPrefix("#EXT-X-SKIP:") || line == "#EXT-X-I-FRAMES-ONLY" {
                throw LiveTimeshiftError.unsupported("This HLS playlist type currently plays directly without a temporary rewind buffer.")
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = try attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                if attrs["URI"] != nil {
                    throw LiveTimeshiftError.unsupported("Streams with separate audio or subtitle playlists play directly without a temporary rewind buffer.")
                }
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                variantAttributes = try attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                guard let value = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count)), value.isFinite, value >= 1, value <= 120, value.rounded() == value else {
                    throw LiveTimeshiftError.invalidPlaylist
                }
                target = value
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                guard segments.isEmpty, let value = Int64(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)), value >= 0 else {
                    throw LiveTimeshiftError.invalidPlaylist
                }
                sequence = value
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") {
                guard segments.isEmpty, let value = Int64(line.dropFirst("#EXT-X-DISCONTINUITY-SEQUENCE:".count)), value >= 0 else {
                    throw LiveTimeshiftError.invalidPlaylist
                }
                discontinuity = value
            } else if line == "#EXT-X-DISCONTINUITY" {
                guard discontinuity < Int64.max else { throw LiveTimeshiftError.invalidPlaylist }
                discontinuity += 1
            } else if line.hasPrefix("#EXTINF:") {
                guard let raw = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first,
                      let value = Double(raw),
                      value.isFinite, value >= 0.25, value <= 120 else { throw LiveTimeshiftError.invalidPlaylist }
                duration = value
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                date = String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))
            } else if line == "#EXT-X-GAP" {
                gap = true
            } else if line == "#EXT-X-ENDLIST" {
                ended = true
            } else if !line.hasPrefix("#") {
                let url = try resolve(line, relativeTo: baseURL)
                if let attrs = variantAttributes {
                    guard variants.count < segmentLimit else { throw LiveTimeshiftError.tooLarge }
                    variants.append((url, Int(attrs["AVERAGE-BANDWIDTH"] ?? attrs["BANDWIDTH"] ?? "0") ?? 0))
                    variantAttributes = nil
                } else {
                    guard let length = duration, sequence < Int64.max else { throw LiveTimeshiftError.invalidPlaylist }
                    guard segments.count < segmentLimit else { throw LiveTimeshiftError.tooLarge }
                    segments.append(RecordedHLSSegment(sequence: sequence, discontinuity: discontinuity,
                                                       duration: length, url: url, programDateTime: date, gap: gap))
                    sequence += 1
                    duration = nil
                    date = nil
                    gap = false
                }
            }
        }
        if !variants.isEmpty {
            guard segments.isEmpty else { throw LiveTimeshiftError.invalidPlaylist }
            let ordered = variants.sorted { $0.1 < $1.1 }
            let chosen = ordered.last(where: { $0.1 <= 8_000_000 }) ?? ordered[0]
            return .variant(chosen.0)
        }
        guard target > 0, !segments.isEmpty, duration == nil else { throw LiveTimeshiftError.invalidPlaylist }
        guard segments.allSatisfy({ $0.duration.rounded() <= target }) else { throw LiveTimeshiftError.invalidPlaylist }
        guard !ended else {
            throw LiveTimeshiftError.unsupported("This is an on-demand playlist; live rewind buffering is not needed.")
        }
        return .media(LiveHLSPlaylist(targetDuration: target, segments: segments, ended: ended))
    }

    private static func resolve(_ value: String, relativeTo base: URL) throws -> URL {
        guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw LiveTimeshiftError.invalidPlaylist
        }
        return url
    }

    private static func attributes(_ value: String) throws -> [String: String] {
        var result: [String: String] = [:]
        var part = ""
        var quoted = false
        var parts: [String] = []
        for char in value {
            if char == "\"" { quoted.toggle() }
            if char == ",", !quoted { parts.append(part); part = "" } else { part.append(char) }
        }
        guard !quoted else { throw LiveTimeshiftError.invalidPlaylist }
        parts.append(part)
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw LiveTimeshiftError.invalidPlaylist }
            result[String(pair[0])] = String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return result
    }
}

struct LiveTimeshiftSnapshot: Sendable, Equatable {
    var duration: Double = 0
    var bytes: Int = 0
    var targetDuration: Double = 6
    var recordedEnd: Double = 0
    var notice: String?
    var canRewind: Bool { duration > targetDuration * 3 }
}

struct LiveTimeshiftCodecFallback {
    private(set) var attempted = false

    mutating func consume(for failure: PlaybackFailure, recording: Bool) -> Bool {
        guard failure == .unsupported, recording, !attempted else { return false }
        attempted = true
        return true
    }
}

struct LiveTimeshiftSeekPolicy {
    static func clamp(_ position: Double, start: Double, end: Double) -> Double? {
        guard position.isFinite, start.isFinite, end.isFinite, end > start else { return nil }
        return min(max(position, start), max(start, end - 0.05))
    }

    static func restoredPosition(recordedPosition: Double, recordedEnd: Double, seekableStart: Double, seekableEnd: Double) -> Double? {
        clamp(seekableEnd - (recordedEnd - recordedPosition), start: seekableStart, end: seekableEnd)
    }

    static func livePosition(start: Double, end: Double, targetDuration: Double) -> Double? {
        guard targetDuration.isFinite, targetDuration > 0 else { return nil }
        return clamp(end - targetDuration * 3, start: start, end: end)
    }
}

/// Files referenced by a previous manifest remain leased for its full HLS retention interval.
/// The byte budget includes those leases, not only the currently advertised rewind window.
final class LiveTimeshiftRing {
    struct Entry {
        let segment: RecordedHLSSegment
        let name: String
        let bytes: Int
        let start: Double
        var advertisedUntil: TimeInterval = 0
    }

    let directory: URL
    let limits: LiveTimeshiftLimits
    private(set) var entries: [Entry] = []
    private var retired: [Entry] = []
    private var readerCounts: [String: Int] = [:]
    private(set) var totalBytes = 0
    private(set) var targetDuration: Double = 0
    private var nextStart: Double = 0
    private var localSequence: Int64 = 0
    private var lastSourceSequence: Int64?
    private var lastSourceDiscontinuity: Int64?
    private var localDiscontinuity: Int64 = 0
    private var dateOrigin: Date?
    private let dateFormatter = ISO8601DateFormatter()
    private(set) var notice: String?
    private var stopped = false

    init(directory: URL, limits: LiveTimeshiftLimits = LiveTimeshiftLimits()) throws {
        self.directory = directory
        self.limits = limits
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var snapshot: LiveTimeshiftSnapshot {
        LiveTimeshiftSnapshot(duration: entries.reduce(0) { $0 + $1.segment.duration }, bytes: totalBytes,
                              targetDuration: targetDuration, recordedEnd: nextStart, notice: notice)
    }

    func append(_ segment: RecordedHLSSegment, data: Data, target: Double, now: TimeInterval) throws {
        guard !stopped else { throw LiveTimeshiftError.stopped }
        guard data.count <= limits.segmentBytes else { throw LiveTimeshiftError.tooLarge }
        guard data.count > 0, target.isFinite, target > 0, segment.duration.isFinite, segment.duration >= 0.25 else { throw LiveTimeshiftError.invalidPlaylist }
        reap(now: now)
        targetDuration = max(targetDuration, target)
        // Reserve half the total budget for leases of recently removed manifests.
        let windowByteLimit = limits.bytes / 2
        guard data.count <= windowByteLimit else { throw LiveTimeshiftError.bufferLimit }
        while !entries.isEmpty,
              entries.count >= max(1, limits.segmentCount / 2) ||
              entries.reduce(0, { $0 + $1.bytes }) + data.count > windowByteLimit ||
              entries.reduce(0, { $0 + $1.segment.duration }) + segment.duration > limits.seconds {
            let removed = entries.removeFirst()
            retired.append(removed)
            notice = "The temporary buffer is full. Older content expires as capture continues."
        }
        reap(now: now)
        guard entries.count + retired.count < limits.segmentCount, totalBytes <= limits.bytes - data.count else {
            throw LiveTimeshiftError.bufferLimit
        }
        if let previous = lastSourceSequence,
           segment.sequence != previous + 1 || segment.discontinuity != lastSourceDiscontinuity {
            localDiscontinuity += 1
            notice = "Capture resumed after a stream gap; unavailable content was not recorded."
        }
        if dateOrigin == nil { dateOrigin = Date(timeIntervalSinceReferenceDate: now - segment.duration) }
        if let value = segment.programDateTime {
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = dateFormatter.date(from: value)
            dateFormatter.formatOptions = [.withInternetDateTime]
            if let date = date ?? dateFormatter.date(from: value) { dateOrigin = date.addingTimeInterval(-nextStart) }
        }
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = dateFormatter.string(from: dateOrigin!.addingTimeInterval(nextStart))
        let adjusted = RecordedHLSSegment(sequence: localSequence, discontinuity: localDiscontinuity,
                                          duration: segment.duration, url: segment.url,
                                          programDateTime: date, gap: false)
        let name = "segment-\(localSequence).ts"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        entries.append(Entry(segment: adjusted, name: name, bytes: data.count, start: nextStart))
        totalBytes += data.count
        nextStart += segment.duration
        localSequence += 1
        lastSourceSequence = segment.sequence
        lastSourceDiscontinuity = segment.discontinuity
    }

    func playlist(now: TimeInterval) throws -> Data {
        guard !stopped, let first = entries.first else { throw LiveTimeshiftError.stopped }
        let duration = snapshot.duration
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(Int(ceil(targetDuration)))",
                     "#EXT-X-MEDIA-SEQUENCE:\(first.segment.sequence)",
                     "#EXT-X-DISCONTINUITY-SEQUENCE:\(first.segment.discontinuity)"]
        var discontinuity = first.segment.discontinuity
        for index in entries.indices {
            let entry = entries[index]
            entries[index].advertisedUntil = max(entry.advertisedUntil, now + duration + entry.segment.duration)
            if entry.segment.discontinuity != discontinuity {
                lines.append("#EXT-X-DISCONTINUITY")
                discontinuity = entry.segment.discontinuity
            }
            if let date = entry.segment.programDateTime { lines.append("#EXT-X-PROGRAM-DATE-TIME:\(date)") }
            lines.append(String(format: "#EXTINF:%.6f,", entry.segment.duration))
            lines.append(entry.name)
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    func file(named name: String) -> URL? {
        guard !stopped, entries.contains(where: { $0.name == name }) || retired.contains(where: { $0.name == name }) else { return nil }
        return directory.appendingPathComponent(name)
    }

    func acquireFile(named name: String) -> URL? {
        guard let url = file(named: name) else { return nil }
        readerCounts[name, default: 0] += 1
        return url
    }

    func releaseFile(named name: String, now: TimeInterval) {
        if let readers = readerCounts[name] {
            if readers <= 1 { readerCounts.removeValue(forKey: name) }
            else { readerCounts[name] = readers - 1 }
        }
        reap(now: now)
        if stopped, totalBytes == 0 { try? FileManager.default.removeItem(at: directory) }
    }

    func reap(now: TimeInterval) {
        retired.removeAll { entry in
            guard (stopped || entry.advertisedUntil <= now), readerCounts[entry.name] == nil else { return false }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.name))
            totalBytes -= entry.bytes
            return true
        }
    }

    func stop() {
        stopped = true
        retired.append(contentsOf: entries)
        entries.removeAll()
        reap(now: .greatestFiniteMagnitude)
        if totalBytes == 0 { try? FileManager.default.removeItem(at: directory) }
    }
}

/// URLSession's delegate applies the cap while receiving, before buffering an oversized response.
final class BoundedHLSRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URL), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var responseURL: URL?
    private var failure: Error?
    private var cancelled = false

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    static func fetch(_ url: URL, maximumBytes: Int) async throws -> (Data, URL) {
        let request = BoundedHLSRequest(maximumBytes: maximumBytes)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { request.start(url, continuation: $0) }
        }, onCancel: { request.cancel() })
    }

    private func start(_ url: URL, continuation: CheckedContinuation<(Data, URL), Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var value = URLRequest(url: url)
        value.setValue("IPTVSmartersPro/1.1.1", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: value)
        self.task = task
        task.resume()
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(status) {
            failure = LiveTimeshiftError.network(status)
            completionHandler(.cancel)
        } else if response.expectedContentLength > maximumBytes {
            failure = LiveTimeshiftError.tooLarge
            completionHandler(.cancel)
        } else {
            responseURL = response.url
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.data.count <= maximumBytes - data.count else {
            failure = LiveTimeshiftError.tooLarge
            dataTask.cancel()
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        session.invalidateAndCancel()
        if let error = failure ?? error {
            continuation?.resume(throwing: error)
        } else if let responseURL {
            continuation?.resume(returning: (data, responseURL))
        } else {
            continuation?.resume(throwing: LiveTimeshiftError.invalidPlaylist)
        }
    }
}

actor LiveTimeshiftRecorder {
    static let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("BruTV-live-timeshift", isDirectory: true)
    private let limits: LiveTimeshiftLimits
    private let ring: LiveTimeshiftRing
    private let fetch: @Sendable (URL, Int) async throws -> (Data, URL)
    private let clock: @Sendable () -> TimeInterval
    private var latestSequence: Int64?
    private var latestURL: URL?
    private var stopped = false
    private var previousPollTime: TimeInterval?
    private var captureNotice: String?

    init(limits: LiveTimeshiftLimits = LiveTimeshiftLimits(), directory: URL? = nil,
         fetch: @escaping @Sendable (URL, Int) async throws -> (Data, URL) = {
             try await BoundedHLSRequest.fetch($0, maximumBytes: $1)
         }, clock: @escaping @Sendable () -> TimeInterval = { Date.timeIntervalSinceReferenceDate }) throws {
        self.limits = limits
        self.fetch = fetch
        self.clock = clock
        let directory = directory ?? Self.temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.ring = try LiveTimeshiftRing(directory: directory, limits: limits)
    }

    static func removeStaleSessions() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func capture(_ url: URL, timeout: TimeInterval) async throws -> Double {
        guard timeout > 0 else { throw LiveTimeshiftError.startupTimeout }
        return try await withThrowingTaskGroup(of: Double.self) { group in
            group.addTask { try await self.capture(url) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw LiveTimeshiftError.startupTimeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func capture(_ url: URL) async throws -> Double {
        guard !stopped else { throw LiveTimeshiftError.stopped }
        var source = latestURL ?? url
        var playlist: LiveHLSPlaylist?
        for _ in 0..<4 {
            let (data, resolvedURL) = try await fetch(source, limits.manifestBytes)
            try Task.checkCancellation()
            guard !stopped else { throw LiveTimeshiftError.stopped }
            switch try LiveHLSParser.parse(data, baseURL: resolvedURL, limit: limits.manifestBytes, segmentLimit: limits.segmentCount) {
            case .variant(let next): source = next
            case .media(let media): playlist = media
            }
            if playlist != nil { break }
        }
        guard let playlist else { throw LiveTimeshiftError.invalidPlaylist }
        latestURL = source
        let now = clock()
        if let previousPollTime, now - previousPollTime > max(30, playlist.targetDuration * 5) {
            captureNotice = "Capture paused while the app was inactive. Any missing live content is unavailable."
        }
        previousPollTime = now
        if let latestSequence, let last = playlist.segments.last, last.sequence < latestSequence {
            throw LiveTimeshiftError.unsupported("The provider reset its live timeline. Retry the channel to start a new buffer.")
        }
        var candidates = playlist.segments.filter { segment in latestSequence.map { segment.sequence > $0 } ?? true }
        if latestSequence == nil {
            var recent: [RecordedHLSSegment] = []
            var duration: Double = 0
            for segment in candidates.suffix(64).reversed() {
                recent.append(segment)
                duration += segment.duration
                if duration >= playlist.targetDuration * 3 { break }
            }
            if candidates.count > 64, duration < playlist.targetDuration * 3 {
                throw LiveTimeshiftError.unsupported("This provider requires an oversized startup window. Playing directly without rewind.")
            }
            candidates = Array(recent.reversed())
        }
        for segment in candidates {
            try Task.checkCancellation()
            guard !stopped else { throw LiveTimeshiftError.stopped }
            if segment.gap { latestSequence = segment.sequence; continue }
            let (data, _) = try await fetch(segment.url, limits.segmentBytes)
            try Task.checkCancellation()
            guard !stopped else { throw LiveTimeshiftError.stopped }
            try ring.append(segment, data: data, target: playlist.targetDuration, now: clock())
            latestSequence = segment.sequence
        }
        ring.reap(now: Date.timeIntervalSinceReferenceDate)
        return max(1, playlist.targetDuration / 2)
    }

    func snapshot() -> LiveTimeshiftSnapshot {
        var value = ring.snapshot
        value.notice = captureNotice ?? value.notice
        return value
    }

    func playlist() throws -> Data { try ring.playlist(now: clock()) }

    func openSegment(named name: String) throws -> (FileHandle, Int)? {
        guard let url = ring.acquireFile(named: name) else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            do {
                let length = try handle.seekToEnd()
                try handle.seek(toOffset: 0)
                return (handle, Int(length))
            } catch { try? handle.close(); throw error }
        } catch {
            ring.releaseFile(named: name, now: clock())
            throw error
        }
    }

    func releaseSegment(named name: String) { ring.releaseFile(named: name, now: clock()) }

    func segment(named name: String) throws -> Data? {
        guard let url = ring.file(named: name) else { return nil }
        return try Data(contentsOf: url)
    }

    func stop() {
        stopped = true
        ring.stop()
    }
}
