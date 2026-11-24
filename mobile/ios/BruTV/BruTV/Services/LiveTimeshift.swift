import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os

/// Relay and recorder diagnostics. Messages never contain URLs, because they hold credentials.
let relayLog = Logger(subsystem: "com.bvolpato.brutv", category: "live-relay")
#endif

struct LiveTimeshiftLimits: Sendable {
    #if os(tvOS)
    static let defaultBytes: Int = 96 * 1024 * 1024
    #else
    static let defaultBytes: Int = 256 * 1024 * 1024
    #endif

    var seconds: Double = 600
    var bytes: Int = LiveTimeshiftLimits.defaultBytes
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
    case stalePlaylist
    case bufferLimit
    case stopped

    var errorDescription: String? {
        switch self {
        case .unsupported(let reason): return reason
        case .invalidPlaylist: return "This provider does not offer a supported live HLS playlist."
        case .tooLarge: return "A provider response exceeded the temporary-buffer limit."
        case .network: return "The provider could not supply the live buffer."
        case .startupTimeout: return "The temporary live buffer took too long to start."
        case .stalePlaylist: return "The live stream stopped publishing new segments."
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
        guard var text = String(data: data, encoding: .utf8) else { throw LiveTimeshiftError.invalidPlaylist }
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
        for line in lines.dropFirst() {
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
                let rawTarget = line.dropFirst("#EXT-X-TARGETDURATION:".count).trimmingCharacters(in: .whitespaces)
                guard let value = Double(rawTarget), value.isFinite, value > 0, value <= 120 else {
                    throw LiveTimeshiftError.invalidPlaylist
                }
                target = max(1, ceil(value))
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let rawSeq = line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count).trimmingCharacters(in: .whitespaces)
                guard segments.isEmpty, let value = Int64(rawSeq), value >= 0 else {
                    throw LiveTimeshiftError.invalidPlaylist
                }
                sequence = value
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") {
                let rawDisc = line.dropFirst("#EXT-X-DISCONTINUITY-SEQUENCE:".count).trimmingCharacters(in: .whitespaces)
                guard segments.isEmpty, let value = Int64(rawDisc), value >= 0 else {
                    throw LiveTimeshiftError.invalidPlaylist
                }
                discontinuity = value
            } else if line == "#EXT-X-DISCONTINUITY" {
                guard discontinuity < Int64.max else { throw LiveTimeshiftError.invalidPlaylist }
                discontinuity += 1
            } else if line.hasPrefix("#EXTINF:") {
                guard let raw = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespaces),
                      let value = Double(raw),
                      value.isFinite, value >= 0.25, value <= 120 else { throw LiveTimeshiftError.invalidPlaylist }
                duration = value
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                date = String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count)).trimmingCharacters(in: .whitespaces)
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
        // Tolerate slight segment duration overshoot over declared targetDuration by adjusting
        // effective targetDuration (within the 120s safety ceiling) instead of rejecting the stream.
        let maxSegmentDuration = segments.map(\.duration).max() ?? target
        let effectiveTarget = min(120, max(target, ceil(maxSegmentDuration)))
        guard !ended else {
            throw LiveTimeshiftError.unsupported("This is an on-demand playlist; live rewind buffering is not needed.")
        }
        return .media(LiveHLSPlaylist(targetDuration: effectiveTarget, segments: segments, ended: ended))
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
    var canRewind: Bool { duration > 0 }
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
    private var entryStorage: [Entry] = []
    private var entryHead: Int = 0
    private var retired: [Entry] = []
    private var fileIndex: [String: URL] = [:]
    private var readerCounts: [String: Int] = [:]
    private(set) var activeBytes: Int = 0
    private(set) var activeDuration: Double = 0
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

    var entries: ArraySlice<Entry> {
        entryStorage[entryHead...]
    }

    init(directory: URL, limits: LiveTimeshiftLimits = LiveTimeshiftLimits()) throws {
        self.directory = directory
        self.limits = limits
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var snapshot: LiveTimeshiftSnapshot {
        LiveTimeshiftSnapshot(duration: activeDuration, bytes: totalBytes,
                              targetDuration: targetDuration, recordedEnd: nextStart, notice: notice)
    }

    func nextSegmentFileSpec() throws -> (name: String, url: URL) {
        guard !stopped else { throw LiveTimeshiftError.stopped }
        let name = "segment-\(localSequence).ts"
        return (name, directory.appendingPathComponent(name))
    }

    func append(_ segment: RecordedHLSSegment, data: Data, target: Double, now: TimeInterval) throws {
        guard !stopped else { throw LiveTimeshiftError.stopped }
        try validate(segment: segment, byteCount: data.count, target: target)
        let name = "segment-\(localSequence).ts"
        let fileURL = directory.appendingPathComponent(name)
        // Each segment has a unique monotonically increasing filename and is published only after write completes.
        try data.write(to: fileURL)
        do {
            try publishPrepared(segment, name: name, fileURL: fileURL, byteCount: data.count, target: target, now: now)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    func appendPrewritten(
        _ segment: RecordedHLSSegment,
        name: String,
        fileURL: URL,
        byteCount: Int,
        target: Double,
        now: TimeInterval
    ) throws {
        do {
            guard !stopped else { throw LiveTimeshiftError.stopped }
            try validate(segment: segment, byteCount: byteCount, target: target)
            try publishPrepared(segment, name: name, fileURL: fileURL, byteCount: byteCount, target: target, now: now)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    private func validate(segment: RecordedHLSSegment, byteCount: Int, target: Double) throws {
        guard byteCount <= limits.segmentBytes else { throw LiveTimeshiftError.tooLarge }
        guard byteCount > 0, target.isFinite, target > 0, segment.duration.isFinite, segment.duration >= 0.25 else {
            throw LiveTimeshiftError.invalidPlaylist
        }
        let windowByteLimit = limits.bytes / 2
        guard byteCount <= windowByteLimit else { throw LiveTimeshiftError.bufferLimit }
    }

    private func publishPrepared(
        _ segment: RecordedHLSSegment,
        name: String,
        fileURL: URL,
        byteCount: Int,
        target: Double,
        now: TimeInterval
    ) throws {
        reap(now: now)
        targetDuration = max(targetDuration, target)
        // Reserve half the total budget for leases of recently removed manifests.
        let windowByteLimit = limits.bytes / 2
        let maxActiveSegments = max(1, limits.segmentCount / 2)
        while entryHead < entryStorage.count,
              (entryStorage.count - entryHead) >= maxActiveSegments ||
              activeBytes + byteCount > windowByteLimit ||
              activeDuration + segment.duration > limits.seconds {
            let removed = entryStorage[entryHead]
            entryHead += 1
            activeBytes -= removed.bytes
            activeDuration = max(0, activeDuration - removed.segment.duration)
            retired.append(removed)
            notice = "The temporary buffer is full. Older content expires as capture continues."
        }
        compactEntriesIfNeeded()
        reap(now: now)
        guard (entryStorage.count - entryHead) + retired.count < limits.segmentCount,
              totalBytes <= limits.bytes - byteCount else {
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
        entryStorage.append(Entry(segment: adjusted, name: name, bytes: byteCount, start: nextStart))
        fileIndex[name] = fileURL
        activeBytes += byteCount
        activeDuration += segment.duration
        totalBytes += byteCount
        nextStart += segment.duration
        localSequence += 1
        lastSourceSequence = segment.sequence
        lastSourceDiscontinuity = segment.discontinuity
    }

    private func compactEntriesIfNeeded() {
        if entryHead == entryStorage.count {
            entryStorage.removeAll(keepingCapacity: true)
            entryHead = 0
        } else if entryHead >= 64 && entryHead * 2 >= entryStorage.count {
            entryStorage.removeFirst(entryHead)
            entryHead = 0
        }
    }

    func playlist(now: TimeInterval) throws -> Data {
        guard !stopped, entryHead < entryStorage.count else { throw LiveTimeshiftError.stopped }
        let first = entryStorage[entryHead]
        let duration = activeDuration
        var lines: [String] = []
        lines.reserveCapacity((entryStorage.count - entryHead) * 3 + 6)
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:3")
        lines.append("#EXT-X-TARGETDURATION:\(Int(ceil(targetDuration)))")
        lines.append("#EXT-X-MEDIA-SEQUENCE:\(first.segment.sequence)")
        lines.append("#EXT-X-DISCONTINUITY-SEQUENCE:\(first.segment.discontinuity)")
        var discontinuity = first.segment.discontinuity
        for index in entryHead..<entryStorage.count {
            let entry = entryStorage[index]
            entryStorage[index].advertisedUntil = max(entry.advertisedUntil, now + duration + entry.segment.duration)
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
        guard !stopped else { return nil }
        return fileIndex[name]
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
            let url = fileIndex.removeValue(forKey: entry.name) ?? directory.appendingPathComponent(entry.name)
            try? FileManager.default.removeItem(at: url)
            totalBytes -= entry.bytes
            return true
        }
    }

    func stop() {
        stopped = true
        if entryHead < entryStorage.count {
            retired.append(contentsOf: entryStorage[entryHead...])
        }
        entryStorage.removeAll()
        entryHead = 0
        activeBytes = 0
        activeDuration = 0
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
        value.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
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

/// Reuses one ephemeral URLSession with a single delegate and OperationQueue across all
/// manifest polls and segment downloads for a `LiveTimeshiftRecorder`, preserving TCP/TLS
/// keep-alive connections behind Cloudflare and reverse proxies.
final class BoundedHLSSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class TaskState {
        let maximumBytes: Int
        var continuation: CheckedContinuation<(Data, URL), Error>?
        weak var task: URLSessionDataTask?
        var data = Data()
        var responseURL: URL?
        var failure: Error?
        var cancelled = false

        init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }
    }

    private let lock = NSLock()
    private var session: URLSession?
    private var states: [Int: TaskState] = [:]
    private var invalidated = false

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 45
        configuration.httpMaximumConnectionsPerHost = 2
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func fetch(_ url: URL, maximumBytes: Int) async throws -> (Data, URL) {
        let state = TaskState(maximumBytes: maximumBytes)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if invalidated || state.cancelled {
                    lock.unlock()
                    continuation.resume(throwing: invalidated ? LiveTimeshiftError.stopped : CancellationError())
                    return
                }
                guard let session = self.session else {
                    lock.unlock()
                    continuation.resume(throwing: LiveTimeshiftError.stopped)
                    return
                }
                state.continuation = continuation
                var request = URLRequest(url: url)
                request.setValue("IPTVSmartersPro/1.1.1", forHTTPHeaderField: "User-Agent")
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                let task = session.dataTask(with: request)
                state.task = task
                states[task.taskIdentifier] = state
                lock.unlock()
                task.resume()
            }
        }, onCancel: { [weak self] in
            guard let self else { return }
            self.lock.lock()
            state.cancelled = true
            let task = state.task
            self.lock.unlock()
            task?.cancel()
        })
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        let session = self.session
        self.session = nil
        let pending = Array(states.values)
        states.removeAll()
        var continuations: [CheckedContinuation<(Data, URL), Error>] = []
        for state in pending {
            if let continuation = state.continuation {
                state.continuation = nil
                continuations.append(continuation)
            }
        }
        lock.unlock()
        for continuation in continuations {
            continuation.resume(throwing: LiveTimeshiftError.stopped)
        }
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard let state = states[dataTask.taskIdentifier] else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(status) {
            state.failure = LiveTimeshiftError.network(status)
            lock.unlock()
            completionHandler(.cancel)
        } else if response.expectedContentLength > state.maximumBytes {
            state.failure = LiveTimeshiftError.tooLarge
            lock.unlock()
            completionHandler(.cancel)
        } else {
            state.responseURL = response.url
            lock.unlock()
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let state = states[dataTask.taskIdentifier] else {
            lock.unlock()
            dataTask.cancel()
            return
        }
        guard state.data.count <= state.maximumBytes - data.count else {
            state.failure = LiveTimeshiftError.tooLarge
            lock.unlock()
            dataTask.cancel()
            return
        }
        state.data.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        let continuation = state?.continuation
        state?.continuation = nil
        let failure = state?.failure
        let data = state?.data ?? Data()
        let responseURL = state?.responseURL
        lock.unlock()
        guard let continuation else { return }
        if let error = failure ?? error {
            continuation.resume(throwing: error)
        } else if let responseURL {
            continuation.resume(returning: (data, responseURL))
        } else {
            continuation.resume(throwing: LiveTimeshiftError.invalidPlaylist)
        }
    }
}

private final class ActiveTimeshiftRegistry: @unchecked Sendable {
    static let shared = ActiveTimeshiftRegistry()
    private let lock = NSLock()
    private var names: Set<String> = []

    func register(_ name: String) {
        lock.lock()
        names.insert(name)
        lock.unlock()
    }

    func unregister(_ name: String) {
        lock.lock()
        names.remove(name)
        lock.unlock()
    }

    func snapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return names
    }
}

actor LiveTimeshiftRecorder {
    static let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("BruTV-live-timeshift", isDirectory: true)
    private let limits: LiveTimeshiftLimits
    private let ring: LiveTimeshiftRing
    private let hlsSession: BoundedHLSSession?
    private let registeredDirectoryName: String?
    private let fetch: @Sendable (URL, Int) async throws -> (Data, URL)
    private let clock: @Sendable () -> TimeInterval
    private var latestSequence: Int64?
    private var latestURL: URL?
    private var lastNewSegmentAt: TimeInterval?
    private var stopped = false
    private var previousPollTime: TimeInterval?
    private var captureNotice: String?

    init(limits: LiveTimeshiftLimits = LiveTimeshiftLimits(), directory: URL? = nil,
         fetch: (@Sendable (URL, Int) async throws -> (Data, URL))? = nil,
         clock: @escaping @Sendable () -> TimeInterval = { Date.timeIntervalSinceReferenceDate }) throws {
        self.limits = limits
        self.clock = clock
        if let fetch {
            self.hlsSession = nil
            self.fetch = fetch
        } else {
            let sharedSession = BoundedHLSSession()
            self.hlsSession = sharedSession
            self.fetch = { try await sharedSession.fetch($0, maximumBytes: $1) }
        }
        let targetDirectory: URL
        if let directory {
            targetDirectory = directory
            self.registeredDirectoryName = nil
        } else {
            let name = UUID().uuidString
            ActiveTimeshiftRegistry.shared.register(name)
            self.registeredDirectoryName = name
            targetDirectory = Self.temporaryRoot.appendingPathComponent(name, isDirectory: true)
        }
        do {
            self.ring = try LiveTimeshiftRing(directory: targetDirectory, limits: limits)
        } catch {
            if let registeredDirectoryName {
                ActiveTimeshiftRegistry.shared.unregister(registeredDirectoryName)
            }
            self.hlsSession?.invalidate()
            throw error
        }
    }

    deinit {
        hlsSession?.invalidate()
    }

    static func removeStaleSessions() {
        let active = ActiveTimeshiftRegistry.shared.snapshot()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where !active.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
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
        do {
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
            if let currentLatest = latestSequence, let last = playlist.segments.last, last.sequence < currentLatest {
                latestSequence = nil
                captureNotice = "Capture resumed after a stream gap; unavailable content was not recorded."
            }
            var candidates = playlist.segments.filter { segment in latestSequence.map { segment.sequence > $0 } ?? true }
            if latestSequence == nil {
                // Cap initial blocking startup window so long-segment Xtream streams (e.g. 6-10s)
                // do not time out downloading 30s of media before starting playback.
                let startupWindow = min(8.0, playlist.targetDuration * 3)
                var recent: [RecordedHLSSegment] = []
                var duration: Double = 0
                for segment in candidates.suffix(64).reversed() {
                    recent.append(segment)
                    duration += segment.duration
                    if duration >= startupWindow { break }
                }
                if candidates.count > 64, duration < startupWindow {
                    throw LiveTimeshiftError.unsupported("This provider requires an oversized startup window. Playing directly without rewind.")
                }
                candidates = Array(recent.reversed())
            }
            if candidates.isEmpty {
                let staleThreshold = max(20.0, playlist.targetDuration * 3)
                if let since = lastNewSegmentAt {
                    if now - since >= staleThreshold {
                        latestURL = nil
                        throw LiveTimeshiftError.stalePlaylist
                    }
                } else {
                    lastNewSegmentAt = now
                }
            } else {
                for segment in candidates {
                    try Task.checkCancellation()
                    guard !stopped else { throw LiveTimeshiftError.stopped }
                    if segment.gap {
                        latestSequence = segment.sequence
                        lastNewSegmentAt = clock()
                        continue
                    }
                    let (data, _) = try await fetch(segment.url, limits.segmentBytes)
                    try Task.checkCancellation()
                    guard !stopped else { throw LiveTimeshiftError.stopped }
                    let segmentNow = clock()
                    try await writeAndPublish(segment, data: data, target: playlist.targetDuration, now: segmentNow)
                    latestSequence = segment.sequence
                    lastNewSegmentAt = segmentNow
                }
            }
            ring.reap(now: clock())
            return max(1, playlist.targetDuration / 2)
        } catch {
            // Clear cached redirect/variant URL so the next retry re-resolves the original entry URL
            // instead of hammering an expired edge token URL.
            latestURL = nil
            throw error
        }
    }

    private func writeAndPublish(
        _ segment: RecordedHLSSegment,
        data: Data,
        target: Double,
        now: TimeInterval
    ) async throws {
        let (name, fileURL) = try ring.nextSegmentFileSpec()
        // Write segment data off the actor executor so local HTTP manifest/segment reads stay non-blocking.
        try await Task.detached(priority: .userInitiated) {
            try data.write(to: fileURL)
        }.value
        if stopped || Task.isCancelled {
            try? FileManager.default.removeItem(at: fileURL)
            throw LiveTimeshiftError.stopped
        }
        try ring.appendPrewritten(segment, name: name, fileURL: fileURL, byteCount: data.count, target: target, now: now)
        notifyStateWaiters()
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
        hlsSession?.invalidate()
        ring.stop()
        if let registeredDirectoryName {
            ActiveTimeshiftRegistry.shared.unregister(registeredDirectoryName)
        }
        notifyStateWaiters()
    }

    private var relayFailure: Error?
    private var relaySequence: Int64 = 0
    private var relayDiscontinuity: Int64 = 0
    private var stateWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private func notifyStateWaiters() {
        guard !stateWaiters.isEmpty else { return }
        let waiters = Array(stateWaiters.values)
        stateWaiters.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }

    private func removeStateWaiter(_ id: UUID) {
        if let continuation = stateWaiters.removeValue(forKey: id) {
            continuation.resume()
        }
    }

    private func waitForStateChange() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if stopped || relayFailure != nil || Task.isCancelled {
                    continuation.resume()
                    return
                }
                stateWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.removeStateWaiter(waiterID) }
        }
    }

    /// Event-driven readiness notification: returns immediately once the first segment is available,
    /// or throws if capture fails, stops, or exceeds `timeout`.
    func waitForFirstSegment(timeout: TimeInterval) async throws -> LiveTimeshiftSnapshot {
        if let failure = relayFailure { throw failure }
        if stopped { throw LiveTimeshiftError.stopped }
        let current = snapshot()
        if current.duration > 0 { return current }

        guard timeout > 0 else { throw LiveTimeshiftError.startupTimeout }
        return try await withThrowingTaskGroup(of: LiveTimeshiftSnapshot.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    if let failure = await self.transportStreamFailure() { throw failure }
                    if await self.isStopped() { throw LiveTimeshiftError.stopped }
                    let snap = await self.snapshot()
                    if snap.duration > 0 { return snap }
                    await self.waitForStateChange()
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw LiveTimeshiftError.startupTimeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Waits for a new segment to land (or `timeout` to elapse) without busy polling.
    func waitForSnapshotUpdate(afterRecordedEnd previousEnd: Double, timeout: TimeInterval = 2.0) async throws -> LiveTimeshiftSnapshot {
        if let failure = relayFailure { throw failure }
        if stopped { throw LiveTimeshiftError.stopped }
        let current = snapshot()
        if current.recordedEnd > previousEnd { return current }

        return try await withThrowingTaskGroup(of: LiveTimeshiftSnapshot.self) { group in
            group.addTask {
                await self.waitForStateChange()
                if let failure = await self.transportStreamFailure() { throw failure }
                if await self.isStopped() { throw LiveTimeshiftError.stopped }
                return await self.snapshot()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                if let failure = await self.transportStreamFailure() { throw failure }
                return await self.snapshot()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func isStopped() -> Bool { stopped }

    func clearTransportStreamFailure() {
        relayFailure = nil
    }

    /// Reads a continuous MPEG-TS response and records it as HLS segments until stopped.
    /// It reconnects after a dropped response and gives up after 3 failures in a row.
    /// `transportStreamFailure()` returns the reason after it gives up.
    func captureTransportStream(
        _ url: URL,
        segmentStallTimeout: TimeInterval = 15,
        reconnectBackoff: TimeInterval = 1.0,
        open: @Sendable (URL) -> AsyncThrowingStream<Data, Error> = { TransportStreamRequest.stream($0) }
    ) async {
        var failures = 0
        while !stopped, !Task.isCancelled {
            var segmenter = MPEGTSSegmenter()
            var bytes = 0
            var lastSegmentTime = clock()
            #if canImport(os)
            relayLog.info("relay connecting, attempt \(failures + 1, privacy: .public)")
            #endif
            do {
                for try await chunk in open(url) {
                    guard !stopped, !Task.isCancelled else { return }
                    bytes += chunk.count
                    let emitted = segmenter.append(chunk)
                    for segment in emitted {
                        let now = clock()
                        if segment.discontinuity, relaySequence > 0 {
                            relayDiscontinuity += 1
                        }
                        let recorded = RecordedHLSSegment(sequence: relaySequence, discontinuity: relayDiscontinuity,
                                                          duration: segment.duration, url: url,
                                                          programDateTime: nil, gap: false)
                        do {
                            // Keep #EXT-X-TARGETDURATION stable across typical 2-4s provider GOPs
                            // instead of mutating upward on every minor GOP fluctuation.
                            try await writeAndPublish(recorded, data: segment.data, target: max(4, ceil(segment.duration)), now: now)
                        } catch {
                            #if canImport(os)
                            relayLog.error("relay buffer rejected a segment: \(String(describing: error), privacy: .public)")
                            #endif
                            relayFailure = error
                            notifyStateWaiters()
                            return
                        }
                        #if canImport(os)
                        relayLog.debug("relay segment \(self.relaySequence, privacy: .public): \(segment.duration, privacy: .public)s, \(segment.data.count, privacy: .public) bytes")
                        #endif
                        lastSegmentTime = now
                        relaySequence += 1
                        failures = 0
                    }
                    if bytes > 4 * 1024 * 1024, !segmenter.hasProgram {
                        relayFailure = LiveTimeshiftError.unsupported("The provider's .ts stream is not MPEG-TS video.")
                        notifyStateWaiters()
                        return
                    }
                    if emitted.isEmpty, bytes > 0, clock() - lastSegmentTime > segmentStallTimeout {
                        throw LiveTimeshiftError.startupTimeout
                    }
                }
                throw LiveTimeshiftError.network(0)
            } catch {
                if stopped || Task.isCancelled { return }
                #if canImport(os)
                relayLog.error("relay response ended after \(bytes, privacy: .public) bytes: \(String(describing: error), privacy: .public)")
                #endif
                if case LiveTimeshiftError.network(let status) = error, status == 401 || status == 404 {
                    relayFailure = error
                    notifyStateWaiters()
                    return
                }
                failures += 1
                let maxFailures: Int
                if case LiveTimeshiftError.network(let status) = error, status == 403 {
                    maxFailures = 2
                } else {
                    maxFailures = 3
                }
                if failures >= maxFailures {
                    relayFailure = error
                    notifyStateWaiters()
                    return
                }
            }
            // A new response restarts the timeline, so mark a discontinuity.
            relayDiscontinuity += 1
            if reconnectBackoff > 0 {
                try? await Task.sleep(nanoseconds: UInt64(Double(failures) * reconnectBackoff * 1_000_000_000))
            }
        }
    }

    func transportStreamFailure() -> Error? { relayFailure }
}
