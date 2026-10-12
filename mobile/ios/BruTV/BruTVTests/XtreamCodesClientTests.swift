import XCTest
@testable import BruTV

final class XtreamCodesClientTests: XCTestCase {
    func testLiveStreamURLGeneration() async {
        let client = XtreamCodesClient(
            serverURLString: "http://virello.win",
            username: "Bruno081225p2",
            password: "tv8392602653"
        )

        let hlsURL = await client.liveStreamURL(streamID: 62169, format: .hls)
        XCTAssertEqual(hlsURL?.absoluteString, "http://virello.win/live/Bruno081225p2/tv8392602653/62169.m3u8")

        let tsURL = await client.liveStreamURL(streamID: 62169, format: .ts)
        XCTAssertEqual(tsURL?.absoluteString, "http://virello.win/live/Bruno081225p2/tv8392602653/62169.ts")
    }

    func testVODStreamURLGeneration() async {
        let client = XtreamCodesClient(
            serverURLString: "http://virello.win",
            username: "Bruno081225p2",
            password: "tv8392602653"
        )

        let vodURL = await client.vodStreamURL(streamID: 1325116, containerExtension: "mp4")
        XCTAssertEqual(vodURL?.absoluteString, "http://virello.win/movie/Bruno081225p2/tv8392602653/1325116.mp4")
    }

    func testAuthResponseDecoding() throws {
        let json = """
        {
          "user_info": {
            "username": "Bruno081225p2",
            "password": "tv8392602653",
            "message": "",
            "auth": 1,
            "status": "Active",
            "exp_date": "1796785199",
            "is_trial": "0",
            "active_cons": "0",
            "created_at": "1765202020",
            "max_connections": "1",
            "allowed_output_formats": ["m3u8", "ts", "rtmp"]
          },
          "server_info": {
            "url": "virello.win",
            "port": "80",
            "https_port": "25463",
            "server_protocol": "http",
            "rtmp_port": "25462",
            "timezone": "America/Sao_Paulo",
            "timestamp_now": 1791787563,
            "time_now": "2026-10-12 03:46:03",
            "process": true
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(AuthResponse.self, from: json)
        XCTAssertEqual(response.userInfo.username, "Bruno081225p2")
        XCTAssertEqual(response.userInfo.status, "Active")
        XCTAssertEqual(response.userInfo.auth, 1)
        XCTAssertFalse(response.userInfo.isExpired)
        XCTAssertEqual(response.serverInfo.url, "virello.win")
    }

    func testLiveStreamQualityDetection() {
        let fhdStream = LiveStream(id: 1, name: "Globo SP FHD")
        XCTAssertEqual(fhdStream.quality, .fhd)
        XCTAssertEqual(fhdStream.cleanName, "Globo SP")

        let hdStream = LiveStream(id: 2, name: "SBT HD")
        XCTAssertEqual(hdStream.quality, .hd)
        XCTAssertEqual(hdStream.cleanName, "SBT")

        let uhdStream = LiveStream(id: 3, name: "Record 4K")
        XCTAssertEqual(uhdStream.quality, .uhd4k)
        XCTAssertEqual(uhdStream.cleanName, "Record")

        let sdStream = LiveStream(id: 4, name: "Band")
        XCTAssertEqual(sdStream.quality, .sd)
        XCTAssertEqual(sdStream.cleanName, "Band")
    }
}
