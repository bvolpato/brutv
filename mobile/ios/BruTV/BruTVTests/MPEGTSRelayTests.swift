import XCTest
@testable import BruTV

final class MPEGTSRelayTests: XCTestCase {
    private let videoPID = 0x100
    private let pmtPID = 0x1000

    // MARK: - Synthetic MPEG-TS

    private func packet(pid: Int, unitStart: Bool, randomAccess: Bool = false, payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0x47, UInt8((unitStart ? 0x40 : 0) | (pid >> 8)), UInt8(pid & 0xFF)]
        let room = 184
        if randomAccess || payload.count < room {
            // Adaptation field carries the random access flag and the stuffing.
            let fieldLength = max(1, room - 1 - payload.count)
            bytes.append(0x30)
            bytes.append(UInt8(fieldLength))
            bytes.append(randomAccess ? 0x40 : 0x00)
            bytes.append(contentsOf: [UInt8](repeating: 0xFF, count: fieldLength - 1))
        } else {
            bytes.append(0x10)
        }
        bytes.append(contentsOf: payload.prefix(188 - bytes.count))
        return bytes
    }

    private func section(tableID: UInt8, body: [UInt8]) -> [UInt8] {
        let length = body.count + 5 + 4 // header after length, plus CRC
        var bytes: [UInt8] = [0x00, tableID, 0xB0 | UInt8(length >> 8), UInt8(length & 0xFF), 0x00, 0x01, 0xC1, 0x00, 0x00]
        bytes.append(contentsOf: body)
        bytes.append(contentsOf: [0, 0, 0, 0])
        return bytes
    }

    private var pat: [UInt8] {
        packet(pid: 0, unitStart: true, payload: section(tableID: 0x00, body: [0x00, 0x01, 0xE0 | UInt8(pmtPID >> 8), UInt8(pmtPID & 0xFF)]))
    }

    private var pmt: [UInt8] {
        let body: [UInt8] = [0xE0 | UInt8(videoPID >> 8), UInt8(videoPID & 0xFF), 0xF0, 0x00,
                             0x1B, 0xE0 | UInt8(videoPID >> 8), UInt8(videoPID & 0xFF), 0xF0, 0x00]
        return packet(pid: pmtPID, unitStart: true, payload: section(tableID: 0x02, body: body))
    }

    private func pes(pts: Int64, keyframe: Bool) -> [UInt8] {
        let ptsBytes: [UInt8] = [
            0x21 | UInt8((pts >> 29) & 0x0E), UInt8((pts >> 22) & 0xFF),
            0x01 | UInt8((pts >> 14) & 0xFE), UInt8((pts >> 7) & 0xFF), 0x01 | UInt8((pts << 1) & 0xFE),
        ]
        let nal: [UInt8] = keyframe ? [0, 0, 0, 1, 0x67, 0x64] : [0, 0, 0, 1, 0x41, 0x9A]
        return [0, 0, 1, 0xE0, 0, 0, 0x80, 0x80, 0x05] + ptsBytes + nal
    }

    /// A stream with PAT and PMT every frame, 10 frames per second, and a keyframe every second.
    private func stream(seconds: Int, startPTS: Int64 = 900_000, flagKeyframes: Bool = true) -> [UInt8] {
        var bytes: [UInt8] = []
        for frame in 0..<(seconds * 10) {
            let keyframe = frame % 10 == 0
            bytes += pat + pmt
            bytes += packet(pid: videoPID, unitStart: true, randomAccess: keyframe && flagKeyframes,
                            payload: pes(pts: startPTS + Int64(frame) * 9_000, keyframe: keyframe))
            bytes += packet(pid: videoPID, unitStart: false, payload: [UInt8](repeating: 0xAB, count: 184))
        }
        return bytes
    }

    // MARK: - Tests

    func testCutsAtKeyframesWithTimestampDurationsAndProgramTablesFirst() {
        var segmenter = MPEGTSSegmenter(targetDuration: 2)
        let segments = segmenter.append(Data(stream(seconds: 7)))

        // Keyframes every second and a 2 second target give 2 second segments. The last
        // unfinished segment waits for the next keyframe.
        XCTAssertEqual(segments.map(\.duration), [2, 2, 2])
        for segment in segments {
            XCTAssertEqual(segment.data.count % 188, 0)
            XCTAssertEqual([UInt8](segment.data.prefix(188)), pat)
            XCTAssertEqual([UInt8](segment.data.dropFirst(188).prefix(188)), pmt)
        }
    }

    func testSmallChunksGarbageAndNalOnlyKeyframesGiveTheSameSegments() {
        // No random access flags: keyframes are found from the H.264 NAL units only.
        var whole = MPEGTSSegmenter(targetDuration: 2)
        let expected = whole.append(Data(stream(seconds: 5, flagKeyframes: false)))
        XCTAssertEqual(expected.map(\.duration), [2, 2])

        // Garbage before the first packet, and 1000-byte network reads.
        var chunked = MPEGTSSegmenter(targetDuration: 2)
        let bytes = [UInt8](repeating: 0x00, count: 77) + stream(seconds: 5, flagKeyframes: false)
        var segments: [TransportStreamSegment] = []
        for start in stride(from: 0, to: bytes.count, by: 1000) {
            segments += chunked.append(Data(bytes[start..<min(start + 1000, bytes.count)]))
        }
        XCTAssertEqual(segments, expected)
    }

    func testTimestampWrapKeepsDurationsAndTimelineJumpRestartsCleanly() {
        let wrap: Int64 = 1 << 33
        var wrapping = MPEGTSSegmenter(targetDuration: 2)
        let wrapped = wrapping.append(Data(stream(seconds: 5, startPTS: wrap - 90_000)))
        XCTAssertEqual(wrapped.map(\.duration), [2, 2])

        // A provider restart moves the clock by an hour: no segment spans the jump.
        var jumping = MPEGTSSegmenter(targetDuration: 2)
        let segments = jumping.append(Data(stream(seconds: 3) + stream(seconds: 5, startPTS: 900_000 + 90_000 * 3600)))
        XCTAssertTrue(segments.allSatisfy { $0.duration <= 2.01 }, "\(segments.map(\.duration))")
        XCTAssertEqual(segments.count, 3)
    }

    func testXtreamLiveURLsMapToTheirTransportStream() {
        let hls = URL(string: "http://host:8080/live/user/pass/1305445.m3u8")!
        XCTAssertEqual(TransportStreamRelayPolicy.relayURL(for: hls)?.absoluteString, "http://host:8080/live/user/pass/1305445.ts")
        let ts = URL(string: "http://host/live/user/pass/7.ts")!
        XCTAssertEqual(TransportStreamRelayPolicy.relayURL(for: ts), ts)
        XCTAssertNil(TransportStreamRelayPolicy.relayURL(for: URL(string: "https://cdn.example/channel/index.m3u8")!))
        XCTAssertNil(TransportStreamRelayPolicy.relayURL(for: URL(string: "http://host/movie/user/pass/9.mp4")!))
    }

    func testRecorderPublishesRelayedSegmentsAndMarksReconnects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder = try LiveTimeshiftRecorder(directory: directory)
        let first = Data(stream(seconds: 5))
        let second = Data(stream(seconds: 5, startPTS: 50_000_000))
        let responses = Responses([first, second])
        // Each response ends, so the recorder reconnects until 3 responses in a row fail.
        await recorder.captureTransportStream(URL(string: "http://host/live/u/p/1.ts")!) { _ in
            AsyncThrowingStream { continuation in
                if let data = responses.next() { continuation.yield(data) }
                continuation.finish()
            }
        }

        let failure = await recorder.transportStreamFailure()
        XCTAssertNotNil(failure, "Ended responses must count as failures")
        let playlist = String(decoding: try await recorder.playlist(), as: UTF8.self)
        XCTAssertEqual(playlist.components(separatedBy: "#EXTINF:2.000000,").count - 1, 4)
        XCTAssertTrue(playlist.contains("#EXT-X-DISCONTINUITY\n"), playlist)
        let segment = try await recorder.segment(named: "segment-0.ts")
        XCTAssertEqual(segment.map { [UInt8]($0.prefix(188)) }, pat)
        await recorder.stop()
    }

    func testMoveAccessUnitDelimiterFirstReordersMisplacedAUD() {
        let pesHeader: [UInt8] = [0, 0, 1, 0xE0, 0, 0, 0x80, 0x80, 0x05, 0x21, 0, 1, 0, 1]
        let sps: [UInt8] = [0, 0, 0, 1, 0x67, 0x42, 0x00]
        let pps: [UInt8] = [0, 0, 0, 1, 0x68, 0xCE]
        let aud: [UInt8] = [0, 0, 0, 1, 0x09, 0x10]
        let idr: [UInt8] = [0, 0, 0, 1, 0x65, 0x88]

        var payload = pesHeader + sps + pps + aud + idr
        let stuffing = [UInt8](repeating: 0xFF, count: 184 - payload.count)
        var pkt: [UInt8] = [0x47, 0x41, 0x00, 0x10] + payload + stuffing

        MPEGTSSegmenter.moveAccessUnitDelimiterFirst(&pkt, payload: 4)

        // After reordering, AUD should precede SPS and PPS
        let esStart = 4 + 9 + Int(pkt[4 + 8])
        let reordered = Array(pkt[esStart..<esStart + aud.count + sps.count + pps.count + idr.count])
        XCTAssertEqual(reordered, aud + sps + pps + idr)
    }
}

private final class Responses: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data]

    init(_ items: [Data]) { self.items = items }

    func next() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }
}
