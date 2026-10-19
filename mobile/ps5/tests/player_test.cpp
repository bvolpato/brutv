#include "brutv/player.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>

namespace {

using Clock = std::chrono::steady_clock;

void require(bool condition, const char* message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

// A bounded, real-time output queue without a physical audio device. The
// fixture's decoded samples still pass through FFmpeg's resampler and gain.
class CountingSink final : public brutv::AudioSink {
public:
    bool queue(const std::int16_t* samples, std::size_t frames) override {
        std::lock_guard<std::mutex> lock(mutex_);
        update();
        const double seconds = static_cast<double>(frames) / 48000;
        if (queued_ + seconds > 0.6) {
            return false;
        }
        queued_ += seconds;
        totalFrames_ += frames;
        for (std::size_t index = 0; index < frames * 2; ++index) {
            if (samples[index] != 0) {
                ++nonzeroSamples_;
            }
        }
        return true;
    }

    double queuedSeconds() const override {
        std::lock_guard<std::mutex> lock(mutex_);
        update();
        return queued_;
    }

    void clear() override {
        std::lock_guard<std::mutex> lock(mutex_);
        queued_ = 0;
        anchor_ = Clock::now();
    }

    void setPaused(bool paused) override {
        std::lock_guard<std::mutex> lock(mutex_);
        update();
        paused_ = paused;
    }

    std::size_t totalFrames() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return totalFrames_;
    }

    std::size_t nonzeroSamples() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return nonzeroSamples_;
    }

private:
    void update() const {
        const auto now = Clock::now();
        if (!paused_) {
            queued_ = std::max(0.0, queued_ - std::chrono::duration<double>(now - anchor_).count());
        }
        anchor_ = now;
    }

    mutable std::mutex mutex_;
    mutable double queued_ = 0;
    mutable Clock::time_point anchor_ = Clock::now();
    bool paused_ = false;
    std::size_t totalFrames_ = 0;
    std::size_t nonzeroSamples_ = 0;
};

template <typename Predicate>
void waitFor(brutv::Player& player, Predicate ready, std::chrono::seconds timeout) {
    const auto deadline = Clock::now() + timeout;
    while (Clock::now() < deadline) {
        const auto status = player.status();
        if (status.state == brutv::Player::State::Error) {
            throw std::runtime_error(status.message);
        }
        if (ready(status)) {
            return;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(3));
    }
    throw std::runtime_error("Timed out waiting for playback state.");
}

void decodeFixture(const std::string& path, bool withAudio) {
    auto sink = withAudio ? std::make_shared<CountingSink>() : nullptr;
    brutv::Player player(sink);
    player.open(path, false, {{"User-Agent", "BruTV-Player-Test"},
                              {"Referer", "https://brutv.example/"}});
    std::size_t frameCount = 0;
    double previousPts = -1;
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        if (player.takeFrame(frame)) {
            require(frame.width > 0 && frame.width <= 1280, "Invalid decoded frame width.");
            require(frame.height > 0 && frame.height <= 720, "Invalid decoded frame height.");
            require(frame.rgba.size() == static_cast<std::size_t>(frame.width) * frame.height * 4,
                    "Decoded frame has the wrong byte size.");
            require(frame.ptsSeconds >= previousPts, "Video presentation time went backwards.");
            require(std::any_of(frame.rgba.begin(), frame.rgba.end(), [](auto byte) { return byte != 0; }),
                    "Decoded video is empty.");
            previousPts = frame.ptsSeconds;
            ++frameCount;
        }
        return status.state == brutv::Player::State::Ended;
    }, std::chrono::seconds(10));
    require(frameCount >= 15, "Too few frames decoded from the media fixture.");
    require(player.status().hasVideo && player.status().hasAudio, "Missing media stream discovery.");
    if (sink) {
        require(sink->totalFrames() >= 48000, "Audio was not decoded and resampled.");
        require(sink->nonzeroSamples() > 1000, "Decoded audio is silent.");
    }
    player.seekRelative(-1.0);
    bool resumed = false;
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        resumed = player.takeFrame(frame) || resumed;
        return resumed && status.state == brutv::Player::State::Playing;
    }, std::chrono::seconds(3));
    player.stop();
    require(player.status().state == brutv::Player::State::Idle, "stop() did not reset playback.");
}

void controls(const std::string& path) {
    auto sink = std::make_shared<CountingSink>();
    brutv::Player player(sink);
    player.open(path, false);
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        player.takeFrame(frame);
        return status.currentSeconds > 0.15;
    }, std::chrono::seconds(3));
    player.setPaused(true);
    const double pausedAt = player.status().currentSeconds;
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    require(std::abs(player.status().currentSeconds - pausedAt) < 0.01, "Pause did not freeze the clock.");
    player.seekRelative(0.5);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    require(player.status().state == brutv::Player::State::Paused, "Seeking resumed paused playback.");
    player.setPaused(false);
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        player.takeFrame(frame);
        return status.currentSeconds > pausedAt + 0.5;
    }, std::chrono::seconds(3));
    player.setVolume(0.25F);
    require(std::abs(player.status().volume - 0.25F) < 0.001F, "Volume setting was not retained.");
    const auto stopStarted = Clock::now();
    player.stop();
    require(Clock::now() - stopStarted < std::chrono::seconds(1), "stop() was not prompt.");
    for (int attempt = 0; attempt < 8; ++attempt) {
        player.open(path, false);
        player.stop();
    }
    for (const auto& headers : {
             std::unordered_map<std::string, std::string>{{"User-Agent", "BruTV\r\nInjected: secret"}},
             std::unordered_map<std::string, std::string>{{"Referer", std::string("hidden\0secret", 13)}},
             std::unordered_map<std::string, std::string>{{"Cookie", "private-secret"}},
             std::unordered_map<std::string, std::string>{{"user-agent", std::string(8193, 'a')}}}) {
        player.open(path, false, headers);
        require(player.status().state == brutv::Player::State::Error, "Unsafe request header was accepted.");
        require(player.status().message.find("secret") == std::string::npos,
                "Header validation diagnostics exposed private values.");
    }
    player.open("http://example-user:example-secret@127.0.0.1:1/missing", false);
    const auto deadline = Clock::now() + std::chrono::seconds(3);
    while (player.status().state != brutv::Player::State::Error && Clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    const auto failed = player.status();
    require(failed.state == brutv::Player::State::Error, "Connection failure was not reported.");
    require(failed.message.find("example-secret") == std::string::npos &&
            failed.message.find("example-user") == std::string::npos,
            "Playback diagnostics exposed credentials.");
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "Usage: brutv_player_test <two-second video+audio fixture path or URL>\n";
        return 2;
    }
    try {
        decodeFixture(argv[1], true);
        decodeFixture(argv[1], false);
        controls(argv[1]);
        std::cout << "Media decode, audio resampling, timing, controls and lifecycle passed.\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
