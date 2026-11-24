// SPDX-License-Identifier: MIT
#include "brutv/player.hpp"
#include "brutv/catalog.hpp"
#include "brutv/timeshift.hpp"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/codec_desc.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/imgutils.h>
#include <libavutil/log.h>
#include <libavutil/mathematics.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdarg>
#include <cstring>
#include <deque>
#include <limits>
#include <mutex>
#include <random>
#include <stdexcept>
#include <string_view>
#include <thread>
#include <unordered_set>
#include <utility>

namespace brutv {
namespace {

using Clock = std::chrono::steady_clock;
constexpr int kAudioRate = 48000;
constexpr int kMaxYuvWidth = 1920;
constexpr int kMaxYuvHeight = 1080;
constexpr int kMaxSwsWidth = 1280;
constexpr int kMaxSwsHeight = 720;
constexpr std::size_t kMaxFrames = 6;
constexpr std::size_t kMaxFramePool = kMaxFrames + 2;
constexpr std::size_t kMaxRecentSubPackets = 256;
constexpr int kMaxCachedSubPacketBytes = 4096;
constexpr double kMaxAudioSeconds = 0.5;
constexpr auto kIoTimeout = std::chrono::seconds(15);
constexpr auto kCloseTimeout = std::chrono::seconds(3);
constexpr auto kFreezeTimeout = std::chrono::seconds(15);
constexpr auto kSnapshotThrottle = std::chrono::milliseconds(250);
constexpr const char* kDefaultUserAgent = "BruTV/1.0";
constexpr double kNoTime = std::numeric_limits<double>::quiet_NaN();

struct RewindUnavailable : std::runtime_error {
    using std::runtime_error::runtime_error;
};

struct RequestOptions {
    std::string userAgent;
    std::string referer;
    std::string extraHeaders;
    bool local = false;
};

std::string asciiLower(std::string text) {
    for (char& letter : text) {
        if (letter >= 'A' && letter <= 'Z') {
            letter = static_cast<char>(letter + ('a' - 'A'));
        }
    }
    return text;
}

bool isHlsPlaylistUrl(const std::string& url) {
    const auto suffix = url.find_first_of("?#");
    const std::string path = asciiLower(url.substr(0, suffix));
    return path.size() >= 5 && path.compare(path.size() - 5, 5, ".m3u8") == 0;
}

bool isHttpTokenChar(unsigned char c) {
    return std::isalnum(c) ||
           std::string_view("!#$%&'*+-.^_|~").find(static_cast<char>(c)) != std::string_view::npos ||
           c == 0x60;
}

bool isForbiddenRequestHeader(std::string_view lowerName) {
    return lowerName == "host" || lowerName == "connection" || lowerName == "content-length" ||
           lowerName == "transfer-encoding" || lowerName == "upgrade" || lowerName == "te" ||
           lowerName == "keep-alive" || lowerName == "proxy-connection" ||
           lowerName == "proxy-authorization";
}

RequestOptions requestOptions(const std::string& url,
                             const std::unordered_map<std::string, std::string>& headers) {
    RequestOptions options;
    const std::string lowerUrl = asciiLower(url);
    options.local = lowerUrl.compare(0, 7, "http://") != 0 &&
                    lowerUrl.compare(0, 8, "https://") != 0;
    std::size_t size = 0;
    std::unordered_set<std::string> seen;
    for (const auto& header : headers) {
        size += header.first.size() + header.second.size() + 4;
        if (header.first.empty() || header.first.size() > 128 || size > 8192 ||
            header.second.size() > 4096 ||
            !std::all_of(header.first.begin(), header.first.end(), isHttpTokenChar) ||
            std::any_of(header.second.begin(), header.second.end(), [](unsigned char c) {
                return c < 0x20 || c == 0x7F;
            })) {
            throw std::runtime_error("The source request headers are invalid or too large.");
        }
        const std::string name = asciiLower(header.first);
        if (isForbiddenRequestHeader(name)) {
            throw std::runtime_error("A forbidden source request header was rejected.");
        }
        if (!seen.insert(name).second) {
            throw std::runtime_error("Duplicate source request headers are not supported.");
        }
        if (name == "user-agent") {
            options.userAgent = header.second;
        } else if (name == "referer") {
            options.referer = header.second;
        } else {
            options.extraHeaders += header.first;
            options.extraHeaders += ": ";
            options.extraHeaders += header.second;
            options.extraHeaders += "\r\n";
        }
    }
    return options;
}

std::int64_t monotonicNanoseconds() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               Clock::now().time_since_epoch()).count();
}

std::string avError(int error) {
    char buffer[AV_ERROR_MAX_STRING_SIZE]{};
    av_strerror(error, buffer, sizeof(buffer));
    return buffer;
}

// FFmpeg's protocol logs can include full authenticated URLs. BruTV reports
// error codes through Status instead of forwarding those raw library logs.
void discardAvLog(void*, int, const char*, va_list) {}

void initializeFfmpeg() {
    static std::once_flag initialized;
    std::call_once(initialized, [] {
        av_log_set_callback(discardAvLog);
        avformat_network_init();
    });
}

struct RunControl {
    std::uint64_t id = 0;
    std::atomic<bool> stopping{false};
    std::atomic<bool> seekInterrupt{false};
    std::atomic<bool> trackSwitchPending{false};
    std::atomic<bool> capturingLive{false};
    std::atomic<bool> captureStopping{false};
    std::atomic<bool> waitingForSpool{false};
    std::atomic<std::int64_t> deadline{0};

    static int interrupt(void* opaque) {
        auto* self = static_cast<RunControl*>(opaque);
        const auto limit = self->deadline.load(std::memory_order_relaxed);
        return self->stopping.load(std::memory_order_relaxed) ||
               self->captureStopping.load(std::memory_order_relaxed) ||
               (self->seekInterrupt.load(std::memory_order_relaxed) &&
                !self->capturingLive.load(std::memory_order_relaxed)) ||
               (limit != 0 && monotonicNanoseconds() >= limit);
    }

    void beginIo(std::chrono::milliseconds timeout = kIoTimeout) {
        deadline.store(monotonicNanoseconds() +
                           std::chrono::duration_cast<std::chrono::nanoseconds>(timeout).count(),
                       std::memory_order_relaxed);
    }

    void endIo() {
        deadline.store(0, std::memory_order_relaxed);
    }
};

struct CachedSubtitlePacket {
    AVPacket* packet = nullptr;
    CachedSubtitlePacket() = default;
    explicit CachedSubtitlePacket(const AVPacket* src) {
        packet = av_packet_clone(src);
    }
    CachedSubtitlePacket(CachedSubtitlePacket&& other) noexcept : packet(other.packet) {
        other.packet = nullptr;
    }
    CachedSubtitlePacket& operator=(CachedSubtitlePacket&& other) noexcept {
        if (this != &other) {
            av_packet_free(&packet);
            packet = other.packet;
            other.packet = nullptr;
        }
        return *this;
    }
    CachedSubtitlePacket(const CachedSubtitlePacket&) = delete;
    CachedSubtitlePacket& operator=(const CachedSubtitlePacket&) = delete;
    ~CachedSubtitlePacket() { av_packet_free(&packet); }
};

struct Session {
    std::shared_ptr<RunControl> run;
    AVFormatContext* format = nullptr;
    AVCodecContext* video = nullptr;
    AVCodecContext* audio = nullptr;
    AVCodecContext* subtitle = nullptr;
    AVPacket* packet = nullptr;
    AVFrame* decoded = nullptr;
    SwsContext* scaler = nullptr;
    int lastSwsColorspace = -1;
    int lastSwsColorRange = -1;
    int lastSwsSrcW = 0;
    int lastSwsSrcH = 0;
    int lastSwsSrcFmt = -1;
    int lastSwsDstW = 0;
    int lastSwsDstH = 0;
    SwrContext* resampler = nullptr;
    AVChannelLayout resampleLayout{};
    int resampleRate = 0;
    int resampleFormat = -1;
    std::vector<std::int16_t> pcmBuffer;
    int videoIndex = -1;
    int audioIndex = -1;
    std::atomic<int> activeAudioIndex{-1};
    int subtitleIndex = -1;
    std::unordered_set<int> textSubtitleStreams;
    std::deque<CachedSubtitlePacket> recentSubtitlePackets;
    std::vector<AVCodecParameters*> streamParameters;
    std::vector<AVRational> timeBases;
    AVRational frameRate{0, 1};
    double origin = kNoTime;
    double videoOffset = 0.0;
    double audioOffset = 0.0;
    double lastRawVideo = kNoTime;
    double lastRawAudio = kNoTime;
    double nextVideo = 0.0;
    double nextAudio = 0.0;
    double discardBefore = -1.0;
    bool live = false;
    bool preview = true;
    bool useAudioOutput = false;
    bool audioOutputStalled = false;
    Clock::time_point audioRetryAt{};
    bool hasFirstFrame = false;
    Clock::time_point firstFrameAt{};
    Clock::time_point lastActiveFrameAt{};
    std::uint64_t lastPauseEpoch = 0;
    double activePlayingSeconds = 0.0;
    Clock::time_point lastProgressAt = Clock::now();
    int videoDecodeErrors = 0;
    int audioDecodeErrors = 0;

    void setOffsets(double value) {
        videoOffset = value;
        audioOffset = value;
    }

    ~Session() {
        recentSubtitlePackets.clear();
        sws_freeContext(scaler);
        swr_free(&resampler);
        av_channel_layout_uninit(&resampleLayout);
        av_frame_free(&decoded);
        av_packet_free(&packet);
        avcodec_free_context(&video);
        avcodec_free_context(&audio);
        avcodec_free_context(&subtitle);
        for (auto*& parameters : streamParameters) avcodec_parameters_free(&parameters);
        if (format && run) {
            run->deadline.store(
                monotonicNanoseconds() +
                    std::chrono::duration_cast<std::chrono::nanoseconds>(kCloseTimeout).count(),
                std::memory_order_relaxed);
        }
        avformat_close_input(&format);
        if (run) {
            run->endIo();
        }
    }
};

AVCodecContext* openDecoder(const AVCodecParameters* parameters, AVRational timebase) {
    const AVCodec* codec = avcodec_find_decoder(parameters->codec_id);
    if (!codec) {
        throw std::runtime_error("This source uses an unsupported codec.");
    }
    AVCodecContext* context = avcodec_alloc_context3(codec);
    if (!context) {
        throw std::runtime_error("Cannot allocate a media decoder.");
    }
    int result = avcodec_parameters_to_context(context, parameters);
    if (result >= 0) {
        const unsigned cores = std::thread::hardware_concurrency();
        context->thread_count = std::clamp<int>(static_cast<int>(cores / 2U), 2, 4);
        context->max_pixels = 3840LL * 2160LL;
        context->pkt_timebase = timebase;
        result = avcodec_open2(context, codec, nullptr);
    }
    if (result < 0) {
        avcodec_free_context(&context);
        throw std::runtime_error("Cannot initialize a media decoder: " + avError(result));
    }
    return context;
}

std::string trackLabel(const AVStream* stream, const char* kind, int number) {
    const auto* title = av_dict_get(stream->metadata, "title", nullptr, 0);
    const auto* language = av_dict_get(stream->metadata, "language", nullptr, 0);
    std::string label = title ? title->value : std::string(kind) + " " + std::to_string(number);
    if (language && std::string(language->value) != "und") {
        label += " (" + std::string(language->value) + ")";
    }
    if (label.size() > 120) label.resize(120);
    return label;
}

std::string subtitleText(const AVSubtitleRect* rect) {
    std::string input;
    if (rect->text) {
        input = rect->text;
    } else if (rect->ass) {
        input = rect->ass;
        std::size_t start = 0;
        for (int field = 0; field < 8; ++field) {
            const auto comma = input.find(',', start);
            if (comma == std::string::npos) return {};
            start = comma + 1;
        }
        input.erase(0, start);
    }
    std::string result;
    bool override = false;
    bool tag = false;
    for (std::size_t index = 0; index < input.size() && result.size() < 2048; ++index) {
        const char value = input[index];
        if (value == '{') { override = true; continue; }
        if (value == '}' && override) { override = false; continue; }
        if (value == '<') { tag = true; continue; }
        if (value == '>' && tag) { tag = false; continue; }
        if (override || tag) continue;
        if (value == '\\' && index + 1 < input.size()) {
            const char next = input[index + 1];
            if (next == 'N' || next == 'n' || next == 'h') {
                result += next == 'h' ? ' ' : '\n';
                ++index;
                continue;
            }
        }
        if (static_cast<unsigned char>(value) >= 0x20 || value == '\n') result += value;
    }
    return result;
}

void copyPlane(const std::uint8_t* src, int srcStride, std::vector<std::uint8_t>& dst,
               int width, int height) {
    const std::size_t w = static_cast<std::size_t>(width);
    const std::size_t h = static_cast<std::size_t>(height);
    dst.resize(w * h);
    if (srcStride == width) {
        std::memcpy(dst.data(), src, w * h);
        return;
    }
    std::uint8_t* out = dst.data();
    for (int row = 0; row < height; ++row) {
        std::memcpy(out, src + static_cast<std::ptrdiff_t>(row) * srcStride, w);
        out += w;
    }
}

VideoFrame::ColorSpace detectColorSpace(const AVFrame* frame) {
    switch (frame->colorspace) {
        case AVCOL_SPC_BT709:
            return VideoFrame::ColorSpace::Bt709;
        case AVCOL_SPC_BT2020_NCL:
        case AVCOL_SPC_BT2020_CL:
            return VideoFrame::ColorSpace::Bt2020;
        case AVCOL_SPC_BT470BG:
        case AVCOL_SPC_SMPTE170M:
            return VideoFrame::ColorSpace::Bt601;
        default:
            return frame->height >= 720 ? VideoFrame::ColorSpace::Bt709
                                        : VideoFrame::ColorSpace::Bt601;
    }
}

} // namespace

ReconnectPolicy::Outcome ReconnectPolicy::evaluate(
    bool live, bool local, bool hadFirstFrame, bool everOpened,
    double healthyPlaybackSeconds, bool hasAlternateFormat, int previousFailures,
    int previousFailuresOnActive, double jitterUnit) {
    Outcome outcome;
    int failures = previousFailures;
    int failuresOnActive = previousFailuresOnActive;
    if (hadFirstFrame && healthyPlaybackSeconds > static_cast<double>(kHealthyPlaybackSeconds)) {
        failures = 0;
        failuresOnActive = 0;
    }
    ++failures;
    ++failuresOnActive;
    outcome.failures = failures;
    outcome.failuresOnActiveFormat = failuresOnActive;
    outcome.maxFailures = live ? kMaxLiveFailures : kMaxVodFailures;
    if (live) {
        if (failures > kMaxLiveFailures) {
            return outcome;
        }
        if (hasAlternateFormat && ((!hadFirstFrame && failuresOnActive >= 1) || failuresOnActive >= 2)) {
            outcome.switchFormat = true;
            outcome.failuresOnActiveFormat = 0;
        }
    } else {
        if (local || !everOpened || failures > kMaxVodFailures) {
            return outcome;
        }
    }
    if (outcome.switchFormat && !hadFirstFrame && failures == 1) {
        outcome.backoffMs = kFormatSwitchBackoffMs;
    } else {
        const int shift = std::min(failures - 1, 4);
        const int baseMs = std::min(kMinBackoffMs * (1 << shift), kMaxBackoffMs);
        const double clampedJitter = std::clamp(jitterUnit, 0.0, 1.0);
        const int jittered = baseMs + static_cast<int>(std::lround((clampedJitter - 0.5) * 0.3 * baseMs));
        outcome.backoffMs = std::clamp(jittered, kMinBackoffMs, kMaxBackoffMs);
    }
    outcome.shouldRetry = true;
    return outcome;
}

WorkingFormatCache::WorkingFormatCache(std::size_t maxEntries) : maxEntries_(maxEntries) {}

std::optional<std::string> WorkingFormatCache::lookup(const std::string& primaryUrl) {
    const auto found = index_.find(primaryUrl);
    if (found == index_.end()) {
        return std::nullopt;
    }
    order_.splice(order_.begin(), order_, found->second);
    return found->second->second;
}

void WorkingFormatCache::remember(const std::string& primaryUrl, const std::string& workingUrl) {
    if (maxEntries_ == 0 || primaryUrl.empty() || workingUrl.empty()) {
        return;
    }
    const auto found = index_.find(primaryUrl);
    if (found != index_.end()) {
        found->second->second = workingUrl;
        order_.splice(order_.begin(), order_, found->second);
        return;
    }
    if (order_.size() >= maxEntries_) {
        index_.erase(order_.back().first);
        order_.pop_back();
    }
    order_.emplace_front(primaryUrl, workingUrl);
    index_[order_.front().first] = order_.begin();
}

void WorkingFormatCache::clear() {
    index_.clear();
    order_.clear();
}

std::size_t WorkingFormatCache::size() const {
    return order_.size();
}

DirectFallbackTiming prepareDirectFallbackTiming(double currentPosition) {
    return {kNoTime, std::max(0.0, currentPosition), -1.0};
}

struct Player::Impl {
    explicit Impl(std::shared_ptr<AudioSink> output) : sink(std::move(output)) {
        initializeFfmpeg();
        reaper = std::thread([this] { reapWorkers(); });
    }

    ~Impl() {
        {
            std::lock_guard<std::mutex> lock(lifecycle);
            stopLocked();
        }
        {
            std::lock_guard<std::mutex> lock(reaperMutex);
            reaperStopping = true;
        }
        reaperCv.notify_all();
        if (reaper.joinable()) {
            reaper.join();
        }
    }

    std::shared_ptr<AudioSink> sink;
    std::mutex sinkMutex;
    mutable std::mutex mutex;
    std::mutex lifecycle;
    std::condition_variable changed;
    std::thread worker;
    std::shared_ptr<RunControl> activeRun;
    std::atomic<std::uint64_t> activeRunId{0};
    std::atomic<bool> isLive{false};
    std::atomic<float> volume{1.0F};
    std::atomic<bool> preferYuv{true};

    // Background worker reaper so Player::open()/stop() never block the UI thread on worker.join().
    std::mutex reaperMutex;
    std::condition_variable reaperCv;
    std::deque<std::thread> retiredWorkers;
    bool reaperStopping = false;
    std::thread reaper;

    Status snapshot;
    std::deque<VideoFrame> frames;
    std::vector<VideoFrame> framePool;
    bool paused = false;
    bool sourceOpened = false;
    bool clockStarted = false;
    bool audioMaster = false;
    double clockBase = 0.0;
    mutable double lastClock = 0.0;
    double audioEnd = kNoTime;
    Clock::time_point clockAnchor = Clock::now();
    double seekTarget = kNoTime;
    int requestedAudio = -2;
    int requestedSubtitle = -2;
    struct Cue { double start; double end; std::string text; };
    std::deque<Cue> cues;
    std::uint64_t serial = 0;
    std::uint64_t pauseEpoch = 0;
    WorkingFormatCache workingFormatCache;

    void reapWorkers() {
        for (;;) {
            std::thread toJoin;
            {
                std::unique_lock<std::mutex> lock(reaperMutex);
                reaperCv.wait(lock, [&] { return reaperStopping || !retiredWorkers.empty(); });
                if (retiredWorkers.empty()) {
                    if (reaperStopping) return;
                    continue;
                }
                toJoin = std::move(retiredWorkers.front());
                retiredWorkers.pop_front();
            }
            if (toJoin.joinable()) {
                toJoin.join();
            }
        }
    }

    bool isCurrentRun(const RunControl& run) const {
        return !run.stopping.load(std::memory_order_relaxed) &&
               activeRunId.load(std::memory_order_acquire) == run.id;
    }

    void recycleFrameLocked(VideoFrame&& frame) {
        if (framePool.size() >= kMaxFramePool) {
            return;
        }
        if (!frame.yPlane.empty() || !frame.uPlane.empty() || !frame.vPlane.empty() ||
            !frame.rgba.empty()) {
            frame.width = 0;
            frame.height = 0;
            frame.displayWidth = 0;
            frame.displayHeight = 0;
            frame.ptsSeconds = 0.0;
            frame.serial = 0;
            framePool.push_back(std::move(frame));
        }
    }

    VideoFrame borrowFrame() {
        std::lock_guard<std::mutex> lock(mutex);
        if (!framePool.empty()) {
            VideoFrame f = std::move(framePool.back());
            framePool.pop_back();
            return f;
        }
        return VideoFrame{};
    }

    void clearSinkForRun(const RunControl& run) {
        if (!sink) return;
        std::lock_guard<std::mutex> lock(sinkMutex);
        if (activeRunId.load(std::memory_order_acquire) == run.id) {
            sink->clear();
        }
    }

    bool queueAudioForRun(const RunControl& run, const std::int16_t* samples, std::size_t framesCount) {
        if (!sink) return false;
        std::lock_guard<std::mutex> lock(sinkMutex);
        if (activeRunId.load(std::memory_order_acquire) != run.id) {
            return false;
        }
        return sink->queue(samples, framesCount);
    }

    double queuedAudio() const {
        if (!sink) {
            return 0.0;
        }
        const double queued = sink->queuedSeconds();
        return std::isfinite(queued) ? std::clamp(queued, 0.0, 5.0) : 0.0;
    }

    double clockLocked() const {
        if (!clockStarted || paused) {
            return clockBase;
        }
        const double wall = clockBase +
            std::chrono::duration<double>(Clock::now() - clockAnchor).count();
        if (audioMaster && std::isfinite(audioEnd)) {
            const double queued = queuedAudio();
            if (queued > 0.001) {
                const double audioClock = std::max(0.0, audioEnd - queued);
                lastClock = std::max(lastClock, audioClock);
                return lastClock;
            }
            return std::max(lastClock, std::max(0.0, std::max(wall, audioEnd)));
        }
        lastClock = std::max(lastClock, std::max(0.0, wall));
        return lastClock;
    }

    void noteDecodedProgressLocked(Session& session) {
        const auto now = Clock::now();
        if (!session.hasFirstFrame) {
            session.hasFirstFrame = true;
            session.firstFrameAt = now;
            session.lastActiveFrameAt = now;
            session.lastPauseEpoch = pauseEpoch;
        } else if (paused || session.lastPauseEpoch != pauseEpoch) {
            session.lastActiveFrameAt = now;
            session.lastPauseEpoch = pauseEpoch;
        } else {
            const double delta =
                std::chrono::duration<double>(now - session.lastActiveFrameAt).count();
            if (delta > 0.0 && delta <= 2.0) {
                session.activePlayingSeconds += delta;
            }
            session.lastActiveFrameAt = now;
        }
        session.lastProgressAt = now;
    }

    void commitAudioClockLocked(Session& session, double pts, int samples) {
        if (!session.video) {
            noteDecodedProgressLocked(session);
        }
        audioEnd = pts + static_cast<double>(samples) / kAudioRate;
        audioMaster = true;
        const double queued = queuedAudio();
        const double audioClock = std::max(0.0, audioEnd - queued);
        startClockLocked(audioClock);
        if (queued > 0.001) {
            // Enforce monotonic lastClock; only seek/discontinuity resetOutput() lowers it.
            const double monotonic = std::max(lastClock, audioClock);
            clockBase = monotonic;
            lastClock = monotonic;
            clockAnchor = Clock::now();
        } else {
            const double current = clockLocked();
            clockBase = std::max(current, audioClock);
            lastClock = clockBase;
            clockAnchor = Clock::now();
        }
    }

    void markPlayingLocked() {
        if (snapshot.state == State::Opening || snapshot.state == State::Buffering) {
            snapshot.state = paused ? State::Paused : State::Playing;
            snapshot.message.clear();
        }
    }

    void startClockLocked(double position) {
        if (!clockStarted) {
            clockBase = std::max(0.0, position);
            lastClock = clockBase;
            clockAnchor = Clock::now();
            clockStarted = true;
        }
        markPlayingLocked();
    }

    void resetOutput(const RunControl& run, double position) {
        clearSinkForRun(run);
        std::lock_guard<std::mutex> lock(mutex);
        if (!isCurrentRun(run)) return;
        while (!frames.empty()) {
            recycleFrameLocked(std::move(frames.front()));
            frames.pop_front();
        }
        cues.clear();
        ++serial;
        clockBase = std::max(0.0, position);
        lastClock = clockBase;
        clockAnchor = Clock::now();
        clockStarted = false;
        audioMaster = false;
        audioEnd = kNoTime;
        changed.notify_all();
    }

    bool waitActive(const RunControl& run, bool allowPreview = false) {
        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [&] {
            return !isCurrentRun(run) || run.seekInterrupt.load() ||
                   run.trackSwitchPending.load() || !paused || allowPreview;
        });
        return isCurrentRun(run) && !run.seekInterrupt.load() && !run.trackSwitchPending.load();
    }

    bool openSource(Session& session, const std::string& url, bool live, bool allowConnectRetry,
                    double resumePosition, const RequestOptions& request) {
        auto& run = *session.run;
        session.live = live;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!isCurrentRun(run)) return false;
            snapshot.liveRewind = false;
            snapshot.recordedBytes = 0;
            snapshot.windowStartSeconds = snapshot.windowEndSeconds = 0.0;
            snapshot.rewindMessage.clear();
        }
        session.format = avformat_alloc_context();
        if (!session.format) {
            throw std::runtime_error("Cannot allocate a media reader.");
        }
        session.format->interrupt_callback = {&RunControl::interrupt, &run};
        session.format->flags |= AVFMT_FLAG_DISCARD_CORRUPT | AVFMT_FLAG_GENPTS;
        if (live) {
            session.format->probesize = 1 * 1024 * 1024;
            session.format->max_analyze_duration = 2 * AV_TIME_BASE;
        } else {
            session.format->probesize = 4 * 1024 * 1024;
            session.format->max_analyze_duration = 5 * AV_TIME_BASE;
        }
        AVDictionary* options = nullptr;
        av_dict_set(&options, "rw_timeout", "15000000", 0);
        av_dict_set(&options, "tls_verify", "1", 0);
        av_dict_set(&options, "merge_pmt_versions", "1", 0);
        av_dict_set(&options, "protocol_whitelist", request.local
            ? "file,http,https,tcp,tls,crypto,httpproxy,data"
            : "http,https,tcp,tls,crypto,httpproxy,data", 0);
        const std::string ua = request.userAgent.empty() ? kDefaultUserAgent : request.userAgent;
        av_dict_set(&options, "user_agent", ua.c_str(), 0);
        if (!request.referer.empty()) {
            av_dict_set(&options, "referer", request.referer.c_str(), 0);
        }
        std::string headers = request.extraHeaders;
        if (!request.local && live) {
            const std::string lowerHeaders = asciiLower(headers);
            const bool hasCacheControl =
                lowerHeaders.rfind("cache-control:", 0) == 0 ||
                lowerHeaders.find("\r\ncache-control:") != std::string::npos;
            if (!hasCacheControl) {
                headers += "Cache-Control: no-cache\r\n";
            }
        }
        if (!headers.empty()) {
            av_dict_set(&options, "headers", headers.c_str(), 0);
        }
        if (!request.local) {
            av_dict_set(&options, "timeout", "15000000", 0);
            av_dict_set(&options, "http_multiple", "0", 0);
            av_dict_set(&options, "icy", "0", 0);
            av_dict_set(&options, "allowed_extensions", "ALL", 0);
            av_dict_set(&options, "max_reload", "5", 0);
            av_dict_set(&options, "seg_max_retry", "2", 0);
            av_dict_set(&options, "reconnect", "1", 0);
            if (allowConnectRetry) {
                av_dict_set(&options, "reconnect_on_network_error", "1", 0);
            }
            av_dict_set(&options, "reconnect_on_http_error",
                        "408,429,458,500,502,503,504,520,521,522,523,524,525,526", 0);
            av_dict_set(&options, "reconnect_delay_max", "4", 0);
            if (live) {
                const bool isHls = isHlsPlaylistUrl(url);
                av_dict_set(&options, "http_persistent", isHls ? "1" : "0", 0);
                av_dict_set(&options, "http_seekable", "0", 0);
                av_dict_set(&options, "reconnect_streamed", "1", 0);
                if (!isHls) {
                    av_dict_set(&options, "reconnect_at_eof", "1", 0);
                }
                av_dict_set(&options, "m3u8_hold_counters", "5", 0);
            }
        }
#ifdef BRUTV_PS5
        av_dict_set(&options, "ca_file", "/app0/assets/ca-bundle.crt", 0);
#endif
        run.beginIo(std::chrono::seconds(20));
        int result = avformat_open_input(&session.format, url.c_str(), nullptr, &options);
        av_dict_free(&options);
        run.endIo();
        if (!isCurrentRun(run)) {
            return false;
        }
        if (result < 0) {
            throw std::runtime_error("Cannot open source: " + avError(result));
        }
        run.beginIo(std::chrono::seconds(20));
        result = avformat_find_stream_info(session.format, nullptr);
        run.endIo();
        if (!isCurrentRun(run)) {
            return false;
        }
        if (result < 0) {
            throw std::runtime_error("Cannot read stream information: " + avError(result));
        }
        session.videoIndex = av_find_best_stream(session.format, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
        session.audioIndex = av_find_best_stream(session.format, AVMEDIA_TYPE_AUDIO, -1,
                                               session.videoIndex, nullptr, 0);
        session.activeAudioIndex.store(session.audioIndex, std::memory_order_relaxed);
        if (session.videoIndex < 0 && session.audioIndex < 0) {
            throw std::runtime_error("This source contains no playable video or audio stream.");
        }
        for (unsigned index = 0; index < session.format->nb_streams; ++index) {
            auto* parameters = avcodec_parameters_alloc();
            if (!parameters) throw std::runtime_error("Cannot retain stream information.");
            session.streamParameters.push_back(parameters);
            if (avcodec_parameters_copy(parameters, session.format->streams[index]->codecpar) < 0) {
                throw std::runtime_error("Cannot retain stream information.");
            }
            session.timeBases.push_back(session.format->streams[index]->time_base);
        }
        if (session.videoIndex >= 0) {
            session.video = openDecoder(session.streamParameters[session.videoIndex], session.timeBases[session.videoIndex]);
            session.frameRate = av_guess_frame_rate(session.format, session.format->streams[session.videoIndex], nullptr);
        }
        if (session.audioIndex >= 0) {
            session.audio = openDecoder(session.streamParameters[session.audioIndex], session.timeBases[session.audioIndex]);
        }
        session.packet = av_packet_alloc();
        session.decoded = av_frame_alloc();
        if (!session.packet || !session.decoded) {
            throw std::runtime_error("Cannot allocate media buffers.");
        }
        if (session.format->start_time != AV_NOPTS_VALUE) {
            session.origin = static_cast<double>(session.format->start_time) / AV_TIME_BASE;
        }
        if (!live && resumePosition > 0.0) {
            const double absolute =
                resumePosition + (std::isfinite(session.origin) ? session.origin : 0.0);
            run.beginIo();
            const int seekResult = avformat_seek_file(
                session.format, -1, INT64_MIN,
                static_cast<std::int64_t>(absolute * AV_TIME_BASE), INT64_MAX,
                AVSEEK_FLAG_BACKWARD);
            run.endIo();
            if (seekResult >= 0) {
                if (!std::isfinite(session.origin)) {
                    session.origin = 0.0;
                }
                session.setOffsets(0.0);
                session.discardBefore = resumePosition;
                session.nextVideo = resumePosition;
                session.nextAudio = resumePosition;
            } else {
                session.setOffsets(0.0);
                session.discardBefore = -1.0;
                session.nextVideo = 0.0;
                session.nextAudio = 0.0;
                resetOutput(run, 0.0);
            }
        } else {
            session.setOffsets(resumePosition);
            session.nextVideo = resumePosition;
            session.nextAudio = resumePosition;
        }
        session.useAudioOutput = session.audio && static_cast<bool>(sink);
        session.audioOutputStalled = false;
        session.lastProgressAt = Clock::now();
        session.textSubtitleStreams.clear();
        std::lock_guard<std::mutex> lock(mutex);
        if (!isCurrentRun(run)) return false;
        snapshot.audioTracks.clear();
        snapshot.subtitleTracks.clear();
        for (unsigned index = 0; index < session.format->nb_streams; ++index) {
            const auto* stream = session.format->streams[index];
            const auto* codec = avcodec_descriptor_get(stream->codecpar->codec_id);
            if (!avcodec_find_decoder(stream->codecpar->codec_id)) continue;
            if (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
                snapshot.audioTracks.push_back({static_cast<int>(index),
                    trackLabel(stream, "Audio", static_cast<int>(snapshot.audioTracks.size()) + 1)});
            } else if (stream->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE && codec &&
                       (codec->props & AV_CODEC_PROP_TEXT_SUB)) {
                session.textSubtitleStreams.insert(static_cast<int>(index));
                snapshot.subtitleTracks.push_back({static_cast<int>(index),
                    trackLabel(stream, "Subtitles", static_cast<int>(snapshot.subtitleTracks.size()) + 1)});
            }
        }
        snapshot.audioTrack = session.audioIndex;
        snapshot.subtitleTrack = -1;
        snapshot.hasVideo = session.video != nullptr;
        snapshot.hasAudio = session.audio != nullptr;
        snapshot.durationSeconds = session.format->duration > 0
            ? static_cast<double>(session.format->duration) / AV_TIME_BASE : 0.0;
        sourceOpened = true;
        snapshot.state = paused ? State::Paused : State::Buffering;
        snapshot.message = "Buffering...";
        return true;
    }

    double frameTime(Session& session, AVFrame* frame, int streamIndex, bool audio) {
        const auto timestamp = frame->best_effort_timestamp != AV_NOPTS_VALUE
            ? frame->best_effort_timestamp : frame->pts;
        double& previousRaw = audio ? session.lastRawAudio : session.lastRawVideo;
        double& streamOffset = audio ? session.audioOffset : session.videoOffset;
        const double fallback = audio ? session.nextAudio : session.nextVideo;
        if (timestamp == AV_NOPTS_VALUE) {
            return fallback;
        }
        const double raw = static_cast<double>(timestamp) *
            av_q2d(session.timeBases[streamIndex]);
        if (!std::isfinite(session.origin)) {
            session.origin = raw;
        }
        if (session.live) {
            if (std::isfinite(previousRaw) &&
                (raw - previousRaw > 30.0 || raw - previousRaw < -3.0)) {
                double current;
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    current = clockLocked();
                }
                streamOffset = current - (raw - session.origin);
                previousRaw = raw;
                resetOutput(*session.run, current);
                return std::max(0.0, raw - session.origin + streamOffset);
            }
            if (!std::isfinite(previousRaw)) {
                double current;
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    current = clockStarted ? clockLocked() : clockBase;
                }
                const double candidate = raw - session.origin + streamOffset;
                if (candidate > current + 30.0 || candidate < current - 30.0) {
                    streamOffset = current - (raw - session.origin);
                }
            }
        }
        previousRaw = raw;
        return std::max(0.0, raw - session.origin + streamOffset);
    }

    bool outputVideo(Session& session, AVFrame* frame) {
        auto& run = *session.run;
        if (frame->width <= 0 || frame->height <= 0 ||
            static_cast<std::int64_t>(frame->width) * frame->height > 3840LL * 2160LL) {
            throw std::runtime_error("Video exceeds the supported 4K software decode limit.");
        }
        const double pts = frameTime(session, frame, session.videoIndex, false);
        const double fps = av_q2d(session.frameRate);
        session.nextVideo = pts + (fps >= 1.0 && fps <= 240.0 ? 1.0 / fps : 1.0 / 25.0);
        if (pts + 0.02 < session.discardBefore) {
            return true;
        }
        double aspect = static_cast<double>(frame->width) / frame->height;
        if (frame->sample_aspect_ratio.num > 0 && frame->sample_aspect_ratio.den > 0) {
            aspect *= av_q2d(frame->sample_aspect_ratio);
        }
        if (!std::isfinite(aspect) || aspect < 0.1 || aspect > 10.0) {
            throw std::runtime_error("Invalid video aspect ratio.");
        }

        const bool useYuv =
            preferYuv.load(std::memory_order_relaxed) &&
            (frame->format == AV_PIX_FMT_YUV420P || frame->format == AV_PIX_FMT_YUVJ420P) &&
            frame->width <= kMaxYuvWidth && frame->height <= kMaxYuvHeight &&
            (frame->width & 1) == 0 && (frame->height & 1) == 0 &&
            frame->data[0] != nullptr && frame->data[1] != nullptr && frame->data[2] != nullptr;

        VideoFrame output = borrowFrame();
        output.ptsSeconds = pts;

        int statusWidth = 0;
        int statusHeight = 0;

        if (useYuv) {
            int displayW = std::min(frame->width, kMaxYuvWidth);
            int displayH = std::max(1, static_cast<int>(std::lround(displayW / aspect)));
            if (displayH > kMaxYuvHeight) {
                displayH = kMaxYuvHeight;
                displayW = std::max(1, static_cast<int>(std::lround(displayH * aspect)));
            }
            output.format = VideoFrame::Format::Yuv420p;
            output.colorSpace = detectColorSpace(frame);
            output.fullRange =
                frame->color_range == AVCOL_RANGE_JPEG || frame->format == AV_PIX_FMT_YUVJ420P;
            output.width = frame->width;
            output.height = frame->height;
            output.displayWidth = displayW;
            output.displayHeight = displayH;
            output.yStride = frame->width;
            output.uStride = frame->width / 2;
            output.vStride = frame->width / 2;
            copyPlane(frame->data[0], frame->linesize[0], output.yPlane, frame->width, frame->height);
            copyPlane(frame->data[1], frame->linesize[1], output.uPlane, frame->width / 2, frame->height / 2);
            copyPlane(frame->data[2], frame->linesize[2], output.vPlane, frame->width / 2, frame->height / 2);
            output.rgba.clear();
            statusWidth = displayW;
            statusHeight = displayH;
        } else {
            int width = std::min(frame->width, kMaxSwsWidth);
            int height = std::max(1, static_cast<int>(std::lround(width / aspect)));
            if (height > kMaxSwsHeight) {
                height = kMaxSwsHeight;
                width = std::max(1, static_cast<int>(std::lround(height * aspect)));
            }
            output.format = VideoFrame::Format::Rgba;
            output.width = width;
            output.height = height;
            output.displayWidth = width;
            output.displayHeight = height;
            output.yPlane.clear();
            output.uPlane.clear();
            output.vPlane.clear();
            output.rgba.resize(static_cast<std::size_t>(width) * height * 4);
            const bool scalerChanged =
                !session.scaler || session.lastSwsSrcW != frame->width ||
                session.lastSwsSrcH != frame->height || session.lastSwsSrcFmt != frame->format ||
                session.lastSwsDstW != width || session.lastSwsDstH != height;
            session.scaler = sws_getCachedContext(
                session.scaler, frame->width, frame->height, static_cast<AVPixelFormat>(frame->format),
                width, height, AV_PIX_FMT_RGBA, SWS_BILINEAR, nullptr, nullptr, nullptr);
            if (!session.scaler) {
                throw std::runtime_error("Cannot initialize video conversion.");
            }
            const int space = frame->colorspace == AVCOL_SPC_BT709 ? SWS_CS_ITU709 :
                              frame->colorspace == AVCOL_SPC_BT2020_NCL ? SWS_CS_BT2020 : SWS_CS_ITU601;
            const int fullRange =
                (frame->color_range == AVCOL_RANGE_JPEG || frame->format == AV_PIX_FMT_YUVJ420P) ? 1 : 0;
            if (scalerChanged || session.lastSwsColorspace != space ||
                session.lastSwsColorRange != fullRange) {
                const int* coefficients = sws_getCoefficients(space);
                sws_setColorspaceDetails(session.scaler, coefficients, fullRange,
                                         coefficients, 1, 0, 1 << 16, 1 << 16);
                session.lastSwsColorspace = space;
                session.lastSwsColorRange = fullRange;
                session.lastSwsSrcW = frame->width;
                session.lastSwsSrcH = frame->height;
                session.lastSwsSrcFmt = frame->format;
                session.lastSwsDstW = width;
                session.lastSwsDstH = height;
            }
            std::uint8_t* destinations[] = {output.rgba.data(), nullptr, nullptr, nullptr};
            int strides[] = {width * 4, 0, 0, 0};
            const int rows = sws_scale(session.scaler, frame->data, frame->linesize, 0,
                                       frame->height, destinations, strides);
            if (rows != height) {
                throw std::runtime_error("Video conversion failed.");
            }
            statusWidth = width;
            statusHeight = height;
        }

        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [&] {
            return !isCurrentRun(run) || run.seekInterrupt.load() || frames.size() < kMaxFrames;
        });
        if (!isCurrentRun(run) || run.seekInterrupt.load()) {
            recycleFrameLocked(std::move(output));
            return false;
        }
        output.serial = serial;
        frames.push_back(std::move(output));
        snapshot.width = statusWidth;
        snapshot.height = statusHeight;
        startClockLocked(pts);
        noteDecodedProgressLocked(session);
        session.preview = false;
        return true;
    }

    void configureResampler(Session& session, const AVFrame* frame) {
        if (frame->sample_rate < 8000 || frame->sample_rate > 192000 ||
            frame->ch_layout.nb_channels <= 0 || frame->ch_layout.nb_channels > 16 ||
            frame->nb_samples < 0 || frame->nb_samples > 192000) {
            throw std::runtime_error("Unsupported audio format or frame size.");
        }
        if (session.resampler && session.resampleRate == frame->sample_rate &&
            session.resampleFormat == frame->format &&
            av_channel_layout_compare(&session.resampleLayout, &frame->ch_layout) == 0) {
            return;
        }
        swr_free(&session.resampler);
        av_channel_layout_uninit(&session.resampleLayout);
        AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
        AVChannelLayout input{};
        int result = av_channel_layout_copy(&input, &frame->ch_layout);
        if (result >= 0) {
            result = swr_alloc_set_opts2(&session.resampler, &stereo, AV_SAMPLE_FMT_S16,
                                        kAudioRate, &input, static_cast<AVSampleFormat>(frame->format),
                                        frame->sample_rate, 0, nullptr);
        }
        av_channel_layout_uninit(&input);
        if (result >= 0) {
            result = swr_init(session.resampler);
        }
        if (result < 0) {
            throw std::runtime_error("Cannot initialize audio conversion: " + avError(result));
        }
        if (av_channel_layout_copy(&session.resampleLayout, &frame->ch_layout) < 0) {
            throw std::runtime_error("Cannot retain the audio channel layout.");
        }
        session.resampleRate = frame->sample_rate;
        session.resampleFormat = frame->format;
    }

    bool outputAudio(Session& session, AVFrame* frame) {
        auto& run = *session.run;
        const double pts = frameTime(session, frame, session.audioIndex, true);
        if (frame->sample_rate <= 0) {
            throw std::runtime_error("Invalid audio sample rate.");
        }
        session.nextAudio = pts + static_cast<double>(frame->nb_samples) / frame->sample_rate;
        const bool probingAudioRecovery =
            !session.useAudioOutput && session.audioOutputStalled && sink &&
            Clock::now() >= session.audioRetryAt;
        if (!session.useAudioOutput && !probingAudioRecovery) {
            if (!session.video) {
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    if (!isCurrentRun(run)) return false;
                    noteDecodedProgressLocked(session);
                }
                paceAudioOnly(run, session.nextAudio);
            }
            return isCurrentRun(run) && !run.seekInterrupt.load() && !run.trackSwitchPending.load();
        }
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!isCurrentRun(run)) return false;
            if (paused && ((session.preview && session.video) || probingAudioRecovery)) {
                return true;
            }
        }
        configureResampler(session, frame);
        const auto capacity = av_rescale_rnd(
            swr_get_delay(session.resampler, frame->sample_rate) + frame->nb_samples,
            kAudioRate, frame->sample_rate, AV_ROUND_UP);
        if (capacity < 0 || capacity > kAudioRate * 2) {
            throw std::runtime_error("Audio conversion exceeds its buffer limit.");
        }
        const std::size_t needed = static_cast<std::size_t>(capacity) * 2;
        if (session.pcmBuffer.size() < needed) {
            session.pcmBuffer.resize(needed);
        }
        auto& pcm = session.pcmBuffer;
        std::uint8_t* destinations[] = {reinterpret_cast<std::uint8_t*>(pcm.data())};
        const int samples = swr_convert(session.resampler, destinations, static_cast<int>(capacity),
                                       const_cast<const std::uint8_t**>(frame->extended_data),
                                       frame->nb_samples);
        if (samples < 0) {
            throw std::runtime_error("Audio conversion failed: " + avError(samples));
        }
        std::size_t skip = 0;
        if (session.discardBefore > pts) {
            skip = std::min(static_cast<std::size_t>(samples), static_cast<std::size_t>(
                std::ceil((session.discardBefore - pts) * kAudioRate)));
        }
        const std::size_t count = static_cast<std::size_t>(samples) - skip;
        if (count == 0) {
            return true;
        }
        const float gain = volume.load(std::memory_order_relaxed);
        if (gain < 0.999F) {
            const std::int32_t scale = static_cast<std::int32_t>(std::lround(gain * 32768.0F));
            const std::size_t endIdx = static_cast<std::size_t>(samples) * 2;
            for (std::size_t sample = skip * 2; sample < endIdx; ++sample) {
                const std::int32_t scaled = (static_cast<std::int32_t>(pcm[sample]) * scale + 16384) >> 15;
                pcm[sample] = static_cast<std::int16_t>(std::clamp(scaled, -32768, 32767));
            }
        }
        if (probingAudioRecovery) {
            if (queuedAudio() + static_cast<double>(count) / kAudioRate <= kMaxAudioSeconds &&
                queueAudioForRun(run, pcm.data() + skip * 2, count)) {
                session.useAudioOutput = true;
                session.audioOutputStalled = false;
                std::lock_guard<std::mutex> lock(mutex);
                if (!isCurrentRun(run)) return false;
                if (snapshot.message == "Audio output stalled; continuing without audio.") {
                    snapshot.message.clear();
                }
                commitAudioClockLocked(session, pts, samples);
                return true;
            }
            session.audioRetryAt = Clock::now() + std::chrono::seconds(5);
            if (!session.video) {
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    if (!isCurrentRun(run)) return false;
                    noteDecodedProgressLocked(session);
                }
                paceAudioOnly(run, session.nextAudio);
            }
            return isCurrentRun(run) && !run.seekInterrupt.load() && !run.trackSwitchPending.load();
        }
        auto stalledSince = Clock::now();
        while (isCurrentRun(run) && !run.seekInterrupt.load() && !run.trackSwitchPending.load()) {
            const auto waitStarted = Clock::now();
            if (!waitActive(run, session.preview && session.video)) {
                return false;
            }
            stalledSince += Clock::now() - waitStarted;
            if (queuedAudio() + static_cast<double>(count) / kAudioRate <= kMaxAudioSeconds &&
                queueAudioForRun(run, pcm.data() + skip * 2, count)) {
                std::lock_guard<std::mutex> lock(mutex);
                if (!isCurrentRun(run)) return false;
                commitAudioClockLocked(session, pts, samples);
                return true;
            }
            std::unique_lock<std::mutex> lock(mutex);
            if (!isCurrentRun(run)) return false;
            if (paused) {
                stalledSince = Clock::now();
            } else if (Clock::now() - stalledSince > std::chrono::seconds(3)) {
                session.useAudioOutput = false;
                session.audioOutputStalled = true;
                session.audioRetryAt = Clock::now() + std::chrono::seconds(5);
                audioMaster = false;
                snapshot.message = "Audio output stalled; continuing without audio.";
                lock.unlock();
                clearSinkForRun(run);
                return true;
            }
            changed.wait_for(lock, std::chrono::milliseconds(10));
        }
        return false;
    }

    void paceAudioOnly(const RunControl& run, double until) {
        std::unique_lock<std::mutex> lock(mutex);
        if (!isCurrentRun(run)) return;
        startClockLocked(until);
        while (isCurrentRun(run) && !run.seekInterrupt.load() &&
               (paused || clockLocked() + kMaxAudioSeconds < until)) {
            changed.wait_for(lock, std::chrono::milliseconds(10));
        }
    }

    bool receiveFrames(Session& session, AVCodecContext* decoder, bool audio) {
        int& decodeErrors = audio ? session.audioDecodeErrors : session.videoDecodeErrors;
        const int limit = session.live ? 96 : 8;
        for (;;) {
            const int result = avcodec_receive_frame(decoder, session.decoded);
            if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
                return true;
            }
            if (result < 0) {
                if (++decodeErrors > limit) {
                    throw std::runtime_error("Repeated media decode failure: " + avError(result));
                }
                return true;
            }
            decodeErrors = 0;
            const bool keepGoing = audio ? outputAudio(session, session.decoded)
                                         : outputVideo(session, session.decoded);
            av_frame_unref(session.decoded);
            if (!keepGoing) {
                return false;
            }
        }
    }

    bool decodePacket(Session& session, AVCodecContext* decoder, bool audio, const AVPacket* packet) {
        int& decodeErrors = audio ? session.audioDecodeErrors : session.videoDecodeErrors;
        const int limit = session.live ? 96 : 8;
        int result = avcodec_send_packet(decoder, packet);
        if (result == AVERROR(EAGAIN)) {
            if (!receiveFrames(session, decoder, audio)) {
                return false;
            }
            result = avcodec_send_packet(decoder, packet);
        }
        if (result < 0 && result != AVERROR_EOF) {
            if (++decodeErrors > limit) {
                throw std::runtime_error("Repeated media decode failure: " + avError(result));
            }
            return true;
        }
        return receiveFrames(session, decoder, audio);
    }

    void decodeSubtitle(Session& session, AVPacket* packet) {
        auto& run = *session.run;
        AVSubtitle decoded{};
        int available = 0;
        const int result = avcodec_decode_subtitle2(session.subtitle, &decoded, &available, packet);
        if (result >= 0 && available) {
            const double raw = decoded.pts != AV_NOPTS_VALUE
                ? static_cast<double>(decoded.pts) / AV_TIME_BASE
                : packet->pts != AV_NOPTS_VALUE
                    ? packet->pts * av_q2d(session.timeBases[session.subtitleIndex])
                    : session.nextVideo + (std::isfinite(session.origin) ? session.origin : 0.0);
            const double start = raw - (std::isfinite(session.origin) ? session.origin : 0.0) +
                session.videoOffset + decoded.start_display_time / 1000.0;
            const double end = raw - (std::isfinite(session.origin) ? session.origin : 0.0) +
                session.videoOffset + decoded.end_display_time / 1000.0;
            std::string text;
            for (unsigned index = 0; index < decoded.num_rects; ++index) {
                const auto value = subtitleText(decoded.rects[index]);
                if (!value.empty()) {
                    if (!text.empty()) text += '\n';
                    text += value;
                }
                if (text.size() >= 2048) { text.resize(2048); break; }
            }
            if (!text.empty() && std::isfinite(start) && std::isfinite(end) && end > start) {
                std::lock_guard<std::mutex> lock(mutex);
                if (!isCurrentRun(run)) {
                    avsubtitle_free(&decoded);
                    return;
                }
                while (!cues.empty() && (cues.front().end < clockLocked() || cues.size() >= 256)) {
                    cues.pop_front();
                }
                cues.push_back({start, std::min(end, start + 120.0), std::move(text)});
            }
        }
        avsubtitle_free(&decoded);
    }

    double takeSeek(Session& session) {
        auto& run = *session.run;
        double target;
        int audio;
        int subtitle;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!isCurrentRun(run)) return kNoTime;
            target = seekTarget;
            audio = requestedAudio;
            subtitle = requestedSubtitle;
            seekTarget = kNoTime;
            requestedAudio = requestedSubtitle = -2;
            run.seekInterrupt.store(false);
            run.trackSwitchPending.store(false);
        }
        if (audio != -2 && audio != session.audioIndex) {
            auto* decoder = openDecoder(session.streamParameters[audio], session.timeBases[audio]);
            avcodec_free_context(&session.audio);
            session.audio = decoder;
            session.audioIndex = audio;
            session.activeAudioIndex.store(audio, std::memory_order_relaxed);
            session.useAudioOutput = static_cast<bool>(sink);
            session.audioOutputStalled = false;
            session.audioDecodeErrors = 0;
            if (!std::isfinite(target)) {
                swr_free(&session.resampler);
                session.lastRawAudio = kNoTime;
                clearSinkForRun(run);
            }
            std::lock_guard<std::mutex> lock(mutex);
            if (isCurrentRun(run)) {
                snapshot.audioTrack = audio;
                if (!std::isfinite(target)) {
                    audioMaster = false;
                    audioEnd = kNoTime;
                }
            }
        }
        if (subtitle != -2 && subtitle != session.subtitleIndex) {
            auto* decoder = subtitle >= 0
                ? openDecoder(session.streamParameters[subtitle], session.timeBases[subtitle])
                : nullptr;
            avcodec_free_context(&session.subtitle);
            session.subtitle = decoder;
            session.subtitleIndex = subtitle;
            {
                std::lock_guard<std::mutex> lock(mutex);
                if (isCurrentRun(run)) {
                    snapshot.subtitleTrack = subtitle;
                    cues.clear();
                }
            }
            // Replay recently demuxed packets for the newly selected subtitle stream so active
            // cues appear instantly without flushing video/audio decoders or seeking!
            if (session.subtitle) {
                for (const auto& cached : session.recentSubtitlePackets) {
                    if (cached.packet && cached.packet->stream_index == session.subtitleIndex) {
                        decodeSubtitle(session, cached.packet);
                    }
                }
            }
        }
        return target;
    }

    void resetDecoders(Session& session, double target) {
        auto& run = *session.run;
        if (session.video) avcodec_flush_buffers(session.video);
        if (session.audio) avcodec_flush_buffers(session.audio);
        if (session.subtitle) avcodec_flush_buffers(session.subtitle);
        session.recentSubtitlePackets.clear();
        swr_free(&session.resampler);
        session.lastRawAudio = kNoTime;
        session.lastRawVideo = kNoTime;
        session.nextAudio = target;
        session.nextVideo = target;
        session.discardBefore = target;
        session.preview = true;
        session.videoDecodeErrors = 0;
        session.audioDecodeErrors = 0;
        session.lastProgressAt = Clock::now();
        resetOutput(run, target);
        std::lock_guard<std::mutex> lock(mutex);
        if (!isCurrentRun(run)) return;
        snapshot.state = paused ? State::Paused : State::Buffering;
        snapshot.message = "Seeking...";
        snapshot.rewindMessage.clear();
    }

    bool livePlaybackStalled(Session& session) {
        auto& run = *session.run;
        if (!session.live || run.seekInterrupt.load()) {
            return false;
        }
        bool isPaused = false;
        {
            std::lock_guard<std::mutex> lock(mutex);
            isPaused = paused;
        }
        if (isPaused) {
            session.lastProgressAt = Clock::now();
            return false;
        }
        return Clock::now() - session.lastProgressAt > kFreezeTimeout;
    }

    void processSeek(Session& session) {
        auto& run = *session.run;
        const double target = takeSeek(session);
        if (!std::isfinite(target)) {
            return;
        }
        const double absolute = target + (std::isfinite(session.origin) ? session.origin : 0.0);
        if (session.format->pb) {
            session.format->pb->error = 0;
            session.format->pb->eof_reached = 0;
        }
        run.beginIo();
        const int result = avformat_seek_file(session.format, -1, INT64_MIN,
            static_cast<std::int64_t>(absolute * AV_TIME_BASE), INT64_MAX, AVSEEK_FLAG_BACKWARD);
        run.endIo();
        if (result < 0) {
            std::lock_guard<std::mutex> lock(mutex);
            if (isCurrentRun(run)) {
                snapshot.message = "This source does not support seeking: " + avError(result);
            }
            return;
        }
        session.setOffsets(0.0);
        resetDecoders(session, target);
    }

    bool consumePacket(Session& session) {
        if (session.packet->stream_index == session.videoIndex) {
            return decodePacket(session, session.video, false, session.packet);
        }
        if (session.packet->stream_index == session.audioIndex) {
            return decodePacket(session, session.audio, true, session.packet);
        }
        if (session.textSubtitleStreams.count(session.packet->stream_index) != 0) {
            if (session.packet->size >= 0 && session.packet->size <= kMaxCachedSubPacketBytes) {
                while (session.recentSubtitlePackets.size() >= kMaxRecentSubPackets) {
                    session.recentSubtitlePackets.pop_front();
                }
                session.recentSubtitlePackets.emplace_back(session.packet);
            }
            if (session.subtitle && session.packet->stream_index == session.subtitleIndex) {
                decodeSubtitle(session, session.packet);
            }
        }
        return true;
    }

    int playDirectSession(Session& session) {
        auto& run = *session.run;
        session.lastProgressAt = Clock::now();
        for (;;) {
            if (!isCurrentRun(run)) {
                return AVERROR_EXIT;
            }
            if (run.seekInterrupt.load() || run.trackSwitchPending.load()) {
                processSeek(session);
            }
            const auto beforeWait = Clock::now();
            if (!waitActive(run, session.preview)) {
                continue;
            }
            if (Clock::now() - beforeWait > std::chrono::milliseconds(50)) {
                session.lastProgressAt = Clock::now();
            }
            run.beginIo();
            const int result = av_read_frame(session.format, session.packet);
            run.endIo();
            if (!isCurrentRun(run)) {
                return AVERROR_EXIT;
            }
            if (run.seekInterrupt.load()) {
                av_packet_unref(session.packet);
                continue;
            }
            if (result < 0) {
                return result;
            }
            if (session.packet->size > 64 * 1024 * 1024) {
                av_packet_unref(session.packet);
                throw std::runtime_error("Media packet exceeds the supported size limit.");
            }
            const bool keepGoing = consumePacket(session);
            av_packet_unref(session.packet);
            if (!keepGoing && !isCurrentRun(run)) {
                return AVERROR_EXIT;
            }
            if (livePlaybackStalled(session)) {
                throw std::runtime_error("Live playback stalled without decoded frames.");
            }
        }
    }

    int playLiveSession(Session& session) {
        auto& run = *session.run;
        std::unique_ptr<PacketSpool> spool;
        try {
            spool = std::make_unique<PacketSpool>();
        } catch (const std::exception&) {
            throw RewindUnavailable("Temporary live rewind storage is unavailable.");
        }
        const double initialOrigin = session.origin;
        const double initialOffset = session.videoOffset;
        session.origin = 0.0;
        session.setOffsets(0.0);
        session.lastProgressAt = Clock::now();
        run.capturingLive.store(true);
        run.captureStopping.store(false);
        int captureResult = AVERROR_EOF;
        bool storageFailed = false;
        struct Capture {
            Impl& owner;
            RunControl& run;
            Session& session;
            double origin;
            double offset;
            std::thread thread;
            void stop() {
                run.captureStopping.store(true);
                owner.changed.notify_all();
                if (thread.joinable()) thread.join();
                run.capturingLive.store(false);
                run.captureStopping.store(false);
                session.origin = origin;
                session.setOffsets(offset);
            }
            ~Capture() { stop(); }
        } capture{*this, run, session, initialOrigin, initialOffset, {}};
        capture.thread = std::thread([&] {
            AVPacket* packet = av_packet_alloc();
            double origin = initialOrigin;
            double timeline = initialOffset;
            std::vector<double> previous(session.timeBases.size(), kNoTime);
            std::vector<double> streamOffsets(session.timeBases.size(), initialOffset);
            auto waitingForKeyframe = Clock::now();
            auto lastSnapshotUpdate = Clock::time_point{};
            bool hadRecordedBytes = false;
            try {
                if (!packet) throw RewindUnavailable("Cannot allocate the live recorder buffer.");
                while (isCurrentRun(run) && !run.captureStopping.load()) {
                    run.beginIo();
                    captureResult = av_read_frame(session.format, packet);
                    run.endIo();
                    if (captureResult < 0) break;
                    if (packet->size > 64 * 1024 * 1024) {
                        throw RewindUnavailable("A live packet exceeds the recording limit.");
                    }
                    if (packet->stream_index < 0 || static_cast<std::size_t>(packet->stream_index) >= session.timeBases.size()) {
                        av_packet_unref(packet);
                        continue;
                    }
                    const std::size_t streamIndex = static_cast<std::size_t>(packet->stream_index);
                    const auto timebase = session.timeBases[streamIndex];
                    if (timebase.num <= 0 || timebase.den <= 0) {
                        throw RewindUnavailable("The live source has invalid media timing.");
                    }
                    const bool activeStream =
                        packet->stream_index == session.videoIndex ||
                        packet->stream_index == session.activeAudioIndex.load(std::memory_order_relaxed);
                    const auto stamp = packet->dts != AV_NOPTS_VALUE ? packet->dts : packet->pts;
                    if (stamp != AV_NOPTS_VALUE) {
                        const double raw = stamp * av_q2d(timebase);
                        if (activeStream && !std::isfinite(origin)) origin = raw;
                        if (std::isfinite(origin)) {
                            auto& last = previous[streamIndex];
                            auto& streamOffset = streamOffsets[streamIndex];
                            if (activeStream) {
                                if (std::isfinite(last)) {
                                    if (raw - last > 30.0 || raw - last < -3.0) {
                                        streamOffset = timeline - (raw - origin);
                                    }
                                } else {
                                    const double candidate = raw - origin + streamOffset;
                                    if (candidate > timeline + 30.0 || candidate < timeline - 30.0) {
                                        streamOffset = timeline - (raw - origin);
                                    }
                                }
                                last = raw;
                                timeline = std::max(timeline, raw - origin + streamOffset);
                            } else {
                                const double candidate = raw - origin + streamOffset;
                                if (candidate > timeline + 30.0 || candidate < timeline - 30.0) {
                                    streamOffset = timeline - (raw - origin);
                                }
                                last = raw;
                            }
                        }
                    }
                    const double packetOffset = streamOffsets[streamIndex];
                    const auto retime = [&](std::int64_t value) {
                        if (value == AV_NOPTS_VALUE) return value;
                        const long double adjusted = std::round(
                            (static_cast<long double>(value) * timebase.num / timebase.den -
                             (std::isfinite(origin) ? origin : 0.0) + packetOffset) * timebase.den / timebase.num);
                        if (!std::isfinite(adjusted) || adjusted <= std::numeric_limits<std::int64_t>::min() ||
                            adjusted > std::numeric_limits<std::int64_t>::max()) {
                            throw RewindUnavailable("The live source has invalid media timing.");
                        }
                        return static_cast<std::int64_t>(adjusted);
                    };
                    const std::int64_t origPts = packet->pts;
                    const std::int64_t origDts = packet->dts;
                    packet->dts = retime(origDts);
                    if (origPts != AV_NOPTS_VALUE && origDts != AV_NOPTS_VALUE &&
                        std::abs((static_cast<double>(origPts) - static_cast<double>(origDts)) * av_q2d(timebase)) > 30.0) {
                        packet->pts = AV_NOPTS_VALUE;
                    } else {
                        packet->pts = retime(origPts);
                    }
                    const bool keyframe = session.videoIndex < 0 ||
                        (packet->stream_index == session.videoIndex && (packet->flags & AV_PKT_FLAG_KEY));
                    if (!spool->append(packet, timeline, keyframe)) {
                        throw RewindUnavailable("The live recorder cannot retain a complete video keyframe group within its storage limit.");
                    }
                    av_packet_unref(packet);

                    // Throttle snapshot updates to keyframes, first recorded packet, or every 250 ms.
                    const auto now = Clock::now();
                    if (!hadRecordedBytes || keyframe || now - lastSnapshotUpdate >= kSnapshotThrottle) {
                        lastSnapshotUpdate = now;
                        const auto saved = spool->snapshot();
                        if (saved.bytes > 0) {
                            hadRecordedBytes = true;
                            waitingForKeyframe = now;
                        } else if (now - waitingForKeyframe > std::chrono::seconds(12)) {
                            throw RewindUnavailable("The live source does not provide recordable keyframes.");
                        }
                        {
                            std::lock_guard<std::mutex> lock(mutex);
                            if (isCurrentRun(run)) {
                                snapshot.liveRewind = saved.bytes > 0;
                                snapshot.windowStartSeconds = saved.startSeconds;
                                snapshot.windowEndSeconds = saved.endSeconds;
                                snapshot.recordedBytes = saved.bytes;
                                static constexpr const char* kFilling =
                                    "Waiting for a video keyframe to resume live recording.";
                                if (saved.bytes == 0) snapshot.rewindMessage = kFilling;
                                else if (snapshot.rewindMessage == kFilling) snapshot.rewindMessage.clear();
                            }
                        }
                    }
                    if (run.waitingForSpool.exchange(false, std::memory_order_acq_rel)) {
                        changed.notify_one();
                    }
                }
            } catch (const std::exception&) {
                storageFailed = true;
            }
            av_packet_free(&packet);
            run.endIo();
            spool->close();
            changed.notify_all();
        });
        std::uint64_t cursor = 0;
        for (;;) {
            if (!isCurrentRun(run)) return AVERROR_EXIT;
            if (run.seekInterrupt.load() || run.trackSwitchPending.load()) {
                const double target = takeSeek(session);
                if (std::isfinite(target)) {
                    cursor = spool->seek(target);
                    resetDecoders(session, target);
                }
            }
            const auto beforeWait = Clock::now();
            if (!waitActive(run, session.preview)) continue;
            if (Clock::now() - beforeWait > std::chrono::milliseconds(50)) {
                session.lastProgressAt = Clock::now();
            }
            PacketSpool::ReadResult result;
            try {
                result = spool->read(cursor, session.packet);
            } catch (const std::exception&) {
                throw RewindUnavailable("Cannot read temporary live rewind storage.");
            }
            if (result == PacketSpool::ReadResult::Expired) {
                const auto saved = spool->snapshot();
                resetDecoders(session, saved.startSeconds);
                std::lock_guard<std::mutex> lock(mutex);
                if (isCurrentRun(run)) {
                    snapshot.rewindMessage = "Your pause exceeded the saved window. Playback moved to the earliest saved point.";
                }
                continue;
            }
            if (result == PacketSpool::ReadResult::Waiting) {
                if (livePlaybackStalled(session)) {
                    capture.stop();
                    throw std::runtime_error("Live playback stalled without decoded frames.");
                }
                std::unique_lock<std::mutex> lock(mutex);
                run.waitingForSpool.store(true, std::memory_order_release);
                changed.wait_for(lock, std::chrono::milliseconds(10));
                run.waitingForSpool.store(false, std::memory_order_relaxed);
                continue;
            }
            if (result == PacketSpool::ReadResult::Finished) {
                capture.stop();
                if (storageFailed) throw RewindUnavailable("Live rewind stopped because temporary storage is unavailable or the stream exceeds its limit.");
                return captureResult;
            }
            consumePacket(session);
            av_packet_unref(session.packet);
            if (livePlaybackStalled(session)) {
                capture.stop();
                throw std::runtime_error("Live playback stalled without decoded frames.");
            }
        }
    }

    int playSession(Session& session) {
        auto& run = *session.run;
        if (!session.live) return playDirectSession(session);
        try {
            return playLiveSession(session);
        } catch (const RewindUnavailable& error) {
            double current;
            {
                std::lock_guard<std::mutex> lock(mutex);
                if (!isCurrentRun(run)) return AVERROR_EXIT;
                current = std::max(clockLocked(), snapshot.windowEndSeconds);
            }
            resetDecoders(session, current);
            const auto timing = prepareDirectFallbackTiming(current);
            session.origin = timing.origin;
            session.setOffsets(timing.offset);
            session.discardBefore = timing.discardBefore;
            if (session.format->pb) {
                session.format->pb->error = 0;
                session.format->pb->eof_reached = 0;
            }
            {
                std::lock_guard<std::mutex> lock(mutex);
                if (isCurrentRun(run)) {
                    snapshot.liveRewind = false;
                    snapshot.recordedBytes = 0;
                    snapshot.windowStartSeconds = snapshot.windowEndSeconds = 0.0;
                    snapshot.rewindMessage = std::string(error.what()) + " Continuing with direct playback.";
                }
            }
            return playDirectSession(session);
        }
    }

    void finishPlayback(Session& session) {
        auto& run = *session.run;
        if (session.video && !decodePacket(session, session.video, false, nullptr)) {
            return;
        }
        if (session.audio && !decodePacket(session, session.audio, true, nullptr)) {
            return;
        }
        std::unique_lock<std::mutex> lock(mutex);
        while (isCurrentRun(run) && !run.seekInterrupt.load() &&
               (!frames.empty() || (session.useAudioOutput && queuedAudio() > 0.025))) {
            changed.wait_for(lock, std::chrono::milliseconds(10));
        }
        if (isCurrentRun(run) && !run.seekInterrupt.load()) {
            clockBase = clockLocked();
            lastClock = clockBase;
            clockStarted = false;
            snapshot.state = State::Ended;
            snapshot.message = "Playback finished.";
        }
    }

    void runWorker(std::shared_ptr<RunControl> run, std::string url, bool live,
                   RequestOptions request, double startSeconds) {
        const std::string primaryUrl = url;
        const auto alternateUrl = live ? alternateXtreamLiveUrl(primaryUrl) : std::nullopt;
        std::string activeUrl = primaryUrl;
        if (live && alternateUrl) {
            std::lock_guard<std::mutex> lock(mutex);
            if (const auto cached = workingFormatCache.lookup(primaryUrl)) {
                if (*cached == primaryUrl || *cached == *alternateUrl) {
                    activeUrl = *cached;
                }
            }
        }
        int failures = 0;
        int failuresOnActive = 0;
        bool everOpened = false;
        double resumePosition = (!live && std::isfinite(startSeconds) && startSeconds > 0.0)
            ? startSeconds : 0.0;
        std::mt19937 rng(static_cast<std::uint32_t>(
            Clock::now().time_since_epoch().count() ^ 0x9e3779b9U));
        std::uniform_real_distribution<double> jitterDist(0.0, 1.0);
        try {
            if (sink) {
                clearSinkForRun(*run);
                std::lock_guard<std::mutex> lock(mutex);
                if (isCurrentRun(*run)) {
                    std::lock_guard<std::mutex> sinkLock(sinkMutex);
                    if (activeRunId.load(std::memory_order_acquire) == run->id) {
                        sink->setPaused(paused);
                    }
                }
            }
            while (isCurrentRun(*run)) {
                int result = AVERROR_UNKNOWN;
                std::string failure;
                bool sessionHadFirstFrame = false;
                double healthySeconds = 0.0;
                {
                    Session session;
                    session.run = run;
                    try {
                        if (openSource(session, activeUrl, live, live || everOpened, resumePosition, request)) {
                            everOpened = true;
                            result = playSession(session);
                            if (isCurrentRun(*run)) {
                                if (result == AVERROR_EOF && !live) {
                                    finishPlayback(session);
                                    while (isCurrentRun(*run)) {
                                        std::unique_lock<std::mutex> lock(mutex);
                                        changed.wait(lock, [&] {
                                            return !isCurrentRun(*run) || run->seekInterrupt.load();
                                        });
                                        if (!isCurrentRun(*run)) {
                                            break;
                                        }
                                        lock.unlock();
                                        processSeek(session);
                                        result = playSession(session);
                                        if (result == AVERROR_EOF) {
                                            finishPlayback(session);
                                        } else {
                                            break;
                                        }
                                    }
                                }
                                if (isCurrentRun(*run)) {
                                    failure = result == AVERROR_EOF
                                        ? "The live source closed its connection."
                                        : "Source read failed: " + avError(result);
                                }
                            }
                        }
                    } catch (const std::exception& error) {
                        failure = error.what();
                    }
                    sessionHadFirstFrame = session.hasFirstFrame;
                    healthySeconds = session.hasFirstFrame ? session.activePlayingSeconds : 0.0;
                }
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    if (live && alternateUrl && sessionHadFirstFrame && healthySeconds >= 10.0) {
                        workingFormatCache.remember(primaryUrl, activeUrl);
                    }
                    if (isCurrentRun(*run)) {
                        sourceOpened = false;
                        snapshot.liveRewind = false;
                        snapshot.recordedBytes = 0;
                        snapshot.windowStartSeconds = snapshot.windowEndSeconds = 0.0;
                    }
                }
                if (!isCurrentRun(*run)) {
                    break;
                }
                const auto decision = ReconnectPolicy::evaluate(
                    live, request.local, sessionHadFirstFrame, everOpened, healthySeconds,
                    alternateUrl.has_value(), failures, failuresOnActive, jitterDist(rng));
                if (!decision.shouldRetry) {
                    throw std::runtime_error(failure);
                }
                failures = decision.failures;
                failuresOnActive = decision.failuresOnActiveFormat;
                if (decision.switchFormat && alternateUrl) {
                    activeUrl = (activeUrl == primaryUrl) ? *alternateUrl : primaryUrl;
                }
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    if (!isCurrentRun(*run)) break;
                    resumePosition = clockLocked();
                    snapshot.state = paused ? State::Paused : State::Buffering;
                    snapshot.message = "Reconnecting (" + std::to_string(failures) + "/" +
                        std::to_string(decision.maxFailures) + ")...";
                }
                resetOutput(*run, resumePosition);
                std::unique_lock<std::mutex> lock(mutex);
                changed.wait_for(lock, std::chrono::milliseconds(decision.backoffMs),
                                 [&] { return !isCurrentRun(*run); });
            }
        } catch (const std::exception& error) {
            std::lock_guard<std::mutex> lock(mutex);
            if (isCurrentRun(*run)) {
                clockBase = clockLocked();
                clockStarted = false;
                sourceOpened = false;
                snapshot.state = State::Error;
                snapshot.message = error.what();
            }
        } catch (...) {
            std::lock_guard<std::mutex> lock(mutex);
            if (isCurrentRun(*run)) {
                snapshot.state = State::Error;
                snapshot.message = "Unexpected media playback failure.";
                clockStarted = false;
                sourceOpened = false;
            }
        }
        run->endIo();
        clearSinkForRun(*run);
        changed.notify_all();
    }

    void stopLocked() {
        // Signal the current run to abort immediately and retire its worker thread
        // asynchronously to the background reaper so the UI thread never freezes.
        if (activeRun) {
            activeRun->stopping.store(true, std::memory_order_release);
            activeRun->captureStopping.store(true, std::memory_order_release);
            activeRun->deadline.store(1, std::memory_order_relaxed);
        }
        activeRunId.fetch_add(1, std::memory_order_acq_rel);
        changed.notify_all();
        if (worker.joinable()) {
            std::lock_guard<std::mutex> rlock(reaperMutex);
            retiredWorkers.push_back(std::move(worker));
            reaperCv.notify_one();
        }
        activeRun.reset();
        if (sink) {
            std::lock_guard<std::mutex> slock(sinkMutex);
            sink->clear();
        }
        std::lock_guard<std::mutex> lock(mutex);
        while (!frames.empty()) {
            recycleFrameLocked(std::move(frames.front()));
            frames.pop_front();
        }
        cues.clear();
        snapshot = {};
        snapshot.volume = volume.load();
        paused = false;
        sourceOpened = false;
        clockStarted = false;
        audioMaster = false;
        audioEnd = kNoTime;
        clockBase = 0.0;
        lastClock = 0.0;
        seekTarget = kNoTime;
        requestedAudio = requestedSubtitle = -2;
        isLive.store(false);
        ++serial;
    }
};

Player::Player(std::shared_ptr<AudioSink> audioSink)
    : impl_(std::make_unique<Impl>(std::move(audioSink))) {}

Player::~Player() = default;

void Player::open(const std::string& url, bool live,
                  const std::unordered_map<std::string, std::string>& requestHeaders,
                  double startSeconds) {
    std::lock_guard<std::mutex> lifecycle(impl_->lifecycle);
    impl_->stopLocked();
    RequestOptions request;
    std::shared_ptr<RunControl> run;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->isLive.store(live);
        impl_->snapshot.live = live;
        impl_->sourceOpened = false;
        if (url.empty() || url.size() > 8192 || url.find('\0') != std::string::npos) {
            impl_->snapshot.state = State::Error;
            impl_->snapshot.message = "The source address is empty or invalid.";
            return;
        }
        try {
            request = requestOptions(url, requestHeaders);
        } catch (const std::exception& error) {
            impl_->snapshot.state = State::Error;
            impl_->snapshot.message = error.what();
            return;
        }
        run = std::make_shared<RunControl>();
        run->id = impl_->activeRunId.fetch_add(1, std::memory_order_acq_rel) + 1;
        impl_->activeRun = run;
        impl_->snapshot.state = State::Opening;
        impl_->snapshot.message = "Opening source...";
    }
    impl_->worker = std::thread([this, run, url, live, request, startSeconds] {
        impl_->runWorker(run, url, live, request, startSeconds);
    });
}

void Player::stop() {
    std::lock_guard<std::mutex> lifecycle(impl_->lifecycle);
    impl_->stopLocked();
}

void Player::setPaused(bool paused) {
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (impl_->paused == paused || impl_->snapshot.state == State::Idle ||
            impl_->snapshot.state == State::Error || impl_->snapshot.state == State::Ended) {
            return;
        }
        impl_->clockBase = impl_->clockLocked();
        impl_->lastClock = impl_->clockBase;
        impl_->clockAnchor = Clock::now();
        impl_->paused = paused;
        ++impl_->pauseEpoch;
        if (paused) {
            if (impl_->snapshot.state != State::Opening) {
                impl_->snapshot.state = State::Paused;
            }
        } else if (impl_->snapshot.state == State::Paused) {
            impl_->snapshot.state = !impl_->sourceOpened
                ? State::Opening
                : (impl_->clockStarted ? State::Playing : State::Buffering);
        }
        if (impl_->sink) {
            std::lock_guard<std::mutex> slock(impl_->sinkMutex);
            impl_->sink->setPaused(paused);
        }
    }
    impl_->changed.notify_all();
}

void Player::togglePause() {
    bool paused;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        paused = impl_->paused;
    }
    setPaused(!paused);
}

void Player::seekRelative(double seconds) {
    if (!std::isfinite(seconds)) {
        return;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->snapshot.state == State::Idle || impl_->snapshot.state == State::Error ||
        impl_->snapshot.state == State::Opening || !impl_->activeRun) {
        return;
    }
    if (impl_->snapshot.live) {
        if (!impl_->snapshot.liveRewind) {
            impl_->snapshot.message = "Live rewind is unavailable for this source.";
            return;
        }
        impl_->seekTarget = std::clamp(impl_->clockLocked() + seconds,
            impl_->snapshot.windowStartSeconds, impl_->snapshot.windowEndSeconds);
    } else {
        const double upper = impl_->snapshot.durationSeconds > 0.0
            ? std::max(0.0, impl_->snapshot.durationSeconds - 0.1)
            : std::numeric_limits<double>::max();
        impl_->seekTarget = std::clamp(impl_->clockLocked() + seconds, 0.0, upper);
    }
    impl_->activeRun->seekInterrupt.store(true);
    impl_->changed.notify_all();
}

void Player::goLive() {
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (!impl_->snapshot.live || !impl_->snapshot.liveRewind || !impl_->activeRun ||
            impl_->snapshot.state == State::Error || impl_->snapshot.state == State::Idle) return;
        impl_->seekTarget = std::max(impl_->snapshot.windowStartSeconds,
            impl_->snapshot.windowEndSeconds - 0.5);
        impl_->clockBase = impl_->clockLocked();
        impl_->lastClock = impl_->clockBase;
        impl_->clockAnchor = Clock::now();
        if (impl_->paused) {
            impl_->paused = false;
            ++impl_->pauseEpoch;
        }
        if (impl_->sink) {
            std::lock_guard<std::mutex> slock(impl_->sinkMutex);
            impl_->sink->setPaused(false);
        }
        impl_->activeRun->seekInterrupt.store(true);
    }
    impl_->changed.notify_all();
}

void Player::cycleAudioTrack() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const auto& tracks = impl_->snapshot.audioTracks;
    if (tracks.size() < 2 || !impl_->activeRun || impl_->snapshot.state == State::Opening ||
        impl_->snapshot.state == State::Error || impl_->snapshot.state == State::Idle) return;
    const int current = impl_->requestedAudio == -2 ? impl_->snapshot.audioTrack : impl_->requestedAudio;
    auto selected = std::find_if(tracks.begin(), tracks.end(), [current](const Track& track) { return track.id == current; });
    if (selected == tracks.end() || ++selected == tracks.end()) selected = tracks.begin();
    impl_->requestedAudio = selected->id;
    if (!impl_->snapshot.live || impl_->snapshot.liveRewind) {
        impl_->seekTarget = impl_->clockLocked();
        impl_->activeRun->seekInterrupt.store(true);
    } else {
        impl_->activeRun->trackSwitchPending.store(true);
    }
    impl_->changed.notify_all();
}

void Player::cycleSubtitleTrack() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const auto& tracks = impl_->snapshot.subtitleTracks;
    if (tracks.empty() || !impl_->activeRun || impl_->snapshot.state == State::Opening ||
        impl_->snapshot.state == State::Error || impl_->snapshot.state == State::Idle) return;
    const int current = impl_->requestedSubtitle == -2 ? impl_->snapshot.subtitleTrack : impl_->requestedSubtitle;
    auto selected = std::find_if(tracks.begin(), tracks.end(), [current](const Track& track) { return track.id == current; });
    if (selected == tracks.end()) impl_->requestedSubtitle = tracks.front().id;
    else impl_->requestedSubtitle = ++selected == tracks.end() ? -1 : selected->id;
    // Switch subtitle decoder seamlessly without flushing video/audio decoders or seeking.
    impl_->activeRun->trackSwitchPending.store(true);
    impl_->changed.notify_all();
}

void Player::setVolume(float volume) {
    if (std::isfinite(volume)) {
        impl_->volume.store(std::clamp(volume, 0.0F, 1.0F));
    }
}

void Player::setPreferYuv(bool preferYuv) {
    impl_->preferYuv.store(preferYuv, std::memory_order_relaxed);
}

void Player::clearFormatCache() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->workingFormatCache.clear();
}

Player::Status Player::status() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    Status status = impl_->snapshot;
    status.currentSeconds = impl_->clockLocked();
    status.volume = impl_->volume.load();
    for (const auto& cue : impl_->cues) {
        if (cue.start <= status.currentSeconds && status.currentSeconds < cue.end) {
            if (!status.subtitleText.empty()) status.subtitleText += '\n';
            status.subtitleText += cue.text;
        }
    }
    return status;
}

bool Player::takeFrame(VideoFrame& frame) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->frames.empty()) {
        return false;
    }
    const double position = impl_->clockLocked();
    const double tolerance = impl_->paused ? 0.08 : 0.015;
    if (impl_->frames.front().ptsSeconds > position + tolerance) {
        return false;
    }
    while (impl_->frames.size() > 1 &&
           impl_->frames[1].ptsSeconds <= position + tolerance) {
        impl_->recycleFrameLocked(std::move(impl_->frames.front()));
        impl_->frames.pop_front();
        ++impl_->snapshot.droppedFrames;
    }
    // Recycle caller's previously rendered buffers into the decoder frame pool.
    impl_->recycleFrameLocked(std::move(frame));
    frame = std::move(impl_->frames.front());
    impl_->frames.pop_front();
    impl_->changed.notify_one();
    return true;
}

void Player::recycleFrame(VideoFrame&& frame) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->recycleFrameLocked(std::move(frame));
}

} // namespace brutv
