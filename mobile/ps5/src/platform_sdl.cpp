#include "brutv/platform.hpp"
#include "brutv/player.hpp"
#include <SDL.h>
#include <algorithm>
#include <array>
#include <mutex>
#include <stdexcept>

namespace brutv {
namespace {
class SdlAudio final : public AudioSink {
  public:
    SdlAudio() {
        SDL_AudioSpec wanted{};
        wanted.freq = 48000;
        wanted.format = AUDIO_S16SYS;
        wanted.channels = 2;
        wanted.samples = 1024;
        device_ = SDL_OpenAudioDevice(nullptr, 0, &wanted, nullptr, 0);
        if (device_)
            SDL_PauseAudioDevice(device_, 0);
    }
    ~SdlAudio() override {
        if (device_)
            SDL_CloseAudioDevice(device_);
    }
    bool queue(const std::int16_t *samples, std::size_t frames) override {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!device_)
            return true;
        if (frames > 96000 || SDL_GetQueuedAudioSize(device_) + frames * 4 > 48000 * 4 * 2)
            return false;
        return SDL_QueueAudio(device_, samples, static_cast<Uint32>(frames * 4)) == 0;
    }
    double queuedSeconds() const override {
        std::lock_guard<std::mutex> lock(mutex_);
        return device_ ? SDL_GetQueuedAudioSize(device_) / 192000.0 : 0;
    }
    void clear() override {
        std::lock_guard<std::mutex> lock(mutex_);
        if (device_)
            SDL_ClearQueuedAudio(device_);
    }
    void setPaused(bool paused) override {
        std::lock_guard<std::mutex> lock(mutex_);
        if (device_)
            SDL_PauseAudioDevice(device_, paused ? 1 : 0);
    }
    bool available() const { return device_ != 0; }

  private:
    SDL_AudioDeviceID device_{};
    mutable std::mutex mutex_;
};

class SdlPlatform final : public Platform {
  public:
    SdlPlatform() {
        if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_GAMECONTROLLER) != 0)
            throw std::runtime_error(std::string("SDL initialization: ") + SDL_GetError());
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
        SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
        window_ = SDL_CreateWindow(
            "BruTV - PS5 desktop preview", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 1280,
            720, SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
        if (!window_) {
            SDL_Quit();
            throw std::runtime_error(std::string("OpenGL window: ") + SDL_GetError());
        }
        context_ = SDL_GL_CreateContext(window_);
        if (!context_) {
            SDL_DestroyWindow(window_);
            SDL_Quit();
            throw std::runtime_error("OpenGL 3.3 is required for the desktop preview");
        }
        SDL_GL_SetSwapInterval(1);
        SDL_StartTextInput();
        for (int i = 0; i < SDL_NumJoysticks(); ++i)
            if (SDL_IsGameController(i)) {
                controller_ = SDL_GameControllerOpen(i);
                break;
            }
        auto sink = std::make_shared<SdlAudio>();
        if (sink->available())
            audio_ = std::move(sink);
    }
    ~SdlPlatform() override {
        audio_.reset();
        if (controller_)
            SDL_GameControllerClose(controller_);
        SDL_GL_DeleteContext(context_);
        SDL_DestroyWindow(window_);
        SDL_Quit();
    }
    Input poll() override {
        Input input;
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT)
                input.pressed.push_back(Key::Quit);
            else if (event.type == SDL_TEXTINPUT)
                input.text += event.text.text;
            else if (event.type == SDL_CONTROLLERDEVICEADDED && !controller_)
                controller_ = SDL_GameControllerOpen(event.cdevice.which);
            else if (event.type == SDL_CONTROLLERDEVICEREMOVED && controller_ &&
                     SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(controller_)) ==
                         event.cdevice.which) {
                SDL_GameControllerClose(controller_);
                controller_ = nullptr;
            } else if (event.type == SDL_KEYDOWN) {
                switch (event.key.keysym.sym) {
                case SDLK_UP:
                    input.pressed.push_back(Key::Up);
                    break;
                case SDLK_DOWN:
                    input.pressed.push_back(Key::Down);
                    break;
                case SDLK_LEFT:
                    input.pressed.push_back(Key::Left);
                    break;
                case SDLK_RIGHT:
                    input.pressed.push_back(Key::Right);
                    break;
                case SDLK_RETURN:
                case SDLK_KP_ENTER:
                    if (!event.key.repeat)
                        input.pressed.push_back(Key::Confirm);
                    break;
                case SDLK_ESCAPE:
                    if (!event.key.repeat)
                        input.pressed.push_back(Key::Back);
                    break;
                case SDLK_BACKSPACE:
                    input.pressed.push_back(Key::Backspace);
                    break;
                case SDLK_TAB:
                    input.pressed.push_back(event.key.keysym.mod & KMOD_SHIFT ? Key::PreviousTab
                                                                              : Key::NextTab);
                    break;
                case SDLK_F2:
                    input.pressed.push_back(Key::Favorite);
                    break;
                case SDLK_F3:
                    input.pressed.push_back(Key::Search);
                    break;
                case SDLK_F4:
                    input.pressed.push_back(Key::Options);
                    break;
                case SDLK_PAGEUP:
                    input.pressed.push_back(Key::Rewind);
                    break;
                case SDLK_PAGEDOWN:
                    input.pressed.push_back(Key::Forward);
                    break;
                default:
                    break;
                }
            }
        }
        if (controller_) {
            const bool left =
                SDL_GameControllerGetAxis(controller_, SDL_CONTROLLER_AXIS_LEFTX) < -16000;
            const bool right =
                SDL_GameControllerGetAxis(controller_, SDL_CONTROLLER_AXIS_LEFTX) > 16000;
            const bool up =
                SDL_GameControllerGetAxis(controller_, SDL_CONTROLLER_AXIS_LEFTY) < -16000;
            const bool down =
                SDL_GameControllerGetAxis(controller_, SDL_CONTROLLER_AXIS_LEFTY) > 16000;
            const std::array<bool, 12> held = {
                bool(SDL_GameControllerGetButton(controller_, SDL_CONTROLLER_BUTTON_DPAD_UP) || up),
                bool(SDL_GameControllerGetButton(controller_, SDL_CONTROLLER_BUTTON_DPAD_DOWN) ||
                     down),
                bool(SDL_GameControllerGetButton(controller_, SDL_CONTROLLER_BUTTON_DPAD_LEFT) ||
                     left),
                bool(SDL_GameControllerGetButton(controller_, SDL_CONTROLLER_BUTTON_DPAD_RIGHT) ||
                     right),
                bool(SDL_GameControllerGetButton(controller_, SDL_CONTROLLER_BUTTON_A)),
                bool(SDL_GameControllerGetButton(controller_, SDL_CONTROLLER_BUTTON_B)),
                bool(SDL_GameControllerGetButton(controller_, SDL_CONTROLLER_BUTTON_X)),
                bool(SDL_GameControllerGetButton(controller_, SDL_CONTROLLER_BUTTON_Y)),
                bool(SDL_GameControllerGetButton(controller_, SDL_CONTROLLER_BUTTON_LEFTSHOULDER)),
                bool(SDL_GameControllerGetButton(controller_, SDL_CONTROLLER_BUTTON_RIGHTSHOULDER)),
                bool(SDL_GameControllerGetButton(controller_, SDL_CONTROLLER_BUTTON_START)),
                bool(SDL_GameControllerGetAxis(controller_, SDL_CONTROLLER_AXIS_TRIGGERLEFT) >
                     16000)};
            const std::array<Key, 12> keys = {Key::Up,       Key::Down,    Key::Left,
                                              Key::Right,    Key::Confirm, Key::Back,
                                              Key::Favorite, Key::Search,  Key::PreviousTab,
                                              Key::NextTab,  Key::Options, Key::Rewind};
            const auto now = SDL_GetTicks64();
            for (std::size_t i = 0; i < held.size(); ++i) {
                if (held[i] && (!held_[i] || ((i < 4 || i == 11) && now >= repeat_[i]))) {
                    input.pressed.push_back(keys[i]);
                    repeat_[i] = now + (held_[i] ? 110 : 360);
                }
                held_[i] = held[i];
            }
            const bool forward =
                SDL_GameControllerGetAxis(controller_, SDL_CONTROLLER_AXIS_TRIGGERRIGHT) > 16000;
            if (forward && (!forwardHeld_ || now >= forwardRepeat_)) {
                input.pressed.push_back(Key::Forward);
                forwardRepeat_ = now + (forwardHeld_ ? 160 : 360);
            }
            forwardHeld_ = forward;
        }
        return input;
    }
    void present() override {
        SDL_GL_SwapWindow(window_);
        SDL_Delay(1);
    }
    int width() const override {
        int w = 0;
        SDL_GL_GetDrawableSize(window_, &w, nullptr);
        return w;
    }
    int height() const override {
        int h = 0;
        SDL_GL_GetDrawableSize(window_, nullptr, &h);
        return h;
    }
    std::shared_ptr<AudioSink> audio() override { return audio_; }

  private:
    SDL_Window *window_{};
    SDL_GLContext context_{};
    SDL_GameController *controller_{};
    std::shared_ptr<AudioSink> audio_;
    std::array<bool, 12> held_{};
    std::array<Uint64, 12> repeat_{};
    bool forwardHeld_{};
    Uint64 forwardRepeat_{};
};
} // namespace
std::unique_ptr<Platform> makePlatform() { return std::make_unique<SdlPlatform>(); }
} // namespace brutv
