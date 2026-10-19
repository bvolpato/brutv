#include "brutv/artwork.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstddef>
#include <cstdlib>
#include <deque>
#include <list>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <utility>

namespace {
constexpr std::size_t compressedLimit = 4 * 1024 * 1024;
constexpr std::size_t decoderLimit = 48 * 1024 * 1024;
constexpr std::size_t readyImageLimit = 12 * 1024 * 1024;
constexpr int dimensionLimit = 4096;
constexpr std::size_t pixelLimit = 8 * 1024 * 1024;
constexpr int thumbnailLimit = 512;

struct alignas(std::max_align_t) DecoderAllocation {
  std::size_t size;
};
thread_local std::size_t decoderAllocated = 0;

void *decoderMalloc(std::size_t size) {
  if (size > decoderLimit - decoderAllocated)
    return nullptr;
  auto *allocation = static_cast<DecoderAllocation *>(
      std::malloc(sizeof(DecoderAllocation) + size));
  if (!allocation)
    return nullptr;
  allocation->size = size;
  decoderAllocated += size;
  return allocation + 1;
}

void decoderFree(void *pointer) {
  if (!pointer)
    return;
  auto *allocation = static_cast<DecoderAllocation *>(pointer) - 1;
  decoderAllocated -= allocation->size;
  std::free(allocation);
}

void *decoderRealloc(void *pointer, std::size_t size) {
  if (!pointer)
    return decoderMalloc(size);
  auto *allocation = static_cast<DecoderAllocation *>(pointer) - 1;
  const auto previousSize = allocation->size;
  if (size > decoderLimit - (decoderAllocated - previousSize))
    return nullptr;
  auto *resized = static_cast<DecoderAllocation *>(
      std::realloc(allocation, sizeof(DecoderAllocation) + size));
  if (!resized)
    return nullptr;
  resized->size = size;
  decoderAllocated = decoderAllocated - previousSize + size;
  return resized + 1;
}
} // namespace

#define STBI_MALLOC(size) decoderMalloc(size)
#define STBI_REALLOC(pointer, size) decoderRealloc(pointer, size)
#define STBI_FREE(pointer) decoderFree(pointer)
#define STBI_MAX_DIMENSIONS 4096
#define STBI_NO_STDIO
#define STBI_NO_FAILURE_STRINGS
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

namespace brutv {
namespace {
std::shared_ptr<const ArtworkImage> decode(const std::string &bytes) {
  if (bytes.empty() || bytes.size() > compressedLimit)
    return {};
  const auto *data = reinterpret_cast<const stbi_uc *>(bytes.data());
  int width = 0;
  int height = 0;
  int channels = 0;
  if (!stbi_info_from_memory(data, static_cast<int>(bytes.size()), &width,
                             &height, &channels) ||
      width <= 0 || height <= 0 || width > dimensionLimit ||
      height > dimensionLimit ||
      static_cast<std::size_t>(width) * static_cast<std::size_t>(height) >
          pixelLimit ||
      stbi_is_16_bit_from_memory(data, static_cast<int>(bytes.size())))
    return {};
  std::unique_ptr<stbi_uc, decltype(&stbi_image_free)> pixels(
      stbi_load_from_memory(data, static_cast<int>(bytes.size()), &width,
                            &height, &channels, 4),
      stbi_image_free);
  if (!pixels || width <= 0 || height <= 0 || width > dimensionLimit ||
      height > dimensionLimit ||
      static_cast<std::size_t>(width) * static_cast<std::size_t>(height) >
          pixelLimit)
    return {};

  auto image = std::make_shared<ArtworkImage>();
  const double scale = std::min(1.0, static_cast<double>(thumbnailLimit) /
                                         std::max(width, height));
  image->width = std::max(1, static_cast<int>(std::round(width * scale)));
  image->height = std::max(1, static_cast<int>(std::round(height * scale)));
  image->rgba.resize(static_cast<std::size_t>(image->width) * image->height *
                     4);
  if (image->width == width && image->height == height) {
    std::copy_n(pixels.get(), image->rgba.size(), image->rgba.data());
    return image;
  }

  for (int y = 0; y < image->height; ++y) {
    const double sourceY = std::clamp((y + 0.5) * height / image->height - 0.5,
                                      0.0, static_cast<double>(height - 1));
    const int y0 = static_cast<int>(sourceY);
    const int y1 = std::min(height - 1, y0 + 1);
    const double fy = sourceY - y0;
    for (int x = 0; x < image->width; ++x) {
      const double sourceX = std::clamp((x + 0.5) * width / image->width - 0.5,
                                        0.0, static_cast<double>(width - 1));
      const int x0 = static_cast<int>(sourceX);
      const int x1 = std::min(width - 1, x0 + 1);
      const double fx = sourceX - x0;
      for (int channel = 0; channel < 4; ++channel) {
        const auto sample = [&](int sx, int sy) {
          return pixels
              .get()[(static_cast<std::size_t>(sy) * width + sx) * 4 + channel];
        };
        const double top = sample(x0, y0) * (1.0 - fx) + sample(x1, y0) * fx;
        const double bottom = sample(x0, y1) * (1.0 - fx) + sample(x1, y1) * fx;
        image->rgba[(static_cast<std::size_t>(y) * image->width + x) * 4 +
                    channel] =
            static_cast<std::uint8_t>(
                std::round(top * (1.0 - fy) + bottom * fy));
      }
    }
  }
  return image;
}
} // namespace

struct ArtworkCache::Impl {
  enum class State { Queued, Active, Complete, Evicted };
  struct Entry {
    std::shared_ptr<const ArtworkImage> image;
    std::list<std::string>::iterator recent;
    State state{State::Queued};
    std::uint64_t generation{0};
    std::chrono::steady_clock::time_point retryAfter{};
  };
  struct Job {
    std::string url;
    std::uint64_t generation;
  };
  HttpGet fetch;
  std::mutex mutex;
  std::condition_variable wake;
  std::array<std::thread, 2> workers;
  std::deque<Job> jobs;
  std::unordered_map<std::string, Entry> entries;
  std::list<std::string> recent;
  std::size_t readyImageBytes{0};
  std::uint64_t generation{0};
  bool stopping{false};

  explicit Impl(HttpGet get) : fetch(std::move(get)) {
    if (!fetch)
      return;
    try {
      for (auto &worker : workers)
        worker = std::thread([this] { run(); });
    } catch (...) {
      stop();
      throw;
    }
  }

  ~Impl() { stop(); }

  void stop() {
    {
      std::lock_guard<std::mutex> lock(mutex);
      stopping = true;
      jobs.clear();
    }
    wake.notify_all();
    for (auto &worker : workers)
      if (worker.joinable())
        worker.join();
  }

  void run() {
    for (;;) {
      Job job;
      {
        std::unique_lock<std::mutex> lock(mutex);
        wake.wait(lock, [this] { return stopping || !jobs.empty(); });
        if (stopping)
          return;
        job = std::move(jobs.front());
        jobs.pop_front();
        const auto entry = entries.find(job.url);
        if (entry == entries.end() ||
            entry->second.generation != job.generation)
          continue;
        entry->second.state = State::Active;
      }
      std::shared_ptr<const ArtworkImage> image;
      try {
        image = decode(fetch(job.url));
      } catch (...) {
        // Provider URLs can contain credentials. Rendering only needs a
        // fallback image.
      }
      {
        std::lock_guard<std::mutex> lock(mutex);
        const auto entry = entries.find(job.url);
        if (entry != entries.end() &&
            entry->second.generation == job.generation) {
          if (image) {
            for (auto oldest = recent.rbegin();
                 readyImageBytes + image->rgba.size() > readyImageLimit &&
                 oldest != recent.rend();
                 ++oldest) {
              auto &cached = entries.at(*oldest);
              if (cached.image) {
                readyImageBytes -= cached.image->rgba.size();
                cached.image.reset();
                cached.state = State::Evicted;
                cached.retryAfter = std::chrono::steady_clock::now() +
                                    std::chrono::milliseconds(250);
              }
            }
            readyImageBytes += image->rgba.size();
          }
          entry->second.image = std::move(image);
          entry->second.state = State::Complete;
        }
      }
    }
  }

  std::shared_ptr<const ArtworkImage> request(const std::string &url) {
    if (!fetch || url.empty() || url.size() > 8192 ||
        (url.rfind("https://", 0) != 0 && url.rfind("http://", 0) != 0))
      return {};
    std::lock_guard<std::mutex> lock(mutex);
    const auto existing = entries.find(url);
    if (existing != entries.end()) {
      recent.splice(recent.begin(), recent, existing->second.recent);
      if (existing->second.state == State::Evicted && jobs.size() < 32 &&
          !stopping &&
          std::chrono::steady_clock::now() >= existing->second.retryAfter) {
        existing->second.state = State::Queued;
        existing->second.generation = ++generation;
        jobs.push_back({url, existing->second.generation});
        wake.notify_one();
      }
      return existing->second.image;
    }
    if (stopping || jobs.size() >= 32)
      return {};
    if (entries.size() >= 48) {
      auto oldest = recent.end();
      while (oldest != recent.begin()) {
        --oldest;
        const auto entry = entries.find(*oldest);
        if (entry->second.state == State::Active)
          continue;
        const auto oldGeneration = entry->second.generation;
        if (entry->second.image)
          readyImageBytes -= entry->second.image->rgba.size();
        jobs.erase(std::remove_if(jobs.begin(), jobs.end(),
                                  [&](const Job &job) {
                                    return job.generation == oldGeneration;
                                  }),
                   jobs.end());
        entries.erase(entry);
        recent.erase(oldest);
        break;
      }
    }
    recent.push_front(url);
    const auto token = ++generation;
    entries.emplace(url, Entry{{}, recent.begin(), State::Queued, token, {}});
    jobs.push_back({url, token});
    wake.notify_one();
    return {};
  }
};

ArtworkCache::ArtworkCache(HttpGet fetch)
    : impl_(std::make_unique<Impl>(std::move(fetch))) {}
ArtworkCache::~ArtworkCache() = default;
std::shared_ptr<const ArtworkImage>
ArtworkCache::request(const std::string &url) {
  return impl_->request(url);
}

} // namespace brutv
