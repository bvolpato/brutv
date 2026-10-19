#include "brutv/app.hpp"
#include "brutv/gfx.hpp"
#include "brutv/http.hpp"
#include "brutv/player.hpp"
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>

#ifndef BRUTV_ASSET_DIR
#define BRUTV_ASSET_DIR "assets"
#endif

namespace {
std::string defaultSettings() {
#ifdef BRUTV_PS5
    return "/download0/brutv/settings.json";
#else
    if (const char *dir = std::getenv("XDG_CONFIG_HOME"))
        return std::string(dir) + "/brutv-ps5/settings.json";
    if (const char *homeDir = std::getenv("HOME"))
        return std::string(homeDir) + "/.config/brutv-ps5/settings.json";
    return "settings.json";
#endif
}
} // namespace
int main(int argc, char **argv) {
    try {
        bool preview = false;
        int frames = 0;
        std::string screenshot, source, play, settings = defaultSettings(),
                                              assets = BRUTV_ASSET_DIR;
        for (int i = 1; i < argc; ++i) {
            const std::string arg = argv[i];
            auto value = [&]() {
                if (i + 1 >= argc)
                    throw std::runtime_error("Missing command option value");
                return std::string(argv[++i]);
            };
            if (arg == "--preview")
                preview = true;
            else if (arg == "--frames") {
                frames = std::stoi(value());
                if (frames < 1 || frames > 360000)
                    throw std::runtime_error("Frame limit must be between 1 and 360000");
            } else if (arg == "--screenshot")
                screenshot = value();
            else if (arg == "--source")
                source = value();
            else if (arg == "--play")
                play = value();
            else if (arg == "--settings")
                settings = value();
            else if (arg == "--assets")
                assets = value();
            else if (arg == "--help") {
                std::cout << "BruTV PS5 / desktop preview\n  --source URL       Connect an M3U or "
                             "BruTV sign-in link\n  --play URL_OR_FILE Play a stream or local "
                             "video\n  --settings FILE    Settings file (contains source "
                             "credentials)\n  --preview          Synthetic UI preview, no saved "
                             "source changes\n  --frames N         Exit after N rendered frames\n  "
                             "--screenshot PNG   Capture the final frame before exiting\n  "
                             "--assets DIR       Font and artwork folder\n";
                return 0;
            } else
                throw std::runtime_error("Unknown command option. Use --help.");
        }
        if (!screenshot.empty() && !frames)
            frames = 180;
        auto platform = brutv::makePlatform();
        brutv::Gfx gfx(assets + "/DejaVuSans.ttf");
        brutv::App app(*platform, gfx, settings, brutv::httpGet, preview, brutv::httpGetArtwork);
        if (!source.empty()) {
            const auto parsed = brutv::parseLoginLink(source);
            if (!parsed)
                throw std::runtime_error("The source is not a supported URL or BruTV sign-in link");
            app.connect(*parsed);
        }
        if (!play.empty())
            app.playUrl(play, false);
        int frame = 0;
        while (!app.shouldQuit()) {
            const auto nextFrame =
                std::chrono::steady_clock::now() + std::chrono::microseconds(16667);
            app.handle(platform->poll());
            app.tick();
            const int width = platform->width(), height = platform->height();
            if (width < 1 || height < 1)
                continue;
            gfx.begin(width, height);
            app.render();
            gfx.end();
            ++frame;
            if (frames && frame >= frames) {
                if (!screenshot.empty())
                    gfx.screenshot(screenshot);
                break;
            }
            platform->present();
            std::this_thread::sleep_until(nextFrame);
        }
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "BruTV: " << error.what() << '\n';
        return 1;
    }
}
