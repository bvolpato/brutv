#include "brutv/app.hpp"
#include "brutv/gfx.hpp"
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <future>
#include <iostream>
#include <mutex>
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
        cleanup();
        std::cout << "Controller source setup, identity, clearing, and favorite removal passed.\n";
        return 0;
    } catch (const std::exception &error) {
        cleanup();
        std::cerr << error.what() << '\n';
        return 1;
    }
}
