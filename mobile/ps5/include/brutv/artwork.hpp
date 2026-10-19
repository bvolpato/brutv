#pragma once

#include "brutv/catalog.hpp"
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
  explicit ArtworkCache(HttpGet fetch);
  ~ArtworkCache();
  ArtworkCache(const ArtworkCache &) = delete;
  ArtworkCache &operator=(const ArtworkCache &) = delete;

  // Enqueues an image once, returning null until ready. Failures are negatively
  // cached.
  std::shared_ptr<const ArtworkImage> request(const std::string &url);

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace brutv
