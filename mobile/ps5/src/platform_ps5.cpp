// SPDX-License-Identifier: GPL-3.0-or-later
#include "brutv/platform.hpp"
#include "brutv/player.hpp"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <ps5_opengl_display.h>
#if __has_include(<ps5_opengl_display_modes.h>)
#include <ps5_opengl_display_modes.h>
#endif
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <pthread.h>
#include <unistd.h>

// Public reverse-engineered ScePad sample ABI from ps5-homebrew-ui. The public
// payload SDK has import libraries, but does not ship typed Pad/Audio headers.
namespace {
struct PadSample {
    std::uint32_t buttons;
    std::uint8_t leftX, leftY, rightX, rightY, l2, r2;
    std::uint8_t reserved0[66];
    std::int32_t connected;
    std::uint64_t timestampUs;
    std::uint8_t extension[16];
    std::uint8_t connectedCount;
    std::uint8_t reserved1[15];
};
static_assert(sizeof(PadSample) == 120);
static_assert(offsetof(PadSample, connected) == 0x4c);
static_assert(offsetof(PadSample, timestampUs) == 0x50);
}
extern "C" {
int sceUserServiceInitialize(const void* parameters);
int sceUserServiceGetInitialUser(int* user);
int sceUserServiceTerminate();
int scePadInit();
int scePadOpen(int user, int type, int index, const void* parameters);
int scePadRead(int handle, PadSample* samples, int count);
int scePadClose(int handle);
int sceAudioOutInit();
int sceAudioOutOpen(int user, int type, int index, unsigned grainFrames, unsigned frequency, unsigned format);
int sceAudioOutOutput(int handle, const void* samples);
int sceAudioOutClose(int handle);
}

namespace brutv {
namespace {
class Ps5Audio final : public AudioSink {
public:
    Ps5Audio() {
        const int init = sceAudioOutInit();
        if (init != 0 && init != static_cast<int>(0x8026000e)) {
            std::fprintf(stderr, "[BruTV] sceAudioOutInit failed: 0x%08x\n",
                         static_cast<unsigned>(init));
            failed_.store(true);
            return;
        }
        handle_ = sceAudioOutOpen(0xff, 0, 0, grainFrames, 48000, 1);
        if (handle_ < 0) {
            std::fprintf(stderr, "[BruTV] sceAudioOutOpen failed at launch: 0x%08x\n",
                         static_cast<unsigned>(handle_));
            failed_.store(true);
        }
        if (pthread_create(&thread_, nullptr, runThread, this) != 0) {
            std::fprintf(stderr, "[BruTV] Could not start the PS5 audio output thread\n");
            if (handle_ >= 0) {
                sceAudioOutClose(handle_);
                handle_ = -1;
            }
            failed_.store(true);
            return;
        }
        threadStarted_ = true;
    }
    ~Ps5Audio() override {
        stop_.store(true);
        if (threadStarted_) {
            pthread_join(thread_, nullptr);
        }
        if (handle_ >= 0) {
            sceAudioOutClose(handle_);
            handle_ = -1;
        }
    }
    bool available() const { return threadStarted_; }
    bool queue(const std::int16_t* samples, std::size_t frames) override {
        if (frames == 0) return true;
        if (!samples || frames > capacityFrames || failed_.load()) return false;
        std::lock_guard<std::mutex> lock(mutex_);
        if (frames > capacityFrames - count_) return false;
        const std::size_t tail = (head_ + count_) % capacityFrames;
        const std::size_t first = std::min(frames, capacityFrames - tail);
        std::memcpy(ring_.data() + tail * 2, samples, first * 2 * sizeof(*samples));
        if (first < frames)
            std::memcpy(ring_.data(), samples + first * 2, (frames - first) * 2 * sizeof(*samples));
        count_ += frames;
        return true;
    }
    double queuedSeconds() const override {
        std::lock_guard<std::mutex> lock(mutex_);
        return static_cast<double>(count_) / 48000.0;
    }
    void clear() override {
        std::lock_guard<std::mutex> lock(mutex_);
        count_ = head_ = 0;
    }
    void setPaused(bool paused) override {
        std::lock_guard<std::mutex> lock(mutex_);
        paused_ = paused;
    }
private:
    static constexpr std::size_t grainFrames = 256;
    static constexpr std::size_t capacityFrames = 48000; // one bounded second
    static void* runThread(void* self) {
        static_cast<Ps5Audio*>(self)->run();
        return nullptr;
    }
    void sleepInterruptible(unsigned milliseconds) {
        for (unsigned elapsed = 0; elapsed < milliseconds && !stop_.load(); elapsed += 50) {
            const unsigned slice = std::min(50U, milliseconds - elapsed);
            usleep(slice * 1000U);
        }
    }
    void run() {
        alignas(64) std::array<std::int16_t, grainFrames * 2> grain{};
        unsigned reopenAttempt = 0;
        while (!stop_.load()) {
            if (handle_ < 0) {
                const unsigned shift = std::min(reopenAttempt, 4U);
                const unsigned backoffMs = std::min(250U << shift, 4000U);
                sleepInterruptible(backoffMs);
                if (stop_.load()) break;
                handle_ = sceAudioOutOpen(0xff, 0, 0, grainFrames, 48000, 1);
                if (handle_ >= 0) {
                    clear();
                    failed_.store(false);
                    reopenAttempt = 0;
                } else {
                    ++reopenAttempt;
                }
                continue;
            }
            grain.fill(0);
            {
                std::lock_guard<std::mutex> lock(mutex_);
                const std::size_t frames = paused_ ? 0 : std::min(grainFrames, count_);
                const std::size_t first = std::min(frames, capacityFrames - head_);
                std::memcpy(grain.data(), ring_.data() + head_ * 2, first * 2 * sizeof(std::int16_t));
                if (first < frames)
                    std::memcpy(grain.data() + first * 2, ring_.data(), (frames - first) * 2 * sizeof(std::int16_t));
                head_ = (head_ + frames) % capacityFrames;
                count_ -= frames;
            }
            // This call blocks at the hardware audio rate, on this thread only.
            const int result = sceAudioOutOutput(handle_, grain.data());
            if (result < 0) {
                std::fprintf(stderr, "[BruTV] sceAudioOutOutput failed: 0x%08x; attempting recovery\n",
                             static_cast<unsigned>(result));
                failed_.store(true);
                sceAudioOutClose(handle_);
                handle_ = -1;
                reopenAttempt = 0;
            }
        }
        if (handle_ >= 0) {
            sceAudioOutOutput(handle_, nullptr);
        }
    }
    mutable std::mutex mutex_;
    std::array<std::int16_t, capacityFrames * 2> ring_{};
    std::size_t head_ = 0, count_ = 0;
    bool paused_ = false;
    bool threadStarted_ = false;
    std::atomic<bool> stop_{false}, failed_{false};
    pthread_t thread_{};
    int handle_ = -1;
};

class Ps5Platform final : public Platform {
public:
    Ps5Platform() {
        try {
            openDisplay();
            const int init = sceUserServiceInitialize(nullptr);
            ownsUserService_ = init == 0;
            if (init != 0 && init != static_cast<int>(0x80960003))
                throw std::runtime_error("sceUserServiceInitialize failed");
            if (sceUserServiceGetInitialUser(&user_) != 0)
                throw std::runtime_error("No signed-in PS5 user is available for DualSense input");
            scePadInit();
            for (int attempt = 0; attempt < 20 && pad_ < 0; ++attempt) {
                pad_ = scePadOpen(user_, 0, 0, nullptr);
                if (pad_ < 0) usleep(50000);
            }
            if (pad_ < 0) throw std::runtime_error("scePadOpen failed");
            auto sink = std::make_shared<Ps5Audio>();
            if (sink->available()) {
                audio_ = std::move(sink);
            }
        } catch (...) {
            close();
            throw;
        }
    }
    ~Ps5Platform() override { close(); }
    Input poll() override {
        Input input;
        const auto now = std::chrono::steady_clock::now();
        if (pad_ < 0) {
            if (now >= padReopenAt_) {
                pad_ = scePadOpen(user_, 0, 0, nullptr);
                if (pad_ < 0) {
                    padReopenAt_ = now + std::chrono::milliseconds(500);
                }
            }
            return input;
        }
        PadSample samples[64]{};
        const int count = scePadRead(pad_, samples, 64);
        if (count < 0) {
            if (++padErrors_ >= 30) {
                std::fprintf(stderr, "[BruTV] scePadRead failed persistently (0x%08x); reopening pad\n",
                             static_cast<unsigned>(count));
                scePadClose(pad_);
                pad_ = -1;
                held_ = 0;
                padErrors_ = 0;
                padReopenAt_ = now + std::chrono::milliseconds(250);
            }
            return input;
        }
        padErrors_ = 0;
        if (count == 0) return input;
        constexpr std::uint32_t repeatable = 0x00f0 | 0x0100 | 0x0200; // D-pad/stick + L2 + R2
        const std::uint32_t previousRepeatable = held_ & repeatable;
        std::uint32_t pressed = 0;
        for (int i = 0; i < count; ++i) {
            const auto& sample = samples[i];
            if (!sample.connected) {
                held_ = 0;
                continue;
            }
            std::uint32_t buttons = sample.buttons;
            if (sample.leftY < 80) buttons |= 0x0010;
            if (sample.leftY > 176) buttons |= 0x0040;
            if (sample.leftX < 80) buttons |= 0x0080;
            if (sample.leftX > 176) buttons |= 0x0020;
            if (sample.l2 > 128) buttons |= 0x0100;
            if (sample.r2 > 128) buttons |= 0x0200;
            pressed |= (buttons & ~held_);
            held_ = buttons;
        }
        if ((held_ & repeatable) != previousRepeatable) {
            repeatAt_ = now + std::chrono::milliseconds(350);
        } else if ((held_ & repeatable) != 0 && now >= repeatAt_) {
            pressed |= (held_ & repeatable);
            repeatAt_ = now + std::chrono::milliseconds(110);
        }
        const auto add = [&](std::uint32_t mask, Key key) { if ((pressed & mask) != 0) input.pressed.push_back(key); };
        add(0x0010, Key::Up); add(0x0040, Key::Down);
        add(0x0080, Key::Left); add(0x0020, Key::Right);
        add(0x4000, Key::Confirm); add(0x2000, Key::Back);
        add(0x8000, Key::Favorite); add(0x1000, Key::Search);
        add(0x0400, Key::PreviousTab); add(0x0800, Key::NextTab);
        add(0x0100, Key::Rewind); add(0x0200, Key::Forward);
        add(0x0008, Key::Options);
        return input;
    }
    void present() override {
        if (!eglSwapBuffers(display_, surface_)) {
            const EGLint err = eglGetError();
            std::fprintf(stderr, "[BruTV] eglSwapBuffers failed: 0x%04x\n",
                         static_cast<unsigned>(err));
            usleep(16000);
        }
    }
    int width() const override { return width_; }
    int height() const override { return height_; }
    std::shared_ptr<AudioSink> audio() override { return audio_; }
private:
    void openDisplay() {
        display_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (display_ == EGL_NO_DISPLAY) throw std::runtime_error("eglGetDisplay failed");
#ifdef PS5_OPENGL_DYNAMIC_DISPLAY
        if (!eglSetDisplayModePS5(display_, 1920, 1080))
            throw std::runtime_error("PS5 OpenGL could not select 1080p");
#endif
        if (!eglInitialize(display_, nullptr, nullptr) || !eglBindAPI(EGL_OPENGL_API))
            throw std::runtime_error("EGL OpenGL initialization failed");
        const EGLint configAttrs[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
            EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8, EGL_NONE};
        EGLConfig config{};
        EGLint count = 0;
        if (!eglChooseConfig(display_, configAttrs, &config, 1, &count) || count != 1)
            throw std::runtime_error("No usable EGL window configuration");
        surface_ = eglCreateWindowSurface(display_, config, static_cast<EGLNativeWindowType>(0), nullptr);
        const EGLint contextAttrs[] = {EGL_CONTEXT_MAJOR_VERSION_KHR, 3, EGL_CONTEXT_MINOR_VERSION_KHR, 3,
            EGL_CONTEXT_OPENGL_PROFILE_MASK_KHR, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT_KHR, EGL_NONE};
        context_ = eglCreateContext(display_, config, EGL_NO_CONTEXT, contextAttrs);
        if (surface_ == EGL_NO_SURFACE || context_ == EGL_NO_CONTEXT ||
            !eglMakeCurrent(display_, surface_, surface_, context_))
            throw std::runtime_error("Could not create the PS5 OpenGL 3.3 context");
        if (!eglQuerySurface(display_, surface_, EGL_WIDTH, &width_) ||
            !eglQuerySurface(display_, surface_, EGL_HEIGHT, &height_) ||
            !eglSwapInterval(display_, 1))
            throw std::runtime_error("Could not configure the PS5 EGL surface");
    }
    void close() noexcept {
        audio_.reset();
        if (pad_ >= 0) { scePadClose(pad_); pad_ = -1; }
        if (ownsUserService_) { sceUserServiceTerminate(); ownsUserService_ = false; }
        if (display_ != EGL_NO_DISPLAY) {
            eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            if (context_ != EGL_NO_CONTEXT) eglDestroyContext(display_, context_);
            if (surface_ != EGL_NO_SURFACE) eglDestroySurface(display_, surface_);
            eglTerminate(display_);
            display_ = EGL_NO_DISPLAY;
        }
    }
    EGLDisplay display_ = EGL_NO_DISPLAY;
    EGLSurface surface_ = EGL_NO_SURFACE;
    EGLContext context_ = EGL_NO_CONTEXT;
    int width_ = 0, height_ = 0, pad_ = -1, user_ = 0, padErrors_ = 0;
    bool ownsUserService_ = false;
    std::uint32_t held_ = 0;
    std::chrono::steady_clock::time_point repeatAt_{};
    std::chrono::steady_clock::time_point padReopenAt_{};
    std::shared_ptr<Ps5Audio> audio_;
};
}
std::unique_ptr<Platform> makePlatform() { return std::make_unique<Ps5Platform>(); }
}
