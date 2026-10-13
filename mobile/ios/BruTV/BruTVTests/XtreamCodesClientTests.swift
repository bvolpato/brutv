import XCTest
@testable import BruTV

final class XtreamCodesClientTests: XCTestCase {
    func testLiveStreamURLGeneration() {
        let client = XtreamCodesClient(
            serverURLString: "http://provider.example.test",
            username: "fixture-user",
            password: "fixture-password"
        )

        let hlsURL = client.liveStreamURL(streamID: 62169, format: .hls)
        XCTAssertEqual(hlsURL?.absoluteString, "http://provider.example.test/live/fixture-user/fixture-password/62169.m3u8")

        let tsURL = client.liveStreamURL(streamID: 62169, format: .ts)
        XCTAssertEqual(tsURL?.absoluteString, "http://provider.example.test/live/fixture-user/fixture-password/62169.ts")
    }

    func testVODStreamURLGeneration() {
        let client = XtreamCodesClient(
            serverURLString: "http://provider.example.test",
            username: "fixture-user",
            password: "fixture-password"
        )

        let vodURL = client.vodStreamURL(streamID: 1325116, containerExtension: "mp4")
        XCTAssertEqual(vodURL?.absoluteString, "http://provider.example.test/movie/fixture-user/fixture-password/1325116.mp4")
    }

    func testSeriesStreamURLGeneration() {
        let client = XtreamCodesClient(
            serverURLString: "http://provider.example.test",
            username: "fixture-user",
            password: "fixture-password"
        )

        let seriesURL = client.seriesStreamURL(streamID: 22615, containerExtension: "mp4")
        XCTAssertEqual(seriesURL?.absoluteString, "http://provider.example.test/series/fixture-user/fixture-password/22615.mp4")
    }

    func testSeriesDetailsDecoding() throws {
        let json = """
        {
          "seasons": [],
          "info": {
            "name": "Altered Carbon",
            "cover": "http://img.example.test/cover.jpg",
            "plot": "In a futuristic world where consciousness is digitized...",
            "cast": "Joel Kinnaman",
            "director": "Laeta Kalogridis",
            "genre": "Sci-Fi",
            "rating": "8.0"
          },
          "episodes": {
            "1": [
              {
                "id": "22615",
                "episode_num": "1",
                "title": "Out of the Past",
                "container_extension": "mp4",
                "season": "1",
                "info": {
                  "duration": "55m",
                  "duration_secs": "3300",
                  "movie_image": "http://img.example.test/ep1.jpg",
                  "plot": "Takeshi Kovacs is awakened...",
                  "rating": "8.5"
                }
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let details = try JSONDecoder().decode(SeriesDetails.self, from: json)
        XCTAssertEqual(details.info?.name, "Altered Carbon")
        XCTAssertEqual(details.info?.rating, "8.0")
        XCTAssertEqual(details.episodes.count, 1)

        let season1 = try XCTUnwrap(details.episodes["1"])
        XCTAssertEqual(season1.count, 1)
        XCTAssertEqual(season1[0].id, 22615)
        XCTAssertEqual(season1[0].episodeNum, 1)
        XCTAssertEqual(season1[0].title, "Out of the Past")
        XCTAssertEqual(season1[0].containerExtension, "mp4")
        XCTAssertEqual(season1[0].season, 1)
        XCTAssertEqual(season1[0].info?.duration, "55m")
        XCTAssertEqual(season1[0].info?.durationSecs, 3300)
    }

    func testAuthResponseDecoding() throws {
        let expiration = Int(Date().timeIntervalSince1970) + 3_600
        let json = """
        {
          "user_info": {
            "username": "fixture-user",
            "password": "fixture-password",
            "message": "",
            "auth": 1,
            "status": "Active",
            "exp_date": "\(expiration)",
            "is_trial": "0",
            "active_cons": "0",
            "created_at": "1765202020",
            "max_connections": "1",
            "allowed_output_formats": ["m3u8", "ts", "rtmp"]
          },
          "server_info": {
            "url": "provider.example.test",
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
        XCTAssertEqual(response.userInfo.username, "fixture-user")
        XCTAssertEqual(response.userInfo.status, "Active")
        XCTAssertEqual(response.userInfo.auth, 1)
        XCTAssertFalse(response.userInfo.isExpired)
        XCTAssertEqual(response.serverInfo.url, "provider.example.test")
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

    func testVODDetailsDecodingAndPlot() throws {
        let json = """
        {
          "info": {
            "name": "Inception",
            "plot": "A thief who steals corporate secrets through dream-sharing technology...",
            "cast": "Leonardo DiCaprio",
            "director": "Christopher Nolan",
            "genre": "Action, Sci-Fi",
            "rating": "8.8"
          }
        }
        """.data(using: .utf8)!

        let details = try JSONDecoder().decode(VODDetails.self, from: json)
        XCTAssertEqual(details.info?.name, "Inception")
        XCTAssertEqual(details.info?.director, "Christopher Nolan")
        XCTAssertEqual(details.info?.rating, "8.8")
        XCTAssertTrue(details.info?.plot?.contains("dream-sharing") == true)

        let streamJSON = """
        {
          "stream_id": 991,
          "name": "Inception",
          "stream_icon": "http://img.example.test/inception.jpg",
          "rating": 8.8,
          "plot": "A thief who steals corporate secrets..."
        }
        """.data(using: .utf8)!
        let stream = try JSONDecoder().decode(VODStream.self, from: streamJSON)
        XCTAssertEqual(stream.id, 991)
        XCTAssertEqual(stream.name, "Inception")
        XCTAssertEqual(stream.rating, "8.8")
        XCTAssertEqual(stream.plot, "A thief who steals corporate secrets...")
    }
}
