#pragma once

#include "brutv/catalog.hpp"
#include "brutv/platform.hpp"

#include <memory>
#include <string>

namespace brutv {

class Gfx;

// TV application state and presentation. The host owns the frame lifecycle:
// call Gfx::begin(), App::render(), Gfx::end(), then Platform::present().
class App {
  public:
    App(Platform &platform, Gfx &gfx, std::string settingsFile, HttpGet httpGet,
        bool preview = false, HttpGet artworkGet = {});
    ~App();
    App(const App &) = delete;
    App &operator=(const App &) = delete;

    void handle(Input input);
    void tick();
    void render();
    bool shouldQuit() const;

    void connect(Source source);
    void playUrl(std::string url, bool live = false);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace brutv
