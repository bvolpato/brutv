#include "brutv/catalog.hpp"

#include <atomic>
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <sys/stat.h>

using namespace brutv;

namespace {
void loginLinks() {
    const auto link = "https://brunovolpato.com/brutv/join.html?m3u="
        "https%3A%2F%2Fprovider.example%2Flist.m3u%3Ftoken%3Da%252Bb%26name%3DA%2520B";
    auto source = parseLoginLink(link);
    assert(source && source->type == SourceType::M3U);
    assert(source->url == "https://provider.example/list.m3u?token=a%2Bb&name=A%20B");

    auto xtream = parseLoginLink(
        "brutv://login?server=https%3A%2F%2Fprovider.example%2Fpanel&username=jo%C3%A3o%2Bone%26two&password=secret%20%2B%20%26%3D%3F%23%25");
    assert(xtream && xtream->type == SourceType::Xtream);
    assert(xtream->url == "https://provider.example/panel");
    assert(xtream->username == "joão+one&two");
    assert(xtream->password == "secret + &=?#%");

    auto getPhp = parseLoginLink("https://provider.example/panel/get.php?username=one%2Btwo&password=secret%26value&type=m3u_plus");
    assert(getPhp && getPhp->type == SourceType::Xtream);
    assert(getPhp->url == "https://provider.example/panel");
    assert(getPhp->username == "one+two" && getPhp->password == "secret&value");
    assert(!parseLoginLink("https://brunovolpato.com/brutv/join.html?username=missing"));
    auto unrelated = parseLoginLink("https://untrusted.example/brutv/join.html?server=https%3A%2F%2Fp.example&username=x&password=y");
    assert(unrelated && unrelated->type == SourceType::M3U);
}

void m3uCatalogAndHlsGuard() {
    Source source;
    source.id = "playlist-one";
    source.type = SourceType::M3U;
    source.url = "https://provider.example/lists/main.m3u?token=t";
    const std::string playlist =
        "#EXTM3U\n"
        "#EXTINF:-1 tvg-id=\"news.us\" tvg-logo='https://img.example/logo.png' group-title=\"News;US\",News HD, East\n"
        "#EXTVLCOPT:http-user-agent=BruTV Test Agent\n"
        "#EXTHTTP:{\"Referer\":\"https://provider.example/watch\"}\n"
        "channels/news.m3u8?token=a%2Bb\n"
        "#EXTINF:-1 group-title=\"Films\",A Film\n"
        "../movie/a-film.mkv\n";
    CatalogClient client([&](const std::string& url) {
        assert(url == source.url);
        return playlist;
    });

    auto live = client.load(source, MediaKind::Live);
    assert(live.items.size() == 1);
    assert(live.categories.size() == 1 && live.categories[0].name == "News");
    const auto& channel = live.items.front();
    assert(channel.title == "News HD, East");
    assert(channel.epgId == "news.us");
    assert(channel.logoUrl == "https://img.example/logo.png");
    assert(channel.mediaUrl == "https://provider.example/lists/channels/news.m3u8?token=a%2Bb");
    assert(channel.requestHeaders.at("User-Agent") == "BruTV Test Agent");
    assert(channel.requestHeaders.at("Referer") == "https://provider.example/watch");
    assert(channel.id == client.load(source, MediaKind::Live).items.front().id);
    auto movies = client.load(source, MediaKind::Movie);
    assert(movies.items.size() == 1 && movies.items[0].title == "A Film");

    CatalogClient hls([](const std::string&) {
        return "#EXTM3U\n#EXT-X-TARGETDURATION:8\n#EXTINF:8,\nhttps://cdn.example/seg.ts\n#EXT-X-ENDLIST\n";
    });
    bool rejected = false;
    try { (void)hls.load(source, MediaKind::Live); }
    catch (const CatalogError& error) { rejected = std::string(error.what()).find("HLS media manifest") != std::string::npos; }
    assert(rejected);
}

void xtreamCatalogEpisodesAndEpg() {
    Source source;
    source.id = "provider";
    source.type = SourceType::Xtream;
    source.url = "https://iptv.example/panel/";
    source.username = "user/name";
    source.password = "pass + word";
    std::vector<std::string> requested;
    CatalogClient client([&](const std::string& url) {
        requested.push_back(url);
        assert(url.find("username=user%2Fname") != std::string::npos);
        assert(url.find("password=pass%20%2B%20word") != std::string::npos);
        if (url.find("action=get_live_categories") != std::string::npos)
            return std::string(R"([{"category_id":3,"category_name":"News"},{"category_id":"3","category_name":"Duplicate"}])");
        if (url.find("action=get_live_streams") != std::string::npos)
            return std::string(R"([{"stream_id":77,"name":"World News","category_id":"3","epg_channel_id":"world.news","stream_icon":"https://img.example/news.png"},{"stream_id":77,"name":"duplicate"}])");
        if (url.find("action=get_series_info") != std::string::npos)
            return std::string(R"({"episodes":{"10":[{"id":100,"episode_num":1,"title":"Later Season","container_extension":"mkv","info":{"plot":"later","duration_secs":1200}}],"2":[{"id":20,"episode_num":3,"title":"First Season","info":{"movie_image":"https://img.example/ep.png","releasedate":"2025-01-02"}}]}})");
        if (url.find("action=get_short_epg") != std::string::npos)
            return std::string(R"({"epg_listings":[{"title":"Evening News","description":"World update","start_timestamp":"1735689600","stop_timestamp":"1735693200"},{"title":"TmV3cw==","description":"VGVzdA==","start":"2025-01-01 00:00:00","end":"2025-01-01 01:00:00"}]})");
        if (url.find("/player_api.php?") != std::string::npos)
            return std::string(R"({"user_info":{"auth":"1","status":"Active"}})");
        return std::string("[]");
    });

    auto live = client.load(source, MediaKind::Live);
    assert(live.categories.size() == 1 && live.categories[0].name == "News");
    assert(live.items.size() == 1);
    assert(live.items[0].epgId == "world.news");
    assert(live.items[0].mediaUrl == "https://iptv.example/panel/live/user%2Fname/pass%20%2B%20word/77.m3u8");
    assert(live.items[0].logoUrl == "https://img.example/news.png");

    client.authenticate(source);
    auto episodes = client.loadEpisodes(source, "99");
    assert(episodes.size() == 2);
    assert(episodes[0].title == "First Season");
    assert(episodes[0].episodeDetails->seasonNumber == 2);
    assert(episodes[0].episodeDetails->episodeNumber == 3);
    assert(episodes[0].mediaUrl == "https://iptv.example/panel/series/user%2Fname/pass%20%2B%20word/20.mp4");
    assert(episodes[1].episodeDetails->durationSeconds == 1200);
    auto guide = client.loadEpg(source, "77");
    assert(guide.size() == 2 && guide[0].title == "Evening News");
    assert(guide[0].startEpochSeconds == 1735689600);
    assert(guide[1].title == "News" && guide[1].description == "Test");
    assert(guide[1].startEpochSeconds == 1735689600 && guide[1].endEpochSeconds == 1735693200);
    assert(requested.size() == 5);
}

void providerFailuresDoNotExposeCredentials() {
    Source source;
    source.type = SourceType::Xtream;
    source.url = "https://iptv.example";
    source.username = "private-user";
    source.password = "private-password";
    CatalogClient rejected([](const std::string&) {
        return std::string(R"({"user_info":{"auth":0,"status":"Disabled"}})");
    });
    bool failed = false;
    try { rejected.authenticate(source); }
    catch (const CatalogError& error) {
        const std::string message = error.what();
        failed = message.find("private-user") == std::string::npos &&
                 message.find("private-password") == std::string::npos;
    }
    assert(failed);

    CatalogClient transport([](const std::string&) { throw std::runtime_error("URL and credentials should not escape"); return std::string{}; });
    try { (void)transport.load(source, MediaKind::Live); assert(false); }
    catch (const CatalogError& error) {
        assert(std::string(error.what()).find("credentials") == std::string::npos);
    }

    CatalogClient deeplyNested([](const std::string&) {
        return std::string(70, '[') + "0" + std::string(70, ']');
    });
    try { (void)deeplyNested.load(source, MediaKind::Live); assert(false); }
    catch (const CatalogError& error) {
        assert(std::string(error.what()).find("nesting limit") != std::string::npos);
    }
}

void settingsAtomicPrivateRoundTripAndRecovery() {
    const auto root = std::filesystem::temp_directory_path() / "brutv-ps5-catalog-test";
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root);
    const auto path = root / "settings.json";
    SettingsStore store(path);

    Settings settings;
    Source source;
    source.id = "source-key";
    source.type = SourceType::Xtream;
    source.name = "Test";
    source.url = "https://iptv.example/panel";
    source.username = "user";
    source.password = "credential";
    settings.source = source;
    settings.volume = 0.65F;
    settings.locale = "pt-BR";
    settings.favoritesBySource[source.id] = {"source-key:live:9"};
    MediaItem recent;
    recent.id = "source-key:live:9";
    recent.sourceId = source.id;
    recent.providerId = "9";
    recent.title = "News";
    recent.kind = MediaKind::Live;
    recent.mediaUrl = "https://iptv.example/live/user/credential/9.m3u8";
    settings.recentsBySource[source.id] = {recent};
    store.save(settings);

    struct stat status {};
    assert(::stat(path.c_str(), &status) == 0);
    assert((status.st_mode & 0777) == 0600);
    auto restored = store.load();
    assert(restored.source && restored.source->password == "credential");
    assert(restored.volume > 0.64F && restored.volume < 0.66F);
    assert(restored.locale == "pt-BR");
    assert(restored.favoritesBySource.at(source.id).count(recent.id) == 1);
    assert(restored.recentsBySource.at(source.id).front().title == "News");

    Settings draftSettings;
    Source draft;
    draft.type = SourceType::M3U;
    draft.name = "Draft source";
    draftSettings.source = draft;
    store.save(draftSettings);
    auto restoredDraft = store.load();
    assert(restoredDraft.source && restoredDraft.source->url.empty());

    { std::ofstream malformed(path, std::ios::trunc); malformed << "{broken"; }
    auto recovered = store.load();
    assert(!recovered.source && recovered.volume == 1.0F && recovered.locale == "system");
    { std::ofstream wrongVersion(path, std::ios::trunc); wrongVersion << R"({"version":987,"volume":0.2})"; }
    assert(store.load().volume == 1.0F);
    std::filesystem::remove_all(root);
}

void xtreamLiveAlternateAndOutputFormats() {
    auto toTs = alternateXtreamLiveUrl("https://iptv.example/live/user1/pass1/77.m3u8");
    assert(toTs && *toTs == "https://iptv.example/live/user1/pass1/77.ts");

    auto toM3u8 = alternateXtreamLiveUrl("https://iptv.example/live/user1/pass1/77.ts");
    assert(toM3u8 && *toM3u8 == "https://iptv.example/live/user1/pass1/77.m3u8");

    auto withPanelAndQuery = alternateXtreamLiveUrl(
        "https://iptv.example/panel/live/user%2Fname/pass%20word/77.M3U8?token=a%2Bb&k=1#frag");
    assert(withPanelAndQuery &&
           *withPanelAndQuery ==
               "https://iptv.example/panel/live/user%2Fname/pass%20word/77.ts?token=a%2Bb&k=1#frag");

    auto reverseWithPortAndQuery = alternateXtreamLiveUrl(
        "http://127.0.0.1:8080/live/u/p/99.TS?token=xyz");
    assert(reverseWithPortAndQuery &&
           *reverseWithPortAndQuery == "http://127.0.0.1:8080/live/u/p/99.m3u8?token=xyz");

    auto shortToTs = alternateXtreamLiveUrl("https://iptv.example/user1/pass1/77.m3u8?k=1#frag");
    assert(shortToTs && *shortToTs == "https://iptv.example/user1/pass1/77.ts?k=1#frag");
    auto shortToM3u8 = alternateXtreamLiveUrl("https://iptv.example/user1/pass1/77.ts?k=1");
    assert(shortToM3u8 && *shortToM3u8 == "https://iptv.example/user1/pass1/77.m3u8?k=1");

    assert(!alternateXtreamLiveUrl("https://iptv.example/movie/u/p/77.m3u8"));
    assert(!alternateXtreamLiveUrl("https://iptv.example/series/u/p/77.ts"));
    assert(!alternateXtreamLiveUrl("https://iptv.example/movie/sub/77.m3u8"));
    assert(!alternateXtreamLiveUrl("https://iptv.example/series/sub/77.ts"));
    assert(!alternateXtreamLiveUrl("https://iptv.example/timeshift/sub/77.ts"));
    assert(!alternateXtreamLiveUrl("https://iptv.example/vod/sub/77.m3u8"));
    assert(!alternateXtreamLiveUrl("https://iptv.example/hls/sub/77.m3u8"));
    assert(!alternateXtreamLiveUrl("https://iptv.example/streams/sub/77.m3u8"));
    assert(!alternateXtreamLiveUrl("https://iptv.example/static/sub/77.m3u8"));
    assert(!alternateXtreamLiveUrl("https://iptv.example/assets/sub/77.m3u8"));
    assert(!alternateXtreamLiveUrl("https://iptv.example/hls/index.m3u8"));
    assert(!alternateXtreamLiveUrl("https://iptv.example/live/u/p/.m3u8"));
    assert(!alternateXtreamLiveUrl("https://iptv.example/live/u//77.m3u8"));
    assert(!alternateXtreamLiveUrl("https://iptv.example/user1//77.m3u8"));
    assert(!alternateXtreamLiveUrl("https://iptv.example//live/u/p/77.m3u8"));
    assert(!alternateXtreamLiveUrl("https://iptv.example/live/u/p/77.mp4"));
    assert(!alternateXtreamLiveUrl("file:///live/u/p/77.m3u8"));
    assert(!alternateXtreamLiveUrl("/live/u/p/77.m3u8"));

    Source source;
    source.id = "ts-only-provider";
    source.type = SourceType::Xtream;
    source.url = "https://iptv.example/panel";
    source.username = "u";
    source.password = "p";
    CatalogClient tsOnlyClient([](const std::string& url) {
        if (url.find("action=get_live_categories") != std::string::npos)
            return std::string(R"([{"category_id":"1","category_name":"Live"}])");
        if (url.find("action=get_live_streams") != std::string::npos)
            return std::string(R"([{"stream_id":42,"name":"Channel TS","category_id":"1"}])");
        return std::string(R"({"user_info":{"auth":1,"status":"Active","allowed_output_formats":["ts"]}})");
    });
    tsOnlyClient.authenticate(source);
    assert(tsOnlyClient.preferredLiveFormat(source) == "ts");
    auto tsLive = tsOnlyClient.load(source, MediaKind::Live);
    assert(tsLive.items.size() == 1);
    assert(tsLive.items[0].mediaUrl == "https://iptv.example/panel/live/u/p/42.ts");

    CatalogClient bothFormatsClient([](const std::string& url) {
        if (url.find("action=get_live_categories") != std::string::npos)
            return std::string(R"([{"category_id":"1","category_name":"Live"}])");
        if (url.find("action=get_live_streams") != std::string::npos)
            return std::string(R"([{"stream_id":42,"name":"Channel Both","category_id":"1"}])");
        return std::string(R"({"user_info":{"auth":1,"status":"Active","allowed_output_formats":["ts","m3u8"]}})");
    });
    bothFormatsClient.authenticate(source);
    assert(bothFormatsClient.preferredLiveFormat(source) == "m3u8");
    auto bothLive = bothFormatsClient.load(source, MediaKind::Live);
    assert(bothLive.items.size() == 1);
    assert(bothLive.items[0].mediaUrl == "https://iptv.example/panel/live/u/p/42.m3u8");

    // UTF-8 BOM in provider JSON + "mpegts" / "hls" aliases in allowed_output_formats.
    CatalogClient mpegtsBomClient([](const std::string& url) {
        const std::string bom("\xEF\xBB\xBF", 3);
        if (url.find("action=get_live_categories") != std::string::npos)
            return bom + R"([{"category_id":"1","category_name":"Live"}])";
        if (url.find("action=get_live_streams") != std::string::npos)
            return bom + R"([{"stream_id":55,"name":"Channel MPEGTS","category_id":"1"}])";
        return bom + R"({"user_info":{"auth":1,"status":"Active","allowed_output_formats":["mpegts"]}})";
    });
    mpegtsBomClient.authenticate(source);
    assert(mpegtsBomClient.preferredLiveFormat(source) == "ts");
    auto mpegtsLive = mpegtsBomClient.load(source, MediaKind::Live);
    assert(mpegtsLive.items.size() == 1);
    assert(mpegtsLive.items[0].mediaUrl == "https://iptv.example/panel/live/u/p/55.ts");

    CatalogClient hlsAliasClient([](const std::string&) {
        return std::string(R"({"user_info":{"auth":1,"status":"Active","allowed_output_formats":["mpegts","hls"]}})");
    });
    hlsAliasClient.authenticate(source);
    assert(hlsAliasClient.preferredLiveFormat(source) == "m3u8");

    // Verify M3U parses Cookie/Origin while dropping hop-by-hop headers.
    Source m3uSource;
    m3uSource.id = "headers-m3u";
    m3uSource.type = SourceType::M3U;
    m3uSource.url = "https://provider.example/list.m3u";
    CatalogClient m3uClient([](const std::string&) {
        return std::string(
            "#EXTM3U\n"
            "#EXTINF:-1,Header Channel\n"
            "#EXTVLCOPT:http-cookie=sid=abc\n"
            "#EXTHTTP:{\"Origin\":\"https://provider.example\",\"Transfer-Encoding\":\"chunked\",\"Host\":\"evil.example\"}\n"
            "https://provider.example/ch.m3u8\n");
    });
    auto m3uLive = m3uClient.load(m3uSource, MediaKind::Live);
    assert(m3uLive.items.size() == 1);
    assert(m3uLive.items[0].requestHeaders.at("Cookie") == "sid=abc");
    assert(m3uLive.items[0].requestHeaders.at("Origin") == "https://provider.example");
    assert(m3uLive.items[0].requestHeaders.count("Transfer-Encoding") == 0);
    assert(m3uLive.items[0].requestHeaders.count("Host") == 0);
}

void saxM3uCacheDiskCacheAndEpgParity() {
    // 1. M3U caching across authenticate() + load(Live/Movie/Series) -> only 1 HTTP fetch!
    {
        Source source;
        source.id = "cached-m3u";
        source.type = SourceType::M3U;
        source.url = "https://provider.example/playlist.m3u";
        std::atomic<int> fetches{0};
        const std::string xmltv =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<tv>\n"
            "  <programme start=\"20250101000000 +0000\" stop=\"20250101010000 +0000\" channel=\"news.us\">\n"
            "    <title>News &amp; Weather</title>\n"
            "    <desc>Top stories &lt;live&gt;</desc>\n"
            "  </programme>\n"
            "  <programme start=\"20250101010000 +0000\" stop=\"20250101020000 +0000\" channel=\"news.us\">\n"
            "    <title>Late Show</title>\n"
            "  </programme>\n"
            "</tv>\n";
        std::atomic<int> xmltvFetches{0};
        CatalogClient client([&](const std::string& url) {
            if (url == "https://provider.example/guide.xml") {
                ++xmltvFetches;
                return xmltv;
            }
            ++fetches;
            return std::string(
                "#EXTM3U url-tvg=\"guide.xml\"\n"
                "#EXTINF:-1 tvg-id=\"news.us\" group-title=\"News\",News 24\n"
                "https://provider.example/live/news.m3u8\n"
                "#EXTINF:-1 group-title=\"Cinema\",Movie One\n"
                "https://provider.example/movie/one.mp4\n");
        });
        client.authenticate(source);
        auto live = client.load(source, MediaKind::Live);
        auto movies = client.load(source, MediaKind::Movie);
        auto series = client.load(source, MediaKind::Series);
        assert(fetches.load() == 1);
        assert(live.items.size() == 1 && movies.items.size() == 1 && series.items.empty());
        assert(client.xmltvUrl(source) == "https://provider.example/guide.xml");

        auto epg1 = client.loadEpg(source, "news.us");
        auto epg2 = client.loadEpg(source, "news.us");
        assert(xmltvFetches.load() == 1);
        assert(epg1.size() == 2 && epg2.size() == 2);
        assert(epg1[0].title == "News & Weather");
        assert(epg1[0].description == "Top stories <live>");
        assert(epg1[0].startEpochSeconds == 1735689600 && epg1[0].endEpochSeconds == 1735693200);
        assert(epg1[1].title == "Late Show");

        client.invalidateCache(source.id);
        (void)client.load(source, MediaKind::Live);
        assert(fetches.load() == 2);
    }

    // 2. Streaming SAX parsing with nested arrays, parallel fetch, and on-disk TTL cache.
    {
        const auto cacheDir = std::filesystem::temp_directory_path() / "brutv-ps5-disk-cache-test";
        std::filesystem::remove_all(cacheDir);
        Source source;
        source.id = "sax-provider";
        source.type = SourceType::Xtream;
        source.url = "https://iptv.example/panel";
        source.username = "u1";
        source.password = "p1";

        std::ostringstream items;
        items << '[';
        for (int i = 1; i <= 500; ++i) {
            if (i > 1) items << ',';
            items << R"({"stream_id":)" << i << R"(,"name":"Ch )" << i
                  << R"(","category_id":"2","category_ids":[2,3],"backdrop_path":["a","b"],"rating":8.5,"stream_icon":"https://img.example/)"
                  << i << R"(.png"})";
        }
        items << ']';
        const std::string itemsJson = items.str();

        std::atomic<int> httpCalls{0};
        auto transport = [&](const std::string& url) {
            ++httpCalls;
            if (url.find("action=get_live_categories") != std::string::npos)
                return std::string(R"([{"category_id":"2","category_name":"Sports","nested":{"x":1}}])");
            if (url.find("action=get_live_streams") != std::string::npos)
                return itemsJson;
            return std::string("[]");
        };
        {
            CatalogClient client(transport, true);
            client.setCacheDirectory(cacheDir, std::chrono::seconds(900));
            auto live = client.load(source, MediaKind::Live);
            assert(httpCalls.load() == 2);
            assert(live.categories.size() == 1 && live.categories[0].name == "Sports");
            assert(live.items.size() == 500);
            assert(live.items[0].categoryName == "Sports" && live.items[0].rating == "8.5");
            assert(live.items[499].mediaUrl == "https://iptv.example/panel/live/u1/p1/500.m3u8");
        }
        // Second client reads directly from on-disk cache with 0 HTTP calls.
        {
            CatalogClient client2(transport, true);
            client2.setCacheDirectory(cacheDir, std::chrono::seconds(900));
            auto cachedLive = client2.load(source, MediaKind::Live);
            assert(httpCalls.load() == 2);
            assert(cachedLive.items.size() == 500 && cachedLive.categories.size() == 1);
            // Password change invalidates fingerprint automatically.
            Source changed = source;
            changed.password = "p2";
            auto refreshed = client2.load(changed, MediaKind::Live);
            assert(httpCalls.load() == 4);
            assert(refreshed.items[0].mediaUrl == "https://iptv.example/panel/live/u1/p2/1.m3u8");
        }
        std::filesystem::remove_all(cacheDir);
    }

    // 3. EPG > 1000 entries truncates cleanly instead of throwing.
    {
        Source source;
        source.id = "epg-trunc";
        source.type = SourceType::Xtream;
        source.url = "https://iptv.example";
        source.username = "u";
        source.password = "p";
        std::ostringstream epg;
        epg << R"({"epg_listings":[)";
        for (int i = 0; i < 1200; ++i) {
            if (i) epg << ',';
            epg << R"({"title":"Show )" << i << R"(","start_timestamp":)" << (1700000000 + i * 3600)
                << R"(,"stop_timestamp":)" << (1700003600 + i * 3600) << '}';
        }
        epg << "]}";
        const std::string epgJson = epg.str();
        CatalogClient client([&](const std::string&) { return epgJson; });
        auto entries = client.loadEpg(source, "10");
        assert(entries.size() == 1000);
        assert(entries.front().title == "Show 0" && entries.back().title == "Show 999");
    }

    // 4. Settings round-trip for resumePositionsBySource and savedSources.
    {
        const auto root = std::filesystem::temp_directory_path() / "brutv-ps5-resume-settings-test";
        std::filesystem::remove_all(root);
        std::filesystem::create_directories(root);
        SettingsStore store(root / "settings.json");
        Settings s;
        Source s1;
        s1.id = "src-1";
        s1.name = "Primary";
        s1.type = SourceType::M3U;
        s1.url = "https://provider-a.example/list.m3u";
        Source s2;
        s2.id = "src-2";
        s2.name = "Backup";
        s2.type = SourceType::Xtream;
        s2.url = "https://provider-b.example";
        s2.username = "u";
        s2.password = "p";
        s.source = s1;
        s.savedSources = {s1, s2};
        s.resumePositionsBySource[s1.id]["movie-1"] = 1234.5;
        store.save(s);
        auto loaded = store.load();
        assert(loaded.savedSources.size() == 2);
        assert(loaded.savedSources[1].name == "Backup");
        assert(loaded.resumePositionsBySource.at(s1.id).at("movie-1") > 1234.0);
        std::filesystem::remove_all(root);
    }
}
} // namespace

int main() {
    loginLinks();
    m3uCatalogAndHlsGuard();
    xtreamCatalogEpisodesAndEpg();
    providerFailuresDoNotExposeCredentials();
    settingsAtomicPrivateRoundTripAndRecovery();
    xtreamLiveAlternateAndOutputFormats();
    saxM3uCacheDiskCacheAndEpgParity();
    std::cout << "BruTV catalog tests passed\n";
}
