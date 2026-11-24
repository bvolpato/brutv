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
    let discontinuity: Bool

    init(data: Data, duration: Double, discontinuity: Bool = false) {
        self.data = data
        self.duration = duration
        self.discontinuity = discontinuity
    }
}

/// Cuts a continuous MPEG-TS stream into HLS segments without per-packet heap allocations.
///
/// Each segment starts at a video keyframe and begins with a copy of the stream's PAT and
/// PMT, so a player can start decoding at any segment. Durations come from the PES
/// timestamps (90 kHz). Bytes before the first keyframe are dropped. A timestamp jump
/// (a provider restart) drops the unfinished segment and starts again at the next keyframe.
struct MPEGTSSegmenter {
    static let packetSize = 188
    private static let ptsWrap: Int64 = 1 << 33
    private static let ptsHalfWrap: Int64 = 1 << 32
    static let defaultMaximumSegmentBytes = 24 * 1024 * 1024
    private static let maxPendingVideoPackets = 16
    private static let maxPendingTotalPackets = 96

    /// Inline 3-byte tail to detect 0x00 0x00 0x01 start codes crossing packet boundaries with zero heap allocation.
    private struct StartCodeTail {
        var b0: UInt8 = 0
        var b1: UInt8 = 0
        var b2: UInt8 = 0
        var count: Int = 0

        @inline(__always)
        subscript(index: Int) -> UInt8 {
            switch index {
            case 0: return b0
            case 1: return b1
            default: return b2
            }
        }

        mutating func update(from packet: UnsafeBufferPointer<UInt8>, start: Int) {
            guard start < MPEGTSSegmenter.packetSize else { return }
            let sliceCount = MPEGTSSegmenter.packetSize - start
            if sliceCount >= 3 {
                let end = MPEGTSSegmenter.packetSize
                b0 = packet[end - 3]
                b1 = packet[end - 2]
                b2 = packet[end - 1]
                count = 3
            } else {
                var combined: (UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0)
                var total = 0
                for i in 0..<count {
                    Self.set(&combined, at: total, to: self[i])
                    total += 1
                }
                for i in start..<MPEGTSSegmenter.packetSize {
                    Self.set(&combined, at: total, to: packet[i])
                    total += 1
                }
                let keep = min(3, total)
                let base = total - keep
                count = keep
                b0 = keep > 0 ? Self.get(combined, at: base) : 0
                b1 = keep > 1 ? Self.get(combined, at: base + 1) : 0
                b2 = keep > 2 ? Self.get(combined, at: base + 2) : 0
            }
        }

        @inline(__always)
        private static func set(_ t: inout (UInt8, UInt8, UInt8, UInt8, UInt8), at idx: Int, to val: UInt8) {
            switch idx {
            case 0: t.0 = val
            case 1: t.1 = val
            case 2: t.2 = val
            case 3: t.3 = val
            default: t.4 = val
            }
        }

        @inline(__always)
        private static func get(_ t: (UInt8, UInt8, UInt8, UInt8, UInt8), at idx: Int) -> UInt8 {
            switch idx {
            case 0: return t.0
            case 1: return t.1
            case 2: return t.2
            case 3: return t.3
            default: return t.4
            }
        }
    }

    private struct PendingVideoPES {
        let pts: Int64
        /// Duration to emit for the in-progress segment if this PES is a keyframe (nil if no segment is open).
        let cutDuration: Double?
        var packets: Data
        var packetCount: Int
        var videoPacketsScanned: Int
        var tail: StartCodeTail
    }

    let targetDuration: Double
    /// Past this duration, cut at any PES start even without a detected keyframe.
    let maximumDuration: Double
    /// Hard memory ceiling for an in-progress segment to prevent OOM on undecodable streams.
    let maximumSegmentBytes: Int

    private var pending = Data()
    private var pat: Data?
    private var pmt: Data?
    private var pmtPID: Int?
    private var timingPID: Int?
    private var timingIsVideo = false
    private var videoStreamType: UInt8 = 0
    private var current = Data()
    private var currentStartPTS: Int64?
    private var currentMaxPTS: Int64?
    private var pendingPES: PendingVideoPES?
    private var pendingDiscontinuity = false
    private var hasEmittedSegment = false
    /// Reusable 188-byte scratch buffer used only when H.264 AUD reordering is needed.
    private var reorderScratch = [UInt8](repeating: 0, count: MPEGTSSegmenter.packetSize)

    init(
        targetDuration: Double = 2,
        maximumDuration: Double = 12,
        maximumSegmentBytes: Int = MPEGTSSegmenter.defaultMaximumSegmentBytes
    ) {
        self.targetDuration = targetDuration
        self.maximumDuration = max(maximumDuration, targetDuration)
        self.maximumSegmentBytes = max(Self.packetSize * 4, maximumSegmentBytes)
    }

    /// True after the PMT names a stream that BruTV can time.
    var hasProgram: Bool { timingPID != nil }

    /// Signed 33-bit PTS difference (`end - start`) in 90 kHz ticks, in `[-(1 << 32), (1 << 32) - 1]`.
    static func signedPTSDelta(from start: Int64, to end: Int64) -> Int64 {
        let raw = (end - start) & (ptsWrap - 1)
        return raw >= ptsHalfWrap ? raw - ptsWrap : raw
    }

    mutating func append(_ data: Data) -> [TransportStreamSegment] {
        guard !data.isEmpty else { return [] }
        var segments: [TransportStreamSegment] = []

        if pending.isEmpty {
            // Fast zero-copy path: scan incoming chunk directly without copying into `pending`.
            let consumed = processBuffer(data, segments: &segments)
            if consumed < data.count {
                pending.append(data[(data.startIndex + consumed)...])
            }
            return segments
        }

        pending.append(data)
        let buffer = pending
        pending = Data()
        let consumed = processBuffer(buffer, segments: &segments)
        if consumed < buffer.count {
            pending.append(buffer[(buffer.startIndex + consumed)...])
        }
        return segments
    }

    private mutating func processBuffer(_ data: Data, segments: inout [TransportStreamSegment]) -> Int {
        var offset = 0
        let count = data.count
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            while count - offset >= Self.packetSize {
                // Resynchronize on a sync byte that the next packet confirms.
                guard base[offset] == 0x47,
                      count - offset < Self.packetSize * 2 || base[offset + Self.packetSize] == 0x47 else {
                    offset += 1
                    continue
                }
                let packet = UnsafeBufferPointer(start: base + offset, count: Self.packetSize)
                if let segment = process(packet) {
                    segments.append(segment)
                }
                offset += Self.packetSize
            }
        }
        return offset
    }

    private mutating func process(_ p: UnsafeBufferPointer<UInt8>) -> TransportStreamSegment? {
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
            if parsePAT(p, payload: payload) {
                pat = Data(buffer: p)
            }
        } else if pid == pmtPID, unitStart, hasPayload {
            if parsePMT(p, payload: payload) {
                pmt = Data(buffer: p)
            }
        } else if pid == timingPID, unitStart, hasPayload {
            flushPendingPES()
            if let pts = Self.presentationTime(p, payload: payload) {
                // Only copy into the reusable scratch buffer when H.264 AUD reordering is actually required.
                var useScratch = false
                if timingIsVideo && videoStreamType == 0x1B && Self.needsAccessUnitDelimiterReorder(p, payload: payload) {
                    for i in 0..<Self.packetSize {
                        reorderScratch[i] = p[i]
                    }
                    Self.moveAccessUnitDelimiterFirst(&reorderScratch, payload: payload)
                    useScratch = true
                }
                if useScratch {
                    return reorderScratch.withUnsafeBufferPointer { scratchPtr in
                        processTimingUnitStart(
                            scratchPtr,
                            pts: pts,
                            payload: payload,
                            randomAccess: randomAccess
                        )
                    }
                } else {
                    return processTimingUnitStart(
                        p,
                        pts: pts,
                        payload: payload,
                        randomAccess: randomAccess
                    )
                }
            }
        } else if pid == timingPID, !unitStart, hasPayload, var pending = pendingPES {
            if containsKeyframeBytes(p, start: payload, prefix: pending.tail) {
                pendingPES = nil
                if let cutDuration = pending.cutDuration, currentStartPTS != nil, cutDuration >= 0.25 {
                    emitted = emitCurrentSegment(duration: cutDuration)
                }
                startSegment(at: pending.pts)
                if currentStartPTS != nil {
                    appendDataToCurrent(pending.packets)
                    if currentStartPTS != nil {
                        appendPacketToCurrent(p)
                    }
                }
                return emitted
            }
            pending.packets.append(p)
            pending.packetCount += 1
            pending.videoPacketsScanned += 1
            pending.tail.update(from: p, start: payload)
            pendingPES = pending
            if pending.videoPacketsScanned >= Self.maxPendingVideoPackets
                || pending.packetCount >= Self.maxPendingTotalPackets {
                flushPendingPES()
            }
            return nil
        }

        if var pending = pendingPES {
            pending.packets.append(p)
            pending.packetCount += 1
            pendingPES = pending
            if pending.packetCount >= Self.maxPendingTotalPackets {
                flushPendingPES()
            }
            return nil
        }

        if currentStartPTS != nil {
            appendPacketToCurrent(p)
        }
        return emitted
    }

    private mutating func processTimingUnitStart(
        _ p: UnsafeBufferPointer<UInt8>,
        pts: Int64,
        payload: Int,
        randomAccess: Bool
    ) -> TransportStreamSegment? {
        var emitted: TransportStreamSegment?
        let immediateKeyframe = !timingIsVideo || randomAccess || containsKeyframe(p, payload: payload)
        let esStart = payload + 9 <= Self.packetSize ? payload + 9 + Int(p[payload + 8]) : Self.packetSize
        if let start = currentStartPTS {
            let deltaTicks = Self.signedPTSDelta(from: start, to: pts)
            let deltaSeconds = Double(deltaTicks) / 90_000
            if abs(deltaSeconds) > 60 {
                // True timeline jump (forward or backward > 60s). Start again at the next keyframe.
                resetCurrent()
                if hasEmittedSegment {
                    pendingDiscontinuity = true
                }
                if immediateKeyframe {
                    startSegment(at: pts)
                } else if timingIsVideo, pat != nil, pmt != nil {
                    pendingPES = makePendingPES(pts: pts, cutDuration: nil, packet: p, esStart: esStart)
                    return nil
                }
            } else {
                // Open-GOP B-frame reordering can yield small negative deltas relative to start.
                // Preserve the segment and track maxPTS in the current segment for duration.
                let previousMaxPTS = currentMaxPTS ?? start
                let maxDeltaTicks = max(deltaTicks, Self.signedPTSDelta(from: start, to: previousMaxPTS))
                let duration = Double(max(0, maxDeltaTicks)) / 90_000
                if (immediateKeyframe && duration >= targetDuration) || duration >= maximumDuration {
                    if duration >= 0.25 {
                        emitted = emitCurrentSegment(duration: duration)
                    }
                    startSegment(at: pts)
                } else if timingIsVideo, !immediateKeyframe, duration >= targetDuration {
                    // Hold this PES briefly while scanning continuation packets for SPS/IDR
                    // (e.g. when a large SEI/AUD precedes the keyframe NAL unit).
                    pendingPES = makePendingPES(pts: pts, cutDuration: duration, packet: p, esStart: esStart)
                    return nil
                } else if Self.signedPTSDelta(from: previousMaxPTS, to: pts) > 0 {
                    currentMaxPTS = pts
                }
            }
        } else if immediateKeyframe {
            startSegment(at: pts)
        } else if timingIsVideo, pat != nil, pmt != nil {
            pendingPES = makePendingPES(pts: pts, cutDuration: nil, packet: p, esStart: esStart)
            return nil
        }

        if currentStartPTS != nil {
            appendPacketToCurrent(p)
        }
        return emitted
    }

    private func makePendingPES(
        pts: Int64,
        cutDuration: Double?,
        packet: UnsafeBufferPointer<UInt8>,
        esStart: Int
    ) -> PendingVideoPES {
        var buffer = Data(capacity: Self.packetSize * 8)
        buffer.append(packet)
        var tail = StartCodeTail()
        tail.update(from: packet, start: esStart)
        return PendingVideoPES(
            pts: pts,
            cutDuration: cutDuration,
            packets: buffer,
            packetCount: 1,
            videoPacketsScanned: 1,
            tail: tail
        )
    }

    private mutating func resetCurrent() {
        current.removeAll(keepingCapacity: false)
        currentStartPTS = nil
        currentMaxPTS = nil
        pendingPES = nil
    }

    private mutating func flushPendingPES() {
        guard let pending = pendingPES else { return }
        pendingPES = nil
        guard currentStartPTS != nil else { return }
        if let previousMaxPTS = currentMaxPTS,
           Self.signedPTSDelta(from: previousMaxPTS, to: pending.pts) > 0 {
            currentMaxPTS = pending.pts
        }
        appendDataToCurrent(pending.packets)
    }

    private mutating func emitCurrentSegment(duration: Double) -> TransportStreamSegment {
        let data = current
        current = Data()
        let segment = TransportStreamSegment(
            data: data,
            duration: duration,
            discontinuity: pendingDiscontinuity
        )
        pendingDiscontinuity = false
        hasEmittedSegment = true
        return segment
    }

    private mutating func appendPacketToCurrent(_ packet: UnsafeBufferPointer<UInt8>) {
        if current.count + Self.packetSize > maximumSegmentBytes {
            resetCurrent()
            if hasEmittedSegment {
                pendingDiscontinuity = true
            }
            return
        }
        current.append(packet)
    }

    private mutating func appendDataToCurrent(_ bytes: Data) {
        if current.count + bytes.count > maximumSegmentBytes {
            resetCurrent()
            if hasEmittedSegment {
                pendingDiscontinuity = true
            }
            return
        }
        current.append(bytes)
    }

    private mutating func startSegment(at pts: Int64) {
        guard let pat, let pmt else { return }
        let reserve = min(512 * 1024, maximumSegmentBytes)
        current = Data(capacity: reserve)
        current.append(pat)
        current.append(pmt)
        currentStartPTS = pts
        currentMaxPTS = pts
    }

    /// Start of the section after the pointer field, or nil when it does not fit.
    @inline(__always)
    private static func sectionStart(_ p: UnsafeBufferPointer<UInt8>, payload: Int) -> Int? {
        let start = payload + 1 + Int(p[payload])
        return start + 3 < packetSize ? start : nil
    }

    private mutating func parsePAT(_ p: UnsafeBufferPointer<UInt8>, payload: Int) -> Bool {
        guard let s = Self.sectionStart(p, payload: payload), p[s] == 0x00 else { return false }
        let sectionLength = Int(p[s + 1] & 0x0F) << 8 | Int(p[s + 2])
        guard sectionLength >= 9 else { return false }
        let end = min(s + 3 + sectionLength - 4, Self.packetSize)
        var index = s + 8
        while index + 4 <= end {
            let program = Int(p[index]) << 8 | Int(p[index + 1])
            let pid = Int(p[index + 2] & 0x1F) << 8 | Int(p[index + 3])
            if program != 0, pid != 0 {
                if let existing = pmtPID, existing != pid {
                    pmt = nil
                    resetCurrent()
                    pendingDiscontinuity = true
                }
                pmtPID = pid
                return true
            }
            index += 4
        }
        return false
    }

    private mutating func parsePMT(_ p: UnsafeBufferPointer<UInt8>, payload: Int) -> Bool {
        guard let s = Self.sectionStart(p, payload: payload), p[s] == 0x02, s + 12 <= Self.packetSize else { return false }
        let sectionLength = Int(p[s + 1] & 0x0F) << 8 | Int(p[s + 2])
        guard sectionLength >= 13 else { return false }
        let programInfoLength = Int(p[s + 10] & 0x0F) << 8 | Int(p[s + 11])
        let end = min(s + 3 + sectionLength - 4, Self.packetSize)
        var index = s + 12 + programInfoLength
        guard index <= end else { return false }
        var video: (pid: Int, type: UInt8)?
        var audio: Int?
        while index + 5 <= end {
            let type = p[index]
            let pid = Int(p[index + 1] & 0x1F) << 8 | Int(p[index + 2])
            let infoLength = Int(p[index + 3] & 0x0F) << 8 | Int(p[index + 4])
            switch type {
            case 0x01, 0x02, 0x10, 0x1B, 0x24:
                if video == nil { video = (pid, type) }
            case 0x03, 0x04, 0x0F, 0x11, 0x81, 0x87:
                if audio == nil { audio = pid }
            default:
                break
            }
            index += 5 + infoLength
        }
        let resolvedTimingPID: Int
        let resolvedIsVideo: Bool
        let resolvedVideoType: UInt8
        if let video {
            resolvedTimingPID = video.pid
            resolvedIsVideo = true
            resolvedVideoType = video.type
        } else if let audio {
            resolvedTimingPID = audio
            resolvedIsVideo = false
            resolvedVideoType = 0
        } else {
            return false
        }
        if let existingPID = timingPID,
           existingPID != resolvedTimingPID || timingIsVideo != resolvedIsVideo || videoStreamType != resolvedVideoType {
            resetCurrent()
            pendingDiscontinuity = true
        }
        timingPID = resolvedTimingPID
        timingIsVideo = resolvedIsVideo
        videoStreamType = resolvedVideoType
        return true
    }

    static func presentationTime(_ p: [UInt8], payload q: Int) -> Int64? {
        p.withUnsafeBufferPointer { presentationTime($0, payload: q) }
    }

    @inline(__always)
    static func presentationTime(_ p: UnsafeBufferPointer<UInt8>, payload q: Int) -> Int64? {
        guard q + 14 <= packetSize, p[q] == 0, p[q + 1] == 0, p[q + 2] == 1, p[q + 7] & 0x80 != 0 else { return nil }
        let pts = Int64(p[q + 9] & 0x0E) << 29 | Int64(p[q + 10]) << 22 | Int64(p[q + 11] & 0xFE) << 14
            | Int64(p[q + 12]) << 7 | Int64(p[q + 13]) >> 1
        return pts
    }

    /// Fast read-only check before copying a packet into the scratch buffer for AUD reordering.
    private static func needsAccessUnitDelimiterReorder(_ p: UnsafeBufferPointer<UInt8>, payload q: Int) -> Bool {
        guard q + 9 <= packetSize else { return false }
        let esStart = q + 9 + Int(p[q + 8])
        guard esStart < packetSize else { return false }
        var seenParamSet = false
        var seenAUD = false
        var index = esStart
        while index + 3 < packetSize {
            if p[index] == 0, p[index + 1] == 0, p[index + 2] == 1 {
                let nalType = p[index + 3] & 0x1F
                if seenAUD {
                    return true
                }
                if nalType == 9 {
                    if !seenParamSet { return false }
                    seenAUD = true
                } else if nalType == 7 || nalType == 8 {
                    seenParamSet = true
                } else {
                    return false
                }
                index += 3
            } else {
                index += 1
            }
        }
        return false
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
        let audStart = starts[audIndex].begin
        let audEnd = starts[audIndex + 1].begin
        // Rotate [first..<audStart] and [audStart..<audEnd] in place using three reversals (zero heap allocation).
        reverseRange(&p, from: first, to: audStart)
        reverseRange(&p, from: audStart, to: audEnd)
        reverseRange(&p, from: first, to: audEnd)
    }

    @inline(__always)
    private static func reverseRange(_ buffer: inout [UInt8], from start: Int, to end: Int) {
        var lo = start
        var hi = end - 1
        while lo < hi {
            buffer.swapAt(lo, hi)
            lo += 1
            hi -= 1
        }
    }

    /// Looks for a keyframe start in the first packet of a video PES.
    private func containsKeyframe(_ p: UnsafeBufferPointer<UInt8>, payload q: Int) -> Bool {
        guard q + 9 <= Self.packetSize else { return false }
        let esStart = q + 9 + Int(p[q + 8])
        guard esStart < Self.packetSize else { return false }
        return containsKeyframeBytes(p, start: esStart, prefix: StartCodeTail())
    }

    private func containsKeyframeBytes(
        _ p: UnsafeBufferPointer<UInt8>,
        start: Int,
        prefix: StartCodeTail
    ) -> Bool {
        let prefixCount = prefix.count
        let sliceCount = Self.packetSize - start
        let total = prefixCount + sliceCount
        guard total >= 4 else { return false }

        @inline(__always)
        func byte(at idx: Int) -> UInt8 {
            idx < prefixCount ? prefix[idx] : p[start + idx - prefixCount]
        }

        var index = 0
        while index + 3 < total {
            if byte(at: index) == 0, byte(at: index + 1) == 0, byte(at: index + 2) == 1 {
                let header = byte(at: index + 3)
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
    static let maxBufferedChunks = 256

    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var failure: Error?
    private var cancelled = false

    static func stream(_ url: URL, idleTimeout: TimeInterval = 15) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(maxBufferedChunks)) { continuation in
            let request = TransportStreamRequest(continuation: continuation)
            continuation.onTermination = { _ in request.cancel() }
            request.start(url, idleTimeout: idleTimeout)
        }
    }

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var hasActiveTask: Bool {
        lock.lock()
        defer { lock.unlock() }
        return task != nil || session != nil
    }

    func start(_ url: URL, idleTimeout: TimeInterval = 15) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.finish()
            return
        }
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
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let isCancelled = self.cancelled
        if isCancelled {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200...299).contains(status) {
            lock.unlock()
            completionHandler(.allow)
        } else {
            failure = LiveTimeshiftError.network(status)
            lock.unlock()
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let isCancelled = self.cancelled
        lock.unlock()
        guard !isCancelled else {
            dataTask.cancel()
            return
        }
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let storedFailure = self.failure
        self.task = nil
        self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let error = storedFailure ?? error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
