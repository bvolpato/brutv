#pragma once

#include <cstddef>
#include <cstdint>
#include <list>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace brutv {

// Implementations must copy accepted data and make every method thread-safe.
// queue() must never wait for playback or grow an unbounded device queue.
class AudioSink {
public:
    virtual ~AudioSink() = default;
    virtual bool queue(const std::int16_t* stereoSamples, std::size_t frames) = 0;
    virtual double queuedSeconds() const = 0;
    virtual void clear() = 0;
    virtual void setPaused(bool paused) = 0;
};

// AudioSink data is always interleaved, signed 16-bit, stereo PCM at 48 kHz.
struct VideoFrame {
    int width = 0;
    int height = 0;
    double ptsSeconds = 0.0;
    std::uint64_t serial = 0;
    std::vector<std::uint8_t> rgba;
};

struct ReconnectPolicy {
    static constexpr int kMaxLiveFailures = 6;
    static constexpr int kMaxVodFailures = 2;
    static constexpr int kHealthyPlaybackSeconds = 30;
    static constexpr int kFormatSwitchBackoffMs = 300;
    static constexpr int kMinBackoffMs = 1500;
    static constexpr int kMaxBackoffMs = 12000;

    struct Outcome {
        bool shouldRetry = false;
        int failures = 0;
        int failuresOnActiveFormat = 0;
        int maxFailures = 0;
        int backoffMs = 0;
        bool switchFormat = false;
    };

    static Outcome evaluate(bool live, bool local, bool hadFirstFrame, bool everOpened,
                            double healthyPlaybackSeconds, bool hasAlternateFormat,
                            int previousFailures, int previousFailuresOnActive, double jitterUnit);
};

class WorkingFormatCache {
public:
    static constexpr std::size_t kDefaultMaxEntries = 128;

    explicit WorkingFormatCache(std::size_t maxEntries = kDefaultMaxEntries);

    std::optional<std::string> lookup(const std::string& primaryUrl);
    void remember(const std::string& primaryUrl, const std::string& workingUrl);
    void clear();
    std::size_t size() const;

private:
    using EntryList = std::list<std::pair<std::string, std::string>>;

    std::size_t maxEntries_;
    EntryList order_;
    std::unordered_map<std::string, EntryList::iterator> index_;
};

struct DirectFallbackTiming {
    double origin = 0.0;
    double offset = 0.0;
    double discardBefore = -1.0;
};

DirectFallbackTiming prepareDirectFallbackTiming(double currentPosition);

class Player {
public:
    enum class State { Idle, Opening, Buffering, Playing, Paused, Ended, Error };

    struct Track {
        int id = -1;
        std::string label;
    };

    struct Status {
        State state = State::Idle;
        std::string message;
        double currentSeconds = 0.0;
        double durationSeconds = 0.0;
        int width = 0;
        int height = 0;
        bool hasAudio = false;
        bool hasVideo = false;
        bool live = true;
        float volume = 1.0F;
        std::uint64_t droppedFrames = 0;
        std::vector<Track> audioTracks;
        std::vector<Track> subtitleTracks;
        int audioTrack = -1;
        int subtitleTrack = -1;
        std::string subtitleText;
        bool liveRewind = false;
        std::string rewindMessage;
        double windowStartSeconds = 0.0;
        double windowEndSeconds = 0.0;
        std::size_t recordedBytes = 0;
    };

    explicit Player(std::shared_ptr<AudioSink> audioSink = {});
    ~Player();
    Player(const Player&) = delete;
    Player& operator=(const Player&) = delete;

    // open() replaces any previous session. Demux and software decoding run on
    // a worker without an OpenGL context. HTTP(S), HLS and files use FFmpeg.
    // User-Agent, Referer, and safe custom HTTP headers (such as Cookie/Origin)
    // are forwarded after rejecting forbidden hop-by-hop/Host headers, control
    // characters, duplicates, and oversized values.
    void open(const std::string& url, bool live = true,
              const std::unordered_map<std::string, std::string>& requestHeaders = {});
    void stop();
    void setPaused(bool paused);
    void togglePause();
    void seekRelative(double seconds);
    void goLive();
    void cycleAudioTrack();
    void cycleSubtitleTrack();
    void setVolume(float volume);
    void clearFormatCache();
    Status status() const;

    // Call from the render loop. Returns a due RGBA frame without blocking;
    // retain the previous texture when false. At most six frames are buffered.
    bool takeFrame(VideoFrame& frame);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace brutv
