#include "brutv/app.hpp"
#include "brutv/gfx.hpp"
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <future>
#include <iostream>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <thread>

namespace {
void require(bool condition, const char *message) {
    if (!condition)
        throw std::runtime_error(message);
}
void key(brutv::App &app, brutv::Key value, int count = 1) {
    while (count--)
        app.handle({{value}, {}});
}
void pump(brutv::App &app) {
    for (int i = 0; i < 100; ++i) {
        app.tick();
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
}
brutv::Source account() {
    brutv::Source value;
    value.type = brutv::SourceType::Xtream;
    value.url = "https://provider-a.example";
    value.username = "sampleuser";
    value.password = "samplepassword";
    value.id = brutv::sourceId(value);
    return value;
}
std::string response(const std::string &url) {
    if (url.find("action=") != std::string::npos)
        return "[]";
    if (url.find("player_api.php") != std::string::npos)
        return R"({"user_info":{"auth":1,"status":"Active"}})";
    return "#EXTM3U\n#EXTINF:-1,Sample\nhttps://media.example/stream.m3u8\n";
}
} // namespace

int main() {
    char folder[] = "/tmp/brutv-ps5-app-test-XXXXXX";
    if (!mkdtemp(folder))
        return 1;
    const auto cleanup = [&]() { std::filesystem::remove_all(folder); };
    try {
        auto platform = brutv::makePlatform();
        brutv::Gfx gfx(std::string(BRUTV_TEST_ASSET_DIR) + "/DejaVuSans.ttf");
        const auto original = account();
        std::vector<std::string> failures;
        {
            brutv::SettingsStore store(std::string(folder) + "/source.json");
            brutv::Settings settings;
            settings.source = original;
            store.save(settings);
            std::vector<std::string> requests;
            std::mutex mutex;
            brutv::App app(*platform, gfx, (std::string(folder) + "/source.json"),
                           [&](const std::string &url) {
                               std::lock_guard<std::mutex> lock(mutex);
                               requests.push_back(url);
                               return response(url);
                           });
            pump(app);
            key(app, brutv::Key::Options);
            key(app, brutv::Key::Down, 2);
            key(app, brutv::Key::Backspace, static_cast<int>(original.url.size()));
            app.handle({{}, "https://provider-b.example"});
            auto edited = store.load();
            if (!edited.source || edited.source->id == original.id)
                failures.emplace_back("Editing a server reused the old source identity");
            key(app, brutv::Key::Down, 5);
            key(app, brutv::Key::Confirm);
            pump(app);
            const auto connected = store.load();
            if (!connected.source || connected.source->type != brutv::SourceType::Xtream ||
                connected.source->username != original.username ||
                connected.source->password != original.password)
                failures.emplace_back("Manual Xtream connection lost its type or credentials");
            std::lock_guard<std::mutex> lock(mutex);
            bool usedApi = false;
            for (const auto &url : requests)
                if (url.rfind("https://provider-b.example/player_api.php?", 0) == 0)
                    usedApi = true;
            if (!usedApi)
                failures.emplace_back("Manual Xtream connection did not use the provider API");
        }
        {
            brutv::SettingsStore store(std::string(folder) + "/clear.json");
            brutv::Settings settings;
            settings.source = original;
            brutv::MediaItem item;
            item.id = "recent";
            item.sourceId = original.id;
            item.mediaUrl = "https://provider-a.example/live/sampleuser/samplepassword/1.ts";
            settings.recentsBySource[original.id] = {item};
            settings.favoritesBySource[original.id].insert(item.id);
            settings.favoritesBySource["other-profile"].insert("other-favorite");
            store.save(settings);
            brutv::App app(*platform, gfx, (std::string(folder) + "/clear.json"), response);
            pump(app);
            key(app, brutv::Key::Options);
            key(app, brutv::Key::Down, 8);
            key(app, brutv::Key::Confirm, 2);
            const auto cleared = store.load();
            if (cleared.source || cleared.recentsBySource.count(original.id) ||
                cleared.favoritesBySource.count(original.id))
                failures.emplace_back("Clearing a source retained its credential-bearing history");
            require(cleared.favoritesBySource.count("other-profile") == 1,
                    "Clearing one source removed another profile");
        }
        if (!failures.empty()) {
            for (const auto &failure : failures)
                std::cerr << failure << '\n';
            cleanup();
            return 1;
        }
        {
            const auto file = std::string(folder) + "/reconnect.json";
            brutv::SettingsStore store(file);
            brutv::Settings settings;
            settings.source = original;
            store.save(settings);
            std::promise<void> entered, release;
            auto waiting = release.get_future().share();
            std::mutex mutex;
            bool first = true;
            bool usedNewPassword = false;
            brutv::App app(*platform, gfx, file, [&](const std::string &url) {
                bool block = false;
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    if (first) {
                        first = false;
                        block = true;
                    }
                    if (url.find("password=updated-secret") != std::string::npos)
                        usedNewPassword = true;
                }
                if (block) {
                    entered.set_value();
                    waiting.wait_for(std::chrono::seconds(2));
                    return std::string(R"({"user_info":{"auth":0}})");
                }
                return response(url);
            });
            require(entered.get_future().wait_for(std::chrono::seconds(2)) ==
                        std::future_status::ready,
                    "Initial catalog request did not start");
            auto updated = original;
            updated.password = "updated-secret";
            app.connect(updated);
            release.set_value();
            pump(app);
            std::lock_guard<std::mutex> lock(mutex);
            require(usedNewPassword,
                    "Reconnecting during an old catalog request did not use the new credentials");
        }
        {
            const auto file = std::string(folder) + "/preview.json";
            brutv::Settings settings;
            settings.source = original;
            brutv::SettingsStore store(file);
            store.save(settings);
            brutv::App app(*platform, gfx, file, {}, true);
            key(app, brutv::Key::NextTab, 3);
            key(app, brutv::Key::Right);
            key(app, brutv::Key::Confirm);
            key(app, brutv::Key::Right, 5);
            key(app, brutv::Key::Favorite);
            gfx.begin(1280, 720);
            app.render();
            gfx.end();
            const auto after = store.load();
            require(after.source && after.source->id == original.id &&
                        after.source->url == original.url,
                    "Preview interactions overwrote the real saved source");
        }
        // Test: EPG failure must NOT cause an infinite request hammering loop.
        {
            const auto file = std::string(folder) + "/epg-nonloop.json";
            brutv::SettingsStore store(file);
            brutv::Settings settings;
            settings.source = original;
            store.save(settings);
            std::atomic<int> epgRequests{0};
            brutv::App app(*platform, gfx, file, [&](const std::string &url) -> std::string {
                if (url.find("action=get_live_categories") != std::string::npos)
                    return R"([{"category_id":"1","category_name":"News"}])";
                if (url.find("action=get_live_streams") != std::string::npos)
                    return R"([{"stream_id":1,"name":"Alpha Channel","category_id":"1"},{"stream_id":2,"name":"Beta Channel","category_id":"1"}])";
                if (url.find("action=get_short_epg") != std::string::npos) {
                    ++epgRequests;
                    throw std::runtime_error("EPG unavailable");
                }
                return response(url);
            });
            pump(app);
            // Move focus: Sidebar -> Categories -> Items, launch Alpha Channel.
            key(app, brutv::Key::Right, 2);
            key(app, brutv::Key::Confirm);
            for (int i = 0; i < 150; ++i) {
                app.tick();
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
            require(epgRequests.load() == 1,
                    "Failed EPG request triggered a retry/hammering loop");
            // Return from player, move to Beta Channel, launch -> exactly 1 new EPG request.
            key(app, brutv::Key::Back);
            key(app, brutv::Key::Right);
            key(app, brutv::Key::Confirm);
            for (int i = 0; i < 150; ++i) {
                app.tick();
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
            require(epgRequests.load() == 2,
                    "Switching channel after EPG failure did not fetch once for the new channel");
            key(app, brutv::Key::Back);
        }
        // Test: UTF-8 backspace in searchQuery erases full codepoint instead of corrupting UTF-8.
        {
            const auto file = std::string(folder) + "/utf8-backspace.json";
            brutv::SettingsStore store(file);
            brutv::Settings settings;
            settings.source = original;
            store.save(settings);
            brutv::App app(*platform, gfx, file, [&](const std::string &url) -> std::string {
                if (url.find("action=get_live_categories") != std::string::npos)
                    return R"([{"category_id":"1","category_name":"General"}])";
                if (url.find("action=get_live_streams") != std::string::npos)
                    return R"([{"stream_id":10,"name":"Cafe Live","category_id":"1"},{"stream_id":11,"name":"Zebra Live","category_id":"1"}])";
                return response(url);
            });
            pump(app);
            key(app, brutv::Key::Right, 2); // Focus Items
            app.handle({{}, "Caf\xC3\xA9"}); // "Café" (2-byte UTF-8 'é') -> 0 matches
            key(app, brutv::Key::Confirm);
            require(store.load().recentsBySource.empty(),
                    "Non-matching UTF-8 search query unexpectedly launched an item");
            key(app, brutv::Key::Backspace); // Must erase full 'é' -> "Caf"
            key(app, brutv::Key::Confirm);   // Must launch "Cafe Live"
            const auto saved = store.load();
            require(saved.recentsBySource.count(original.id) == 1 &&
                        !saved.recentsBySource.at(original.id).empty() &&
                        saved.recentsBySource.at(original.id).front().title == "Cafe Live",
                    "UTF-8 backspace corrupted search query instead of erasing full codepoint");
            key(app, brutv::Key::Back);
        }
        // Test: Cached visibleItems avoids per-frame O(N log N) sorting and invalidates on edits.
        {
            const auto file = std::string(folder) + "/cached-visible.json";
            brutv::SettingsStore store(file);
            brutv::Settings settings;
            settings.source = original;
            store.save(settings);
            std::ostringstream streams;
            streams << '[';
            for (int i = 0; i < 4000; ++i) {
                if (i) streams << ',';
                const int cat = (i % 4) + 1;
                streams << R"({"stream_id":)" << (i + 1) << R"(,"name":"Channel )" << (4000 - i)
                        << R"(","category_id":")" << cat << R"("})";
            }
            streams << ']';
            const std::string streamsJson = streams.str();
            brutv::App app(*platform, gfx, file, [&](const std::string &url) -> std::string {
                if (url.find("action=get_live_categories") != std::string::npos)
                    return R"([{"category_id":"1","category_name":"Cat 1"},{"category_id":"2","category_name":"Cat 2"},{"category_id":"3","category_name":"Cat 3"},{"category_id":"4","category_name":"Cat 4"}])";
                if (url.find("action=get_live_streams") != std::string::npos)
                    return streamsJson;
                return response(url);
            });
            pump(app);
            key(app, brutv::Key::Right, 2); // Focus Items
            const auto start = std::chrono::steady_clock::now();
            for (int step = 0; step < 200; ++step) {
                key(app, step % 2 == 0 ? brutv::Key::Right : brutv::Key::Left);
            }
            const auto elapsed = std::chrono::steady_clock::now() - start;
            require(elapsed < std::chrono::milliseconds(1000),
                    "visibleItems navigation across 4000 items was unexpectedly slow (cache miss)");
            // Search invalidates cache and selects exact item.
            app.handle({{}, "Channel 3999"});
            key(app, brutv::Key::Confirm);
            const auto afterSearch = store.load();
            require(afterSearch.recentsBySource.count(original.id) == 1 &&
                        afterSearch.recentsBySource.at(original.id).front().title == "Channel 3999",
                    "Search query did not invalidate cached visibleItems");
            key(app, brutv::Key::Back);
        }
        // Test: Debounced volume save flushes final volume cleanly on app teardown.
        {
            const auto file = std::string(folder) + "/volume-debounce.json";
            brutv::SettingsStore store(file);
            brutv::Settings settings;
            settings.source = original;
            settings.volume = 1.0F;
            store.save(settings);
            {
                brutv::App app(*platform, gfx, file, response);
                pump(app);
                key(app, brutv::Key::Options);
                key(app, brutv::Key::Down, 6);
                key(app, brutv::Key::Left, 4); // 1.0 -> 0.80
                // Before debounce elapses, disk still has 1.0 (not fsync'd every keypress).
                require(std::abs(store.load().volume - 1.0F) < 0.01F,
                        "Volume adjustment fsynced immediately instead of debouncing");
            }
            // Destructor flushed pending debounced volume save.
            require(std::abs(store.load().volume - 0.80F) < 0.01F,
                    "Debounced volume change was not persisted on shutdown");
        }
        cleanup();
        std::cout << "Controller source setup, identity, clearing, EPG non-looping, UTF-8 backspace, cache, and volume debounce passed.\n";
        return 0;
    } catch (const std::exception &error) {
        cleanup();
        std::cerr << error.what() << '\n';
        return 1;
    }
}
