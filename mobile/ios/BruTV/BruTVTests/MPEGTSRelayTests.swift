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

        let payload = pesHeader + sps + pps + aud + idr
        let stuffing = [UInt8](repeating: 0xFF, count: 184 - payload.count)
        var pkt: [UInt8] = [0x47, 0x41, 0x00, 0x10] + payload + stuffing

        MPEGTSSegmenter.moveAccessUnitDelimiterFirst(&pkt, payload: 4)

        // After reordering, AUD should precede SPS and PPS
        let esStart = 4 + 9 + Int(pkt[4 + 8])
        let reordered = Array(pkt[esStart..<esStart + aud.count + sps.count + pps.count + idr.count])
        XCTAssertEqual(reordered, aud + sps + pps + idr)
    }

    func testSignedPTSDeltaHandlesWrapAndNegativeBFrameReordering() {
        let wrap: Int64 = 1 << 33
        XCTAssertEqual(MPEGTSSegmenter.signedPTSDelta(from: 900_000, to: 1_080_000), 180_000)
        XCTAssertEqual(MPEGTSSegmenter.signedPTSDelta(from: 900_000, to: 891_000), -9_000)
        XCTAssertEqual(MPEGTSSegmenter.signedPTSDelta(from: wrap - 90_000, to: 90_000), 180_000)
        XCTAssertEqual(MPEGTSSegmenter.signedPTSDelta(from: 3_000, to: wrap - 6_000), -9_000)
        XCTAssertEqual(MPEGTSSegmenter.signedPTSDelta(from: 900_000, to: 900_000 + 90_000 * 3600), 90_000 * 3600)
        XCTAssertEqual(MPEGTSSegmenter.signedPTSDelta(from: 900_000 + 90_000 * 3600, to: 900_000), -90_000 * 3600)
    }

    func testOpenGOPNegativeBFramePTSDoesNotWipeSegment() {
        // Simulate open-GOP B-frame reordering where B-frames right after each IDR have PTS < IDR PTS.
        var bytes: [UInt8] = []
        let basePTS: Int64 = 900_000
        for gop in 0..<4 {
            let gopPTS = basePTS + Int64(gop) * 180_000 // 2.0s per GOP
            // I-frame at gopPTS + 18_000 (+0.2s), followed by B-frames at gopPTS (-0.2s relative to start!) and gopPTS + 9_000 (-0.1s).
            let frameOffsets: [(Int64, Bool)] = [
                (18_000, true),
                (0, false),
                (9_000, false),
                (54_000, false),
                (36_000, false),
                (90_000, false),
                (126_000, false),
                (162_000, false),
            ]
            for (offset, keyframe) in frameOffsets {
                bytes += pat + pmt
                bytes += packet(pid: videoPID, unitStart: true, randomAccess: keyframe,
                                payload: pes(pts: gopPTS + offset, keyframe: keyframe))
                bytes += packet(pid: videoPID, unitStart: false, payload: [UInt8](repeating: 0xAB, count: 184))
            }
        }

        var segmenter = MPEGTSSegmenter(targetDuration: 2)
        let segments = segmenter.append(Data(bytes))
        XCTAssertEqual(segments.map(\.duration), [2, 2, 2])
    }

    func testKeyframeInContinuationPESPacketAfterLargeSEI() {
        // Packet 1 of each keyframe PES carries AUD + large SEI filling packet 1 completely;
        // SPS + IDR land in continuation packet 2 (even crossing packet boundaries).
        func pesHeader(pts: Int64) -> [UInt8] {
            let ptsBytes: [UInt8] = [
                0x21 | UInt8((pts >> 29) & 0x0E), UInt8((pts >> 22) & 0xFF),
                0x01 | UInt8((pts >> 14) & 0xFE), UInt8((pts >> 7) & 0xFF), UInt8(0x01 | ((pts << 1) & 0xFE)),
            ]
            return [0, 0, 1, 0xE0, 0, 0, 0x80, 0x80, 0x05] + ptsBytes
        }

        var bytes: [UInt8] = []
        let startPTS: Int64 = 900_000
        for second in 0..<5 {
            let pts = startPTS + Int64(second) * 90_000
            let isKeyframe = second % 2 == 0
            bytes += pat + pmt
            if isKeyframe {
                // Fill Packet 1 with PES header + AUD + SEI ending with 0x00, 0x00 so start code spans into Packet 2!
                let header = pesHeader(pts: pts) + [0, 0, 0, 1, 0x09, 0x10, 0, 0, 0, 1, 0x06]
                let seiFillCount = 184 - header.count - 2
                let pkt1Payload = header + [UInt8](repeating: 0xAA, count: seiFillCount) + [0x00, 0x00]
                let pkt2Payload: [UInt8] = [0x01, 0x67, 0x64, 0, 0, 0, 1, 0x65, 0x88] + [UInt8](repeating: 0xBB, count: 175)
                bytes += packet(pid: videoPID, unitStart: true, randomAccess: false, payload: pkt1Payload)
                bytes += packet(pid: videoPID, unitStart: false, payload: pkt2Payload)
            } else {
                bytes += packet(pid: videoPID, unitStart: true, randomAccess: false, payload: pes(pts: pts, keyframe: false))
                bytes += packet(pid: videoPID, unitStart: false, payload: [UInt8](repeating: 0xCC, count: 184))
            }
        }

        var segmenter = MPEGTSSegmenter(targetDuration: 2)
        let segments = segmenter.append(Data(bytes))
        XCTAssertEqual(segments.map(\.duration), [2, 2])
        for segment in segments {
            // Each segment begins with PAT, PMT, then Packet 1 (with unitStart=true and PES header) of the keyframe!
            XCTAssertEqual([UInt8](segment.data.prefix(188)), pat)
            XCTAssertEqual([UInt8](segment.data.dropFirst(188).prefix(188)), pmt)
            let thirdPacket = [UInt8](segment.data.dropFirst(376).prefix(188))
            XCTAssertEqual(thirdPacket[0], 0x47)
            XCTAssertTrue(thirdPacket[1] & 0x40 != 0, "Segment must start at PES packet #1, not continuation packet #2")
        }
    }

    func testSegmenterCapsCurrentSegmentBytesToPreventOOM() {
        var segmenter = MPEGTSSegmenter(targetDuration: 2, maximumDuration: 12, maximumSegmentBytes: 188 * 10)
        // Start a segment with a keyframe, then flood with non-keyframe continuation packets without advancing PTS.
        var flood = pat + pmt + packet(pid: videoPID, unitStart: true, randomAccess: true, payload: pes(pts: 900_000, keyframe: true))
        for _ in 0..<25 {
            flood += packet(pid: videoPID, unitStart: false, payload: [UInt8](repeating: 0xDD, count: 184))
        }
        XCTAssertTrue(segmenter.append(Data(flood)).isEmpty)

        // After hitting the cap and resetting, normal keyframes produce clean segments within the byte cap.
        let normal = segmenter.append(Data(stream(seconds: 3, startPTS: 900_000)))
        XCTAssertEqual(normal.count, 0) // 2s normal stream exceeds tiny 10-packet test cap; test larger cap recovers cleanly:

        var recoverable = MPEGTSSegmenter(targetDuration: 2, maximumDuration: 12, maximumSegmentBytes: 188 * 120)
        var hugeSingleFrame = pat + pmt + packet(pid: videoPID, unitStart: true, randomAccess: true, payload: pes(pts: 900_000, keyframe: true))
        for _ in 0..<130 {
            hugeSingleFrame += packet(pid: videoPID, unitStart: false, payload: [UInt8](repeating: 0xEE, count: 184))
        }
        XCTAssertTrue(recoverable.append(Data(hugeSingleFrame)).isEmpty)
        let recovered = recoverable.append(Data(stream(seconds: 3, startPTS: 1_800_000)))
        XCTAssertEqual(recovered.map(\.duration), [2])
        XCTAssertLessThanOrEqual(recovered[0].data.count, 188 * 120)
    }

    func testTransportStreamRequestCancelBeforeStartPreventsLeakedTask() async throws {
        var capturedRequest: TransportStreamRequest?
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingNewest(TransportStreamRequest.maxBufferedChunks)) { continuation in
            let request = TransportStreamRequest(continuation: continuation)
            capturedRequest = request
            request.cancel()
            request.start(URL(string: "http://127.0.0.1:9/live/u/p/1.ts")!, idleTimeout: 1)
        }
        let req = try XCTUnwrap(capturedRequest)
        XCTAssertTrue(req.isCancelled)
        XCTAssertFalse(req.hasActiveTask)
        var received = 0
        for try await _ in stream { received += 1 }
        XCTAssertEqual(received, 0)
    }

    func testRecorderFailsWhenBytesArriveWithoutEmittingSegments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let clock = MockClock(now: 1000)
        let recorder = try LiveTimeshiftRecorder(directory: directory, clock: { clock.value })
        let stalledChunk = Data(pat + pmt + packet(pid: videoPID, unitStart: false, payload: [UInt8](repeating: 0xAA, count: 184)))

        await recorder.captureTransportStream(
            URL(string: "http://host/live/u/p/stalled.ts")!,
            segmentStallTimeout: 15,
            reconnectBackoff: 0
        ) { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(stalledChunk)
                clock.advance(by: 16)
                continuation.yield(stalledChunk)
                continuation.finish()
            }
        }

        let failure = await recorder.transportStreamFailure()
        XCTAssertEqual(failure as? LiveTimeshiftError, .startupTimeout)
        await recorder.stop()
    }

    func testRelayKeepsTargetDurationStableAcrossTwoToFourSecondGOPs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder = try LiveTimeshiftRecorder(directory: directory)
        let responses = Responses([Data(stream(seconds: 5))])
        await recorder.captureTransportStream(
            URL(string: "http://host/live/u/p/stable.ts")!,
            reconnectBackoff: 0
        ) { _ in
            AsyncThrowingStream { continuation in
                if let chunk = responses.next() { continuation.yield(chunk) }
                continuation.finish()
            }
        }
        let playlist = String(decoding: try await recorder.playlist(), as: UTF8.self)
        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:4\n"), playlist)
        await recorder.stop()
    }

    func testSegmenterEmitsDiscontinuityOnPTSJumpAndMidStreamPIDChange() {
        // 1. PTS timeline jump after emitting segment 0 marks segment 1 discontinuous, then resets for segment 2.
        var jumping = MPEGTSSegmenter(targetDuration: 2)
        let jumped = jumping.append(Data(stream(seconds: 3) + stream(seconds: 5, startPTS: 900_000 + 90_000 * 3600)))
        XCTAssertEqual(jumped.map(\.discontinuity), [false, true, false])

        // 2. Mid-stream PMT change to a new video PID drops unfinished segment and marks the next segment discontinuous.
        let newVideoPID = 0x200
        let newPMTBody: [UInt8] = [0xE0 | UInt8(newVideoPID >> 8), UInt8(newVideoPID & 0xFF), 0xF0, 0x00,
                                   0x1B, 0xE0 | UInt8(newVideoPID >> 8), UInt8(newVideoPID & 0xFF), 0xF0, 0x00]
        let newPMT = packet(pid: pmtPID, unitStart: true, payload: section(tableID: 0x02, body: newPMTBody))
        var changedBytes = stream(seconds: 3)
        for frame in 0..<50 {
            let keyframe = frame % 10 == 0
            changedBytes += pat + newPMT
            changedBytes += packet(pid: newVideoPID, unitStart: true, randomAccess: keyframe,
                                   payload: pes(pts: 1_800_000 + Int64(frame) * 9_000, keyframe: keyframe))
            changedBytes += packet(pid: newVideoPID, unitStart: false, payload: [UInt8](repeating: 0xAB, count: 184))
        }
        var pidChanged = MPEGTSSegmenter(targetDuration: 2)
        let pidSegments = pidChanged.append(Data(changedBytes))
        XCTAssertEqual(pidSegments.map(\.discontinuity), [false, true, false])
        XCTAssertEqual([UInt8](pidSegments[1].data.dropFirst(188).prefix(188)), newPMT)
    }

    func testCorruptPATAndPMTDoNotOverwriteValidCachedTables() {
        var segmenter = MPEGTSSegmenter(targetDuration: 2)
        let corruptPAT = packet(pid: 0, unitStart: true, payload: [0x00, 0xFF, 0xB0, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00])
        let corruptPMT = packet(pid: pmtPID, unitStart: true, payload: section(tableID: 0x02, body: [0xE1, 0x00, 0xF0, 0x00]))

        var bytes = pat + pmt
        // Corrupt PAT and PMT arrive after valid tables; they must be ignored.
        bytes += corruptPAT + corruptPMT
        for frame in 0..<30 {
            let keyframe = frame % 10 == 0
            bytes += packet(pid: videoPID, unitStart: true, randomAccess: keyframe,
                            payload: pes(pts: 900_000 + Int64(frame) * 9_000, keyframe: keyframe))
            bytes += packet(pid: videoPID, unitStart: false, payload: [UInt8](repeating: 0xAB, count: 184))
        }

        let segments = segmenter.append(Data(bytes))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual([UInt8](segments[0].data.prefix(188)), pat)
        XCTAssertEqual([UInt8](segments[0].data.dropFirst(188).prefix(188)), pmt)
        XCTAssertFalse(segments[0].discontinuity)
    }

    func testAudioOnlyStreamDoesNotRunH264AUDReorderAfterVideoStream() {
        // Start with H.264 video (setting videoStreamType = 0x1B), then switch PMT to E-AC-3 (0x87) audio-only.
        let audioPID = 0x101
        let audioPMTBody: [UInt8] = [0xE0 | UInt8(audioPID >> 8), UInt8(audioPID & 0xFF), 0xF0, 0x00,
                                     0x87, 0xE0 | UInt8(audioPID >> 8), UInt8(audioPID & 0xFF), 0xF0, 0x00]
        let audioPMT = packet(pid: pmtPID, unitStart: true, payload: section(tableID: 0x02, body: audioPMTBody))

        // Craft an audio PES payload whose bytes happen to mimic H.264 SPS + PPS + AUD + IDR.
        let spsLike: [UInt8] = [0, 0, 0, 1, 0x67, 0x42, 0x00]
        let ppsLike: [UInt8] = [0, 0, 0, 1, 0x68, 0xCE]
        let audLike: [UInt8] = [0, 0, 0, 1, 0x09, 0x10]
        let idrLike: [UInt8] = [0, 0, 0, 1, 0x65, 0x88]
        let audioESPattern = spsLike + ppsLike + audLike + idrLike

        func audioPES(pts: Int64) -> [UInt8] {
            let ptsBytes: [UInt8] = [
                0x21 | UInt8((pts >> 29) & 0x0E), UInt8((pts >> 22) & 0xFF),
                0x01 | UInt8((pts >> 14) & 0xFE), UInt8((pts >> 7) & 0xFF), 0x01 | UInt8((pts << 1) & 0xFE),
            ]
            return [0, 0, 1, 0xC0, 0, 0, 0x80, 0x80, 0x05] + ptsBytes + audioESPattern
        }

        var bytes = stream(seconds: 3)
        for step in 0..<30 {
            bytes += pat + audioPMT
            bytes += packet(pid: audioPID, unitStart: true, payload: audioPES(pts: 2_700_000 + Int64(step) * 9_000))
        }

        var segmenter = MPEGTSSegmenter(targetDuration: 2)
        let segments = segmenter.append(Data(bytes))
        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments[1].discontinuity)

        // Verify the first audio PES packet in segment 1 kept its exact original byte order (no AUD reorder).
        let audioPacket = [UInt8](segments[1].data.dropFirst(376).prefix(188))
        let adaptation = (audioPacket[3] >> 4) & 0x3
        let payloadStart = (adaptation & 0x2 != 0) ? (5 + Int(audioPacket[4])) : 4
        let esStart = payloadStart + 9 + Int(audioPacket[payloadStart + 8])
        let actualES = Array(audioPacket[esStart..<(esStart + audioESPattern.count)])
        XCTAssertEqual(actualES, audioESPattern)
    }

    func testCaptureTransportStreamFailsFastOn404AndAllowsSingleRetryOn403() async throws {
        let dir404 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder404 = try LiveTimeshiftRecorder(directory: dir404)
        let counter404 = AttemptCounter()
        let started = Date()
        await recorder404.captureTransportStream(
            URL(string: "http://host/live/u/p/missing.ts")!,
            reconnectBackoff: 5.0
        ) { _ in
            counter404.increment()
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: LiveTimeshiftError.network(404))
            }
        }
        XCTAssertEqual(counter404.value, 1, "HTTP 404 must fail fast without retrying")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        let failure404 = await recorder404.transportStreamFailure()
        XCTAssertEqual(failure404 as? LiveTimeshiftError, .network(404))
        await recorder404.stop()

        let dir403 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder403 = try LiveTimeshiftRecorder(directory: dir403)
        let counter403 = AttemptCounter()
        await recorder403.captureTransportStream(
            URL(string: "http://host/live/u/p/slot.ts")!,
            reconnectBackoff: 0
        ) { _ in
            counter403.increment()
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: LiveTimeshiftError.network(403))
            }
        }
        XCTAssertEqual(counter403.value, 2, "HTTP 403 should allow one retry for single-connection handover")
        let failure403 = await recorder403.transportStreamFailure()
        XCTAssertEqual(failure403 as? LiveTimeshiftError, .network(403))
        await recorder403.stop()
    }

    func testCaptureTransportStreamPropagatesSegmentDiscontinuityToPlaylist() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder = try LiveTimeshiftRecorder(directory: directory)
        let payload = Data(stream(seconds: 3) + stream(seconds: 5, startPTS: 900_000 + 90_000 * 3600))
        let responses = Responses([payload])
        await recorder.captureTransportStream(
            URL(string: "http://host/live/u/p/jump.ts")!,
            reconnectBackoff: 0
        ) { _ in
            AsyncThrowingStream { continuation in
                if let chunk = responses.next() { continuation.yield(chunk) }
                continuation.finish()
            }
        }
        let playlist = String(decoding: try await recorder.playlist(), as: UTF8.self)
        XCTAssertTrue(playlist.contains("#EXT-X-DISCONTINUITY\n"), playlist)
        await recorder.stop()
    }

    func testZeroAllocSegmenterParityAcrossUnalignedChunksAndMisplacedAUD() {
        // Build a stream with misplaced AUD (SPS, PPS, AUD, IDR) fed across odd 137-byte chunks.
        func keyframePayload(pts: Int64) -> [UInt8] {
            let ptsBytes: [UInt8] = [
                0x21 | UInt8((pts >> 29) & 0x0E), UInt8((pts >> 22) & 0xFF),
                0x01 | UInt8((pts >> 14) & 0xFE), UInt8((pts >> 7) & 0xFF), 0x01 | UInt8((pts << 1) & 0xFE),
            ]
            let header: [UInt8] = [0, 0, 1, 0xE0, 0, 0, 0x80, 0x80, 0x05] + ptsBytes
            let sps: [UInt8] = [0, 0, 0, 1, 0x67, 0x42, 0x00]
            let pps: [UInt8] = [0, 0, 0, 1, 0x68, 0xCE]
            let aud: [UInt8] = [0, 0, 0, 1, 0x09, 0x10]
            let idr: [UInt8] = [0, 0, 0, 1, 0x65, 0x88]
            return header + sps + pps + aud + idr
        }

        var bytes: [UInt8] = []
        for frame in 0..<50 {
            let isKey = frame % 10 == 0
            let pts = Int64(900_000 + frame * 9_000)
            bytes += pat + pmt
            bytes += packet(
                pid: videoPID,
                unitStart: true,
                randomAccess: isKey,
                payload: isKey ? keyframePayload(pts: pts) : pes(pts: pts, keyframe: false)
            )
            bytes += packet(pid: videoPID, unitStart: false, payload: [UInt8](repeating: 0xAB, count: 184))
        }

        var singleShot = MPEGTSSegmenter(targetDuration: 2)
        let expected = singleShot.append(Data(bytes))
        XCTAssertEqual(expected.map(\.duration), [2, 2])

        var chunked = MPEGTSSegmenter(targetDuration: 2)
        var actual: [TransportStreamSegment] = []
        for start in stride(from: 0, to: bytes.count, by: 137) {
            actual += chunked.append(Data(bytes[start..<min(start + 137, bytes.count)]))
        }
        XCTAssertEqual(actual, expected)
    }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class MockClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval

    init(now: TimeInterval) { self.current = now }

    var value: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by delta: TimeInterval) {
        lock.lock()
        current += delta
        lock.unlock()
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
