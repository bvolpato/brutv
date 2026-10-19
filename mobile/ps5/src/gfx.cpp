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
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <unordered_map>
#include <utility>
#include <vector>

namespace brutv {
namespace {
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
  float x, y, u, v, shapeU, shapeV;
};
constexpr float Pi = 3.14159265358979323846F;
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
void quad(std::vector<Vertex> &vertices, float x, float y, float w, float h,
          float u0 = 0, float v0 = 0, float u1 = 1, float v1 = 1) {
  vertices.insert(vertices.end(), {{x, y, u0, v0, 0, 0},
                                   {x + w, y, u1, v0, 1, 0},
                                   {x + w, y + h, u1, v1, 1, 1},
                                   {x, y, u0, v0, 0, 0},
                                   {x + w, y + h, u1, v1, 1, 1},
                                   {x, y + h, u0, v1, 0, 1}});
}
void triangle(std::vector<Vertex> &vertices, float x1, float y1, float x2,
              float y2, float x3, float y3) {
  vertices.insert(
      vertices.end(),
      {{x1, y1, 0, 0, 0, 0}, {x2, y2, 0, 0, 0, 0}, {x3, y3, 0, 0, 0, 0}});
}
void polygon(std::vector<Vertex> &vertices,
             const std::vector<std::pair<float, float>> &points) {
  if (points.size() < 3)
    return;
  for (std::size_t i = 1; i + 1 < points.size(); ++i)
    triangle(vertices, points[0].first, points[0].second, points[i].first,
             points[i].second, points[i + 1].first, points[i + 1].second);
}
void segment(std::vector<Vertex> &vertices, float x1, float y1, float x2,
             float y2, float width) {
  const float dx = x2 - x1, dy = y2 - y1;
  const float length = std::hypot(dx, dy);
  if (length <= 0.001F || width <= 0)
    return;
  const float nx = dy * width / (2 * length), ny = -dx * width / (2 * length);
  triangle(vertices, x1 - nx, y1 - ny, x2 - nx, y2 - ny, x2 + nx, y2 + ny);
  triangle(vertices, x1 - nx, y1 - ny, x2 + nx, y2 + ny, x1 + nx, y1 + ny);
}
void filledRect(std::vector<Vertex> &vertices, float x, float y, float w,
                float h) {
  polygon(vertices, {{x, y}, {x + w, y}, {x + w, y + h}, {x, y + h}});
}
void disc(std::vector<Vertex> &vertices, float cx, float cy, float radius,
          unsigned steps = 24) {
  if (radius <= 0)
    return;
  for (unsigned i = 0; i < steps; ++i) {
    const float a = 2 * Pi * static_cast<float>(i) / static_cast<float>(steps);
    const float b =
        2 * Pi * static_cast<float>(i + 1) / static_cast<float>(steps);
    triangle(vertices, cx, cy, cx + std::cos(a) * radius,
             cy + std::sin(a) * radius, cx + std::cos(b) * radius,
             cy + std::sin(b) * radius);
  }
}
void circle(std::vector<Vertex> &vertices, float cx, float cy, float radius,
            float width, unsigned steps = 32) {
  float x0 = cx + radius, y0 = cy;
  for (unsigned i = 1; i <= steps; ++i) {
    const float angle =
        2 * Pi * static_cast<float>(i) / static_cast<float>(steps);
    const float x1 = cx + std::cos(angle) * radius;
    const float y1 = cy + std::sin(angle) * radius;
    segment(vertices, x0, y0, x1, y1, width);
    x0 = x1;
    y0 = y1;
  }
}
void outline(std::vector<Vertex> &vertices, float x, float y, float w, float h,
             float width) {
  segment(vertices, x, y, x + w, y, width);
  segment(vertices, x + w, y, x + w, y + h, width);
  segment(vertices, x + w, y + h, x, y + h, width);
  segment(vertices, x, y + h, x, y, width);
}
void arc(std::vector<Vertex> &vertices, float cx, float cy, float radius,
         float start, float end, float width, unsigned steps = 24) {
  float px = cx + std::cos(start) * radius;
  float py = cy + std::sin(start) * radius;
  for (unsigned i = 1; i <= steps; ++i) {
    const float angle = start + (end - start) * static_cast<float>(i) /
                                    static_cast<float>(steps);
    const float x = cx + std::cos(angle) * radius;
    const float y = cy + std::sin(angle) * radius;
    segment(vertices, px, py, x, y, width);
    px = x;
    py = y;
  }
}
void roundRect(std::vector<Vertex> &vertices, float x, float y, float w,
               float h, float radius, float width) {
  radius = std::clamp(radius, 0.0F, std::min(w, h) / 2);
  const float pi2 = Pi / 2;
  arc(vertices, x + w - radius, y + radius, radius, -pi2, 0, width, 8);
  arc(vertices, x + w - radius, y + h - radius, radius, 0, pi2, width, 8);
  arc(vertices, x + radius, y + h - radius, radius, pi2, Pi, width, 8);
  arc(vertices, x + radius, y + radius, radius, Pi, 3 * pi2, width, 8);
  segment(vertices, x + radius, y, x + w - radius, y, width);
  segment(vertices, x + w, y + radius, x + w, y + h - radius, width);
  segment(vertices, x + w - radius, y + h, x + radius, y + h, width);
  segment(vertices, x, y + h - radius, x, y + radius, width);
}
void addIcon(std::vector<Vertex> &v, Icon icon, float x, float y, float s) {
  const float w = std::max(1.5F, s * .075F);
  const float l = x + s * .17F, top = y + s * .17F, r = x + s * .83F,
              bottom = y + s * .83F;
  const float cx = x + s * .5F, cy = y + s * .5F;
  switch (icon) {
  case Icon::Live:
    roundRect(v, l, top + s * .1F, s * .66F, s * .53F, s * .07F, w);
    segment(v, cx, top, cx, top + s * .09F, w);
    segment(v, cx, bottom - s * .18F, cx, bottom, w);
    segment(v, x + s * .34F, bottom, x + s * .66F, bottom, w);
    polygon(v, {{x + s * .44F, y + s * .38F},
                {x + s * .44F, y + s * .62F},
                {x + s * .63F, y + s * .5F}});
    break;
  case Icon::Movies:
    roundRect(v, l, top + s * .13F, s * .66F, s * .55F, s * .04F, w);
    segment(v, l, top + s * .3F, r, top + s * .3F, w);
    for (int i = 0; i < 4; ++i) {
      const float xx = x + s * (.25F + .17F * i);
      segment(v, xx, top + s * .06F, xx + s * .11F, top + s * .25F, w * .8F);
    }
    break;
  case Icon::Series:
    roundRect(v, x + s * .25F, y + s * .19F, s * .57F, s * .47F, s * .04F, w);
    roundRect(v, x + s * .18F, y + s * .27F, s * .57F, s * .47F, s * .04F, w);
    roundRect(v, x + s * .11F, y + s * .35F, s * .57F, s * .47F, s * .04F, w);
    break;
  case Icon::Heart: {
    const float left = x + s * .5F, peak = y + s * .29F;
    const float radius = s * .19F;
    arc(v, left - radius, peak, radius, Pi, 2 * Pi, w, 16);
    arc(v, left + radius, peak, radius, Pi, 2 * Pi, w, 16);
    const float startX = left - radius * 2, startY = peak;
    const float endX = left + radius * 2, endY = peak;
    segment(v, startX, startY, left, y + s * .81F, w);
    segment(v, endX, endY, left, y + s * .81F, w);
    break;
  }
  case Icon::Settings:
    circle(v, cx, cy, s * .3F, w, 40);
    circle(v, cx, cy, s * .1F, w, 24);
    for (int i = 0; i < 8; ++i) {
      const float a = i * Pi / 4;
      const float ix = cx + std::cos(a) * s * .32F;
      const float iy = cy + std::sin(a) * s * .32F;
      const float ox = cx + std::cos(a) * s * .42F;
      const float oy = cy + std::sin(a) * s * .42F;
      segment(v, ix, iy, ox, oy, w * 1.15F);
    }
    break;
  case Icon::Search:
    circle(v, x + s * .43F, y + s * .42F, s * .24F, w, 36);
    segment(v, x + s * .6F, y + s * .6F, x + s * .82F, y + s * .82F, w * 1.2F);
    break;
  case Icon::Play:
    polygon(v, {{x + s * .31F, y + s * .2F},
                {x + s * .31F, y + s * .8F},
                {x + s * .77F, cy}});
    break;
  case Icon::Pause:
    filledRect(v, x + s * .27F, y + s * .2F, s * .16F, s * .6F);
    filledRect(v, x + s * .57F, y + s * .2F, s * .16F, s * .6F);
    break;
  case Icon::Back:
    segment(v, x + s * .76F, cy, x + s * .23F, cy, w * 1.1F);
    segment(v, x + s * .23F, cy, x + s * .47F, y + s * .25F, w * 1.1F);
    segment(v, x + s * .23F, cy, x + s * .47F, y + s * .75F, w * 1.1F);
    break;
  case Icon::ChevronLeft:
    segment(v, x + s * .61F, y + s * .19F, x + s * .37F, cy, w * 1.15F);
    segment(v, x + s * .37F, cy, x + s * .61F, y + s * .81F, w * 1.15F);
    break;
  case Icon::ChevronRight:
    segment(v, x + s * .39F, y + s * .19F, x + s * .63F, cy, w * 1.15F);
    segment(v, x + s * .63F, cy, x + s * .39F, y + s * .81F, w * 1.15F);
    break;
  case Icon::Volume:
    polygon(v, {{x + s * .13F, y + s * .4F},
                {x + s * .31F, y + s * .4F},
                {x + s * .54F, y + s * .22F},
                {x + s * .54F, y + s * .78F},
                {x + s * .31F, y + s * .6F},
                {x + s * .13F, y + s * .6F}});
    arc(v, x + s * .51F, cy, s * .2F, -Pi * .38F, Pi * .38F, w, 16);
    arc(v, x + s * .51F, cy, s * .33F, -Pi * .36F, Pi * .36F, w, 20);
    break;
  case Icon::Rewind:
    polygon(v, {{x + s * .48F, y + s * .21F},
                {x + s * .48F, y + s * .79F},
                {x + s * .16F, cy}});
    polygon(v, {{x + s * .82F, y + s * .21F},
                {x + s * .82F, y + s * .79F},
                {x + s * .5F, cy}});
    segment(v, x + s * .12F, y + s * .2F, x + s * .12F, y + s * .8F, w);
    break;
  case Icon::Forward:
    polygon(v, {{x + s * .52F, y + s * .21F},
                {x + s * .52F, y + s * .79F},
                {x + s * .84F, cy}});
    polygon(v, {{x + s * .18F, y + s * .21F},
                {x + s * .18F, y + s * .79F},
                {x + s * .5F, cy}});
    segment(v, x + s * .88F, y + s * .2F, x + s * .88F, y + s * .8F, w);
    break;
  case Icon::Refresh: {
    arc(v, cx, cy, s * .3F, Pi * .19F, Pi * 1.83F, w, 36);
    polygon(v, {{x + s * .68F, y + s * .16F},
                {x + s * .84F, y + s * .2F},
                {x + s * .7F, y + s * .35F}});
    break;
  }
  case Icon::Dpad:
    roundRect(v, x + s * .38F, y + s * .13F, s * .24F, s * .74F, s * .06F, w);
    roundRect(v, x + s * .13F, y + s * .38F, s * .74F, s * .24F, s * .06F, w);
    break;
  }
}
void glyphLine(std::vector<Vertex> &v, float x, float y, float s, char glyph,
               float width) {
  const float x0 = x, x1 = x + s, ym = y + s * .5F;
  if (glyph == '1') {
    segment(v, x + s * .5F, y, x + s * .5F, y + s, width);
    segment(v, x + s * .22F, y + s, x + s * .78F, y + s, width);
  } else if (glyph == '2') {
    segment(v, x + s * .18F, y, x + s * .82F, y, width);
    segment(v, x + s * .82F, y, x + s * .82F, ym, width);
    segment(v, x + s * .82F, ym, x + s * .18F, ym, width);
    segment(v, x + s * .18F, ym, x + s * .18F, y + s, width);
    segment(v, x + s * .18F, y + s, x + s * .82F, y + s, width);
  } else if (glyph == 'L') {
    segment(v, x0, y, x0, y + s, width);
    segment(v, x0, y + s, x1, y + s, width);
  } else if (glyph == 'R') {
    segment(v, x0, y + s, x0, y, width);
    segment(v, x0, y, x + s * .62F, y, width);
    segment(v, x + s * .62F, y, x1, y + s * .2F, width);
    segment(v, x1, y + s * .2F, x + s * .62F, ym, width);
    segment(v, x + s * .62F, ym, x1, y + s, width);
  }
}
bool isFaceButton(Button button) {
  return button == Button::Cross || button == Button::Circle ||
         button == Button::Square || button == Button::Triangle;
}
Color faceButtonColor(Button button) {
  switch (button) {
  case Button::Cross:
    return {.21F, .69F, .98F, 1};
  case Button::Circle:
    return {.98F, .34F, .35F, 1};
  case Button::Square:
    return {1.0F, .47F, .69F, 1};
  case Button::Triangle:
    return {.33F, .88F, .56F, 1};
  default:
    return {1, 1, 1, 1};
  }
}
void addButton(std::vector<Vertex> &v, Button button, float x, float y,
               float s) {
  const float cx = x + s * .5F, cy = y + s * .5F;
  const float w = std::max(1.4F, s * .075F);
  if (button == Button::Options || button == Button::L1 ||
      button == Button::R1 || button == Button::L2 || button == Button::R2) {
    const float px = x + s * .08F, py = y + s * .27F, pw = s * .84F,
                ph = s * .46F;
    roundRect(v, px, py, pw, ph, ph * .38F, w);
    if (button == Button::Options) {
      for (int i = 0; i < 3; ++i)
        disc(v, x + s * (.35F + .15F * i), cy, s * .045F, 10);
    } else {
      const bool left = button == Button::L1 || button == Button::L2;
      const bool trigger = button == Button::L2 || button == Button::R2;
      glyphLine(v, x + s * (left ? .24F : .46F), y + s * .38F, s * .19F,
                left ? 'L' : 'R', w * .8F);
      glyphLine(v, x + s * (left ? .56F : .68F), y + s * .4F, s * .18F,
                trigger ? '2' : '1', w * .8F);
    }
    return;
  }

  const float gx = cx - s * .2F, gy = cy - s * .2F, gs = s * .4F;
  switch (button) {
  case Button::Cross:
    segment(v, gx + gs * .12F, gy + gs * .12F, gx + gs * .88F, gy + gs * .88F,
            w * 1.25F);
    segment(v, gx + gs * .88F, gy + gs * .12F, gx + gs * .12F, gy + gs * .88F,
            w * 1.25F);
    break;
  case Button::Circle:
    circle(v, cx, cy, s * .2F, w * 1.15F, 32);
    break;
  case Button::Square:
    outline(v, cx - s * .18F, cy - s * .18F, s * .36F, s * .36F, w * 1.1F);
    break;
  case Button::Triangle:
    segment(v, cx, cy - s * .22F, cx + s * .2F, cy + s * .17F, w * 1.1F);
    segment(v, cx + s * .2F, cy + s * .17F, cx - s * .2F, cy + s * .17F,
            w * 1.1F);
    segment(v, cx - s * .2F, cy + s * .17F, cx, cy - s * .22F, w * 1.1F);
    break;
  default:
    break;
  }
}
} // namespace

struct Gfx::Impl {
  struct CachedImage {
    GLuint texture{};
    int width{}, height{};
    std::uint64_t used{};
  };
  GLuint program{}, vao{}, vbo{}, font{}, videoTexture{};
  GLint mode{}, color{}, size{}, radius{};
  int pixelWidth{}, pixelHeight{}, videoWidth{}, videoHeight{};
  float ascent{50};
  std::array<stbtt_bakedchar, 224> chars{};
  std::unordered_map<std::string, CachedImage> images;
  std::uint64_t imageUse{};
  std::size_t imageBytes{};
  void draw(const std::vector<Vertex> &vertices, int kind, Color tint,
            float width = 0, float height = 0, float rounding = 0) {
    if (vertices.empty())
      return;
    glUniform1i(mode, kind);
    glUniform4f(color, tint.r, tint.g, tint.b, tint.a);
    glUniform2f(size, width, height);
    glUniform1f(radius, rounding);
    glBindVertexArray(vao);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER,
                 static_cast<GLsizeiptr>(vertices.size() * sizeof(Vertex)),
                 vertices.data(), GL_STREAM_DRAW);
    glDrawArrays(GL_TRIANGLES, 0, static_cast<GLsizei>(vertices.size()));
  }
};

Gfx::Gfx(const std::string &fontFile) : impl_(std::make_unique<Impl>()) {
  const char *vertex = R"(#version 330 core
layout(location=0) in vec2 position;
layout(location=1) in vec2 texcoord;
layout(location=2) in vec2 maskcoord;
out vec2 uv;
out vec2 shapeUv;
void main(){uv=texcoord;shapeUv=maskcoord;gl_Position=vec4(position.x/960.0-1.0,1.0-position.y/540.0,0,1);}
)";
  const char *fragment = R"(#version 330 core
in vec2 uv;
in vec2 shapeUv;
out vec4 frag;
uniform sampler2D tex;
uniform int mode;
uniform vec4 tint;
uniform vec2 shapeSize;
uniform float radius;
void main(){
 if(mode==1){frag=vec4(tint.rgb,tint.a*texture(tex,uv).r);}
 else if(mode==2){frag=texture(tex,uv)*tint;}
 else if(mode==3){
   vec2 q=abs((shapeUv-0.5)*shapeSize)-(shapeSize*0.5-radius);
   float d=length(max(q,0.0))+min(max(q.x,q.y),0.0)-radius;
   vec4 sampleColor=texture(tex,uv);
   frag=vec4(sampleColor.rgb*tint.rgb,sampleColor.a*tint.a*(1.0-smoothstep(-0.65,0.65,d)));
 }
 else if(mode==4){frag=tint;}
 else {
   vec2 q=abs((uv-0.5)*shapeSize)-(shapeSize*0.5-radius);
   float d=length(max(q,0.0))+min(max(q.x,q.y),0.0)-radius;
   frag=vec4(tint.rgb,tint.a*(1.0-smoothstep(-0.65,0.65,d)));
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
  p.mode = glGetUniformLocation(p.program, "mode");
  p.color = glGetUniformLocation(p.program, "tint");
  p.size = glGetUniformLocation(p.program, "shapeSize");
  p.radius = glGetUniformLocation(p.program, "radius");
  glGenVertexArrays(1, &p.vao);
  glBindVertexArray(p.vao);
  glGenBuffers(1, &p.vbo);
  glBindBuffer(GL_ARRAY_BUFFER, p.vbo);
  glEnableVertexAttribArray(0);
  glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex), nullptr);
  glEnableVertexAttribArray(1);
  glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                        reinterpret_cast<void *>(2 * sizeof(float)));
  glEnableVertexAttribArray(2);
  glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                        reinterpret_cast<void *>(4 * sizeof(float)));
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
  std::vector<unsigned char> bitmap(2048 * 2048);
  if (stbtt_BakeFontBitmap(data.data(), 0, 64, bitmap.data(), 2048, 2048, 32,
                           224, p.chars.data()) <= 0)
    throw std::runtime_error("BruTV font atlas could not be built");
  glGenTextures(1, &p.font);
  glBindTexture(GL_TEXTURE_2D, p.font);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, 2048, 2048, 0, GL_RED, GL_UNSIGNED_BYTE,
               bitmap.data());
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glGenTextures(1, &p.videoTexture);
  glBindTexture(GL_TEXTURE_2D, p.videoTexture);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}
Gfx::~Gfx() {
  auto &p = *impl_;
  for (const auto &entry : p.images)
    glDeleteTextures(1, &entry.second.texture);
  glDeleteTextures(1, &p.font);
  glDeleteTextures(1, &p.videoTexture);
  glDeleteBuffers(1, &p.vbo);
  glDeleteVertexArrays(1, &p.vao);
  glDeleteProgram(p.program);
}
void Gfx::begin(int width, int height) {
  auto &p = *impl_;
  p.pixelWidth = width;
  p.pixelHeight = height;
  glViewport(0, 0, width, height);
  glClearColor(.025F, .035F, .065F, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  glDisable(GL_DEPTH_TEST);
  glEnable(GL_BLEND);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  glUseProgram(p.program);
  glActiveTexture(GL_TEXTURE0);
  glUniform1i(glGetUniformLocation(p.program, "tex"), 0);
}
void Gfx::rect(float x, float y, float w, float h, Color c, float r) {
  if (w <= 0 || h <= 0)
    return;
  std::vector<Vertex> v;
  quad(v, x, y, w, h);
  impl_->draw(v, 0, c, w, h, std::clamp(r, 0.0F, std::min(w, h) / 2));
}
float Gfx::textWidth(const std::string &value, float size) const {
  float x = 0;
  for (std::size_t i = 0; i < value.size();) {
    unsigned c = codepoint(value, i);
    if (c < 32 || c > 255)
      c = '?';
    x += impl_->chars[c - 32].xadvance * size / 64;
  }
  return x;
}
void Gfx::text(const std::string &value, float x, float y, float size, Color c,
               float maxWidth) {
  auto &p = *impl_;
  std::vector<Vertex> vertices;
  float px = 0, py = 0;
  const float scale = size / 64;
  const bool clipped = maxWidth > 0 && textWidth(value, size) > maxWidth;
  const float dots = textWidth("...", size);
  for (std::size_t i = 0; i < value.size();) {
    unsigned cp = codepoint(value, i);
    if (cp < 32 || cp > 255)
      cp = '?';
    if (clipped && (px + p.chars[cp - 32].xadvance) * scale >
                       std::max(0.0F, maxWidth - dots)) {
      for (int n = 0; n < 3; ++n) {
        stbtt_aligned_quad q;
        stbtt_GetBakedQuad(p.chars.data(), 2048, 2048, '.' - 32, &px, &py, &q,
                           1);
        quad(vertices, x + q.x0 * scale, y + (p.ascent + q.y0) * scale,
             (q.x1 - q.x0) * scale, (q.y1 - q.y0) * scale, q.s0, q.t0, q.s1,
             q.t1);
      }
      break;
    }
    stbtt_aligned_quad q;
    stbtt_GetBakedQuad(p.chars.data(), 2048, 2048, static_cast<int>(cp) - 32,
                       &px, &py, &q, 1);
    quad(vertices, x + q.x0 * scale, y + (p.ascent + q.y0) * scale,
         (q.x1 - q.x0) * scale, (q.y1 - q.y0) * scale, q.s0, q.t0, q.s1, q.t1);
  }
  glBindTexture(GL_TEXTURE_2D, p.font);
  p.draw(vertices, 1, c);
}
void Gfx::video(const std::uint8_t *pixels, int width, int height) {
  if (!pixels || width <= 0 || height <= 0 || width > 4096 || height > 4096)
    return;
  auto &p = *impl_;
  glBindTexture(GL_TEXTURE_2D, p.videoTexture);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  if (width != p.videoWidth || height != p.videoHeight) {
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, pixels);
    p.videoWidth = width;
    p.videoHeight = height;
  } else
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RGBA,
                    GL_UNSIGNED_BYTE, pixels);
}
void Gfx::drawVideo(float x, float y, float width, float height) {
  auto &p = *impl_;
  if (!p.videoWidth || !p.videoHeight)
    return;
  const float scale = std::min(width / p.videoWidth, height / p.videoHeight);
  const float w = p.videoWidth * scale, h = p.videoHeight * scale;
  std::vector<Vertex> v;
  quad(v, x + (width - w) / 2, y + (height - h) / 2, w, h);
  glBindTexture(GL_TEXTURE_2D, p.videoTexture);
  p.draw(v, 2, {1, 1, 1, 1});
}
void Gfx::icon(Icon value, float x, float y, float size, Color tint) {
  if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(size) ||
      size <= 0 || size > 4096)
    return;
  std::vector<Vertex> vertices;
  vertices.reserve(256);
  addIcon(vertices, value, x, y, size);
  impl_->draw(vertices, 4, tint);
}
void Gfx::button(Button value, float x, float y, float size, Color tint) {
  if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(size) ||
      size <= 0 || size > 4096)
    return;
  auto &p = *impl_;
  if (isFaceButton(value)) {
    std::vector<Vertex> background;
    background.reserve(160);
    const float cx = x + size * .5F, cy = y + size * .5F;
    disc(background, cx, cy, size * .47F, 40);
    p.draw(background, 4, {.035F, .055F, .095F, tint.a});

    std::vector<Vertex> foreground;
    foreground.reserve(160);
    circle(foreground, cx, cy, size * .44F, std::max(1.0F, size * .025F), 40);
    addButton(foreground, value, x, y, size);
    Color face = faceButtonColor(value);
    face.a = tint.a;
    p.draw(foreground, 4, face);
    return;
  }

  std::vector<Vertex> foreground;
  foreground.reserve(128);
  addButton(foreground, value, x, y, size);
  p.draw(foreground, 4, tint);
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

    while (!p.images.empty() &&
           (p.images.size() >= 64 || p.imageBytes + bytes > maxBytes)) {
      auto oldest = p.images.begin();
      for (auto it = std::next(p.images.begin()); it != p.images.end(); ++it) {
        if (it->second.used < oldest->second.used)
          oldest = it;
      }
      glDeleteTextures(1, &oldest->second.texture);
      p.imageBytes -= static_cast<std::size_t>(oldest->second.width) *
                      static_cast<std::size_t>(oldest->second.height) * 4;
      p.images.erase(oldest);
    }

    Impl::CachedImage entry;
    entry.width = imageWidth;
    entry.height = imageHeight;
    entry.used = ++p.imageUse;
    glGenTextures(1, &entry.texture);
    if (!entry.texture)
      return;
    glBindTexture(GL_TEXTURE_2D, entry.texture);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, imageWidth, imageHeight, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    found = p.images.emplace(key, entry).first;
    p.imageBytes += bytes;
  } else {
    found->second.used = ++p.imageUse;
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

  std::vector<Vertex> vertices;
  quad(vertices, drawX, drawY, drawWidth, drawHeight, u0, v0, u1, v1);
  glBindTexture(GL_TEXTURE_2D, entry.texture);
  radius = std::clamp(radius, 0.0F, std::min(drawWidth, drawHeight) * .5F);
  p.draw(vertices, radius > 0 ? 3 : 2, {1, 1, 1, 1}, drawWidth, drawHeight,
         radius);
}
void Gfx::end() {
  glBindVertexArray(0);
  glFlush();
}
void Gfx::screenshot(const std::string &filename) {
  auto &p = *impl_;
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
