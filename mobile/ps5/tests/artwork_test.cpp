#include "brutv/artwork.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <future>
#include <iostream>
#include <map>
#include <mutex>
#include <stdexcept>
#include <thread>

#define STBI_WRITE_NO_STDIO
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

namespace {
using namespace std::chrono_literals;

void require(bool condition, const char *message) {
  if (!condition)
    throw std::runtime_error(message);
}

template <typename Predicate> void waitUntil(Predicate predicate) {
  const auto deadline = std::chrono::steady_clock::now() + 3s;
  while (!predicate()) {
    require(std::chrono::steady_clock::now() < deadline,
            "Timed out waiting for artwork worker");
    std::this_thread::sleep_for(2ms);
  }
}

std::string png(int width, int height) {
  std::vector<unsigned char> pixels(static_cast<std::size_t>(width) * height *
                                    4);
  for (std::size_t offset = 0; offset < pixels.size(); offset += 4) {
    pixels[offset] = 220;
    pixels[offset + 1] = 40;
    pixels[offset + 2] = 80;
    pixels[offset + 3] = 255;
  }
  std::string result;
  const auto write = [](void *context, void *data, int count) {
    static_cast<std::string *>(context)->append(
        static_cast<const char *>(data), static_cast<std::size_t>(count));
  };
  require(stbi_write_png_to_func(write, &result, width, height, 4,
                                 pixels.data(), width * 4) != 0,
          "Could not encode test artwork");
  return result;
}

std::shared_ptr<const brutv::ArtworkImage> loaded(brutv::ArtworkCache &cache,
                                                  const std::string &url) {
  std::shared_ptr<const brutv::ArtworkImage> result;
  waitUntil([&] {
    result = cache.request(url);
    return static_cast<bool>(result);
  });
  return result;
}

void decodeAndResize() {
  const auto bytes = png(1024, 256);
  std::atomic<int> calls{0};
  brutv::ArtworkCache cache([&](const std::string &) {
    ++calls;
    return bytes;
  });
  const auto image = loaded(cache, "https://test.invalid/wide.png");
  require(image->width == 512 && image->height == 128,
          "Artwork lost its aspect ratio");
  require(image->rgba.size() == 512 * 128 * 4,
          "Artwork buffer has the wrong dimensions");
  require(image->rgba[0] == 220 && image->rgba[1] == 40 &&
              image->rgba[3] == 255,
          "Artwork pixels did not decode correctly");
  for (int frame = 0; frame < 500; ++frame)
    require(cache.request("https://test.invalid/wide.png") == image,
            "Ready artwork was not reused");
  require(calls == 1, "Ready artwork was fetched again");
}

void rejectsInvalidInputs() {
  const auto ordinary = png(2, 2);
  const auto wrongSize = [&](int width, int height) {
    auto bytes = ordinary;
    for (int index = 0; index < 4; ++index) {
      bytes[16 + index] = static_cast<char>((width >> (24 - index * 8)) & 255);
      bytes[20 + index] = static_cast<char>((height >> (24 - index * 8)) & 255);
    }
    return bytes;
  };
  std::map<std::string, std::string> cases{
      {"invalid", "not an image"},
      {"truncated", ordinary.substr(0, ordinary.size() / 2)},
      {"compressed-limit", std::string(4 * 1024 * 1024 + 1, 'x')},
      {"dimension-limit", wrongSize(4097, 1)},
      {"pixel-limit", wrongSize(4096, 2049)},
      {"16-bit", std::string("P5\n2 2\n65535\n") + std::string(8, '\0')},
  };
  std::atomic<int> calls{0};
  brutv::ArtworkCache cache([&](const std::string &url) {
    ++calls;
    return cases.at(url.substr(url.find_last_of('/') + 1));
  });
  for (const auto &item : cases)
    cache.request("https://test.invalid/" + item.first);
  waitUntil([&] { return calls == static_cast<int>(cases.size()); });
  std::this_thread::sleep_for(30ms);
  for (int frame = 0; frame < 500; ++frame)
    for (const auto &item : cases)
      require(!cache.request("https://test.invalid/" + item.first),
              "Invalid or oversized artwork was accepted");
  require(calls == static_cast<int>(cases.size()),
          "Failed artwork was retried every frame");
  require(!cache.request("file:///private/image.png"),
          "A local file URL was accepted");
}

struct Gate {
  std::mutex mutex;
  std::condition_variable changed;
  int calls{0};
  int active{0};
  int maximumActive{0};
  bool released{false};

  std::string fetch(const std::string &) {
    std::unique_lock<std::mutex> lock(mutex);
    ++calls;
    ++active;
    maximumActive = std::max(maximumActive, active);
    changed.notify_all();
    changed.wait(lock, [&] { return released; });
    --active;
    return "invalid";
  }
  void waitForTwo() {
    std::unique_lock<std::mutex> lock(mutex);
    require(changed.wait_for(lock, 3s, [&] { return calls == 2; }),
            "Artwork did not start two workers");
  }
  void release() {
    std::lock_guard<std::mutex> lock(mutex);
    released = true;
    changed.notify_all();
  }
};

void boundedQueueAndNonblockingRequest() {
  Gate gate;
  brutv::ArtworkCache cache(
      [&](const std::string &url) { return gate.fetch(url); });
  cache.request("https://test.invalid/active0");
  cache.request("https://test.invalid/active1");
  gate.waitForTwo();
  const auto started = std::chrono::steady_clock::now();
  for (int index = 0; index < 100; ++index)
    cache.request("https://test.invalid/queued" + std::to_string(index));
  const auto elapsed = std::chrono::steady_clock::now() - started;
  gate.release();
  require(elapsed < 100ms, "Artwork requests blocked on fetching or decoding");
  waitUntil([&] {
    std::lock_guard<std::mutex> lock(gate.mutex);
    return gate.calls == 34 && gate.active == 0;
  });
  require(gate.maximumActive == 2, "Artwork exceeded its two-worker limit");
}

void cancelsQueuedOnDestruction() {
  Gate gate;
  auto cache = std::make_unique<brutv::ArtworkCache>(
      [&](const std::string &url) { return gate.fetch(url); });
  cache->request("https://test.invalid/active0");
  cache->request("https://test.invalid/active1");
  gate.waitForTwo();
  for (int index = 0; index < 32; ++index)
    cache->request("https://test.invalid/queued" + std::to_string(index));
  auto destroyed = std::async(std::launch::async, [&] { cache.reset(); });
  require(destroyed.wait_for(30ms) == std::future_status::timeout,
          "Cache destruction did not wait for active callbacks");
  gate.release();
  require(destroyed.wait_for(1s) == std::future_status::ready,
          "Cache destruction did not finish after active callbacks");
  require(gate.calls == 2, "Cache destruction fetched queued artwork");
}

void lruAndByteBudget() {
  const auto small = png(1, 1);
  const auto large = png(512, 512);
  std::mutex mutex;
  std::map<std::string, int> calls;
  brutv::ArtworkCache cache([&](const std::string &url) {
    std::lock_guard<std::mutex> lock(mutex);
    ++calls[url];
    return url.find("large") == std::string::npos ? small : large;
  });
  for (int index = 0; index < 50; ++index)
    loaded(cache, "https://test.invalid/small" + std::to_string(index));
  loaded(cache, "https://test.invalid/small0");
  {
    std::lock_guard<std::mutex> lock(mutex);
    require(calls.at("https://test.invalid/small0") == 2,
            "The 48-entry LRU did not evict an old image");
    require(calls.at("https://test.invalid/small49") == 1,
            "A recent LRU image was unexpectedly fetched again");
  }
  std::vector<std::weak_ptr<const brutv::ArtworkImage>> images;
  for (int index = 0; index < 14; ++index)
    images.emplace_back(
        loaded(cache, "https://test.invalid/large" + std::to_string(index)));
  const auto retained =
      std::count_if(images.begin(), images.end(),
                    [](const auto &image) { return !image.expired(); });
  require(retained <= 12, "Artwork exceeded its 12 MiB ready-image budget");
  require(images.front().expired(),
          "Oldest ready artwork did not leave the byte budget");
  loaded(cache, "https://test.invalid/large0");
  {
    std::lock_guard<std::mutex> lock(mutex);
    require(calls.at("https://test.invalid/large0") == 2,
            "Byte-evicted artwork could not reload when revisited");
  }
}
} // namespace

int main() {
  try {
    brutv::ArtworkCache disabled({});
    require(!disabled.request("https://test.invalid/unused"),
            "Disabled artwork cache loaded");
    decodeAndResize();
    rejectsInvalidInputs();
    boundedQueueAndNonblockingRequest();
    cancelsQueuedOnDestruction();
    lruAndByteBudget();
    std::cout << "Artwork decode, queue, failure, and cache checks passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
