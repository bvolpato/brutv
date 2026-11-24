#include "brutv/player.hpp"
#include "brutv/catalog.hpp"

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
        std::size_t crossings = 0;
        for (std::size_t index = 0; index < frames * 2; ++index) {
            if (samples[index] != 0) {
                ++nonzeroSamples_;
            }
        }
        for (std::size_t index = 2; index < frames * 2; index += 2) {
            if ((samples[index] >= 0) != (samples[index - 2] >= 0)) ++crossings;
        }
        if (frames > 100) frequency_ = crossings * 48000.0 / (2.0 * frames);
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

    double frequency() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return frequency_;
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
    double frequency_ = 0;
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

void decodeFixture(const std::string& path, bool withAudio, bool preferYuv = true) {
    auto sink = withAudio ? std::make_shared<CountingSink>() : nullptr;
    brutv::Player player(sink);
    player.setPreferYuv(preferYuv);
    player.open(path, false, {{"User-Agent", "BruTV-Player-Test"},
                              {"Referer", "https://brutv.example/"}});
    std::size_t frameCount = 0;
    double previousPts = -1;
    brutv::VideoFrame frame; // Reused across calls to exercise the zero-alloc frame pool!
    std::vector<const std::uint8_t*> seenBuffers;
    bool reusedBuffer = false;
    waitFor(player, [&](const auto& status) {
        if (player.takeFrame(frame)) {
            require(frame.width > 0 && frame.width <= 1920, "Invalid decoded frame width.");
            require(frame.height > 0 && frame.height <= 1080, "Invalid decoded frame height.");
            if (preferYuv) {
                require(frame.format == brutv::VideoFrame::Format::Yuv420p,
                        "Expected GPU YUV420P frame on default path.");
                const std::size_t ySize = static_cast<std::size_t>(frame.width) * frame.height;
                const std::size_t uvSize =
                    static_cast<std::size_t>(frame.width / 2) * (frame.height / 2);
                require(frame.yPlane.size() == ySize && frame.uPlane.size() == uvSize &&
                        frame.vPlane.size() == uvSize,
                        "Decoded YUV420P planes have wrong byte sizes.");
                require(std::any_of(frame.yPlane.begin(), frame.yPlane.end(), [](auto byte) { return byte != 0; }),
                        "Decoded YUV video luma plane is empty.");
                if (std::find(seenBuffers.begin(), seenBuffers.end(), frame.yPlane.data()) != seenBuffers.end()) {
                    reusedBuffer = true;
                } else {
                    seenBuffers.push_back(frame.yPlane.data());
                }
            } else {
                require(frame.format == brutv::VideoFrame::Format::Rgba,
                        "Expected RGBA fallback frame when preferYuv is false.");
                require(frame.rgba.size() == static_cast<std::size_t>(frame.width) * frame.height * 4,
                        "Decoded frame has the wrong byte size.");
                require(std::any_of(frame.rgba.begin(), frame.rgba.end(), [](auto byte) { return byte != 0; }),
                        "Decoded video is empty.");
                if (std::find(seenBuffers.begin(), seenBuffers.end(), frame.rgba.data()) != seenBuffers.end()) {
                    reusedBuffer = true;
                } else {
                    seenBuffers.push_back(frame.rgba.data());
                }
            }
            require(frame.ptsSeconds >= previousPts, "Video presentation time went backwards.");
            previousPts = frame.ptsSeconds;
            ++frameCount;
        }
        return status.state == brutv::Player::State::Ended;
    }, std::chrono::seconds(10));
    require(frameCount >= 15, "Too few frames decoded from the media fixture.");
    require(reusedBuffer, "VideoFrame buffer pool did not recycle frame allocations.");
    require(player.status().hasVideo && player.status().hasAudio, "Missing media stream discovery.");
    if (sink) {
        require(sink->totalFrames() >= 48000, "Audio was not decoded and resampled.");
        require(sink->nonzeroSamples() > 1000, "Decoded audio is silent.");
    }
    player.seekRelative(-1.0);
    bool resumed = false;
    waitFor(player, [&](const auto& status) {
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
             std::unordered_map<std::string, std::string>{{"Host", "private-secret.example"}},
             std::unordered_map<std::string, std::string>{{"Transfer-Encoding", "private-secret"}},
             std::unordered_map<std::string, std::string>{{"user-agent", std::string(8193, 'a')}}}) {
        player.open(path, false, headers);
        require(player.status().state == brutv::Player::State::Error, "Unsafe request header was accepted.");
        require(player.status().message.find("secret") == std::string::npos,
                "Header validation diagnostics exposed private values.");
    }
    // Safe M3U extra headers (Cookie, Origin) are accepted instead of throwing.
    player.open(path, false, {{"Cookie", "session=ok"}, {"Origin", "https://brutv.example"}});
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        player.takeFrame(frame);
        return status.currentSeconds > 0.1;
    }, std::chrono::seconds(4));
    player.stop();
    // Pausing/unpausing while Opening must not falsely report Playing.
    player.open("http://example-user:example-secret@127.0.0.1:1/missing", false);
    player.setPaused(true);
    player.setPaused(false);
    require(player.status().state != brutv::Player::State::Playing,
            "setPaused(false) during Opening falsely claimed Playing.");
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

void tracks(const std::string& path) {
    auto sink = std::make_shared<CountingSink>();
    brutv::Player player(sink);
    player.open(path, false);
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        player.takeFrame(frame);
        return status.currentSeconds > 0.15;
    }, std::chrono::seconds(4));
    const auto initial = player.status();
    require(initial.audioTracks.size() == 2, "Both audio tracks were not discovered.");
    require(initial.subtitleTracks.size() == 1, "The text subtitle track was not discovered.");
    player.cycleAudioTrack();
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        player.takeFrame(frame);
        return status.audioTrack != initial.audioTrack && sink->frequency() > 700;
    }, std::chrono::seconds(3));
    player.cycleSubtitleTrack();
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        player.takeFrame(frame);
        return status.subtitleText.find("Caption regression") != std::string::npos;
    }, std::chrono::seconds(3));
    player.cycleSubtitleTrack();
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        player.takeFrame(frame);
        return status.subtitleTrack == -1 && status.subtitleText.empty();
    }, std::chrono::seconds(3));
    player.stop();
}

void liveRewind(const std::string& url) {
    brutv::Player player(std::make_shared<CountingSink>());
    player.open(url, true);
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        player.takeFrame(frame);
        return status.liveRewind && status.currentSeconds > 0.15;
    }, std::chrono::seconds(8));
    player.setPaused(true);
    const auto paused = player.status();
    std::this_thread::sleep_for(std::chrono::milliseconds(1500));
    const auto recording = player.status();
    require(std::abs(recording.currentSeconds - paused.currentSeconds) < 0.01,
        "Live pause did not freeze playback.");
    require(recording.recordedBytes > paused.recordedBytes &&
        recording.windowEndSeconds > paused.windowEndSeconds + 0.5,
        "Live recording did not continue while playback was paused.");
    player.seekRelative(0.8);
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        player.takeFrame(frame);
        return status.currentSeconds > paused.currentSeconds + 0.6 &&
            status.state == brutv::Player::State::Paused;
    }, std::chrono::seconds(3));
    player.seekRelative(-0.7);
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        player.takeFrame(frame);
        return status.currentSeconds < paused.currentSeconds + 0.3;
    }, std::chrono::seconds(3));
    player.goLive();
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        player.takeFrame(frame);
        return status.state == brutv::Player::State::Playing &&
            status.windowEndSeconds - status.currentSeconds < 1.5;
    }, std::chrono::seconds(3));
    player.stop();
    require(player.status().recordedBytes == 0 && !player.status().liveRewind,
        "Stopping did not release the live recording.");
}

void liveDirectFallback(const std::string& url) {
    brutv::Player player(std::make_shared<CountingSink>());
    player.open(url, true);
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        player.takeFrame(frame);
        return status.currentSeconds > 0.2 && status.state == brutv::Player::State::Playing;
    }, std::chrono::seconds(8));
    const auto status = player.status();
    require(!status.liveRewind && status.recordedBytes == 0,
        "Unavailable temporary storage incorrectly advertised live rewind.");
    require(status.rewindMessage.find("Continuing with direct playback") != std::string::npos,
        "Unavailable live storage was not explained to the viewer.");
    player.stop();
}

void unitTests() {
    // 1. Xtream .m3u8 <-> .ts bidirectional fallback helper.
    const auto ts = brutv::alternateXtreamLiveUrl("https://provider.example/live/u/p/101.m3u8?k=1");
    require(ts && *ts == "https://provider.example/live/u/p/101.ts?k=1",
            "Xtream .m3u8 -> .ts fallback helper failed.");
    const auto m3u8 = brutv::alternateXtreamLiveUrl(*ts);
    require(m3u8 && *m3u8 == "https://provider.example/live/u/p/101.m3u8?k=1",
            "Xtream .ts -> .m3u8 fallback helper failed.");
    require(!brutv::alternateXtreamLiveUrl("https://provider.example/hls/index.m3u8"),
            "Non-Xtream HLS URL was incorrectly rewritten.");

    // 2. Retry budget reset after sustained healthy playback (>30s since first decoded frame).
    {
        const auto reset = brutv::ReconnectPolicy::evaluate(
            true, false, true, true, 35.0, true, brutv::ReconnectPolicy::kMaxLiveFailures, 1, 0.5);
        require(reset.shouldRetry && reset.failures == 1 && reset.maxFailures == 6,
                "Sustained healthy live playback did not reset retry budget before checking limit.");
        require(!reset.switchFormat,
                "First disconnect after sustained healthy playback should stay on working format.");
        require(reset.backoffMs >= brutv::ReconnectPolicy::kMinBackoffMs &&
                reset.backoffMs <= brutv::ReconnectPolicy::kMaxBackoffMs,
                "Retry backoff outside [1.5s, 12s].");

        // Hanging in openSource for 60s WITHOUT decoding a first frame must NOT reset failures.
        const auto noResetOnOpenHang = brutv::ReconnectPolicy::evaluate(
            true, false, false, false, 60.0, true, brutv::ReconnectPolicy::kMaxLiveFailures, 1, 0.5);
        require(!noResetOnOpenHang.shouldRetry && noResetOnOpenHang.failures == 7,
                "Open hang without decoded frame erroneously reset failure counter.");

        // Short playback (<30s) must NOT reset failures.
        const auto shortPlay = brutv::ReconnectPolicy::evaluate(
            true, false, true, true, 12.0, true, brutv::ReconnectPolicy::kMaxLiveFailures, 1, 0.5);
        require(!shortPlay.shouldRetry && shortPlay.failures == 7,
                "Short unhealthy playback erroneously reset failure counter.");

        // Consecutive live failures 1..6: initial format switch uses fast 300ms pause,
        // subsequent retries use jittered exponential backoff; 7th fails.
        int prevFailures = 0;
        int prevOnActive = 0;
        for (int attempt = 1; attempt <= 6; ++attempt) {
            const auto step = brutv::ReconnectPolicy::evaluate(
                true, false, false, false, 0.0, true, prevFailures, prevOnActive, 0.5);
            require(step.shouldRetry && step.failures == attempt,
                    "Live reconnect stopped before reaching 6 consecutive retries.");
            require(step.switchFormat,
                    "Immediate open failure on Xtream live stream did not switch alternate format.");
            if (attempt == 1) {
                require(step.backoffMs == brutv::ReconnectPolicy::kFormatSwitchBackoffMs,
                        "Initial format switch before first frame did not use fast 300ms backoff.");
            } else {
                require(step.backoffMs >= brutv::ReconnectPolicy::kMinBackoffMs &&
                        step.backoffMs <= brutv::ReconnectPolicy::kMaxBackoffMs,
                        "Live reconnect backoff exceeded [1.5s, 12s] after initial format switch.");
            }
            prevFailures = step.failures;
            prevOnActive = step.failuresOnActiveFormat;
        }
        const auto exhausted = brutv::ReconnectPolicy::evaluate(
            true, false, false, false, 0.0, true, prevFailures, prevOnActive, 0.5);
        require(!exhausted.shouldRetry, "Live reconnect exceeded max consecutive failure budget.");

        const auto noAlternate = brutv::ReconnectPolicy::evaluate(
            true, false, false, false, 0.0, false, 0, 0, 0.5);
        require(noAlternate.shouldRetry && !noAlternate.switchFormat &&
                noAlternate.backoffMs >= brutv::ReconnectPolicy::kMinBackoffMs &&
                noAlternate.backoffMs <= brutv::ReconnectPolicy::kMaxBackoffMs,
                "First live failure without alternate format did not use standard backoff.");

        // Jitter varies backoff around exponential base while staying bounded.
        const auto lowJitter = brutv::ReconnectPolicy::evaluate(
            true, false, true, true, 5.0, false, 1, 1, 0.0);
        const auto highJitter = brutv::ReconnectPolicy::evaluate(
            true, false, true, true, 5.0, false, 1, 1, 1.0);
        require(lowJitter.backoffMs < highJitter.backoffMs &&
                lowJitter.backoffMs >= 1500 && highJitter.backoffMs <= 12000,
                "Exponential backoff jitter was not applied cleanly.");

        // VOD: fails immediately if initial open never succeeded or local file; allows 2 retries after open.
        const auto vodInitialFail = brutv::ReconnectPolicy::evaluate(
            false, false, false, false, 0.0, false, 0, 0, 0.5);
        require(!vodInitialFail.shouldRetry,
                "Unreachable VOD initial open should not block with retries.");
        const auto vodLocalFail = brutv::ReconnectPolicy::evaluate(
            false, true, true, true, 5.0, false, 0, 0, 0.5);
        require(!vodLocalFail.shouldRetry, "Local file failure should not retry.");
        const auto vodRetry1 = brutv::ReconnectPolicy::evaluate(
            false, false, true, true, 5.0, false, 0, 0, 0.5);
        const auto vodRetry2 = brutv::ReconnectPolicy::evaluate(
            false, false, true, true, 5.0, false, 1, 1, 0.5);
        const auto vodRetry3 = brutv::ReconnectPolicy::evaluate(
            false, false, true, true, 5.0, false, 2, 2, 0.5);
        require(vodRetry1.shouldRetry && vodRetry2.shouldRetry && !vodRetry3.shouldRetry,
                "HTTP VOD did not allow exactly 2 bounded reconnect retries.");
    }

    // 3. Rewind-to-direct fallback without black-frame timestamp drop.
    {
        const double currentPosition = 142.75;
        auto timing = brutv::prepareDirectFallbackTiming(currentPosition);
        require(!std::isfinite(timing.origin),
                "Direct fallback did not reset origin so next raw PTS re-anchors cleanly.");
        require(std::abs(timing.offset - currentPosition) < 1e-9,
                "Direct fallback did not preserve current timeline offset.");
        require(timing.discardBefore < 0.0,
                "Direct fallback left discardBefore >= 0, risking permanent black-frame drops.");

        // Simulate frameTime() after fallback when incoming raw PTS is arbitrary or wrapped.
        for (double rawFirst : {1142.75, 0.5, 50000.0}) {
            double origin = timing.origin;
            const double offset = timing.offset;
            if (!std::isfinite(origin)) origin = rawFirst;
            const double firstPts = std::max(0.0, rawFirst - origin + offset);
            const double secondPts = std::max(0.0, (rawFirst + 0.04) - origin + offset);
            require(!(firstPts + 0.02 < timing.discardBefore),
                    "Post-fallback frame was silently discarded by discardBefore.");
            require(std::abs(firstPts - currentPosition) < 1e-6 &&
                    secondPts > firstPts,
                    "Post-fallback frame timestamps did not continue seamlessly from current position.");
        }
    }

    // 4. Bounded LRU WorkingFormatCache.
    {
        brutv::WorkingFormatCache cache(2);
        require(!cache.lookup("https://provider.example/live/u/p/1.m3u8").has_value(),
                "Empty WorkingFormatCache unexpectedly returned an entry.");
        cache.remember("https://provider.example/live/u/p/1.m3u8",
                       "https://provider.example/live/u/p/1.ts");
        cache.remember("https://provider.example/live/u/p/2.m3u8",
                       "https://provider.example/live/u/p/2.m3u8");
        require(cache.size() == 2, "WorkingFormatCache size did not match inserted count.");
        const auto hit1 = cache.lookup("https://provider.example/live/u/p/1.m3u8");
        require(hit1 && *hit1 == "https://provider.example/live/u/p/1.ts",
                "WorkingFormatCache lookup did not return remembered URL.");
        cache.remember("https://provider.example/live/u/p/3.m3u8",
                       "https://provider.example/live/u/p/3.ts");
        require(cache.size() == 2, "WorkingFormatCache exceeded max capacity.");
        require(!cache.lookup("https://provider.example/live/u/p/2.m3u8").has_value(),
                "WorkingFormatCache did not evict least-recently-used entry.");
        const auto hit1Again = cache.lookup("https://provider.example/live/u/p/1.m3u8");
        const auto hit3 = cache.lookup("https://provider.example/live/u/p/3.m3u8");
        require(hit1Again && *hit1Again == "https://provider.example/live/u/p/1.ts" &&
                hit3 && *hit3 == "https://provider.example/live/u/p/3.ts",
                "WorkingFormatCache lost recently used entries during LRU eviction.");
        cache.remember("https://provider.example/live/u/p/1.m3u8",
                       "https://provider.example/live/u/p/1.m3u8");
        const auto updated = cache.lookup("https://provider.example/live/u/p/1.m3u8");
        require(updated && *updated == "https://provider.example/live/u/p/1.m3u8",
                "WorkingFormatCache did not update an existing key.");
        cache.clear();
        require(cache.size() == 0 &&
                !cache.lookup("https://provider.example/live/u/p/1.m3u8").has_value(),
                "WorkingFormatCache::clear did not remove cached entries.");
    }
}

void liveFallbackOrReconnect(const std::string& url,
                             const std::unordered_map<std::string, std::string>& headers = {}) {
    brutv::Player player(std::make_shared<CountingSink>());
    player.open(url, true, headers);
    std::size_t frameCount = 0;
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        if (player.takeFrame(frame)) {
            ++frameCount;
        }
        return frameCount >= 5 && status.currentSeconds > 0.2 &&
               status.state == brutv::Player::State::Playing;
    }, std::chrono::seconds(15));
    player.stop();
}

void vodWithHeaders(const std::string& url) {
    brutv::Player player(std::make_shared<CountingSink>());
    player.open(url, false, {{"Cookie", "session=brutv-test"}, {"Origin", "https://brutv.example"}});
    std::size_t frameCount = 0;
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        if (player.takeFrame(frame)) {
            ++frameCount;
        }
        return status.state == brutv::Player::State::Ended;
    }, std::chrono::seconds(15));
    require(frameCount >= 10, "VOD with custom headers decoded too few frames.");
    player.stop();
}

void vodReconnect(const std::string& url) {
    brutv::Player player(std::make_shared<CountingSink>());
    player.open(url, false);
    std::size_t frameCount = 0;
    waitFor(player, [&](const auto& status) {
        brutv::VideoFrame frame;
        if (player.takeFrame(frame)) {
            ++frameCount;
        }
        return status.state == brutv::Player::State::Ended;
    }, std::chrono::seconds(20));
    require(frameCount >= 10, "Reconnected VOD decoded too few frames.");
    player.stop();
}

} // namespace

int main(int argc, char** argv) {
    if (argc == 2 && std::string(argv[1]) == "--unit") {
        try {
            unitTests();
            std::cout << "Player unit tests (Xtream fallback, retry budget, direct fallback timing) passed.\n";
            return 0;
        } catch (const std::exception& error) {
            std::cerr << error.what() << '\n';
            return 1;
        }
    }
    if (argc == 3 && (std::string(argv[1]) == "--live" || std::string(argv[1]) == "--live-direct" ||
                      std::string(argv[1]) == "--live-fallback" ||
                      std::string(argv[1]) == "--vod-headers" ||
                      std::string(argv[1]) == "--vod-reconnect")) {
        try {
            const std::string mode = argv[1];
            if (mode == "--live") {
                liveRewind(argv[2]);
                std::cout << "Live recording during pause, rewind and Go Live passed.\n";
            } else if (mode == "--live-direct") {
                liveDirectFallback(argv[2]);
                std::cout << "Unavailable live storage falls back to direct playback.\n";
            } else if (mode == "--live-fallback") {
                liveFallbackOrReconnect(argv[2]);
                std::cout << "Live fallback / reconnect playback passed.\n";
            } else if (mode == "--vod-headers") {
                vodWithHeaders(argv[2]);
                std::cout << "VOD custom headers playback passed.\n";
            } else {
                vodReconnect(argv[2]);
                std::cout << "VOD reconnect and resume playback passed.\n";
            }
            return 0;
        } catch (const std::exception& error) {
            std::cerr << error.what() << '\n';
            return 1;
        }
    }
    if (argc < 2 || argc > 3) {
        std::cerr << "Usage: brutv_player_test <two-second video+audio fixture path or URL>\n";
        return 2;
    }
    try {
        unitTests();
        decodeFixture(argv[1], true, true);
        decodeFixture(argv[1], false, false);
        controls(argv[1]);
        if (argc == 3) tracks(argv[2]);
        std::cout << "Media decode, GPU YUV & RGBA pool, audio resampling, timing, controls and lifecycle passed.\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
