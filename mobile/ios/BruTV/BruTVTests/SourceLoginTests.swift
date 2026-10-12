import XCTest
@testable import BruTV

final class SourceLoginTests: XCTestCase {
    // MARK: - M3U parser

    func testParsesProviderPlaylistWithCRLFAndAttributes() {
        // Real providers emit "\r\r\n" line endings and commas inside quoted attributes.
        let playlist = "#EXTM3U\r\r\n"
            + "#EXTINF:-1 tvg-id=\"br#globo\" tvg-name=\"Globo SP FHD\" tvg-logo=\"http://img/globo.png\" group-title=\"GLOBO, SUDESTE\",Globo SP FHD\r\r\n"
            + "http://host:80/live/u/p/62169.m3u8\r\r\n"
            + "#EXTINF:-1 group-title=\"FILMES\",Some Movie\r\r\n"
            + "http://host:80/movie/u/p/1.mp4\r\r\n"

        let entries = M3UPlaylistParser.parse(playlist)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Globo SP FHD")
        XCTAssertEqual(entries[0].url, "http://host:80/live/u/p/62169.m3u8")
        XCTAssertEqual(entries[0].logo, "http://img/globo.png")
        XCTAssertEqual(entries[0].group, "GLOBO, SUDESTE")
        XCTAssertEqual(entries[0].tvgID, "br#globo")
        XCTAssertFalse(entries[0].isVOD)
        XCTAssertTrue(entries[1].isVOD)
    }

    func testFallsBackToExtgrpTvgNameAndPlainURLs() {
        let playlist = """
        #EXTM3U
        #EXTINF:-1 tvg-name="News HD",
        #EXTGRP:News
        #EXTVLCOPT:http-user-agent=Foo
        https://cdn/news.m3u8
        https://cdn/bare-channel.m3u8
        """

        let entries = M3UPlaylistParser.parse(playlist)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "News HD")
        XCTAssertEqual(entries[0].group, "News")
        XCTAssertEqual(entries[1].name, "bare-channel.m3u8")
        XCTAssertEqual(entries[1].group, M3UPlaylistParser.ungroupedTitle)
    }

    func testMultiGroupEntryUsesFirstGroup() {
        let playlist = """
        #EXTM3U
        #EXTINF:-1 group-title="Animation;Comedy",Cartoons
        https://cdn/cartoons.m3u8
        #EXTINF:-1 group-title=" ;Kids",Kids TV
        https://cdn/kids.m3u8
        #EXTINF:-1 group-title="",No Group
        https://cdn/none.m3u8
        """

        let groups = M3UPlaylistParser.parse(playlist).map(\.group)

        XCTAssertEqual(groups, ["Animation", "Kids", M3UPlaylistParser.ungroupedTitle])
    }

    func testStableIDIsDeterministicAndPositive() {
        let a = M3UPlaylistParser.stableID(for: "http://host/live/1.m3u8")
        XCTAssertEqual(a, M3UPlaylistParser.stableID(for: "http://host/live/1.m3u8"))
        XCTAssertNotEqual(a, M3UPlaylistParser.stableID(for: "http://host/live/2.m3u8"))
        XCTAssertGreaterThanOrEqual(a, 0)
    }

    // MARK: - Login links

    func testXtreamLinkRoundTripsSpecialCharacters() throws {
        let link = LoginLink.xtream(server: "http://host:8080", username: "joão", password: "p&ss=w+rd?#")
        XCTAssertEqual(LoginLink(url: link.url), link)
        XCTAssertEqual(link.url.scheme, "brutv")
        XCTAssertEqual(link.url.host, "login")
    }

    func testM3ULinkRoundTripsNestedQuery() {
        let playlist = "https://cdn.example.com/list.m3u?token=a&b=c+d"
        let link = LoginLink.m3u(url: playlist)
        XCTAssertEqual(LoginLink(url: link.url), .m3u(url: playlist))
    }

    func testLoginLinksPreserveExistingPercentEscapes() {
        let playlist = "https://cdn.example.com/panel%20name/list.m3u?token=a%2Bb%26c"
        let playlistLink = LoginLink.m3u(url: playlist)
        XCTAssertEqual(LoginLink(url: playlistLink.url), playlistLink)

        let accountLink = LoginLink.xtream(
            server: "https://provider.example/panel%20name",
            username: "user%2B+tag",
            password: "pass%2F+word"
        )
        XCTAssertEqual(LoginLink(url: accountLink.url), accountLink)
    }

    func testXtreamGetPhpPlaylistBecomesXtreamLogin() {
        let link = LoginLink.fromPlaylistURL(
            "http://provider.example.test:80/get.php?username=fixture-user&password=fixture-password&type=m3u_plus&output=m3u8"
        )
        XCTAssertEqual(link, .xtream(server: "http://provider.example.test:80", username: "fixture-user", password: "fixture-password"))
    }

    func testPlainPlaylistStaysM3U() {
        let url = "https://iptv-org.github.io/iptv/countries/br.m3u"
        XCTAssertEqual(LoginLink.fromPlaylistURL(url), .m3u(url: url))
        XCTAssertEqual(LoginLink(pasted: "  \(url)\n"), .m3u(url: url))
    }

    func testRejectsInvalidLinks() {
        XCTAssertNil(LoginLink(url: URL(string: "brutv://login?server=http://h&username=u")!))
        XCTAssertNil(LoginLink(url: URL(string: "https://login?m3u=x")!))
        XCTAssertNil(LoginLink(url: URL(string: "brutv://other?m3u=x")!))
        XCTAssertNil(LoginLink(pasted: "not a url at all"))
        XCTAssertNil(LoginLink(pasted: "ftp://host/list.m3u"))
    }

    // MARK: - Profiles and playback

    func testLegacyProfileWithoutKindDecodesAsXtream() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","serverURL":"http://h","username":"u","password":"p","isActive":true}"#
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.kind, .xtream)
        XCTAssertEqual(profile.loginLink, .xtream(server: "http://h", username: "u", password: "p"))
    }

    #if !SWIFT_PACKAGE
    func testPlaylistTsEntriesPlayAsHLS() {
        XCTAssertEqual(
            PlaybackManager.playableURL(fromPlaylistEntry: "http://host:80/live/u/p/1948.ts")?.absoluteString,
            "http://host:80/live/u/p/1948.m3u8"
        )
        XCTAssertEqual(
            PlaybackManager.playableURL(fromPlaylistEntry: "https://cdn/stream.ts")?.absoluteString,
            "https://cdn/stream.ts"
        )
    }
    #endif
}
