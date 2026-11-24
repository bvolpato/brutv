// SPDX-License-Identifier: MIT
#include "brutv/http.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <curl/curl.h>
#include <fstream>
#include <mutex>
#include <random>
#include <stdexcept>
#include <thread>
#ifdef BRUTV_PS5
extern "C" void console_curl_setup(CURL *handle);
#endif

#ifndef BRUTV_ASSET_DIR
#define BRUTV_ASSET_DIR "assets"
#endif

namespace brutv {
namespace {
struct Response {
  std::string body;
  std::size_t limit;
};

std::size_t writeBody(char *data, std::size_t size, std::size_t count,
                      void *context) {
  auto &response = *static_cast<Response *>(context);
  if (size && count > response.limit / size)
    return 0;
  const auto bytes = size * count;
  if (response.body.size() > response.limit - bytes)
    return 0;
  try {
    response.body.append(data, bytes);
    return bytes;
  } catch (...) {
    return 0;
  }
}

struct SharedCurlCache {
  std::array<std::mutex, CURL_LOCK_DATA_LAST> locks;
  CURLSH *handle{nullptr};

  static void lockCallback(CURL *, curl_lock_data data, curl_lock_access,
                           void *userptr) {
    auto *self = static_cast<SharedCurlCache *>(userptr);
    if (data >= 0 && data < CURL_LOCK_DATA_LAST)
      self->locks[static_cast<std::size_t>(data)].lock();
  }

  static void unlockCallback(CURL *, curl_lock_data data, void *userptr) {
    auto *self = static_cast<SharedCurlCache *>(userptr);
    if (data >= 0 && data < CURL_LOCK_DATA_LAST)
      self->locks[static_cast<std::size_t>(data)].unlock();
  }

  SharedCurlCache() {
    handle = curl_share_init();
    if (handle) {
      curl_share_setopt(handle, CURLSHOPT_USERDATA, this);
      curl_share_setopt(handle, CURLSHOPT_LOCKFUNC, lockCallback);
      curl_share_setopt(handle, CURLSHOPT_UNLOCKFUNC, unlockCallback);
      curl_share_setopt(handle, CURLSHOPT_SHARE, CURL_LOCK_DATA_DNS);
      curl_share_setopt(handle, CURLSHOPT_SHARE, CURL_LOCK_DATA_SSL_SESSION);
    }
  }

  ~SharedCurlCache() {
    if (handle)
      curl_share_cleanup(handle);
  }
};

CURLSH *sharedCurlHandle() {
  static SharedCurlCache cache;
  return cache.handle;
}

struct ThreadCurlHandle {
  CURL *handle{nullptr};

  CURL *acquire() {
    if (!handle) {
      handle = curl_easy_init();
      if (!handle)
        throw std::runtime_error("Network request could not start");
    } else {
      curl_easy_reset(handle);
    }
    return handle;
  }

  void discard() {
    if (handle) {
      curl_easy_cleanup(handle);
      handle = nullptr;
    }
  }

  ~ThreadCurlHandle() { discard(); }
};

bool isTransientCurlError(CURLcode code) {
  switch (code) {
  case CURLE_COULDNT_RESOLVE_HOST:
  case CURLE_COULDNT_CONNECT:
  case CURLE_OPERATION_TIMEDOUT:
  case CURLE_RECV_ERROR:
  case CURLE_SEND_ERROR:
  case CURLE_GOT_NOTHING:
  case CURLE_PARTIAL_FILE:
  case CURLE_SSL_CONNECT_ERROR:
#ifdef CURLE_HTTP2
  case CURLE_HTTP2:
#endif
#ifdef CURLE_HTTP2_STREAM
  case CURLE_HTTP2_STREAM:
#endif
    return true;
  default:
    return false;
  }
}

bool isTransientHttpStatus(long status) {
  return status == 408 || status == 429 || status == 458 ||
         (status >= 500 && status <= 599);
}

long retryDelayMs(int attempt, long status, curl_off_t retryAfterSeconds) {
  static thread_local std::mt19937 rng(static_cast<std::uint32_t>(
      std::chrono::steady_clock::now().time_since_epoch().count() ^
      0x9e3779b9U));
  const long baseMs = attempt == 0 ? 400L : 1000L;
  std::uniform_int_distribution<long> jitterDist(-baseMs / 5, baseMs / 5);
  long delayMs = std::max(100L, baseMs + jitterDist(rng));
  if ((status == 429 || status == 503) && retryAfterSeconds > 0) {
    const long clampedSeconds =
        std::clamp<long>(static_cast<long>(retryAfterSeconds), 0L, 5L);
    delayMs = std::max(delayMs, clampedSeconds * 1000L);
  }
  return delayMs;
}

std::string get(const std::string &url, bool artwork) {
  static std::once_flag initialized;
  std::call_once(initialized, [] {
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK)
      throw std::runtime_error("Network initialization failed");
  });
  if (url.rfind("https://", 0) != 0 && url.rfind("http://", 0) != 0)
    throw std::runtime_error("Only HTTP and HTTPS source URLs are supported");
  const int maxAttempts = artwork ? 1 : 3;
  static const std::string ca = std::string(BRUTV_ASSET_DIR) + "/ca-bundle.crt";
  static const bool hasCa = std::ifstream(ca).good();
  CURLSH *shared = sharedCurlHandle();
  static thread_local ThreadCurlHandle threadHandle;
  for (int attempt = 0; attempt < maxAttempts; ++attempt) {
    CURL *handle = threadHandle.acquire();
#ifdef BRUTV_PS5
    console_curl_setup(handle);
#endif
    if (shared)
      curl_easy_setopt(handle, CURLOPT_SHARE, shared);
    Response response{{}, artwork ? 4U * 1024 * 1024 : 64U * 1024 * 1024};
    curl_easy_setopt(handle, CURLOPT_URL, url.c_str());
    curl_easy_setopt(handle, CURLOPT_USERAGENT, "BruTV/1.0 PS5");
    curl_easy_setopt(handle, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(handle, CURLOPT_MAXREDIRS, 10L);
    curl_easy_setopt(handle, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(handle, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT, artwork ? 2L : 8L);
    curl_easy_setopt(handle, CURLOPT_TIMEOUT, artwork ? 6L : 90L);
    curl_easy_setopt(handle, CURLOPT_LOW_SPEED_LIMIT, 512L);
    curl_easy_setopt(handle, CURLOPT_LOW_SPEED_TIME, artwork ? 4L : 15L);
    curl_easy_setopt(handle, CURLOPT_TCP_KEEPALIVE, 1L);
#ifdef CURLOPT_HAPPY_EYEBALLS_TIMEOUT_MS
    curl_easy_setopt(handle, CURLOPT_HAPPY_EYEBALLS_TIMEOUT_MS, 200L);
#endif
    curl_easy_setopt(handle, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(handle, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(handle, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, writeBody);
    curl_easy_setopt(handle, CURLOPT_WRITEDATA, &response);
    curl_easy_setopt(handle, CURLOPT_MAXFILESIZE_LARGE,
                     static_cast<curl_off_t>(response.limit));
    if (hasCa)
      curl_easy_setopt(handle, CURLOPT_CAINFO, ca.c_str());
    const CURLcode result = curl_easy_perform(handle);
    long status = 0;
    curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &status);
    curl_off_t retryAfter = 0;
#ifdef CURLINFO_RETRY_AFTER
    if (result == CURLE_OK && (status == 429 || status == 503))
      curl_easy_getinfo(handle, CURLINFO_RETRY_AFTER, &retryAfter);
#endif
    if (result == CURLE_WRITE_ERROR || result == CURLE_FILESIZE_EXCEEDED) {
      threadHandle.discard();
      throw std::runtime_error(
          artwork ? "The artwork response exceeded the 4 MiB limit"
                  : "The source response exceeded the 64 MiB limit");
    }
    const bool hasMoreAttempts = attempt + 1 < maxAttempts;
    if (result != CURLE_OK) {
      if (hasMoreAttempts && isTransientCurlError(result)) {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(retryDelayMs(attempt, 0, 0)));
        continue;
      }
      throw std::runtime_error("Could not fetch the source. Check its address, "
                               "connection, and HTTPS certificate.");
    }
    if (status < 200 || status >= 300) {
      if (hasMoreAttempts && isTransientHttpStatus(status)) {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(retryDelayMs(attempt, status, retryAfter)));
        continue;
      }
      throw std::runtime_error("The source returned HTTP " +
                               std::to_string(status));
    }
    return std::move(response.body);
  }
  throw std::runtime_error("Could not fetch the source.");
}
} // namespace
std::string httpGet(const std::string &url) { return get(url, false); }
std::string httpGetArtwork(const std::string &url) { return get(url, true); }
} // namespace brutv
