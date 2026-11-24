#pragma once

#include "brutv/catalog.hpp"
#include <chrono>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace brutv {

struct ArtworkImage {
  int width{0};
  int height{0};
  std::vector<std::uint8_t> rgba;
};

class ArtworkCache {
public:
  explicit ArtworkCache(
      HttpGet fetch,
      std::chrono::seconds negativeTtl = std::chrono::seconds(60));
  ~ArtworkCache();
  ArtworkCache(const ArtworkCache &) = delete;
  ArtworkCache &operator=(const ArtworkCache &) = delete;

  // Enqueues an image with LIFO visible priority, returning null until ready.
  // Failures are negatively cached for negativeTtl.
  std::shared_ptr<const ArtworkImage> request(const std::string &url);

  // Releases the CPU RGBA buffer after the image has been uploaded to the GPU.
  void releaseCpu(const std::string &url);

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace brutv
