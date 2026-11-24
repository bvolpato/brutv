// SPDX-License-Identifier: MIT
#include "brutv/gfx.hpp"
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include <GL/gl.h>
#include <GL/glext.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <fstream>
#include <iterator>
#include <list>
#include <stdexcept>
#include <unordered_map>
#include <utility>
#include <vector>

namespace brutv {
namespace {
constexpr float Pi = 3.14159265358979323846F;
constexpr int kAtlasSize = 2048;
constexpr int kLatinStart = 32;
constexpr int kLatinCount = 224;     // U+0020 .. U+00FF
constexpr int kPunctStart = 0x2010;  // U+2010 .. U+2026 (hyphens, dashes, smart quotes, bullet, ellipsis)
constexpr int kPunctCount = 23;
constexpr int kGlyphCount = kLatinCount + kPunctCount;

GLuint shader(GLenum kind, const char *code) {
  GLuint id = glCreateShader(kind);
  glShaderSource(id, 1, &code, nullptr);
  glCompileShader(id);
  GLint ok = 0;
  glGetShaderiv(id, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[1024]{};
    glGetShaderInfoLog(id, sizeof(log), nullptr, log);
    glDeleteShader(id);
    throw std::runtime_error(std::string("OpenGL shader: ") + log);
  }
  return id;
}

struct Vertex {
  float x, y;
  float u, v;
  float shapeU, shapeV;
  float r, g, b, a;
  float shapeW, shapeH, radius;
};

struct UnitPoint {
  float x, y;
};

unsigned codepoint(const std::string &value, std::size_t &offset) {
  const auto first = static_cast<unsigned char>(value[offset++]);
  if (first < 128)
    return first;
  unsigned count = first < 224 ? 1 : first < 240 ? 2 : 3;
  unsigned result = first & ((1U << (6U - count)) - 1U);
  while (count--) {
    if (offset >= value.size())
      return '?';
    const auto c = static_cast<unsigned char>(value[offset]);
    if ((c & 192) != 128)
      return '?';
    ++offset;
    result = (result << 6) | (c & 63);
  }
  return result;
}

// Returns packed glyph index in [0, kGlyphCount), or -1 to skip (zero-width).
int glyphIndexFor(unsigned cp) {
  if (cp == 0x200B || cp == 0x200C || cp == 0x200D || cp == 0xFEFF)
    return -1;
  if (cp == 0x00A0 || cp == 0x202F || cp == 0x2009 || cp == 0x200A)
    return ' ' - kLatinStart;
  if (cp >= kLatinStart && cp < kLatinStart + kLatinCount)
    return static_cast<int>(cp) - kLatinStart;
  if (cp >= kPunctStart && cp < kPunctStart + kPunctCount)
    return kLatinCount + static_cast<int>(cp - kPunctStart);
  switch (cp) {
  case 0x2039: return '<' - kLatinStart;
  case 0x203A: return '>' - kLatinStart;
  case 0x2212: return '-' - kLatinStart;
  case 0x00B7: return 0x2022 - kPunctStart + kLatinCount;
  default: return '?' - kLatinStart;
  }
}

void pushQuad(std::vector<Vertex> &vertices, float x, float y, float w, float h,
              Color c, float u0 = 0, float v0 = 0, float u1 = 1, float v1 = 1,
              float shapeW = 0, float shapeH = 0, float radius = 0) {
  vertices.push_back({x, y, u0, v0, 0, 0, c.r, c.g, c.b, c.a, shapeW, shapeH, radius});
  vertices.push_back({x + w, y, u1, v0, 1, 0, c.r, c.g, c.b, c.a, shapeW, shapeH, radius});
  vertices.push_back({x + w, y + h, u1, v1, 1, 1, c.r, c.g, c.b, c.a, shapeW, shapeH, radius});
  vertices.push_back({x, y, u0, v0, 0, 0, c.r, c.g, c.b, c.a, shapeW, shapeH, radius});
  vertices.push_back({x + w, y + h, u1, v1, 1, 1, c.r, c.g, c.b, c.a, shapeW, shapeH, radius});
  vertices.push_back({x, y + h, u0, v1, 0, 1, c.r, c.g, c.b, c.a, shapeW, shapeH, radius});
}

// Unit-mesh tessellation helpers (evaluated once at Gfx init).
void unitTriangle(std::vector<UnitPoint> &v, float x1, float y1, float x2,
                  float y2, float x3, float y3) {
  v.push_back({x1, y1});
  v.push_back({x2, y2});
  v.push_back({x3, y3});
}
void unitPolygon(std::vector<UnitPoint> &v,
                 const std::vector<std::pair<float, float>> &points) {
  if (points.size() < 3)
    return;
  for (std::size_t i = 1; i + 1 < points.size(); ++i)
    unitTriangle(v, points[0].first, points[0].second, points[i].first,
                 points[i].second, points[i + 1].first, points[i + 1].second);
}
void unitSegment(std::vector<UnitPoint> &v, float x1, float y1, float x2,
                 float y2, float width) {
  const float dx = x2 - x1, dy = y2 - y1;
  const float length = std::hypot(dx, dy);
  if (length <= 0.0001F || width <= 0)
    return;
  const float nx = dy * width / (2 * length), ny = -dx * width / (2 * length);
  unitTriangle(v, x1 - nx, y1 - ny, x2 - nx, y2 - ny, x2 + nx, y2 + ny);
  unitTriangle(v, x1 - nx, y1 - ny, x2 + nx, y2 + ny, x1 + nx, y1 + ny);
}
void unitFilledRect(std::vector<UnitPoint> &v, float x, float y, float w,
                    float h) {
  unitPolygon(v, {{x, y}, {x + w, y}, {x + w, y + h}, {x, y + h}});
}
void unitDisc(std::vector<UnitPoint> &v, float cx, float cy, float radius,
              unsigned steps = 24) {
  if (radius <= 0)
    return;
  for (unsigned i = 0; i < steps; ++i) {
    const float a = 2 * Pi * static_cast<float>(i) / static_cast<float>(steps);
    const float b =
        2 * Pi * static_cast<float>(i + 1) / static_cast<float>(steps);
    unitTriangle(v, cx, cy, cx + std::cos(a) * radius,
                 cy + std::sin(a) * radius, cx + std::cos(b) * radius,
                 cy + std::sin(b) * radius);
  }
}
void unitCircle(std::vector<UnitPoint> &v, float cx, float cy, float radius,
                float width, unsigned steps = 32) {
  float x0 = cx + radius, y0 = cy;
  for (unsigned i = 1; i <= steps; ++i) {
    const float angle =
        2 * Pi * static_cast<float>(i) / static_cast<float>(steps);
    const float x1 = cx + std::cos(angle) * radius;
    const float y1 = cy + std::sin(angle) * radius;
    unitSegment(v, x0, y0, x1, y1, width);
    x0 = x1;
    y0 = y1;
  }
}
void unitOutline(std::vector<UnitPoint> &v, float x, float y, float w, float h,
                 float width) {
  unitSegment(v, x, y, x + w, y, width);
  unitSegment(v, x + w, y, x + w, y + h, width);
  unitSegment(v, x + w, y + h, x, y + h, width);
  unitSegment(v, x, y + h, x, y, width);
}
void unitArc(std::vector<UnitPoint> &v, float cx, float cy, float radius,
             float start, float end, float width, unsigned steps = 24) {
  float px = cx + std::cos(start) * radius;
  float py = cy + std::sin(start) * radius;
  for (unsigned i = 1; i <= steps; ++i) {
    const float angle = start + (end - start) * static_cast<float>(i) /
                                    static_cast<float>(steps);
    const float x = cx + std::cos(angle) * radius;
    const float y = cy + std::sin(angle) * radius;
    unitSegment(v, px, py, x, y, width);
    px = x;
    py = y;
  }
}
void unitRoundRect(std::vector<UnitPoint> &v, float x, float y, float w,
                   float h, float radius, float width) {
  radius = std::clamp(radius, 0.0F, std::min(w, h) / 2);
  const float pi2 = Pi / 2;
  unitArc(v, x + w - radius, y + radius, radius, -pi2, 0, width, 8);
  unitArc(v, x + w - radius, y + h - radius, radius, 0, pi2, width, 8);
  unitArc(v, x + radius, y + h - radius, radius, pi2, Pi, width, 8);
  unitArc(v, x + radius, y + radius, radius, Pi, 3 * pi2, width, 8);
  unitSegment(v, x + radius, y, x + w - radius, y, width);
  unitSegment(v, x + w, y + radius, x + w, y + h - radius, width);
  unitSegment(v, x + w - radius, y + h, x + radius, y + h, width);
  unitSegment(v, x, y + h - radius, x, y + radius, width);
}

std::vector<UnitPoint> buildIconMesh(Icon icon) {
  std::vector<UnitPoint> v;
  v.reserve(256);
  const float w = 0.075F;
  const float l = .17F, top = .17F, r = .83F, bottom = .83F;
  const float cx = .5F, cy = .5F;
  switch (icon) {
  case Icon::Live:
    unitRoundRect(v, l, top + .1F, .66F, .53F, .07F, w);
    unitSegment(v, cx, top, cx, top + .09F, w);
    unitSegment(v, cx, bottom - .18F, cx, bottom, w);
    unitSegment(v, .34F, bottom, .66F, bottom, w);
    unitPolygon(v, {{.44F, .38F}, {.44F, .62F}, {.63F, .5F}});
    break;
  case Icon::Movies:
    unitRoundRect(v, l, top + .13F, .66F, .55F, .04F, w);
    unitSegment(v, l, top + .3F, r, top + .3F, w);
    for (int i = 0; i < 4; ++i) {
      const float xx = .25F + .17F * i;
      unitSegment(v, xx, top + .06F, xx + .11F, top + .25F, w * .8F);
    }
    break;
  case Icon::Series:
    unitRoundRect(v, .25F, .19F, .57F, .47F, .04F, w);
    unitRoundRect(v, .18F, .27F, .57F, .47F, .04F, w);
    unitRoundRect(v, .11F, .35F, .57F, .47F, .04F, w);
    break;
  case Icon::Heart: {
    const float left = .5F, peak = .29F;
    const float radius = .19F;
    unitArc(v, left - radius, peak, radius, Pi, 2 * Pi, w, 16);
    unitArc(v, left + radius, peak, radius, Pi, 2 * Pi, w, 16);
    unitSegment(v, left - radius * 2, peak, left, .81F, w);
    unitSegment(v, left + radius * 2, peak, left, .81F, w);
    break;
  }
  case Icon::Settings:
    unitCircle(v, cx, cy, .3F, w, 32);
    unitCircle(v, cx, cy, .1F, w, 20);
    for (int i = 0; i < 8; ++i) {
      const float a = i * Pi / 4;
      unitSegment(v, cx + std::cos(a) * .32F, cy + std::sin(a) * .32F,
                  cx + std::cos(a) * .42F, cy + std::sin(a) * .42F, w * 1.15F);
    }
    break;
  case Icon::Search:
    unitCircle(v, .43F, .42F, .24F, w, 28);
    unitSegment(v, .6F, .6F, .82F, .82F, w * 1.2F);
    break;
  case Icon::Play:
    unitPolygon(v, {{.31F, .2F}, {.31F, .8F}, {.77F, cy}});
    break;
  case Icon::Pause:
    unitFilledRect(v, .27F, .2F, .16F, .6F);
    unitFilledRect(v, .57F, .2F, .16F, .6F);
    break;
  case Icon::Back:
    unitSegment(v, .76F, cy, .23F, cy, w * 1.1F);
    unitSegment(v, .23F, cy, .47F, .25F, w * 1.1F);
    unitSegment(v, .23F, cy, .47F, .75F, w * 1.1F);
    break;
  case Icon::ChevronLeft:
    unitSegment(v, .61F, .19F, .37F, cy, w * 1.15F);
    unitSegment(v, .37F, cy, .61F, .81F, w * 1.15F);
    break;
  case Icon::ChevronRight:
    unitSegment(v, .39F, .19F, .63F, cy, w * 1.15F);
    unitSegment(v, .63F, cy, .39F, .81F, w * 1.15F);
    break;
  case Icon::Volume:
    unitPolygon(v, {{.13F, .4F}, {.31F, .4F}, {.54F, .22F},
                    {.54F, .78F}, {.31F, .6F}, {.13F, .6F}});
    unitArc(v, .51F, cy, .2F, -Pi * .38F, Pi * .38F, w, 14);
    unitArc(v, .51F, cy, .33F, -Pi * .36F, Pi * .36F, w, 16);
    break;
  case Icon::Rewind:
    unitPolygon(v, {{.48F, .21F}, {.48F, .79F}, {.16F, cy}});
    unitPolygon(v, {{.82F, .21F}, {.82F, .79F}, {.5F, cy}});
    unitSegment(v, .12F, .2F, .12F, .8F, w);
    break;
  case Icon::Forward:
    unitPolygon(v, {{.52F, .21F}, {.52F, .79F}, {.84F, cy}});
    unitPolygon(v, {{.18F, .21F}, {.18F, .79F}, {.5F, cy}});
    unitSegment(v, .88F, .2F, .88F, .8F, w);
    break;
  case Icon::Refresh:
    unitArc(v, cx, cy, .3F, Pi * .19F, Pi * 1.83F, w, 28);
    unitPolygon(v, {{.68F, .16F}, {.84F, .2F}, {.7F, .35F}});
    break;
  case Icon::Dpad:
    unitRoundRect(v, .38F, .13F, .24F, .74F, .06F, w);
    unitRoundRect(v, .13F, .38F, .74F, .24F, .06F, w);
    break;
  }
  return v;
}

void unitGlyphLine(std::vector<UnitPoint> &v, float x, float y, float s,
                   char glyph, float width) {
  const float x0 = x, x1 = x + s, ym = y + s * .5F;
  if (glyph == '1') {
    unitSegment(v, x + s * .5F, y, x + s * .5F, y + s, width);
    unitSegment(v, x + s * .22F, y + s, x + s * .78F, y + s, width);
  } else if (glyph == '2') {
    unitSegment(v, x + s * .18F, y, x + s * .82F, y, width);
    unitSegment(v, x + s * .82F, y, x + s * .82F, ym, width);
    unitSegment(v, x + s * .82F, ym, x + s * .18F, ym, width);
    unitSegment(v, x + s * .18F, ym, x + s * .18F, y + s, width);
    unitSegment(v, x + s * .18F, y + s, x + s * .82F, y + s, width);
  } else if (glyph == 'L') {
    unitSegment(v, x0, y, x0, y + s, width);
    unitSegment(v, x0, y + s, x1, y + s, width);
  } else if (glyph == 'R') {
    unitSegment(v, x0, y + s, x0, y, width);
    unitSegment(v, x0, y, x + s * .62F, y, width);
    unitSegment(v, x + s * .62F, y, x1, y + s * .2F, width);
    unitSegment(v, x1, y + s * .2F, x + s * .62F, ym, width);
    unitSegment(v, x + s * .62F, ym, x1, y + s, width);
  }
}

bool isFaceButton(Button button) {
  return button == Button::Cross || button == Button::Circle ||
         button == Button::Square || button == Button::Triangle;
}

Color faceButtonColor(Button button) {
  switch (button) {
  case Button::Cross: return {.21F, .69F, .98F, 1};
  case Button::Circle: return {.98F, .34F, .35F, 1};
  case Button::Square: return {1.0F, .47F, .69F, 1};
  case Button::Triangle: return {.33F, .88F, .56F, 1};
  default: return {1, 1, 1, 1};
  }
}

struct ButtonMesh {
  std::vector<UnitPoint> bg;
  std::vector<UnitPoint> fg;
};

ButtonMesh buildButtonMesh(Button button) {
  ButtonMesh mesh;
  const float cx = .5F, cy = .5F;
  const float w = 0.075F;
  if (isFaceButton(button)) {
    unitDisc(mesh.bg, cx, cy, .47F, 32);
    unitCircle(mesh.fg, cx, cy, .44F, 0.035F, 32);
    const float gx = cx - .2F, gy = cy - .2F, gs = .4F;
    switch (button) {
    case Button::Cross:
      unitSegment(mesh.fg, gx + gs * .12F, gy + gs * .12F, gx + gs * .88F,
                  gy + gs * .88F, w * 1.25F);
      unitSegment(mesh.fg, gx + gs * .88F, gy + gs * .12F, gx + gs * .12F,
                  gy + gs * .88F, w * 1.25F);
      break;
    case Button::Circle:
      unitCircle(mesh.fg, cx, cy, .2F, w * 1.15F, 28);
      break;
    case Button::Square:
      unitOutline(mesh.fg, cx - .18F, cy - .18F, .36F, .36F, w * 1.1F);
      break;
    case Button::Triangle:
      unitSegment(mesh.fg, cx, cy - .22F, cx + .2F, cy + .17F, w * 1.1F);
      unitSegment(mesh.fg, cx + .2F, cy + .17F, cx - .2F, cy + .17F, w * 1.1F);
      unitSegment(mesh.fg, cx - .2F, cy + .17F, cx, cy - .22F, w * 1.1F);
      break;
    default:
      break;
    }
    return mesh;
  }

  const float px = .08F, py = .27F, pw = .84F, ph = .46F;
  unitRoundRect(mesh.fg, px, py, pw, ph, ph * .38F, w);
  if (button == Button::Options) {
    for (int i = 0; i < 3; ++i)
      unitDisc(mesh.fg, .35F + .15F * i, cy, .045F, 10);
  } else {
    const bool left = button == Button::L1 || button == Button::L2;
    const bool trigger = button == Button::L2 || button == Button::R2;
    unitGlyphLine(mesh.fg, left ? .24F : .46F, .38F, .19F, left ? 'L' : 'R',
                  w * .8F);
    unitGlyphLine(mesh.fg, left ? .56F : .68F, .4F, .18F, trigger ? '2' : '1',
                  w * .8F);
  }
  return mesh;
}

// Computes row-major 3x3 YUV->RGB conversion matrix and input offset for
// ITU-R BT.601 (0), BT.709 (1), or BT.2020 (2), limited or full range.
void yuvMatrixAndOffset(int colorSpace, bool fullRange,
                        std::array<float, 9> &rowMajorMat,
                        std::array<float, 3> &offset) {
  float kr = 0.2126F, kb = 0.0722F; // BT.709 default
  if (colorSpace == 0) {
    kr = 0.299F;
    kb = 0.114F; // BT.601
  } else if (colorSpace == 2) {
    kr = 0.2627F;
    kb = 0.0593F; // BT.2020
  }
  const float kg = 1.0F - kr - kb;
  const float yScale = fullRange ? 1.0F : (255.0F / 219.0F);
  const float uvScale = fullRange ? 1.0F : (255.0F / 224.0F);
  offset = {fullRange ? 0.0F : (-16.0F / 255.0F), -128.0F / 255.0F,
            -128.0F / 255.0F};
  const float rv = 2.0F * (1.0F - kr) * uvScale;
  const float gu = -2.0F * kb * (1.0F - kb) / kg * uvScale;
  const float gv = -2.0F * kr * (1.0F - kr) / kg * uvScale;
  const float bu = 2.0F * (1.0F - kb) * uvScale;
  rowMajorMat = {
      yScale, 0.0F, rv,
      yScale, gu,   gv,
      yScale, bu,   0.0F,
  };
}
} // namespace

struct Gfx::Impl {
  struct CachedImage {
    GLuint texture{};
    int width{}, height{};
    std::list<std::string>::iterator lruIt;
  };
  GLuint program{}, vao{}, vbo{}, font{};
  GLuint videoTexture{}, videoY{}, videoU{}, videoV{};
  GLint uMode{-1}, uTex{-1}, uTexU{-1}, uTexV{-1}, uYuvMatrix{-1}, uYuvOffset{-1};
  int pixelWidth{}, pixelHeight{};
  int videoWidth{}, videoHeight{}, videoDisplayWidth{}, videoDisplayHeight{};
  int videoYuvWidth{}, videoYuvHeight{};
  int videoColorSpace{1};
  bool videoFullRange{false};
  bool videoIsYuv{false};
  float ascent{50};
  float dotsWidth64{0};
  std::array<stbtt_packedchar, kGlyphCount> chars{};
  std::array<std::vector<UnitPoint>, 16> iconMeshes;
  std::array<ButtonMesh, 9> buttonMeshes;
  std::unordered_map<std::string, CachedImage> images;
  std::list<std::string> imageLru;
  std::size_t imageBytes{};

  // Persistent per-frame batch state
  std::vector<Vertex> batch;
  std::size_t vboCapacityBytes{0};
  int batchMode{-1};
  GLuint batchTexture{0};

  void flushBatch() {
    if (batch.empty())
      return;
    glUniform1i(uMode, batchMode);
    if (batchTexture != 0) {
      glActiveTexture(GL_TEXTURE0);
      glBindTexture(GL_TEXTURE_2D, batchTexture);
    }
    const std::size_t bytes = batch.size() * sizeof(Vertex);
    glBindVertexArray(vao);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    if (bytes > vboCapacityBytes) {
      vboCapacityBytes = std::max(bytes, std::max<std::size_t>(vboCapacityBytes * 2, 65536));
      glBufferData(GL_ARRAY_BUFFER, static_cast<GLsizeiptr>(vboCapacityBytes),
                   nullptr, GL_STREAM_DRAW);
    } else {
      // Orphan buffer before sub-upload to prevent implicit pipeline stalls.
      glBufferData(GL_ARRAY_BUFFER, static_cast<GLsizeiptr>(vboCapacityBytes),
                   nullptr, GL_STREAM_DRAW);
    }
    glBufferSubData(GL_ARRAY_BUFFER, 0, static_cast<GLsizeiptr>(bytes), batch.data());
    glDrawArrays(GL_TRIANGLES, 0, static_cast<GLsizei>(batch.size()));
    batch.clear();
  }

  void prepareBatch(int mode, GLuint texture) {
    if (!batch.empty() && (batchMode != mode || batchTexture != texture)) {
      flushBatch();
    }
    batchMode = mode;
    batchTexture = texture;
  }

  void appendUnitMesh(const std::vector<UnitPoint> &mesh, float x, float y,
                      float size, Color tint) {
    prepareBatch(0, 0);
    batch.reserve(batch.size() + mesh.size());
    for (const auto &pt : mesh) {
      batch.push_back({x + pt.x * size, y + pt.y * size, 0, 0, 0, 0, tint.r,
                       tint.g, tint.b, tint.a, 0, 0, 0});
    }
  }
};

Gfx::Gfx(const std::string &fontFile) : impl_(std::make_unique<Impl>()) {
  const char *vertex = R"(#version 330 core
layout(location=0) in vec2 position;
layout(location=1) in vec2 texcoord;
layout(location=2) in vec2 maskcoord;
layout(location=3) in vec4 vertColor;
layout(location=4) in vec3 shapeParams;
out vec2 uv;
out vec2 shapeUv;
out vec4 vColor;
out vec3 vShape;
void main(){
  uv=texcoord;
  shapeUv=maskcoord;
  vColor=vertColor;
  vShape=shapeParams;
  gl_Position=vec4(position.x/960.0-1.0,1.0-position.y/540.0,0,1);
}
)";
  const char *fragment = R"(#version 330 core
in vec2 uv;
in vec2 shapeUv;
in vec4 vColor;
in vec3 vShape;
out vec4 frag;
uniform sampler2D tex;
uniform sampler2D texU;
uniform sampler2D texV;
uniform int mode;
uniform mat3 yuvMatrix;
uniform vec3 yuvOffset;
void main(){
 if(mode==1){
   frag=vec4(vColor.rgb,vColor.a*texture(tex,uv).r);
 } else if(mode==2){
   frag=texture(tex,uv)*vColor;
 } else if(mode==3){
   vec2 s=vShape.xy;
   float rad=vShape.z;
   vec2 q=abs((shapeUv-0.5)*s)-(s*0.5-rad);
   float d=length(max(q,0.0))+min(max(q.x,q.y),0.0)-rad;
   vec4 sampleColor=texture(tex,uv);
   frag=vec4(sampleColor.rgb*vColor.rgb,sampleColor.a*vColor.a*(1.0-smoothstep(-0.65,0.65,d)));
 } else if(mode==5){
   float y=texture(tex,uv).r;
   float u=texture(texU,uv).r;
   float v=texture(texV,uv).r;
   vec3 rgb=yuvMatrix*(vec3(y,u,v)+yuvOffset);
   frag=vec4(clamp(rgb,0.0,1.0),1.0);
 } else {
   if(vShape.x>0.0){
     vec2 s=vShape.xy;
     float rad=vShape.z;
     vec2 q=abs((uv-0.5)*s)-(s*0.5-rad);
     float d=length(max(q,0.0))+min(max(q.x,q.y),0.0)-rad;
     frag=vec4(vColor.rgb,vColor.a*(1.0-smoothstep(-0.65,0.65,d)));
   } else {
     frag=vColor;
   }
 }
}
)";
  GLuint vs = shader(GL_VERTEX_SHADER, vertex),
         fs = shader(GL_FRAGMENT_SHADER, fragment);
  auto &p = *impl_;
  p.program = glCreateProgram();
  glAttachShader(p.program, vs);
  glAttachShader(p.program, fs);
  glLinkProgram(p.program);
  glDeleteShader(vs);
  glDeleteShader(fs);
  GLint ok = 0;
  glGetProgramiv(p.program, GL_LINK_STATUS, &ok);
  if (!ok)
    throw std::runtime_error("OpenGL shader program could not link");

  p.uMode = glGetUniformLocation(p.program, "mode");
  p.uTex = glGetUniformLocation(p.program, "tex");
  p.uTexU = glGetUniformLocation(p.program, "texU");
  p.uTexV = glGetUniformLocation(p.program, "texV");
  p.uYuvMatrix = glGetUniformLocation(p.program, "yuvMatrix");
  p.uYuvOffset = glGetUniformLocation(p.program, "yuvOffset");

  glUseProgram(p.program);
  glUniform1i(p.uTex, 0);
  glUniform1i(p.uTexU, 1);
  glUniform1i(p.uTexV, 2);

  glGenVertexArrays(1, &p.vao);
  glBindVertexArray(p.vao);
  glGenBuffers(1, &p.vbo);
  glBindBuffer(GL_ARRAY_BUFFER, p.vbo);
  glEnableVertexAttribArray(0);
  glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                        reinterpret_cast<void *>(offsetof(Vertex, x)));
  glEnableVertexAttribArray(1);
  glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                        reinterpret_cast<void *>(offsetof(Vertex, u)));
  glEnableVertexAttribArray(2);
  glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                        reinterpret_cast<void *>(offsetof(Vertex, shapeU)));
  glEnableVertexAttribArray(3);
  glVertexAttribPointer(3, 4, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                        reinterpret_cast<void *>(offsetof(Vertex, r)));
  glEnableVertexAttribArray(4);
  glVertexAttribPointer(4, 3, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                        reinterpret_cast<void *>(offsetof(Vertex, shapeW)));
  p.batch.reserve(8192);

  // Pre-tessellate icon and DualSense button unit meshes once at init.
  for (std::size_t i = 0; i < p.iconMeshes.size(); ++i)
    p.iconMeshes[i] = buildIconMesh(static_cast<Icon>(i));
  for (std::size_t i = 0; i < p.buttonMeshes.size(); ++i)
    p.buttonMeshes[i] = buildButtonMesh(static_cast<Button>(i));

  std::ifstream file(fontFile, std::ios::binary | std::ios::ate);
  if (!file || file.tellg() <= 0 || file.tellg() > 16 * 1024 * 1024)
    throw std::runtime_error("BruTV font asset is missing or invalid");
  std::vector<unsigned char> data(static_cast<std::size_t>(file.tellg()));
  file.seekg(0);
  file.read(reinterpret_cast<char *>(data.data()),
            static_cast<std::streamsize>(data.size()));
  stbtt_fontinfo info{};
  if (!stbtt_InitFont(&info, data.data(), 0))
    throw std::runtime_error("BruTV font could not be loaded");
  int ascent = 0;
  stbtt_GetFontVMetrics(&info, &ascent, nullptr, nullptr);
  p.ascent = ascent * stbtt_ScaleForPixelHeight(&info, 64);

  std::vector<unsigned char> bitmap(static_cast<std::size_t>(kAtlasSize) *
                                    kAtlasSize);
  stbtt_pack_context pack{};
  if (!stbtt_PackBegin(&pack, bitmap.data(), kAtlasSize, kAtlasSize, 0, 1,
                       nullptr))
    throw std::runtime_error("BruTV font packer could not initialize");
  stbtt_PackSetOversampling(&pack, 1, 1);
  std::array<stbtt_pack_range, 2> ranges{};
  ranges[0].font_size = 64.0F;
  ranges[0].first_unicode_codepoint_in_range = kLatinStart;
  ranges[0].num_chars = kLatinCount;
  ranges[0].chardata_for_range = p.chars.data();
  ranges[1].font_size = 64.0F;
  ranges[1].first_unicode_codepoint_in_range = kPunctStart;
  ranges[1].num_chars = kPunctCount;
  ranges[1].chardata_for_range = p.chars.data() + kLatinCount;
  const int packed = stbtt_PackFontRanges(&pack, data.data(), 0, ranges.data(),
                                          static_cast<int>(ranges.size()));
  stbtt_PackEnd(&pack);
  if (!packed)
    throw std::runtime_error("BruTV font atlas could not be built");
  p.dotsWidth64 = p.chars['.' - kLatinStart].xadvance * 3.0F;

  glGenTextures(1, &p.font);
  glBindTexture(GL_TEXTURE_2D, p.font);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, kAtlasSize, kAtlasSize, 0, GL_RED,
               GL_UNSIGNED_BYTE, bitmap.data());
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

  auto initVideoTex = [](GLuint &tex) {
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  };
  initVideoTex(p.videoTexture);
  initVideoTex(p.videoY);
  initVideoTex(p.videoU);
  initVideoTex(p.videoV);
}

Gfx::~Gfx() {
  auto &p = *impl_;
  for (const auto &entry : p.images)
    glDeleteTextures(1, &entry.second.texture);
  glDeleteTextures(1, &p.font);
  glDeleteTextures(1, &p.videoTexture);
  glDeleteTextures(1, &p.videoY);
  glDeleteTextures(1, &p.videoU);
  glDeleteTextures(1, &p.videoV);
  glDeleteBuffers(1, &p.vbo);
  glDeleteVertexArrays(1, &p.vao);
  glDeleteProgram(p.program);
}

void Gfx::begin(int width, int height) {
  auto &p = *impl_;
  p.pixelWidth = width;
  p.pixelHeight = height;
  p.batch.clear();
  p.batchMode = -1;
  p.batchTexture = 0;
  glViewport(0, 0, width, height);
  glClearColor(.025F, .035F, .065F, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  glDisable(GL_DEPTH_TEST);
  glEnable(GL_BLEND);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  glUseProgram(p.program);
  glActiveTexture(GL_TEXTURE0);
}

void Gfx::rect(float x, float y, float w, float h, Color c, float r) {
  if (w <= 0 || h <= 0)
    return;
  auto &p = *impl_;
  p.prepareBatch(0, 0);
  const float rad = std::clamp(r, 0.0F, std::min(w, h) * 0.5F);
  pushQuad(p.batch, x, y, w, h, c, 0, 0, 1, 1, rad > 0.0F ? w : 0.0F,
           rad > 0.0F ? h : 0.0F, rad);
}

float Gfx::textWidth(const std::string &value, float size) const {
  float x = 0;
  const float scale = size / 64.0F;
  for (std::size_t i = 0; i < value.size();) {
    const int idx = glyphIndexFor(codepoint(value, i));
    if (idx >= 0)
      x += impl_->chars[static_cast<std::size_t>(idx)].xadvance;
  }
  return x * scale;
}

void Gfx::text(const std::string &value, float x, float y, float size, Color c,
               float maxWidth) {
  if (value.empty())
    return;
  auto &p = *impl_;
  const float scale = size / 64.0F;
  bool clipped = false;
  float limit64 = 0.0F;
  if (maxWidth > 0.0F) {
    const float max64 = maxWidth / scale;
    float total64 = 0.0F;
    for (std::size_t i = 0; i < value.size();) {
      const int idx = glyphIndexFor(codepoint(value, i));
      if (idx >= 0) {
        total64 += p.chars[static_cast<std::size_t>(idx)].xadvance;
        if (total64 > max64) {
          clipped = true;
          break;
        }
      }
    }
    limit64 = std::max(0.0F, max64 - p.dotsWidth64);
  }
  p.prepareBatch(1, p.font);
  float px = 0.0F, py = 0.0F;
  for (std::size_t i = 0; i < value.size();) {
    const int idx = glyphIndexFor(codepoint(value, i));
    if (idx < 0)
      continue;
    if (clipped && px + p.chars[static_cast<std::size_t>(idx)].xadvance > limit64) {
      for (int n = 0; n < 3; ++n) {
        stbtt_aligned_quad q;
        stbtt_GetPackedQuad(p.chars.data(), kAtlasSize, kAtlasSize,
                            '.' - kLatinStart, &px, &py, &q, 1);
        pushQuad(p.batch, x + q.x0 * scale, y + (p.ascent + q.y0) * scale,
                 (q.x1 - q.x0) * scale, (q.y1 - q.y0) * scale, c, q.s0, q.t0,
                 q.s1, q.t1);
      }
      break;
    }
    stbtt_aligned_quad q;
    stbtt_GetPackedQuad(p.chars.data(), kAtlasSize, kAtlasSize, idx, &px, &py,
                        &q, 1);
    pushQuad(p.batch, x + q.x0 * scale, y + (p.ascent + q.y0) * scale,
             (q.x1 - q.x0) * scale, (q.y1 - q.y0) * scale, c, q.s0, q.t0, q.s1,
             q.t1);
  }
}

void Gfx::video(const std::uint8_t *pixels, int width, int height) {
  if (!pixels || width <= 0 || height <= 0 || width > 4096 || height > 4096)
    return;
  auto &p = *impl_;
  p.flushBatch();
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, p.videoTexture);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  if (width != p.videoWidth || height != p.videoHeight || p.videoIsYuv) {
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, pixels);
    p.videoWidth = width;
    p.videoHeight = height;
  } else {
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RGBA,
                    GL_UNSIGNED_BYTE, pixels);
  }
  p.videoDisplayWidth = width;
  p.videoDisplayHeight = height;
  p.videoIsYuv = false;
}

void Gfx::videoYuv(const std::uint8_t *y, const std::uint8_t *u,
                   const std::uint8_t *v, int width, int height,
                   int displayWidth, int displayHeight, int colorSpace,
                   bool fullRange) {
  if (!y || !u || !v || width <= 0 || height <= 0 || width > 4096 ||
      height > 4096 || (width & 1) != 0 || (height & 1) != 0)
    return;
  auto &p = *impl_;
  p.flushBatch();
  const int cw = width / 2;
  const int ch = height / 2;
  const bool realloc = (width != p.videoYuvWidth || height != p.videoYuvHeight);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, p.videoY);
  if (realloc)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, width, height, 0, GL_RED,
                 GL_UNSIGNED_BYTE, y);
  else
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RED,
                    GL_UNSIGNED_BYTE, y);

  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D, p.videoU);
  if (realloc)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, cw, ch, 0, GL_RED, GL_UNSIGNED_BYTE,
                 u);
  else
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, cw, ch, GL_RED, GL_UNSIGNED_BYTE,
                    u);

  glActiveTexture(GL_TEXTURE2);
  glBindTexture(GL_TEXTURE_2D, p.videoV);
  if (realloc)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, cw, ch, 0, GL_RED, GL_UNSIGNED_BYTE,
                 v);
  else
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, cw, ch, GL_RED, GL_UNSIGNED_BYTE,
                    v);

  glActiveTexture(GL_TEXTURE0);
  p.videoYuvWidth = width;
  p.videoYuvHeight = height;
  p.videoDisplayWidth = displayWidth > 0 ? displayWidth : width;
  p.videoDisplayHeight = displayHeight > 0 ? displayHeight : height;
  p.videoColorSpace = colorSpace;
  p.videoFullRange = fullRange;
  p.videoIsYuv = true;
}

void Gfx::drawVideo(float x, float y, float width, float height) {
  auto &p = *impl_;
  if (!p.videoDisplayWidth || !p.videoDisplayHeight)
    return;
  const float scale =
      std::min(width / p.videoDisplayWidth, height / p.videoDisplayHeight);
  const float w = p.videoDisplayWidth * scale;
  const float h = p.videoDisplayHeight * scale;
  const float drawX = x + (width - w) * 0.5F;
  const float drawY = y + (height - h) * 0.5F;
  if (p.videoIsYuv) {
    p.flushBatch();
    std::array<float, 9> mat{};
    std::array<float, 3> off{};
    yuvMatrixAndOffset(p.videoColorSpace, p.videoFullRange, mat, off);
    glUniformMatrix3fv(p.uYuvMatrix, 1, GL_TRUE, mat.data());
    glUniform3fv(p.uYuvOffset, 1, off.data());
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, p.videoU);
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, p.videoV);
    glActiveTexture(GL_TEXTURE0);
    p.prepareBatch(5, p.videoY);
    pushQuad(p.batch, drawX, drawY, w, h, {1, 1, 1, 1});
    p.flushBatch();
  } else {
    p.prepareBatch(2, p.videoTexture);
    pushQuad(p.batch, drawX, drawY, w, h, {1, 1, 1, 1});
  }
}

void Gfx::icon(Icon value, float x, float y, float size, Color tint) {
  if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(size) ||
      size <= 0 || size > 4096)
    return;
  const auto index = static_cast<std::size_t>(value);
  if (index >= impl_->iconMeshes.size())
    return;
  impl_->appendUnitMesh(impl_->iconMeshes[index], x, y, size, tint);
}

void Gfx::button(Button value, float x, float y, float size, Color tint) {
  if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(size) ||
      size <= 0 || size > 4096)
    return;
  const auto index = static_cast<std::size_t>(value);
  if (index >= impl_->buttonMeshes.size())
    return;
  auto &p = *impl_;
  const auto &mesh = p.buttonMeshes[index];
  if (isFaceButton(value)) {
    p.appendUnitMesh(mesh.bg, x, y, size, {.035F, .055F, .095F, tint.a});
    Color face = faceButtonColor(value);
    face.a = tint.a;
    p.appendUnitMesh(mesh.fg, x, y, size, face);
    return;
  }
  p.appendUnitMesh(mesh.fg, x, y, size, tint);
}

bool Gfx::hasImage(const std::string &key) const {
  if (key.empty())
    return false;
  return impl_->images.find(key) != impl_->images.end();
}

void Gfx::image(const std::string &key, const std::uint8_t *rgba,
                int imageWidth, int imageHeight, float x, float y, float width,
                float height, bool cover, float radius) {
  if (key.empty() || key.size() > 8192 || !std::isfinite(x) ||
      !std::isfinite(y) || !std::isfinite(width) || !std::isfinite(height) ||
      !std::isfinite(radius) || width <= 0 || height <= 0 || width > 8192 ||
      height > 8192)
    return;

  auto &p = *impl_;
  auto found = p.images.find(key);
  if (found == p.images.end()) {
    if (!rgba || imageWidth <= 0 || imageHeight <= 0 || imageWidth > 512 ||
        imageHeight > 512)
      return;
    const std::size_t bytes = static_cast<std::size_t>(imageWidth) *
                              static_cast<std::size_t>(imageHeight) * 4;
    constexpr std::size_t maxBytes = 16U * 1024U * 1024U;
    if (bytes > maxBytes)
      return;

    p.flushBatch();
    while (!p.imageLru.empty() &&
           (p.images.size() >= 64 || p.imageBytes + bytes > maxBytes)) {
      const auto oldestIt = p.images.find(p.imageLru.back());
      p.imageLru.pop_back();
      if (oldestIt != p.images.end()) {
        glDeleteTextures(1, &oldestIt->second.texture);
        p.imageBytes -= static_cast<std::size_t>(oldestIt->second.width) *
                        static_cast<std::size_t>(oldestIt->second.height) * 4;
        p.images.erase(oldestIt);
      }
    }

    GLuint texture = 0;
    glGenTextures(1, &texture);
    if (!texture)
      return;
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, imageWidth, imageHeight, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    p.imageLru.push_front(key);
    Impl::CachedImage entry{texture, imageWidth, imageHeight, p.imageLru.begin()};
    found = p.images.emplace(key, entry).first;
    p.imageBytes += bytes;
  } else {
    p.imageLru.splice(p.imageLru.begin(), p.imageLru, found->second.lruIt);
  }

  const auto &entry = found->second;
  float drawX = x, drawY = y, drawWidth = width, drawHeight = height;
  float u0 = 0, v0 = 0, u1 = 1, v1 = 1;
  if (cover) {
    const float sourceAspect = static_cast<float>(entry.width) / entry.height;
    const float targetAspect = width / height;
    if (sourceAspect > targetAspect) {
      const float fraction = targetAspect / sourceAspect;
      u0 = (1 - fraction) * .5F;
      u1 = 1 - u0;
    } else if (sourceAspect < targetAspect) {
      const float fraction = sourceAspect / targetAspect;
      v0 = (1 - fraction) * .5F;
      v1 = 1 - v0;
    }
  } else {
    const float scale = std::min(width / entry.width, height / entry.height);
    drawWidth = entry.width * scale;
    drawHeight = entry.height * scale;
    drawX += (width - drawWidth) * .5F;
    drawY += (height - drawHeight) * .5F;
  }

  radius = std::clamp(radius, 0.0F, std::min(drawWidth, drawHeight) * .5F);
  p.prepareBatch(radius > 0.0F ? 3 : 2, entry.texture);
  pushQuad(p.batch, drawX, drawY, drawWidth, drawHeight, {1, 1, 1, 1}, u0, v0,
           u1, v1, drawWidth, drawHeight, radius);
}

void Gfx::end() {
  impl_->flushBatch();
  glBindVertexArray(0);
}

void Gfx::screenshot(const std::string &filename) {
  auto &p = *impl_;
  p.flushBatch();
  if (p.pixelWidth <= 0 || p.pixelHeight <= 0 || p.pixelWidth > 8192 ||
      p.pixelHeight > 8192)
    throw std::runtime_error("Invalid screenshot size");
  std::vector<unsigned char> pixels(static_cast<std::size_t>(p.pixelWidth) *
                                    p.pixelHeight * 4);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, p.pixelWidth, p.pixelHeight, GL_RGBA, GL_UNSIGNED_BYTE,
               pixels.data());
  stbi_flip_vertically_on_write(1);
  if (!stbi_write_png(filename.c_str(), p.pixelWidth, p.pixelHeight, 4,
                      pixels.data(), p.pixelWidth * 4))
    throw std::runtime_error("Screenshot could not be written");
}
} // namespace brutv
