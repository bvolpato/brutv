#pragma once
#include <cstdint>
#include <memory>
#include <string>

namespace brutv {
struct Color {
  float r, g, b, a{1.0F};
};

enum class Icon {
  Live,
  Movies,
  Series,
  Heart,
  Settings,
  Search,
  Play,
  Pause,
  Back,
  ChevronLeft,
  ChevronRight,
  Volume,
  Rewind,
  Forward,
  Refresh,
  Dpad
};

enum class Button { Cross, Circle, Square, Triangle, Options, L1, R1, L2, R2 };

class Gfx {
public:
  explicit Gfx(const std::string &fontFile);
  ~Gfx();
  Gfx(const Gfx &) = delete;
  Gfx &operator=(const Gfx &) = delete;
  void begin(int pixelWidth, int pixelHeight);
  void rect(float x, float y, float width, float height, Color color,
            float radius = 0);
  void text(const std::string &value, float x, float y, float size, Color color,
            float maxWidth = 0);
  float textWidth(const std::string &value, float size) const;
  void video(const std::uint8_t *rgba, int width, int height);
  void drawVideo(float x, float y, float width, float height);
  void icon(Icon value, float x, float y, float size, Color color);
  void button(Button value, float x, float y, float size, Color color);
  void image(const std::string &key, const std::uint8_t *rgba, int imageWidth,
             int imageHeight, float x, float y, float width, float height,
             bool cover = false, float radius = 0);
  void end();
  void screenshot(const std::string &filename);

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
} // namespace brutv
