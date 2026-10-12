import XCTest
@testable import BruTV

final class LiveTimeshiftTests: XCTestCase {
    private let base = URL(string: "https://provider.example/live/user/token/index.m3u8")!

    private func parse(_ text: String) throws -> LiveHLSPlaylist {
        guard case .media(let value) = try LiveHLSParser.parse(Data(text.utf8), baseURL: base) else {
            throw LiveTimeshiftError.invalidPlaylist
        }
        return value
    }

    private func segment(_ sequence: Int64, duration: Double = 2, discontinuity: Int64 = 0) -> RecordedHLSSegment {
        RecordedHLSSegment(sequence: sequence, discontinuity: discontinuity, duration: duration,
                           url: base.appendingPathComponent("\(sequence).ts"), programDateTime: nil, gap: false)
    }

    func testRelativeSegmentsAndTimelineMetadataAreParsed() throws {
        let playlist = try parse("""
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:200
        #EXT-X-DISCONTINUITY-SEQUENCE:3
        #EXT-X-PROGRAM-DATE-TIME:2026-10-12T10:00:00Z
        #EXTINF:4,
        ../../200.ts?token=private
        #EXT-X-DISCONTINUITY
        #EXTINF:4,
        201.ts
        """)
        XCTAssertEqual(playlist.segments.map(\.sequence), [200, 201])
        XCTAssertEqual(playlist.segments.map(\.discontinuity), [3, 4])
        XCTAssertEqual(playlist.segments[0].url.absoluteString, "https://provider.example/live/200.ts?token=private")
        XCTAssertEqual(playlist.segments[0].programDateTime, "2026-10-12T10:00:00Z")
    }

    func testMasterVariantSelectionAndSeparateRenditions() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=18000000,CODECS="avc1.640028,mp4a.40.2"
        4k.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6000000
        hd.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        low.m3u8
        """
        guard case .variant(let url) = try LiveHLSParser.parse(Data(master.utf8), baseURL: base) else {
            return XCTFail("Expected a master variant")
        }
        XCTAssertEqual(url.lastPathComponent, "hd.m3u8")
        XCTAssertThrowsError(try LiveHLSParser.parse(Data((master + "\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",URI=\"audio.m3u8\"\n").utf8), baseURL: base))
    }

    func testUnsupportedAndMalformedPlaylistsFailBeforeRecording() {
        let prefix = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n"
        for tag in ["#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"", "#EXT-X-MAP:URI=\"init.mp4\"",
                    "#EXT-X-BYTERANGE:20@0", "#EXT-X-SKIP:SKIPPED-SEGMENTS=2"] {
            XCTAssertThrowsError(try parse(prefix + tag + "\n#EXTINF:2,\n1.ts\n"))
        }
        for text in ["#EXTM3U\n#EXTINF:\n1.ts", prefix + "#EXTINF:NaN,\n1.ts",
                     prefix + "#EXTINF:2,\nfile:///tmp/secret", prefix + "#EXTINF:2,"] {
            XCTAssertThrowsError(try parse(text))
        }
        XCTAssertThrowsError(try LiveHLSParser.parse(Data(repeating: 0, count: 11), baseURL: base, limit: 10))
    }

    func testRingKeepsCapturedContentBeyondUpstreamWindowAndStopsCleanly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ring = try LiveTimeshiftRing(directory: directory, limits: LiveTimeshiftLimits(seconds: 10, bytes: 1024, segmentBytes: 100))
        defer { ring.stop() }
        // The recording loop runs independently of any playback or pause flag.
        for sequence in 0..<8 {
            try ring.append(segment(Int64(sequence)), data: Data(repeating: 1, count: 10), target: 2, now: Double(sequence * 2))
        }
        XCTAssertEqual(ring.snapshot.duration, 10)
        XCTAssertEqual(ring.entries.count, 5)
        let manifest = String(data: try ring.playlist(now: 16), encoding: .utf8)!
        XCTAssertTrue(manifest.contains("#EXT-X-MEDIA-SEQUENCE:3"))
        XCTAssertTrue(manifest.contains("segment-3.ts"))
        XCTAssertTrue(manifest.contains("segment-7.ts"))
        XCTAssertFalse(manifest.contains("PLAYLIST-TYPE"))
        ring.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertThrowsError(try ring.append(segment(9), data: Data([1]), target: 2, now: 18))
    }

    func testByteBudgetIncludesRetiredManifestLeases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ring = try LiveTimeshiftRing(directory: directory,
                                         limits: LiveTimeshiftLimits(seconds: 10, bytes: 80, segmentBytes: 20))
        defer { ring.stop() }
        for sequence in 0..<2 {
            try ring.append(segment(Int64(sequence)), data: Data(repeating: 1, count: 20), target: 2, now: 0)
        }
        _ = try ring.playlist(now: 0)
        try ring.append(segment(2), data: Data(repeating: 1, count: 20), target: 2, now: 2)
        try ring.append(segment(3), data: Data(repeating: 1, count: 20), target: 2, now: 4)
        XCTAssertEqual(ring.totalBytes, 80)
        XCTAssertNotNil(ring.file(named: "segment-0.ts"))
        try ring.append(segment(4), data: Data(repeating: 1, count: 20), target: 2, now: 6)
        XCTAssertLessThanOrEqual(ring.totalBytes, 80)
        XCTAssertNil(ring.file(named: "segment-0.ts"))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertEqual(bytes, ring.totalBytes)
        XCTAssertThrowsError(try ring.append(segment(5), data: Data(repeating: 1, count: 21), target: 2, now: 7))
    }

    func testSequenceGapAndSourceDiscontinuityRemainVisible() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ring = try LiveTimeshiftRing(directory: directory)
        defer { ring.stop() }
        try ring.append(segment(10), data: Data([1]), target: 2, now: 0)
        try ring.append(segment(14), data: Data([2]), target: 2, now: 2)
        try ring.append(segment(15, discontinuity: 1), data: Data([3]), target: 2, now: 4)
        let manifest = String(data: try ring.playlist(now: 4), encoding: .utf8)!
        XCTAssertEqual(manifest.components(separatedBy: "#EXT-X-DISCONTINUITY\n").count - 1, 2)
        XCTAssertNotNil(ring.snapshot.notice)
    }

    func testSeekClampAndGoLiveUseAvailableRangeAndHoldback() {
        XCTAssertEqual(LiveTimeshiftSeekPolicy.clamp(10, start: 30, end: 100), 30)
        XCTAssertEqual(LiveTimeshiftSeekPolicy.clamp(110, start: 30, end: 100) ?? 0, 99.95, accuracy: 0.001)
        XCTAssertEqual(LiveTimeshiftSeekPolicy.livePosition(start: 30, end: 100, targetDuration: 2), 94)
        XCTAssertNil(LiveTimeshiftSeekPolicy.clamp(.nan, start: 30, end: 100))
        XCTAssertNil(LiveTimeshiftSeekPolicy.livePosition(start: 100, end: 100, targetDuration: 2))
    }
}

private actor MovingHLSFixture {
    var head: Int64 = 2
    var window: Int64 = 3
    var segmentRequests: [Int64] = []

    init(head: Int64 = 2, window: Int64 = 3) { self.head = head; self.window = window }

    func fetch(_ url: URL, maximumBytes: Int) throws -> (Data, URL) {
        if url.pathExtension == "m3u8" {
            let first = max(0, head - window + 1)
            var text = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:\(first)\n"
            for sequence in first...head { text += "#EXTINF:2,\n\(sequence).ts\n" }
            head += 1
            return (Data(text.utf8), url)
        }
        let sequence = Int64(url.deletingPathExtension().lastPathComponent)!
        segmentRequests.append(sequence)
        return (Data(repeating: UInt8(sequence), count: 10), url)
    }
}

extension LiveTimeshiftTests {
    func testRecorderFetchesForwardWithoutPlaybackAndRetainsPastUpstreamExpiry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = MovingHLSFixture()
        let recorder = try LiveTimeshiftRecorder(limits: LiveTimeshiftLimits(seconds: 30, bytes: 1024),
                                                directory: directory, fetch: { try await source.fetch($0, maximumBytes: $1) })
        let url = URL(string: "https://provider.example/live.m3u8")!
        for _ in 0..<6 { _ = try await recorder.capture(url) }
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.duration, 16)
        XCTAssertEqual(snapshot.targetDuration, 2)
        let manifest = String(data: try await recorder.playlist(), encoding: .utf8)!
        XCTAssertTrue(manifest.contains("segment-0.ts"))
        let requests = await source.segmentRequests
        XCTAssertEqual(requests, [0, 1, 2, 3, 4, 5, 6, 7])
        // Upstream exposes only sequences 5,6,7; earlier capture remains on disk.
        let first = try await recorder.segment(named: "segment-0.ts")
        XCTAssertEqual(first, Data(repeating: 0, count: 10))
        await recorder.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCancellationCannotPublishAfterSessionCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder = try LiveTimeshiftRecorder(directory: directory, fetch: { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw LiveTimeshiftError.invalidPlaylist
        })
        let task = Task { try await recorder.capture(URL(string: "https://provider.example/live.m3u8")!) }
        await Task.yield()
        task.cancel()
        await recorder.stop()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.bytes, 0)
    }
}

extension LiveTimeshiftTests {
    func testRetryMapsRecordedAnchorWhenNativeItemTimelineRebases() {
        // Original native time80/end100 corresponds to recording second180/end200.
        // During retry recording grows to210 and the new native item has range0...60.
        XCTAssertEqual(LiveTimeshiftSeekPolicy.restoredPosition(recordedPosition: 180, recordedEnd: 210,
                                                               seekableStart: 0, seekableEnd: 60), 30)
        XCTAssertEqual(LiveTimeshiftSeekPolicy.restoredPosition(recordedPosition: 100, recordedEnd: 210,
                                                               seekableStart: 20, seekableEnd: 60), 20)
    }

    func testLocalPlaylistHasStableDatesForNativeItemRetryWithoutProviderDates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ring = try LiveTimeshiftRing(directory: directory)
        defer { ring.stop() }
        try ring.append(segment(1), data: Data([1]), target: 2, now: 1000)
        try ring.append(segment(2), data: Data([2]), target: 2, now: 1004)
        let first = try parse(String(data: try ring.playlist(now: 1004), encoding: .utf8)!)
        try ring.append(segment(3), data: Data([3]), target: 2, now: 1006)
        let second = try parse(String(data: try ring.playlist(now: 1006), encoding: .utf8)!)
        XCTAssertEqual(first.segments.map(\.programDateTime), Array(second.segments.prefix(2)).map(\.programDateTime))
        XCTAssertTrue(second.segments.allSatisfy { $0.programDateTime != nil })
        XCTAssertEqual(ring.snapshot.recordedEnd, 6)
    }
}

extension LiveTimeshiftTests {
    func testCodecFallbackOnlyConsumesOneUnsupportedRecordedVariantPerSession() {
        var policy = LiveTimeshiftCodecFallback()
        XCTAssertFalse(policy.consume(for: .unauthorized, recording: true))
        XCTAssertFalse(policy.consume(for: .transient, recording: true))
        XCTAssertFalse(policy.consume(for: .unsupported, recording: false))
        XCTAssertTrue(policy.consume(for: .unsupported, recording: true))
        XCTAssertFalse(policy.consume(for: .unsupported, recording: true))
        policy = LiveTimeshiftCodecFallback()
        XCTAssertTrue(policy.consume(for: .unsupported, recording: true))
    }
}

extension LiveTimeshiftTests {
    func testTinySegmentsAndOversizedSegmentListsAreRejected() throws {
        XCTAssertThrowsError(try parse("#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:0.000001,\n1.ts\n"))
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:1\n" + (0..<4).map { "#EXTINF:0.25,\n\($0).ts\n" }.joined()
        XCTAssertThrowsError(try LiveHLSParser.parse(Data(text.utf8), baseURL: base, segmentLimit: 3))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ring = try LiveTimeshiftRing(directory: directory, limits: LiveTimeshiftLimits(segmentCount: 4))
        defer { ring.stop() }
        for sequence in 0..<8 {
            try ring.append(segment(Int64(sequence)), data: Data([1]), target: 2, now: Double(sequence * 2))
        }
        XCTAssertEqual(ring.entries.count, 2)
        XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 4)
    }

    func testActiveReadersKeepExpiredFilesCountedUntilClose() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ring = try LiveTimeshiftRing(directory: directory,
                                         limits: LiveTimeshiftLimits(seconds: 10, bytes: 80, segmentBytes: 20))
        defer { ring.stop() }
        try ring.append(segment(0), data: Data(repeating: 1, count: 20), target: 2, now: 0)
        let url = try XCTUnwrap(ring.acquireFile(named: "segment-0.ts"))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        for sequence in 1..<4 {
            try ring.append(segment(Int64(sequence)), data: Data(repeating: 1, count: 20), target: 2, now: Double(sequence * 2))
        }
        ring.reap(now: 100)
        XCTAssertEqual(ring.totalBytes, 60)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try handle.readToEnd(), Data(repeating: 1, count: 20))
        ring.stop()
        XCTAssertEqual(ring.totalBytes, 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        try handle.close()
        ring.releaseFile(named: "segment-0.ts", now: 100)
        XCTAssertEqual(ring.totalBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

extension LiveTimeshiftTests {
    func testStartupDeadlineCancelsAnInFlightSegmentDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder = try LiveTimeshiftRecorder(directory: directory, fetch: { url, _ in
            if url.pathExtension == "m3u8" {
                return (Data("#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\n1.ts\n".utf8), url)
            }
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return (Data([1]), url)
        })
        let started = Date()
        do {
            _ = try await recorder.capture(base, timeout: 0.05)
            XCTFail("Expected the startup deadline to cancel the download")
        } catch {
            XCTAssertEqual(error as? LiveTimeshiftError, .startupTimeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.duration, 0)
        await recorder.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRecorderStartsNearLiveWithoutDownloadingWholeProviderArchive() async throws {
        let source = MovingHLSFixture(head: 50, window: 50)
        let recorder = try LiveTimeshiftRecorder(fetch: { try await source.fetch($0, maximumBytes: $1) })
        _ = try await recorder.capture(URL(string: "https://provider.example/live.m3u8")!)
        let requests = await source.segmentRequests
        XCTAssertEqual(requests, [48, 49, 50])
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.duration, 6)
        _ = try await recorder.capture(URL(string: "https://provider.example/live.m3u8")!)
        let later = await source.segmentRequests
        XCTAssertEqual(later, [48, 49, 50, 51])
        await recorder.stop()
    }
}
