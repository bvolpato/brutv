#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
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

class Player {
public:
    enum class State { Idle, Opening, Buffering, Playing, Paused, Ended, Error };

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
    };

    explicit Player(std::shared_ptr<AudioSink> audioSink = {});
    ~Player();
    Player(const Player&) = delete;
    Player& operator=(const Player&) = delete;

    // open() replaces any previous session. Demux and software decoding run on
    // a worker without an OpenGL context. HTTP(S), HLS and files use FFmpeg.
    // Only User-Agent and Referer source headers are accepted. Header values
    // cannot contain controls, and their combined serialized size is bounded.
    void open(const std::string& url, bool live = true,
              const std::unordered_map<std::string, std::string>& requestHeaders = {});
    void stop();
    void setPaused(bool paused);
    void togglePause();
    void seekRelative(double seconds);
    void setVolume(float volume);
    Status status() const;

    // Call from the render loop. Returns a due RGBA frame without blocking;
    // retain the previous texture when false. At most six frames are buffered.
    bool takeFrame(VideoFrame& frame);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace brutv
