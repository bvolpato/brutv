#include "brutv/http.hpp"
#include <curl/curl.h>
#include <fstream>
#include <mutex>
#include <stdexcept>
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
std::string get(const std::string &url, bool artwork) {
  static std::once_flag initialized;
  std::call_once(initialized, [] {
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK)
      throw std::runtime_error("Network initialization failed");
  });
  if (url.rfind("https://", 0) != 0 && url.rfind("http://", 0) != 0)
    throw std::runtime_error("Only HTTP and HTTPS source URLs are supported");
  CURL *handle = curl_easy_init();
  if (!handle)
    throw std::runtime_error("Network request could not start");
#ifdef BRUTV_PS5
  console_curl_setup(handle);
#endif
  Response response{{}, artwork ? 4U * 1024 * 1024 : 64U * 1024 * 1024};
  curl_easy_setopt(handle, CURLOPT_URL, url.c_str());
  curl_easy_setopt(handle, CURLOPT_USERAGENT, "BruTV/1.0 PS5");
  curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 1L);
  curl_easy_setopt(handle, CURLOPT_MAXREDIRS, 5L);
  curl_easy_setopt(handle, CURLOPT_PROTOCOLS_STR, "http,https");
  curl_easy_setopt(handle, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
  curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT, artwork ? 2L : 8L);
  curl_easy_setopt(handle, CURLOPT_TIMEOUT, artwork ? 6L : 25L);
  curl_easy_setopt(handle, CURLOPT_LOW_SPEED_LIMIT, 1L);
  curl_easy_setopt(handle, CURLOPT_LOW_SPEED_TIME, artwork ? 4L : 15L);
  curl_easy_setopt(handle, CURLOPT_SSL_VERIFYPEER, 1L);
  curl_easy_setopt(handle, CURLOPT_SSL_VERIFYHOST, 2L);
  curl_easy_setopt(handle, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, writeBody);
  curl_easy_setopt(handle, CURLOPT_WRITEDATA, &response);
  curl_easy_setopt(handle, CURLOPT_MAXFILESIZE_LARGE,
                   static_cast<curl_off_t>(response.limit));
  const std::string ca = std::string(BRUTV_ASSET_DIR) + "/ca-bundle.crt";
  if (std::ifstream(ca).good())
    curl_easy_setopt(handle, CURLOPT_CAINFO, ca.c_str());
  const CURLcode result = curl_easy_perform(handle);
  long status = 0;
  curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &status);
  curl_easy_cleanup(handle);
  if (result == CURLE_WRITE_ERROR || result == CURLE_FILESIZE_EXCEEDED)
    throw std::runtime_error(
        artwork ? "The artwork response exceeded the 4 MiB limit"
                : "The source response exceeded the 64 MiB limit");
  if (result != CURLE_OK)
    throw std::runtime_error("Could not fetch the source. Check its address, "
                             "connection, and HTTPS certificate.");
  if (status < 200 || status >= 300)
    throw std::runtime_error("The source returned HTTP " +
                             std::to_string(status));
  return std::move(response.body);
}
} // namespace
std::string httpGet(const std::string &url) { return get(url, false); }
std::string httpGetArtwork(const std::string &url) { return get(url, true); }
} // namespace brutv
