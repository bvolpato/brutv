#include "brutv/player.hpp"

extern "C" {
#include <libavcodec/avcodec.h>
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
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdarg>
#include <deque>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <utility>

namespace brutv {
namespace {

using Clock = std::chrono::steady_clock;
constexpr int kAudioRate = 48000;
constexpr int kMaxWidth = 1280;
constexpr int kMaxHeight = 720;
constexpr std::size_t kMaxFrames = 6;
constexpr double kMaxAudioSeconds = 0.5;
constexpr auto kIoTimeout = std::chrono::seconds(15);
constexpr double kNoTime = std::numeric_limits<double>::quiet_NaN();

struct RequestOptions {
    std::string userAgent;
    std::string referer;
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

RequestOptions requestOptions(const std::string& url,
                             const std::unordered_map<std::string, std::string>& headers) {
    RequestOptions options;
    const std::string lowerUrl = asciiLower(url);
    options.local = lowerUrl.compare(0, 7, "http://") != 0 &&
                    lowerUrl.compare(0, 8, "https://") != 0;
    std::size_t size = 0;
    bool hasUserAgent = false;
    bool hasReferer = false;
    for (const auto& header : headers) {
        size += header.first.size() + header.second.size() + 4;
        if (size > 8192 || header.second.size() > 4096 ||
            std::any_of(header.first.begin(), header.first.end(), [](unsigned char c) {
                return c <= 0x20 || c >= 0x7F;
            }) ||
            std::any_of(header.second.begin(), header.second.end(), [](unsigned char c) {
                return c < 0x20 || c == 0x7F;
            })) {
            throw std::runtime_error("The source request headers are invalid or too large.");
        }
        const std::string name = asciiLower(header.first);
        if (name == "user-agent" && !hasUserAgent) {
            options.userAgent = header.second;
            hasUserAgent = true;
        } else if (name == "referer" && !hasReferer) {
            options.referer = header.second;
            hasReferer = true;
        } else {
            throw std::runtime_error("Only one User-Agent and one Referer source header are supported.");
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

struct Session {
    AVFormatContext* format = nullptr;
    AVCodecContext* video = nullptr;
    AVCodecContext* audio = nullptr;
    AVPacket* packet = nullptr;
    AVFrame* decoded = nullptr;
    SwsContext* scaler = nullptr;
    SwrContext* resampler = nullptr;
    AVChannelLayout resampleLayout{};
    int resampleRate = 0;
    int resampleFormat = -1;
    int videoIndex = -1;
    int audioIndex = -1;
    double origin = kNoTime;
    double offset = 0.0;
    double lastRawVideo = kNoTime;
    double lastRawAudio = kNoTime;
    double nextVideo = 0.0;
    double nextAudio = 0.0;
    double discardBefore = -1.0;
    bool preview = true;
    bool useAudioOutput = false;
    int decodeErrors = 0;

    ~Session() {
        sws_freeContext(scaler);
        swr_free(&resampler);
        av_channel_layout_uninit(&resampleLayout);
        av_frame_free(&decoded);
        av_packet_free(&packet);
        avcodec_free_context(&video);
        avcodec_free_context(&audio);
        avformat_close_input(&format);
    }
};

AVCodecContext* openDecoder(AVFormatContext* format, int index) {
    const AVCodec* codec = avcodec_find_decoder(format->streams[index]->codecpar->codec_id);
    if (!codec) {
        throw std::runtime_error("This source uses an unsupported codec.");
    }
    AVCodecContext* context = avcodec_alloc_context3(codec);
    if (!context) {
        throw std::runtime_error("Cannot allocate a media decoder.");
    }
    int result = avcodec_parameters_to_context(context, format->streams[index]->codecpar);
    if (result >= 0) {
        context->thread_count = 2;
        context->max_pixels = 3840LL * 2160LL;
        context->pkt_timebase = format->streams[index]->time_base;
        result = avcodec_open2(context, codec, nullptr);
    }
    if (result < 0) {
        avcodec_free_context(&context);
        throw std::runtime_error("Cannot initialize a media decoder: " + avError(result));
    }
    return context;
}

} // namespace

struct Player::Impl {
    explicit Impl(std::shared_ptr<AudioSink> output) : sink(std::move(output)) {
        initializeFfmpeg();
    }

    std::shared_ptr<AudioSink> sink;
    mutable std::mutex mutex;
    std::mutex lifecycle;
    std::condition_variable changed;
    std::thread worker;
    std::atomic<bool> stopping{false};
    std::atomic<bool> seekInterrupt{false};
    std::atomic<std::int64_t> deadline{0};
    std::atomic<float> volume{1.0F};
    Status snapshot;
    std::deque<VideoFrame> frames;
    bool paused = false;
    bool clockStarted = false;
    bool audioMaster = false;
    double clockBase = 0.0;
    mutable double lastClock = 0.0;
    double audioEnd = kNoTime;
    Clock::time_point clockAnchor = Clock::now();
    double seekTarget = kNoTime;
    std::uint64_t serial = 0;

    static int interrupt(void* opaque) {
        auto* self = static_cast<Impl*>(opaque);
        const auto limit = self->deadline.load(std::memory_order_relaxed);
        return self->stopping.load(std::memory_order_relaxed) ||
               self->seekInterrupt.load(std::memory_order_relaxed) ||
               (limit != 0 && monotonicNanoseconds() >= limit);
    }

    void beginIo() {
        deadline.store(monotonicNanoseconds() +
                           std::chrono::duration_cast<std::chrono::nanoseconds>(kIoTimeout).count(),
                       std::memory_order_relaxed);
    }

    void endIo() {
        deadline.store(0, std::memory_order_relaxed);
    }

    double queuedAudio() const {
        if (!sink) {
            return 0.0;
        }
        const double queued = sink->queuedSeconds();
        return std::isfinite(queued) ? std::clamp(queued, 0.0, 5.0) : 0.0;
    }

    // mutex is held by the caller. The output queue is the audio clock; wall
    // time advances through an underrun so a full video queue cannot deadlock
    // demux before the next audio packet arrives.
    double clockLocked() const {
        if (!clockStarted || paused) {
            return clockBase;
        }
        double position = clockBase +
            std::chrono::duration<double>(Clock::now() - clockAnchor).count();
        if (audioMaster && std::isfinite(audioEnd)) {
            const double queued = queuedAudio();
            position = queued > 0.001 ? audioEnd - queued : std::max(position, audioEnd);
        }
        lastClock = std::max(lastClock, std::max(0.0, position));
        return lastClock;
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

    void resetOutput(double position) {
        if (sink) {
            sink->clear();
        }
        std::lock_guard<std::mutex> lock(mutex);
        frames.clear();
        ++serial;
        clockBase = std::max(0.0, position);
        lastClock = clockBase;
        clockAnchor = Clock::now();
        clockStarted = false;
        audioMaster = false;
        audioEnd = kNoTime;
        changed.notify_all();
    }

    bool waitActive(bool allowPreview = false) {
        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [&] {
            return stopping.load() || seekInterrupt.load() || !paused || allowPreview;
        });
        return !stopping.load() && !seekInterrupt.load();
    }

    bool openSource(Session& session, const std::string& url, double resumePosition,
                    const RequestOptions& request) {
        session.format = avformat_alloc_context();
        if (!session.format) {
            throw std::runtime_error("Cannot allocate a media reader.");
        }
        session.format->interrupt_callback = {&Impl::interrupt, this};
        session.format->probesize = 2 * 1024 * 1024;
        session.format->max_analyze_duration = 5 * AV_TIME_BASE;
        AVDictionary* options = nullptr;
        av_dict_set(&options, "rw_timeout", "15000000", 0);
        av_dict_set(&options, "tls_verify", "1", 0);
        av_dict_set(&options, "protocol_whitelist", request.local
            ? "file,http,https,tcp,tls,crypto,httpproxy,data"
            : "http,https,tcp,tls,crypto,httpproxy,data", 0);
        if (!request.userAgent.empty()) {
            av_dict_set(&options, "user_agent", request.userAgent.c_str(), 0);
        }
        if (!request.referer.empty()) {
            av_dict_set(&options, "referer", request.referer.c_str(), 0);
        }
#ifdef BRUTV_PS5
        av_dict_set(&options, "ca_file", "/app0/assets/ca-bundle.crt", 0);
#endif
        beginIo();
        int result = avformat_open_input(&session.format, url.c_str(), nullptr, &options);
        av_dict_free(&options);
        endIo();
        if (stopping.load()) {
            return false;
        }
        if (result < 0) {
            throw std::runtime_error("Cannot open source: " + avError(result));
        }
        beginIo();
        result = avformat_find_stream_info(session.format, nullptr);
        endIo();
        if (stopping.load()) {
            return false;
        }
        if (result < 0) {
            throw std::runtime_error("Cannot read stream information: " + avError(result));
        }
        session.videoIndex = av_find_best_stream(session.format, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
        session.audioIndex = av_find_best_stream(session.format, AVMEDIA_TYPE_AUDIO, -1,
                                               session.videoIndex, nullptr, 0);
        if (session.videoIndex < 0 && session.audioIndex < 0) {
            throw std::runtime_error("This source contains no playable video or audio stream.");
        }
        if (session.videoIndex >= 0) {
            session.video = openDecoder(session.format, session.videoIndex);
        }
        if (session.audioIndex >= 0) {
            session.audio = openDecoder(session.format, session.audioIndex);
        }
        session.packet = av_packet_alloc();
        session.decoded = av_frame_alloc();
        if (!session.packet || !session.decoded) {
            throw std::runtime_error("Cannot allocate media buffers.");
        }
        if (session.format->start_time != AV_NOPTS_VALUE) {
            session.origin = static_cast<double>(session.format->start_time) / AV_TIME_BASE;
        }
        session.offset = resumePosition;
        session.nextVideo = resumePosition;
        session.nextAudio = resumePosition;
        session.useAudioOutput = session.audio && static_cast<bool>(sink);
        std::lock_guard<std::mutex> lock(mutex);
        snapshot.hasVideo = session.video != nullptr;
        snapshot.hasAudio = session.audio != nullptr;
        snapshot.durationSeconds = session.format->duration > 0
            ? static_cast<double>(session.format->duration) / AV_TIME_BASE : 0.0;
        snapshot.state = paused ? State::Paused : State::Buffering;
        snapshot.message = "Buffering…";
        return true;
    }

    double frameTime(Session& session, AVFrame* frame, int streamIndex, bool audio) {
        const auto timestamp = frame->best_effort_timestamp != AV_NOPTS_VALUE
            ? frame->best_effort_timestamp : frame->pts;
        double& previousRaw = audio ? session.lastRawAudio : session.lastRawVideo;
        const double fallback = audio ? session.nextAudio : session.nextVideo;
        if (timestamp == AV_NOPTS_VALUE) {
            return fallback;
        }
        const double raw = static_cast<double>(timestamp) *
            av_q2d(session.format->streams[streamIndex]->time_base);
        if (!std::isfinite(session.origin)) {
            session.origin = raw;
        }
        if (snapshot.live && std::isfinite(previousRaw) &&
            (raw - previousRaw > 30.0 || raw - previousRaw < -3.0)) {
            double current;
            {
                std::lock_guard<std::mutex> lock(mutex);
                current = clockLocked();
            }
            session.offset = current - (raw - session.origin);
            session.lastRawAudio = kNoTime;
            session.lastRawVideo = kNoTime;
            resetOutput(current);
        }
        previousRaw = raw;
        return std::max(0.0, raw - session.origin + session.offset);
    }

    bool outputVideo(Session& session, AVFrame* frame) {
        if (frame->width <= 0 || frame->height <= 0 ||
            static_cast<std::int64_t>(frame->width) * frame->height > 3840LL * 2160LL) {
            throw std::runtime_error("Video exceeds the supported 4K software decode limit.");
        }
        const double pts = frameTime(session, frame, session.videoIndex, false);
        const AVRational frameRate = av_guess_frame_rate(
            session.format, session.format->streams[session.videoIndex], frame);
        const double fps = av_q2d(frameRate);
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
        int width = std::min(frame->width, kMaxWidth);
        int height = std::max(1, static_cast<int>(std::lround(width / aspect)));
        if (height > kMaxHeight) {
            height = kMaxHeight;
            width = std::max(1, static_cast<int>(std::lround(height * aspect)));
        }
        VideoFrame output;
        output.width = width;
        output.height = height;
        output.ptsSeconds = pts;
        output.rgba.resize(static_cast<std::size_t>(width) * height * 4);
        session.scaler = sws_getCachedContext(
            session.scaler, frame->width, frame->height, static_cast<AVPixelFormat>(frame->format),
            width, height, AV_PIX_FMT_RGBA, SWS_BILINEAR, nullptr, nullptr, nullptr);
        if (!session.scaler) {
            throw std::runtime_error("Cannot initialize video conversion.");
        }
        const int space = frame->colorspace == AVCOL_SPC_BT709 ? SWS_CS_ITU709 :
                          frame->colorspace == AVCOL_SPC_BT2020_NCL ? SWS_CS_BT2020 : SWS_CS_ITU601;
        const int* coefficients = sws_getCoefficients(space);
        sws_setColorspaceDetails(session.scaler, coefficients,
                                frame->color_range == AVCOL_RANGE_JPEG, coefficients, 1,
                                0, 1 << 16, 1 << 16);
        std::uint8_t* destinations[] = {output.rgba.data(), nullptr, nullptr, nullptr};
        int strides[] = {width * 4, 0, 0, 0};
        const int rows = sws_scale(session.scaler, frame->data, frame->linesize, 0,
                                   frame->height, destinations, strides);
        if (rows != height) {
            throw std::runtime_error("Video conversion failed.");
        }
        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [&] {
            return stopping.load() || seekInterrupt.load() || frames.size() < kMaxFrames;
        });
        if (stopping.load() || seekInterrupt.load()) {
            return false;
        }
        output.serial = serial;
        frames.push_back(std::move(output));
        snapshot.width = width;
        snapshot.height = height;
        startClockLocked(pts);
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
        const double pts = frameTime(session, frame, session.audioIndex, true);
        if (frame->sample_rate <= 0) {
            throw std::runtime_error("Invalid audio sample rate.");
        }
        session.nextAudio = pts + static_cast<double>(frame->nb_samples) / frame->sample_rate;
        if (!session.useAudioOutput) {
            if (!session.video) {
                paceAudioOnly(session.nextAudio);
            }
            return !stopping.load() && !seekInterrupt.load();
        }
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (paused && session.preview && session.video) {
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
        std::vector<std::int16_t> pcm(static_cast<std::size_t>(capacity) * 2);
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
        const float gain = volume.load();
        for (std::size_t sample = skip * 2; sample < static_cast<std::size_t>(samples) * 2; ++sample) {
            pcm[sample] = static_cast<std::int16_t>(std::lround(pcm[sample] * gain));
        }
        auto stalledSince = Clock::now();
        while (!stopping.load() && !seekInterrupt.load()) {
            const auto waitStarted = Clock::now();
            if (!waitActive(session.preview && session.video)) {
                return false;
            }
            stalledSince += Clock::now() - waitStarted;
            if (queuedAudio() + static_cast<double>(count) / kAudioRate <= kMaxAudioSeconds &&
                sink->queue(pcm.data() + skip * 2, count)) {
                std::lock_guard<std::mutex> lock(mutex);
                const double current = clockLocked();
                audioEnd = pts + static_cast<double>(samples) / kAudioRate;
                audioMaster = true;
                startClockLocked(std::max(0.0, audioEnd - queuedAudio()));
                clockBase = std::max(current, audioEnd - queuedAudio());
                lastClock = clockBase;
                clockAnchor = Clock::now();
                return true;
            }
            std::unique_lock<std::mutex> lock(mutex);
            if (paused) {
                stalledSince = Clock::now();
            } else if (Clock::now() - stalledSince > std::chrono::seconds(3)) {
                session.useAudioOutput = false;
                audioMaster = false;
                snapshot.message = "Audio output stalled; continuing without audio.";
                lock.unlock();
                sink->clear();
                return true;
            }
            changed.wait_for(lock, std::chrono::milliseconds(10));
        }
        return false;
    }

    void paceAudioOnly(double until) {
        std::unique_lock<std::mutex> lock(mutex);
        startClockLocked(until);
        while (!stopping.load() && !seekInterrupt.load() &&
               (paused || clockLocked() + kMaxAudioSeconds < until)) {
            changed.wait_for(lock, std::chrono::milliseconds(10));
        }
    }

    bool receiveFrames(Session& session, AVCodecContext* decoder, bool audio) {
        for (;;) {
            const int result = avcodec_receive_frame(decoder, session.decoded);
            if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
                return true;
            }
            if (result < 0) {
                if (++session.decodeErrors > 8) {
                    throw std::runtime_error("Repeated media decode failure: " + avError(result));
                }
                return true;
            }
            session.decodeErrors = 0;
            const bool keepGoing = audio ? outputAudio(session, session.decoded)
                                         : outputVideo(session, session.decoded);
            av_frame_unref(session.decoded);
            if (!keepGoing) {
                return false;
            }
        }
    }

    bool decodePacket(Session& session, AVCodecContext* decoder, bool audio, const AVPacket* packet) {
        int result = avcodec_send_packet(decoder, packet);
        if (result == AVERROR(EAGAIN)) {
            if (!receiveFrames(session, decoder, audio)) {
                return false;
            }
            result = avcodec_send_packet(decoder, packet);
        }
        if (result < 0 && result != AVERROR_EOF) {
            if (++session.decodeErrors > 8) {
                throw std::runtime_error("Repeated media decode failure: " + avError(result));
            }
            return true;
        }
        return receiveFrames(session, decoder, audio);
    }

    void processSeek(Session& session) {
        double target;
        {
            std::lock_guard<std::mutex> lock(mutex);
            target = seekTarget;
            seekTarget = kNoTime;
            seekInterrupt.store(false);
        }
        if (!std::isfinite(target)) {
            return;
        }
        const double absolute = target + (std::isfinite(session.origin) ? session.origin : 0.0);
        if (session.format->pb) {
            session.format->pb->error = 0;
            session.format->pb->eof_reached = 0;
        }
        beginIo();
        const int result = avformat_seek_file(session.format, -1, INT64_MIN,
            static_cast<std::int64_t>(absolute * AV_TIME_BASE), INT64_MAX, AVSEEK_FLAG_BACKWARD);
        endIo();
        if (result < 0) {
            std::lock_guard<std::mutex> lock(mutex);
            snapshot.message = "This source does not support seeking: " + avError(result);
            return;
        }
        if (session.video) {
            avcodec_flush_buffers(session.video);
        }
        if (session.audio) {
            avcodec_flush_buffers(session.audio);
        }
        swr_free(&session.resampler);
        session.lastRawAudio = kNoTime;
        session.lastRawVideo = kNoTime;
        session.nextAudio = target;
        session.nextVideo = target;
        session.offset = 0.0;
        session.discardBefore = target;
        session.preview = true;
        resetOutput(target);
        std::lock_guard<std::mutex> lock(mutex);
        snapshot.state = paused ? State::Paused : State::Buffering;
        snapshot.message = "Seeking…";
    }

    int playSession(Session& session) {
        for (;;) {
            if (stopping.load()) {
                return AVERROR_EXIT;
            }
            if (seekInterrupt.load()) {
                processSeek(session);
            }
            if (!waitActive(session.preview)) {
                continue;
            }
            beginIo();
            const int result = av_read_frame(session.format, session.packet);
            endIo();
            if (stopping.load()) {
                return AVERROR_EXIT;
            }
            if (seekInterrupt.load()) {
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
            bool keepGoing = true;
            if (session.packet->stream_index == session.videoIndex) {
                keepGoing = decodePacket(session, session.video, false, session.packet);
            } else if (session.packet->stream_index == session.audioIndex) {
                keepGoing = decodePacket(session, session.audio, true, session.packet);
            }
            av_packet_unref(session.packet);
            if (!keepGoing && stopping.load()) {
                return AVERROR_EXIT;
            }
        }
    }

    void finishPlayback(Session& session) {
        if (session.video && !decodePacket(session, session.video, false, nullptr)) {
            return;
        }
        if (session.audio && !decodePacket(session, session.audio, true, nullptr)) {
            return;
        }
        std::unique_lock<std::mutex> lock(mutex);
        while (!stopping.load() && !seekInterrupt.load() &&
               (!frames.empty() || (session.useAudioOutput && queuedAudio() > 0.025))) {
            changed.wait_for(lock, std::chrono::milliseconds(10));
        }
        if (!stopping.load() && !seekInterrupt.load()) {
            clockBase = clockLocked();
            lastClock = clockBase;
            clockStarted = false;
            snapshot.state = State::Ended;
            snapshot.message = "Playback finished.";
        }
    }

    void run(std::string url, bool live, RequestOptions request) {
        int failures = 0;
        double resumePosition = 0.0;
        try {
            if (sink) {
                sink->clear();
                std::lock_guard<std::mutex> lock(mutex);
                sink->setPaused(paused);
            }
            while (!stopping.load()) {
                const auto started = Clock::now();
                int result = AVERROR_UNKNOWN;
                std::string failure;
                {
                    Session session;
                    try {
                        if (!openSource(session, url, resumePosition, request)) {
                            break;
                        }
                        result = playSession(session);
                        if (stopping.load()) {
                            break;
                        }
                        if (result == AVERROR_EOF && !live) {
                            finishPlayback(session);
                            while (!stopping.load()) {
                                std::unique_lock<std::mutex> lock(mutex);
                                changed.wait(lock, [&] {
                                    return stopping.load() || seekInterrupt.load();
                                });
                                if (stopping.load()) {
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
                            if (stopping.load()) {
                                break;
                            }
                        }
                        failure = result == AVERROR_EOF ? "The live source closed its connection."
                            : "Source read failed: " + avError(result);
                    } catch (const std::exception& error) {
                        failure = error.what();
                    }
                }
                if (stopping.load()) {
                    break;
                }
                if (!live || ++failures > 3) {
                    throw std::runtime_error(failure);
                }
                if (Clock::now() - started > std::chrono::seconds(20)) {
                    failures = 1;
                }
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    resumePosition = clockLocked();
                    snapshot.state = paused ? State::Paused : State::Buffering;
                    snapshot.message = "Reconnecting (" + std::to_string(failures) + "/3)…";
                }
                resetOutput(resumePosition);
                std::unique_lock<std::mutex> lock(mutex);
                changed.wait_for(lock, std::chrono::milliseconds(500 * (1 << (failures - 1))),
                                 [&] { return stopping.load(); });
            }
        } catch (const std::exception& error) {
            std::lock_guard<std::mutex> lock(mutex);
            clockBase = clockLocked();
            clockStarted = false;
            snapshot.state = State::Error;
            snapshot.message = error.what();
        } catch (...) {
            std::lock_guard<std::mutex> lock(mutex);
            snapshot.state = State::Error;
            snapshot.message = "Unexpected media playback failure.";
            clockStarted = false;
        }
        endIo();
        if (sink) {
            sink->clear();
        }
        changed.notify_all();
    }

    void stopLocked() {
        stopping.store(true);
        changed.notify_all();
        if (worker.joinable()) {
            worker.join();
        }
        std::lock_guard<std::mutex> lock(mutex);
        frames.clear();
        snapshot = {};
        snapshot.volume = volume.load();
        paused = false;
        clockStarted = false;
        audioMaster = false;
        audioEnd = kNoTime;
        clockBase = 0.0;
        lastClock = 0.0;
        seekTarget = kNoTime;
        seekInterrupt.store(false);
        ++serial;
    }
};

Player::Player(std::shared_ptr<AudioSink> audioSink)
    : impl_(std::make_unique<Impl>(std::move(audioSink))) {}

Player::~Player() {
    stop();
}

void Player::open(const std::string& url, bool live,
                  const std::unordered_map<std::string, std::string>& requestHeaders) {
    std::lock_guard<std::mutex> lifecycle(impl_->lifecycle);
    impl_->stopLocked();
    RequestOptions request;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->snapshot.live = live;
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
        impl_->snapshot.state = State::Opening;
        impl_->snapshot.message = "Opening source…";
        impl_->stopping.store(false);
    }
    impl_->worker = std::thread([this, url, live, request] { impl_->run(url, live, request); });
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
        impl_->snapshot.state = paused ? State::Paused : State::Playing;
        if (impl_->sink) {
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
        impl_->snapshot.state == State::Opening) {
        return;
    }
    if (impl_->snapshot.live) {
        impl_->snapshot.message = "Seeking is unavailable for live sources.";
        return;
    }
    const double upper = impl_->snapshot.durationSeconds > 0.0
        ? std::max(0.0, impl_->snapshot.durationSeconds - 0.1)
        : std::numeric_limits<double>::max();
    impl_->seekTarget = std::clamp(impl_->clockLocked() + seconds, 0.0, upper);
    impl_->seekInterrupt.store(true);
    impl_->changed.notify_all();
}

void Player::setVolume(float volume) {
    if (std::isfinite(volume)) {
        impl_->volume.store(std::clamp(volume, 0.0F, 1.0F));
    }
}

Player::Status Player::status() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    Status status = impl_->snapshot;
    status.currentSeconds = impl_->clockLocked();
    status.volume = impl_->volume.load();
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
        impl_->frames.pop_front();
        ++impl_->snapshot.droppedFrames;
    }
    frame = std::move(impl_->frames.front());
    impl_->frames.pop_front();
    impl_->changed.notify_all();
    return true;
}

} // namespace brutv
