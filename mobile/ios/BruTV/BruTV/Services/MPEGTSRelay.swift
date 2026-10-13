import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// When to play a live channel through the MPEG-TS relay.
///
/// Xtream providers serve each live channel twice: as HLS (`/live/u/p/1.m3u8`) and as one
/// continuous MPEG-TS response (`/live/u/p/1.ts`). Many providers make HLS segments on demand,
/// so a segment can take 40 seconds to arrive, while the `.ts` response streams at once.
/// IPTV players such as IPTV Smarters use the `.ts` response. AVPlayer cannot play it
/// directly, so BruTV cuts it into local HLS segments.
enum TransportStreamRelayPolicy {
    /// The `.ts` URL for an Xtream live URL, or nil when the URL has no `.ts` form.
    static func relayURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.contains("/live/") else { return nil }
        let path = components.path
        let lowered = path.lowercased()
        if lowered.hasSuffix(".ts") { return url }
        guard lowered.hasSuffix(".m3u8") else { return nil }
        components.path = String(path.dropLast(5)) + ".ts"
        return components.url
    }
}

/// A finished piece of a continuous MPEG-TS stream, ready to serve as an HLS segment.
struct TransportStreamSegment: Equatable, Sendable {
    let data: Data
    let duration: Double
}

/// Cuts a continuous MPEG-TS stream into HLS segments.
///
/// Each segment starts at a video keyframe and begins with a copy of the stream's PAT and
/// PMT, so a player can start decoding at any segment. Durations come from the PES
/// timestamps (90 kHz). Bytes before the first keyframe are dropped. A timestamp jump
/// (a provider restart) drops the unfinished segment and starts again at the next keyframe.
struct MPEGTSSegmenter {
    static let packetSize = 188
    private static let ptsWrap: Int64 = 1 << 33

    let targetDuration: Double
    /// Past this duration, cut at any PES start even without a detected keyframe.
    let maximumDuration: Double

    private var pending = Data()
    private var pat: [UInt8]?
    private var pmt: [UInt8]?
    private var pmtPID: Int?
    private var timingPID: Int?
    private var timingIsVideo = false
    private var videoStreamType: UInt8 = 0
    private var current: [UInt8] = []
    private var currentStartPTS: Int64?

    init(targetDuration: Double = 2, maximumDuration: Double = 12) {
        self.targetDuration = targetDuration
        self.maximumDuration = max(maximumDuration, targetDuration)
    }

    /// True after the PMT names a stream that BruTV can time.
    var hasProgram: Bool { timingPID != nil }

    mutating func append(_ data: Data) -> [TransportStreamSegment] {
        pending.append(data)
        var segments: [TransportStreamSegment] = []
        var offset = pending.startIndex
        let end = pending.endIndex
        while end - offset >= Self.packetSize {
            // Resynchronize on a sync byte that the next packet confirms.
            guard pending[offset] == 0x47,
                  end - offset < Self.packetSize * 2 || pending[offset + Self.packetSize] == 0x47 else {
                offset += 1
                continue
            }
            let packet = [UInt8](pending[offset..<(offset + Self.packetSize)])
            if let segment = process(packet) { segments.append(segment) }
            offset += Self.packetSize
        }
        pending = Data(pending[offset..<end])
        return segments
    }

    private mutating func process(_ packet: [UInt8]) -> TransportStreamSegment? {
        var p = packet
        let pid = Int(p[1] & 0x1F) << 8 | Int(p[2])
        let unitStart = p[1] & 0x40 != 0
        let adaptation = (p[3] >> 4) & 0x3
        var payload = 4
        var randomAccess = false
        if adaptation & 0x2 != 0 {
            let length = Int(p[4])
            if length > 0 { randomAccess = p[5] & 0x40 != 0 }
            payload = 5 + length
        }
        let hasPayload = adaptation & 0x1 != 0 && payload < Self.packetSize
        var emitted: TransportStreamSegment?

        if pid == 0, unitStart, hasPayload {
            parsePAT(p, payload: payload)
            pat = p
        } else if pid == pmtPID, unitStart, hasPayload {
            parsePMT(p, payload: payload)
            pmt = p
        } else if pid == timingPID, unitStart, hasPayload, let pts = Self.presentationTime(p, payload: payload) {
            if videoStreamType == 0x1B { Self.moveAccessUnitDelimiterFirst(&p, payload: payload) }
            let keyframe = !timingIsVideo || randomAccess || containsKeyframe(p, payload: payload)
            if let start = currentStartPTS {
                let duration = Double((pts - start + Self.ptsWrap) % Self.ptsWrap) / 90_000
                if duration > 60 {
                    // The timeline jumped. Start again at the next keyframe.
                    current = []
                    currentStartPTS = nil
                    if keyframe { startSegment(at: pts) }
                } else if (keyframe && duration >= targetDuration) || duration >= maximumDuration {
                    if duration >= 0.25 {
                        emitted = TransportStreamSegment(data: Data(current), duration: duration)
                    }
                    startSegment(at: pts)
                }
            } else if keyframe {
                startSegment(at: pts)
            }
        }

        if currentStartPTS != nil { current.append(contentsOf: p) }
        return emitted
    }

    private mutating func startSegment(at pts: Int64) {
        guard let pat, let pmt else { return }
        current = pat + pmt
        current.reserveCapacity(1024 * 1024)
        currentStartPTS = pts
    }

    /// Start of the section after the pointer field, or nil when it does not fit.
    private static func sectionStart(_ p: [UInt8], payload: Int) -> Int? {
        let start = payload + 1 + Int(p[payload])
        return start + 3 < packetSize ? start : nil
    }

    private mutating func parsePAT(_ p: [UInt8], payload: Int) {
        guard let s = Self.sectionStart(p, payload: payload), p[s] == 0x00 else { return }
        let sectionLength = Int(p[s + 1] & 0x0F) << 8 | Int(p[s + 2])
        let end = min(s + 3 + sectionLength - 4, Self.packetSize)
        var index = s + 8
        while index + 4 <= end {
            let program = Int(p[index]) << 8 | Int(p[index + 1])
            let pid = Int(p[index + 2] & 0x1F) << 8 | Int(p[index + 3])
            if program != 0 {
                pmtPID = pid
                return
            }
            index += 4
        }
    }

    private mutating func parsePMT(_ p: [UInt8], payload: Int) {
        guard let s = Self.sectionStart(p, payload: payload), p[s] == 0x02, s + 12 <= Self.packetSize else { return }
        let sectionLength = Int(p[s + 1] & 0x0F) << 8 | Int(p[s + 2])
        let programInfoLength = Int(p[s + 10] & 0x0F) << 8 | Int(p[s + 11])
        let end = min(s + 3 + sectionLength - 4, Self.packetSize)
        var index = s + 12 + programInfoLength
        var audio: Int?
        while index + 5 <= end {
            let type = p[index]
            let pid = Int(p[index + 1] & 0x1F) << 8 | Int(p[index + 2])
            let infoLength = Int(p[index + 3] & 0x0F) << 8 | Int(p[index + 4])
            switch type {
            case 0x01, 0x02, 0x10, 0x1B, 0x24:
                timingPID = pid
                timingIsVideo = true
                videoStreamType = type
                return
            case 0x03, 0x04, 0x0F, 0x11, 0x81:
                if audio == nil { audio = pid }
            default:
                break
            }
            index += 5 + infoLength
        }
        if let audio {
            timingPID = audio
            timingIsVideo = false
        }
    }

    static func presentationTime(_ p: [UInt8], payload q: Int) -> Int64? {
        guard q + 14 <= packetSize, p[q] == 0, p[q + 1] == 0, p[q + 2] == 1, p[q + 7] & 0x80 != 0 else { return nil }
        let pts = Int64(p[q + 9] & 0x0E) << 29 | Int64(p[q + 10]) << 22 | Int64(p[q + 11] & 0xFE) << 14
            | Int64(p[q + 12]) << 7 | Int64(p[q + 13]) >> 1
        return pts
    }

    /// Some providers send H.264 keyframes as SPS, PPS, AUD, SEI, IDR. The standard puts the
    /// access unit delimiter (AUD) first. ffmpeg and VLC accept the wrong order, but Apple's
    /// decoder then shows no picture while the sound plays. This moves the AUD in front of
    /// the parameter sets. The bytes only change places, so packet sizes stay the same.
    /// Works on the first packet of a PES, where these NAL units are.
    static func moveAccessUnitDelimiterFirst(_ p: inout [UInt8], payload q: Int) {
        guard q + 9 <= packetSize else { return }
        let esStart = q + 9 + Int(p[q + 8])
        guard esStart < packetSize else { return }
        // Start of each NAL unit (its start code, with the 4-byte form's leading zero).
        var starts: [(begin: Int, type: UInt8)] = []
        var index = esStart
        while index + 3 < packetSize {
            if p[index] == 0, p[index + 1] == 0, p[index + 2] == 1 {
                let begin = index > esStart && p[index - 1] == 0 ? index - 1 : index
                starts.append((begin, p[index + 3] & 0x1F))
                index += 3
            } else {
                index += 1
            }
        }
        // Only parameter sets (SPS 7, PPS 8) may come before the AUD (9) here, and the AUD
        // must end inside this packet.
        guard let audIndex = starts.firstIndex(where: { $0.type == 9 }), audIndex > 0,
              audIndex + 1 < starts.count,
              starts[..<audIndex].allSatisfy({ $0.type == 7 || $0.type == 8 }) else { return }
        let first = starts[0].begin
        let aud = Array(p[starts[audIndex].begin..<starts[audIndex + 1].begin])
        let parameterSets = Array(p[first..<starts[audIndex].begin])
        p.replaceSubrange(first..<starts[audIndex + 1].begin, with: aud + parameterSets)
    }

    /// Looks for a keyframe start in the first packet of a video PES.
    private func containsKeyframe(_ p: [UInt8], payload q: Int) -> Bool {
        guard q + 9 <= Self.packetSize else { return false }
        var index = q + 9 + Int(p[q + 8])
        while index + 3 < Self.packetSize {
            if p[index] == 0, p[index + 1] == 0, p[index + 2] == 1 {
                let header = p[index + 3]
                switch videoStreamType {
                case 0x1B: // H.264: IDR slice or sequence parameter set
                    let type = header & 0x1F
                    if type == 5 || type == 7 { return true }
                case 0x24: // HEVC: IRAP slice or parameter sets
                    let type = (header >> 1) & 0x3F
                    if (16...21).contains(type) || type == 32 || type == 33 { return true }
                default: // MPEG-1/2 sequence header, MPEG-4 visual object sequence
                    if header == 0xB3 || header == 0xB0 { return true }
                }
                index += 3
            } else {
                index += 1
            }
        }
        return false
    }
}

/// Streams one HTTP response as chunks. URLSession times out when no data arrives for
/// `idleTimeout` seconds, but the response itself can run for hours.
final class TransportStreamRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var failure: Error?

    static func stream(_ url: URL, idleTimeout: TimeInterval = 15) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let request = TransportStreamRequest(continuation: continuation)
            continuation.onTermination = { _ in request.cancel() }
            request.start(url, idleTimeout: idleTimeout)
        }
    }

    private init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    private func start(_ url: URL, idleTimeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url)
        request.setValue("IPTVSmartersPro/1.1.1", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        task.resume()
    }

    private func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200...299).contains(status) {
            completionHandler(.allow)
        } else {
            failure = LiveTimeshiftError.network(status)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if let error = failure ?? error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
