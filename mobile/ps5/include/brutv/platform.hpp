#pragma once

#include <memory>
#include <string>
#include <vector>

namespace brutv {
class AudioSink;

enum class Key {
    Up,
    Down,
    Left,
    Right,
    Confirm,
    Back,
    Favorite,
    Search,
    PreviousTab,
    NextTab,
    Rewind,
    Forward,
    Options,
    Quit,
    Backspace
};

struct Input {
    std::vector<Key> pressed;
    std::string text;
};

class Platform {
  public:
    virtual ~Platform() = default;
    virtual Input poll() = 0;
    virtual void present() = 0;
    virtual int width() const = 0;
    virtual int height() const = 0;
    virtual std::shared_ptr<AudioSink> audio() = 0;
};

std::unique_ptr<Platform> makePlatform();
} // namespace brutv
