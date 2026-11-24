// SPDX-License-Identifier: MIT
#include "brutv/catalog.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cctype>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstring>
#include <ctime>
#include <fstream>
#include <future>
#include <limits>
#include <sstream>
#include <string_view>
#include <unordered_set>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <unistd.h>

namespace brutv {
namespace {
using Json = nlohmann::json;
constexpr std::size_t kMaxResponse = 64U * 1024U * 1024U;
constexpr std::size_t kMaxLine = 128U * 1024U;
constexpr std::size_t kMaxItems = 250'000U;
constexpr std::size_t kMaxSettings = 4U * 1024U * 1024U;
constexpr std::size_t kMaxEpgEntries = 1000U;
constexpr std::size_t kMaxJsonDepth = 64U;
constexpr std::string_view kUncategorized = "Uncategorized";
constexpr std::chrono::seconds kM3uMemoryCacheTtl(60);
constexpr std::chrono::seconds kXmltvMemoryCacheTtl(900);

bool ws(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v'; }
std::string trim(std::string_view s) {
    while (!s.empty() && ws(s.front())) s.remove_prefix(1);
    while (!s.empty() && ws(s.back())) s.remove_suffix(1);
    return std::string(s);
}
char lowerChar(char c) { return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c; }
std::string lower(std::string s) { std::transform(s.begin(), s.end(), s.begin(), lowerChar); return s; }
bool ieq(std::string_view a, std::string_view b) {
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0; i < a.size(); ++i) if (lowerChar(a[i]) != lowerChar(b[i])) return false;
    return true;
}
bool starts(std::string_view value, std::string_view prefix) {
    return value.size() >= prefix.size() && ieq(value.substr(0, prefix.size()), prefix);
}
bool unreserved(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
           c == '-' || c == '.' || c == '_' || c == '~';
}
std::string encode(std::string_view value) {
    static constexpr char hex[] = "0123456789ABCDEF";
    std::string out;
    out.reserve(value.size());
    for (unsigned char c : value) {
        if (unreserved(c)) out.push_back(static_cast<char>(c));
        else { out.push_back('%'); out.push_back(hex[c >> 4]); out.push_back(hex[c & 15]); }
    }
    return out;
}
int hexValue(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
std::optional<std::string> decode(std::string_view value, bool plusSpace = true) {
    std::string out;
    out.reserve(value.size());
    for (std::size_t i = 0; i < value.size(); ++i) {
        const char c = value[i];
        if (c == '+') out.push_back(plusSpace ? ' ' : '+');
        else if (c == '%') {
            if (i + 2 >= value.size()) return std::nullopt;
            int hi = hexValue(value[i + 1]), lo = hexValue(value[i + 2]);
            if (hi < 0 || lo < 0 || (hi == 0 && lo == 0)) return std::nullopt;
            out.push_back(static_cast<char>((hi << 4) | lo)); i += 2;
        } else out.push_back(c);
    }
    return out;
}

bool validPort(std::string_view port) {
    if (port.empty()) return false;
    unsigned value = 0;
    auto result = std::from_chars(port.data(), port.data() + port.size(), value);
    return result.ec == std::errc{} && result.ptr == port.data() + port.size() && value <= 65535;
}
struct Url {
    std::string scheme, authority, host, path, query, fragment;
    bool hasQuery{false}, hasFragment{false};
};
std::optional<Url> parseUrl(std::string_view value) {
    if (value.empty() || value.size() > 8192) return std::nullopt;
    for (unsigned char c : value) if (c <= 0x20 || c == 0x7f || c == '\\') return std::nullopt;
    auto colon = value.find(':');
    if (colon == std::string_view::npos || value.substr(colon + 1, 2) != "//") return std::nullopt;
    Url out;
    out.scheme = lower(std::string(value.substr(0, colon)));
    if (out.scheme != "http" && out.scheme != "https") return std::nullopt;
    auto authStart = colon + 3;
    auto authEnd = value.find_first_of("/?#", authStart);
    out.authority = std::string(value.substr(authStart, authEnd == std::string_view::npos ? value.size() - authStart : authEnd - authStart));
    if (out.authority.empty() || out.authority.find('@') != std::string::npos) return std::nullopt;
    if (out.authority.front() == '[') {
        auto close = out.authority.find(']');
        if (close == std::string::npos || close == 1) return std::nullopt;
        out.host = lower(out.authority.substr(0, close + 1));
        if (close + 1 < out.authority.size() &&
            (out.authority[close + 1] != ':' || !validPort(std::string_view(out.authority).substr(close + 2)))) return std::nullopt;
    } else {
        auto port = out.authority.rfind(':');
        if (port != std::string::npos) {
            if (out.authority.find(':') != port || !validPort(std::string_view(out.authority).substr(port + 1))) return std::nullopt;
            out.host = lower(out.authority.substr(0, port));
        } else out.host = lower(out.authority);
        if (out.host.empty()) return std::nullopt;
        for (unsigned char c : out.host) if (!(std::isalnum(c) || c == '.' || c == '-')) return std::nullopt;
    }
    if (authEnd == std::string_view::npos) return out;
    std::size_t pos = authEnd;
    if (value[pos] == '/') {
        auto end = value.find_first_of("?#", pos);
        out.path = std::string(value.substr(pos, end == std::string_view::npos ? value.size() - pos : end - pos));
        pos = end == std::string_view::npos ? value.size() : end;
    }
    if (pos < value.size() && value[pos] == '?') {
        out.hasQuery = true;
        auto end = value.find('#', pos + 1);
        out.query = std::string(value.substr(pos + 1, end == std::string_view::npos ? value.size() - pos - 1 : end - pos - 1));
        pos = end == std::string_view::npos ? value.size() : end;
    }
    if (pos < value.size() && value[pos] == '#') { out.hasFragment = true; out.fragment = std::string(value.substr(pos + 1)); }
    return out;
}
std::string urlString(const Url& url) {
    std::string out = url.scheme + "://" + url.authority + url.path;
    if (url.hasQuery) out += "?" + url.query;
    if (url.hasFragment) out += "#" + url.fragment;
    return out;
}
bool jsonDepthWithin(std::string_view input, std::size_t limit = kMaxJsonDepth) {
    std::size_t depth = 0;
    bool inString = false, escaped = false;
    for (char c : input) {
        if (inString) {
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == '"') inString = false;
            continue;
        }
        if (c == '"') inString = true;
        else if (c == '{' || c == '[') {
            if (++depth > limit) return false;
        } else if (c == '}' || c == ']') {
            if (depth == 0) return false;
            --depth;
        }
    }
    return depth == 0 && !inString;
}
std::string_view stripBom(std::string_view response) {
    if (response.size() >= 3 &&
        static_cast<unsigned char>(response[0]) == 0xEF &&
        static_cast<unsigned char>(response[1]) == 0xBB &&
        static_cast<unsigned char>(response[2]) == 0xBF) {
        response.remove_prefix(3);
    }
    return response;
}
bool validSource(const Source& source) {
    if (source.type == SourceType::M3U) return parseUrl(source.url).has_value();
    auto server = parseUrl(source.url);
    return server && !server->hasQuery && !server->hasFragment &&
           !source.username.empty() && !source.password.empty();
}

std::string hash64(std::string_view input) {
    std::uint64_t hash = 0xcbf29ce484222325ULL;
    for (unsigned char c : input) { hash ^= c; hash *= 0x100000001b3ULL; }
    static constexpr char hex[] = "0123456789abcdef";
    std::array<char, 16> data{};
    for (int i = 15; i >= 0; --i) { data[static_cast<std::size_t>(i)] = hex[hash & 15U]; hash >>= 4U; }
    std::size_t begin = 0;
    while (begin + 1 < data.size() && data[begin] == '0') ++begin;
    return {data.data() + begin, data.size() - begin};
}
std::string typeName(SourceType type) { return type == SourceType::Xtream ? "xtream" : "m3u"; }
std::string kindName(MediaKind kind) {
    switch (kind) {
        case MediaKind::Live: return "live";
        case MediaKind::Movie: return "movie";
        case MediaKind::Series: return "series";
        case MediaKind::Episode: return "episode";
    }
    return "live";
}
MediaKind kindValue(std::string_view value) {
    if (value == "movie") return MediaKind::Movie;
    if (value == "series") return MediaKind::Series;
    if (value == "episode") return MediaKind::Episode;
    return MediaKind::Live;
}

std::string normalizePath(std::string path) {
    bool absolute = !path.empty() && path.front() == '/';
    bool trailing = !path.empty() && path.back() == '/';
    std::vector<std::string> parts;
    std::size_t pos = 0;
    while (pos <= path.size()) {
        auto slash = path.find('/', pos);
        auto end = slash == std::string::npos ? path.size() : slash;
        auto part = path.substr(pos, end - pos);
        if (part == "..") {
            if (!parts.empty() && parts.back() != "..") parts.pop_back();
            else if (!absolute) parts.push_back(part);
        } else if (!part.empty() && part != ".") parts.push_back(part);
        if (slash == std::string::npos) break;
        pos = slash + 1;
    }
    std::string out = absolute ? "/" : "";
    for (std::size_t i = 0; i < parts.size(); ++i) { if (i) out.push_back('/'); out += parts[i]; }
    if (trailing && !out.empty() && out.back() != '/') out.push_back('/');
    return out.empty() && absolute ? "/" : out;
}
std::optional<std::string> resolveUrl(std::string_view base, std::string_view reference) {
    auto ref = trim(reference);
    if (auto absolute = parseUrl(ref)) return urlString(*absolute);
    auto origin = parseUrl(base);
    if (!origin || ref.empty() || ref.front() == '#') return std::nullopt;
    if (ref.rfind("//", 0) == 0) {
        auto parsed = parseUrl(origin->scheme + ":" + ref);
        return parsed ? std::optional<std::string>(urlString(*parsed)) : std::nullopt;
    }
    auto hash = ref.find('#');
    auto noFragment = ref.substr(0, hash);
    auto question = noFragment.find('?');
    auto refPath = noFragment.substr(0, question);
    bool hasQuery = question != std::string_view::npos;
    std::string query = hasQuery ? noFragment.substr(question + 1) : "";
    origin->hasFragment = hash != std::string::npos;
    origin->fragment = hash == std::string::npos ? "" : ref.substr(hash + 1);
    if (!refPath.empty()) {
        if (refPath.front() == '/') origin->path = normalizePath(refPath);
        else {
            auto slash = origin->path.rfind('/');
            auto prefix = slash == std::string::npos ? std::string{} : origin->path.substr(0, slash + 1);
            origin->path = normalizePath(prefix + refPath);
        }
        origin->hasQuery = hasQuery;
        origin->query = std::move(query);
    } else if (hasQuery) {
        origin->hasQuery = true;
        origin->query = std::move(query);
    }
    auto result = urlString(*origin);
    return parseUrl(result) ? std::optional<std::string>(std::move(result)) : std::nullopt;
}

std::size_t commaOutsideQuotes(std::string_view line) {
    char quote = 0;
    bool escaped = false;
    for (std::size_t i = 0; i < line.size(); ++i) {
        char c = line[i];
        if (c == ',' && !quote) return i;
        if (c == '\\' && quote && !escaped) { escaped = true; continue; }
        if ((c == '\'' || c == '"') && !escaped) {
            if (!quote) quote = c;
            else if (quote == c) quote = 0;
        }
        escaped = false;
    }
    return std::string_view::npos;
}
std::unordered_map<std::string, std::string> attributes(std::string_view input) {
    std::unordered_map<std::string, std::string> result;
    std::size_t pos = 0;
    while (pos < input.size()) {
        while (pos < input.size() && (ws(input[pos]) || input[pos] == ',')) ++pos;
        auto start = pos;
        while (pos < input.size() && (std::isalnum(static_cast<unsigned char>(input[pos])) || input[pos] == '_' || input[pos] == '-')) ++pos;
        if (pos == start) { ++pos; continue; }
        auto key = lower(std::string(input.substr(start, pos - start)));
        while (pos < input.size() && ws(input[pos])) ++pos;
        if (pos == input.size() || input[pos] != '=') continue;
        ++pos;
        while (pos < input.size() && ws(input[pos])) ++pos;
        std::string value;
        if (pos < input.size() && (input[pos] == '"' || input[pos] == '\'')) {
            auto quote = input[pos++];
            while (pos < input.size()) {
                char c = input[pos++];
                if (c == quote) break;
                if (c == '\\' && pos < input.size() && input[pos] == quote) c = input[pos++];
                value.push_back(c);
            }
        } else {
            auto valueStart = pos;
            while (pos < input.size() && !ws(input[pos]) && input[pos] != ',') ++pos;
            value = std::string(input.substr(valueStart, pos - valueStart));
        }
        if (!value.empty()) result[key] = std::move(value);
    }
    return result;
}
std::string headerCase(std::string value) {
    bool cap = true;
    for (char& c : value) {
        if (c == '-') cap = true;
        else if (cap) { c = static_cast<char>(std::toupper(static_cast<unsigned char>(c))); cap = false; }
        else c = lowerChar(c);
    }
    return value;
}
bool forbiddenHeaderName(std::string_view name) {
    return ieq(name, "host") || ieq(name, "connection") || ieq(name, "content-length") ||
           ieq(name, "transfer-encoding") || ieq(name, "upgrade") || ieq(name, "te") ||
           ieq(name, "keep-alive") || ieq(name, "proxy-connection") ||
           ieq(name, "proxy-authorization");
}
bool validHeaderValue(std::string_view value) {
    return !value.empty() && value.size() <= 4096 &&
           std::none_of(value.begin(), value.end(), [](unsigned char c) {
               return c < 0x20 || c == 0x7f;
           });
}
void addHeader(std::unordered_map<std::string, std::string>& headers, std::string_view option) {
    auto equals = option.find('=');
    if (equals == std::string_view::npos || equals == 0) return;
    auto key = lower(trim(option.substr(0, equals)));
    std::string name;
    if (key == "http-user-agent") name = "User-Agent";
    else if (key == "http-referrer" || key == "http-referer") name = "Referer";
    else if (key == "http-cookie") name = "Cookie";
    else if (key.rfind("http-header-", 0) == 0) name = headerCase(key.substr(12));
    else return;
    auto value = trim(option.substr(equals + 1));
    if (!validHeaderValue(value) || forbiddenHeaderName(name)) return;
    headers[name] = std::move(value);
}
void addJsonHeaders(std::unordered_map<std::string, std::string>& headers, std::string_view jsonText) {
    if (jsonText.size() > kMaxLine || !jsonDepthWithin(jsonText)) return;
    try {
        const auto values = Json::parse(jsonText.begin(), jsonText.end());
        if (!values.is_object() || values.size() > 64) return;
        for (auto it = values.begin(); it != values.end(); ++it) {
            if (!it.value().is_string() || it.key().empty() || it.key().size() > 64) continue;
            const auto name = it.key();
            const auto value = it.value().get<std::string>();
            const bool token = std::all_of(name.begin(), name.end(), [](unsigned char c) {
                return std::isalnum(c) || std::string_view("!#$%&'*+-.^_|~").find(static_cast<char>(c)) != std::string_view::npos || c == 0x60;
            });
            if (!token || !validHeaderValue(value) || forbiddenHeaderName(name)) continue;
            headers[headerCase(name)] = value;
        }
    } catch (...) {
        // An optional malformed header block does not invalidate the playlist.
    }
}
MediaKind classify(std::string_view address) {
    auto parsed = parseUrl(address);
    auto path = lower(parsed ? parsed->path : std::string(address));
    if (path.find("/movie/") != std::string::npos || path.find("/series/") != std::string::npos) return MediaKind::Movie;
    auto dot = path.rfind('.');
    auto ext = dot == std::string::npos ? std::string{} : path.substr(dot + 1);
    static const std::unordered_set<std::string> video{"mp4", "mkv", "avi", "mov", "webm", "m4v"};
    return video.count(ext) ? MediaKind::Movie : MediaKind::Live;
}
struct PlaylistEntry { MediaItem item; std::string group; };
struct ParsedPlaylist {
    std::vector<PlaylistEntry> entries;
    std::string xmltvUrl;
};
ParsedPlaylist parsePlaylist(std::string_view body, const Source& source) {
    if (body.size() > kMaxResponse) throw CatalogError("The playlist exceeds the size limit.");
    body = stripBom(body);
    ParsedPlaylist parsedResult;
    auto& output = parsedResult.entries;
    std::unordered_set<std::string> seen;
    const std::string sid = brutv::sourceId(source);
    std::string info, fallbackGroup;
    std::unordered_map<std::string, std::string> headers;
    bool hls = false;
    std::size_t consumed = 0, pos = 0;
    while (pos < body.size()) {
        auto newline = body.find('\n', pos);
        auto end = newline == std::string_view::npos ? body.size() : newline;
        if (end - pos > kMaxLine) throw CatalogError("The playlist contains an overlong line.");
        consumed += end - pos + (newline == std::string_view::npos ? 0U : 1U);
        if (consumed > kMaxResponse) throw CatalogError("The playlist exceeds the size limit.");
        auto line = trim(body.substr(pos, end - pos));
        if (newline == std::string_view::npos) pos = body.size(); else pos = newline + 1;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        if (starts(line, "#EXTM3U") && parsedResult.xmltvUrl.empty()) {
            const auto headerAttrs = attributes(std::string_view(line).substr(7));
            std::string rawTvg;
            if (auto it = headerAttrs.find("url-tvg"); it != headerAttrs.end()) rawTvg = it->second;
            else if (auto it2 = headerAttrs.find("x-tvg-url"); it2 != headerAttrs.end()) rawTvg = it2->second;
            if (!rawTvg.empty()) {
                const auto comma = rawTvg.find(',');
                if (comma != std::string::npos) rawTvg.resize(comma);
                if (auto resolvedTvg = resolveUrl(source.url, rawTvg)) {
                    parsedResult.xmltvUrl = std::move(*resolvedTvg);
                }
            }
            continue;
        }
        if (starts(line, "#EXT-X-")) hls = true;
        if (starts(line, "#EXTINF")) { info = line; fallbackGroup.clear(); headers.clear(); }
        else if (starts(line, "#EXTGRP:")) fallbackGroup = trim(std::string_view(line).substr(line.find(':') + 1));
        else if (starts(line, "#EXTVLCOPT:")) addHeader(headers, std::string_view(line).substr(line.find(':') + 1));
        else if (starts(line, "#EXTHTTP:")) addJsonHeaders(headers, std::string_view(line).substr(line.find(':') + 1));
        else if (line.front() != '#') {
            auto resolved = resolveUrl(source.url, line);
            if (resolved) {
                auto comma = commaOutsideQuotes(info);
                std::unordered_map<std::string, std::string> attrs;
                std::string title;
                if (comma != std::string::npos) {
                    auto offset = std::min<std::size_t>(7, info.size());
                    attrs = attributes(std::string_view(info).substr(offset, comma - offset));
                    title = trim(std::string_view(info).substr(comma + 1));
                }
                if (title.empty()) {
                    if (auto it = attrs.find("tvg-name"); it != attrs.end()) title = it->second;
                }
                if (title.empty()) {
                    auto url = parseUrl(*resolved);
                    auto path = url ? url->path : *resolved;
                    auto slash = path.rfind('/');
                    title = path.substr(slash == std::string::npos ? 0 : slash + 1);
                    auto query = title.find('?');
                    if (query != std::string::npos) title.resize(query);
                }
                if (title.empty()) title = *resolved;
                std::string group;
                if (auto it = attrs.find("group-title"); it != attrs.end()) group = it->second;
                auto semi = group.find(';');
                if (semi != std::string::npos) group.resize(semi);
                if (group.empty()) group = fallbackGroup;
                if (group.empty()) group = std::string(kUncategorized);
                auto itemKey = "m3u:" + hash64(*resolved);
                if (seen.insert(itemKey).second) {
                    if (output.size() >= kMaxItems) throw CatalogError("The playlist has too many entries.");
                    MediaItem item;
                    item.sourceId = sid;
                    item.id = sid + ":" + itemKey;
                    item.providerId = itemKey;
                    item.title = std::move(title);
                    item.kind = classify(*resolved);
                    item.categoryId = group;
                    item.categoryName = group;
                    item.mediaUrl = *resolved;
                    if (auto it = attrs.find("tvg-logo"); it != attrs.end()) item.logoUrl = std::move(it->second);
                    if (auto it = attrs.find("tvg-id"); it != attrs.end()) item.epgId = std::move(it->second);
                    item.requestHeaders = headers;
                    output.push_back({std::move(item), std::move(group)});
                }
            }
            info.clear(); fallbackGroup.clear(); headers.clear();
        }
    }
    if (hls) throw CatalogError("This is an HLS media manifest, not an IPTV channel list.");
    return parsedResult;
}

std::string serverBase(const Source& source) {
    if (source.type != SourceType::Xtream || !validSource(source)) throw CatalogError("The provider address or sign-in is invalid.");
    auto url = *parseUrl(source.url);
    while (url.path.size() > 1 && url.path.back() == '/') url.path.pop_back();
    if (url.path == "/") url.path.clear();
    url.hasQuery = url.hasFragment = false; url.query.clear(); url.fragment.clear();
    return urlString(url);
}
std::string apiUrl(const Source& source, const std::vector<std::pair<std::string, std::string>>& params) {
    std::string url = serverBase(source) + "/player_api.php?username=" + encode(source.username) + "&password=" + encode(source.password);
    for (const auto& [key, value] : params) url += "&" + encode(key) + "=" + encode(value);
    return url;
}
std::string safeExtension(std::string_view extension) {
    std::string safe;
    safe.reserve(extension.size());
    for (unsigned char c : extension) {
        if (std::isalnum(c)) safe.push_back(lowerChar(static_cast<char>(c)));
    }
    if (safe.empty()) safe = "mp4";
    return safe;
}
std::string streamUrlWithPrefix(const std::string& prefix, std::string_view id, std::string_view extension) {
    return prefix + encode(std::string(id) + "." + safeExtension(extension));
}
std::string streamUrl(const Source& source, std::string_view type, std::string_view id, std::string extension) {
    const std::string prefix = serverBase(source) + "/" + std::string(type) + "/" +
                               encode(source.username) + "/" + encode(source.password) + "/";
    return streamUrlWithPrefix(prefix, id, extension);
}

std::string js(const Json& object, std::string_view key) {
    if (!object.is_object()) return {};
    auto it = object.find(std::string(key));
    if (it == object.end() || it->is_null()) return {};
    if (it->is_string()) return it->get<std::string>();
    if (it->is_number()) return it->dump();
    if (it->is_boolean()) return it->get<bool>() ? "true" : "false";
    return {};
}
std::int64_t ji(const Json& object, std::string_view key) {
    auto value = js(object, key);
    std::int64_t number = 0;
    auto parsed = std::from_chars(value.data(), value.data() + value.size(), number);
    return parsed.ec == std::errc{} && parsed.ptr == value.data() + value.size() ? number : 0;
}
Json providerJson(std::string_view response) {
    if (response.size() > kMaxResponse) throw CatalogError("The provider response exceeds the size limit.");
    response = stripBom(response);
    if (!jsonDepthWithin(response)) throw CatalogError("The provider response exceeds the nesting limit.");
    try {
        auto value = Json::parse(response.begin(), response.end());
        if (value.is_object() && value.contains("error")) throw CatalogError("The provider rejected the request.");
        return value;
    } catch (const CatalogError&) { throw; }
    catch (...) { throw CatalogError("The provider returned invalid JSON."); }
}
std::string requestRaw(const HttpGet& get, const Source& source, const std::vector<std::pair<std::string, std::string>>& params) {
    if (!get) throw CatalogError("No HTTP transport is configured.");
    try { return get(apiUrl(source, params)); }
    catch (...) { throw CatalogError("Could not connect to the provider."); }
}
Json requestJson(const HttpGet& get, const Source& source, const std::vector<std::pair<std::string, std::string>>& params) {
    return providerJson(requestRaw(get, source, params));
}

// Streaming SAX parser for Xtream categories array (zero DOM memory overhead).
class XtreamCategorySax : public nlohmann::json_sax<Json> {
public:
    XtreamCategorySax(MediaKind kind, std::vector<Category>& categories,
                      std::unordered_map<std::string, std::string>& categoryNames)
        : kind_(kind), categories_(categories), categoryNames_(categoryNames) {}

    bool depthExceeded = false;
    bool providerError = false;
    bool sizeExceeded = false;
    bool rootIsArray = false;
    bool rootStarted = false;
    bool syntaxError = false;

    bool null() override {
        if (!rootStarted) { rootStarted = true; return false; }
        clearKey();
        return true;
    }
    bool boolean(bool val) override {
        if (!rootStarted) { rootStarted = true; return false; }
        assignValue(val ? "true" : "false");
        return true;
    }
    bool number_integer(number_integer_t val) override {
        if (!rootStarted) { rootStarted = true; return false; }
        if (depth_ == 2) assignValue(std::to_string(val));
        return true;
    }
    bool number_unsigned(number_unsigned_t val) override {
        if (!rootStarted) { rootStarted = true; return false; }
        if (depth_ == 2) assignValue(std::to_string(val));
        return true;
    }
    bool number_float(number_float_t, const string_t& s) override {
        if (!rootStarted) { rootStarted = true; return false; }
        if (depth_ == 2) assignValue(s);
        return true;
    }
    bool string(string_t& val) override {
        if (!rootStarted) { rootStarted = true; return false; }
        if (depth_ == 2) assignMove(std::move(val));
        return true;
    }
    bool binary(binary_t&) override {
        clearKey();
        return true;
    }
    bool start_object(std::size_t) override {
        if (!rootStarted) {
            rootStarted = true;
            rootIsArray = false;
        }
        if (++depth_ > kMaxJsonDepth) {
            depthExceeded = true;
            return false;
        }
        if (rootIsArray && depth_ == 2) {
            if (++elementCount_ > kMaxItems) {
                sizeExceeded = true;
                return false;
            }
            catId_.clear();
            fallbackId_.clear();
            catName_.clear();
            field_ = Field::None;
        }
        return true;
    }
    bool key(string_t& val) override {
        if (!rootIsArray && depth_ == 1) {
            if (val == "error") {
                providerError = true;
                return false;
            }
            return true;
        }
        if (rootIsArray && depth_ == 2) {
            if (val == "category_id") field_ = Field::CategoryId;
            else if (val == "id") field_ = Field::Id;
            else if (val == "category_name") field_ = Field::CategoryName;
            else field_ = Field::None;
        }
        return true;
    }
    bool end_object() override {
        if (rootIsArray && depth_ == 2) {
            std::string id = !catId_.empty() ? std::move(catId_) : std::move(fallbackId_);
            if (!id.empty() && seen_.insert(id).second) {
                std::string name = catName_.empty() ? std::string(kUncategorized) : std::move(catName_);
                categoryNames_.emplace(id, name);
                categories_.push_back({std::move(id), std::move(name), kind_});
            }
            field_ = Field::None;
        }
        if (depth_ > 0) --depth_;
        return true;
    }
    bool start_array(std::size_t) override {
        if (!rootStarted) {
            rootStarted = true;
            rootIsArray = true;
        }
        if (++depth_ > kMaxJsonDepth) {
            depthExceeded = true;
            return false;
        }
        if (rootIsArray && depth_ == 2) {
            if (++elementCount_ > kMaxItems) {
                sizeExceeded = true;
                return false;
            }
        }
        return true;
    }
    bool end_array() override {
        if (depth_ > 0) --depth_;
        return true;
    }
    bool parse_error(std::size_t, const std::string&, const nlohmann::detail::exception&) override {
        syntaxError = true;
        return false;
    }

private:
    enum class Field { None, CategoryId, Id, CategoryName };
    void clearKey() { if (depth_ == 2) field_ = Field::None; }
    void assignValue(std::string_view val) {
        if (depth_ != 2) return;
        switch (field_) {
            case Field::CategoryId: catId_.assign(val.data(), val.size()); break;
            case Field::Id: fallbackId_.assign(val.data(), val.size()); break;
            case Field::CategoryName: catName_.assign(val.data(), val.size()); break;
            case Field::None: break;
        }
        field_ = Field::None;
    }
    void assignMove(std::string&& val) {
        if (depth_ != 2) return;
        switch (field_) {
            case Field::CategoryId: catId_ = std::move(val); break;
            case Field::Id: fallbackId_ = std::move(val); break;
            case Field::CategoryName: catName_ = std::move(val); break;
            case Field::None: break;
        }
        field_ = Field::None;
    }

    MediaKind kind_;
    std::vector<Category>& categories_;
    std::unordered_map<std::string, std::string>& categoryNames_;
    std::unordered_set<std::string> seen_;
    std::size_t depth_ = 0;
    std::size_t elementCount_ = 0;
    Field field_ = Field::None;
    std::string catId_, fallbackId_, catName_;
};

// Streaming SAX parser for Xtream Live/VOD/Series item arrays (zero DOM overhead).
class XtreamItemSax : public nlohmann::json_sax<Json> {
public:
    XtreamItemSax(MediaKind kind, std::string sid, std::string kindStr,
                  std::string livePrefix, std::string liveFormat,
                  std::string moviePrefix,
                  const std::unordered_map<std::string, std::string>& categoryNames,
                  std::vector<MediaItem>& items)
        : kind_(kind),
          sid_(std::move(sid)),
          idPrefix_(sid_ + ":" + kindStr + ":"),
          livePrefix_(std::move(livePrefix)),
          liveFormat_(safeExtension(liveFormat)),
          moviePrefix_(std::move(moviePrefix)),
          categoryNames_(categoryNames),
          items_(items) {}

    bool depthExceeded = false;
    bool providerError = false;
    bool sizeExceeded = false;
    bool rootIsArray = false;
    bool rootStarted = false;
    bool syntaxError = false;

    bool null() override {
        if (!rootStarted) { rootStarted = true; return false; }
        clearKey();
        return true;
    }
    bool boolean(bool val) override {
        if (!rootStarted) { rootStarted = true; return false; }
        if (depth_ == 2) assignValue(val ? "true" : "false");
        return true;
    }
    bool number_integer(number_integer_t val) override {
        if (!rootStarted) { rootStarted = true; return false; }
        if (depth_ == 2) assignValue(std::to_string(val));
        return true;
    }
    bool number_unsigned(number_unsigned_t val) override {
        if (!rootStarted) { rootStarted = true; return false; }
        if (depth_ == 2) assignValue(std::to_string(val));
        return true;
    }
    bool number_float(number_float_t, const string_t& s) override {
        if (!rootStarted) { rootStarted = true; return false; }
        if (depth_ == 2) assignValue(s);
        return true;
    }
    bool string(string_t& val) override {
        if (!rootStarted) { rootStarted = true; return false; }
        if (depth_ == 2) assignMove(std::move(val));
        return true;
    }
    bool binary(binary_t&) override {
        clearKey();
        return true;
    }
    bool start_object(std::size_t) override {
        if (!rootStarted) {
            rootStarted = true;
            rootIsArray = false;
        }
        if (++depth_ > kMaxJsonDepth) {
            depthExceeded = true;
            return false;
        }
        if (rootIsArray && depth_ == 2) {
            if (++elementCount_ > kMaxItems) {
                sizeExceeded = true;
                return false;
            }
            resetCurrent();
        }
        return true;
    }
    bool key(string_t& val) override {
        if (!rootIsArray && depth_ == 1) {
            if (val == "error") {
                providerError = true;
                return false;
            }
            return true;
        }
        if (rootIsArray && depth_ == 2) {
            if (kind_ == MediaKind::Series && val == "series_id") field_ = Field::PrimaryId;
            else if (kind_ != MediaKind::Series && val == "stream_id") field_ = Field::PrimaryId;
            else if (val == "id") field_ = Field::FallbackId;
            else if (val == "name") field_ = Field::Name;
            else if (val == "title") field_ = Field::Title;
            else if (val == "category_id") field_ = Field::CategoryId;
            else if (val == "container_extension") field_ = Field::ContainerExt;
            else if (val == "stream_icon") field_ = Field::StreamIcon;
            else if (val == "cover") field_ = Field::Cover;
            else if (val == "cover_big") field_ = Field::CoverBig;
            else if (val == "plot") field_ = Field::Plot;
            else if (val == "rating") field_ = Field::Rating;
            else if (val == "rating_5based") field_ = Field::Rating5;
            else if (val == "epg_channel_id") field_ = Field::EpgId;
            else field_ = Field::None;
        }
        return true;
    }
    bool end_object() override {
        if (rootIsArray && depth_ == 2) {
            std::string providerId = !primaryId_.empty() ? std::move(primaryId_) : std::move(fallbackId_);
            if (!providerId.empty()) {
                std::string id;
                id.reserve(idPrefix_.size() + providerId.size());
                id.append(idPrefix_);
                id.append(providerId);
                if (seenItems_.insert(id).second) {
                    MediaItem item;
                    item.id = std::move(id);
                    item.sourceId = sid_;
                    item.kind = kind_;
                    item.title = !name_.empty() ? std::move(name_)
                                                : (!title_.empty() ? std::move(title_) : std::string("Untitled"));
                    item.categoryId = std::move(categoryId_);
                    if (auto cat = categoryNames_.find(item.categoryId); cat != categoryNames_.end()) {
                        item.categoryName = cat->second;
                    }
                    if (kind_ == MediaKind::Live) {
                        item.mediaUrl = livePrefix_ + encode(providerId + "." + liveFormat_);
                    } else if (kind_ == MediaKind::Movie) {
                        item.mediaUrl = streamUrlWithPrefix(
                            moviePrefix_, providerId,
                            containerExt_.empty() ? std::string_view("mp4") : std::string_view(containerExt_));
                    }
                    item.providerId = std::move(providerId);
                    item.logoUrl = !streamIcon_.empty() ? std::move(streamIcon_)
                                 : (!cover_.empty() ? std::move(cover_) : std::move(coverBig_));
                    item.description = std::move(plot_);
                    item.rating = !rating_.empty() ? std::move(rating_) : std::move(rating5_);
                    item.epgId = std::move(epgId_);
                    items_.push_back(std::move(item));
                }
            }
            field_ = Field::None;
        }
        if (depth_ > 0) --depth_;
        return true;
    }
    bool start_array(std::size_t) override {
        if (!rootStarted) {
            rootStarted = true;
            rootIsArray = true;
        }
        if (++depth_ > kMaxJsonDepth) {
            depthExceeded = true;
            return false;
        }
        if (rootIsArray && depth_ == 2) {
            if (++elementCount_ > kMaxItems) {
                sizeExceeded = true;
                return false;
            }
        }
        return true;
    }
    bool end_array() override {
        if (depth_ > 0) --depth_;
        return true;
    }
    bool parse_error(std::size_t, const std::string&, const nlohmann::detail::exception&) override {
        syntaxError = true;
        return false;
    }

private:
    enum class Field {
        None, PrimaryId, FallbackId, Name, Title, CategoryId, ContainerExt,
        StreamIcon, Cover, CoverBig, Plot, Rating, Rating5, EpgId
    };
    void clearKey() { if (depth_ == 2) field_ = Field::None; }
    void resetCurrent() {
        primaryId_.clear(); fallbackId_.clear(); name_.clear(); title_.clear();
        categoryId_.clear(); containerExt_.clear(); streamIcon_.clear();
        cover_.clear(); coverBig_.clear(); plot_.clear(); rating_.clear();
        rating5_.clear(); epgId_.clear();
        field_ = Field::None;
    }
    void assignValue(std::string_view val) {
        if (depth_ != 2) return;
        std::string* target = targetField();
        if (target) target->assign(val.data(), val.size());
        field_ = Field::None;
    }
    void assignMove(std::string&& val) {
        if (depth_ != 2) return;
        std::string* target = targetField();
        if (target) *target = std::move(val);
        field_ = Field::None;
    }
    std::string* targetField() {
        switch (field_) {
            case Field::PrimaryId: return &primaryId_;
            case Field::FallbackId: return &fallbackId_;
            case Field::Name: return &name_;
            case Field::Title: return &title_;
            case Field::CategoryId: return &categoryId_;
            case Field::ContainerExt: return &containerExt_;
            case Field::StreamIcon: return &streamIcon_;
            case Field::Cover: return &cover_;
            case Field::CoverBig: return &coverBig_;
            case Field::Plot: return &plot_;
            case Field::Rating: return &rating_;
            case Field::Rating5: return &rating5_;
            case Field::EpgId: return &epgId_;
            case Field::None: return nullptr;
        }
        return nullptr;
    }

    MediaKind kind_;
    std::string sid_;
    std::string idPrefix_;
    std::string livePrefix_;
    std::string liveFormat_;
    std::string moviePrefix_;
    const std::unordered_map<std::string, std::string>& categoryNames_;
    std::vector<MediaItem>& items_;
    std::unordered_set<std::string> seenItems_;
    std::size_t depth_ = 0;
    std::size_t elementCount_ = 0;
    Field field_ = Field::None;
    std::string primaryId_, fallbackId_, name_, title_, categoryId_, containerExt_;
    std::string streamIcon_, cover_, coverBig_, plot_, rating_, rating5_, epgId_;
};

template <typename Sax>
void runXtreamSax(std::string_view response, Sax& sax, const char* invalidRootMessage) {
    if (response.size() > kMaxResponse) throw CatalogError("The provider response exceeds the size limit.");
    response = stripBom(response);
    const bool ok = Json::sax_parse(response.begin(), response.end(), &sax, Json::input_format_t::json, false);
    if (sax.depthExceeded) throw CatalogError("The provider response exceeds the nesting limit.");
    if (sax.providerError) throw CatalogError("The provider rejected the request.");
    if (sax.sizeExceeded) throw CatalogError("The provider catalog exceeds the size limit.");
    if (sax.syntaxError) throw CatalogError("The provider returned invalid JSON.");
    if (!sax.rootStarted) throw CatalogError("The provider returned invalid JSON.");
    if (!sax.rootIsArray) throw CatalogError(invalidRootMessage);
    if (!ok) throw CatalogError("The provider returned invalid JSON.");
}

std::optional<std::vector<std::pair<std::string, std::string>>> queryPairs(std::string_view query) {
    std::vector<std::pair<std::string, std::string>> result;
    std::size_t pos = 0;
    while (pos <= query.size()) {
        auto amp = query.find('&', pos);
        auto end = amp == std::string_view::npos ? query.size() : amp;
        auto part = query.substr(pos, end - pos);
        if (!part.empty()) {
            auto equals = part.find('=');
            auto key = decode(part.substr(0, equals));
            auto value = equals == std::string_view::npos ? std::optional<std::string>(std::string{}) : decode(part.substr(equals + 1));
            if (key && value) result.emplace_back(std::move(*key), std::move(*value));
        }
        if (amp == std::string_view::npos) break;
        pos = amp + 1;
    }
    return result;
}
std::optional<std::string> first(const std::vector<std::pair<std::string, std::string>>& query, std::string_view name) {
    for (const auto& [key, value] : query) if (ieq(key, name) && !trim(value).empty()) return trim(value);
    return std::nullopt;
}
std::optional<Source> fromXtream(std::string server, std::string username, std::string password) {
    auto url = parseUrl(server);
    if (!url || url->hasQuery || url->hasFragment || username.empty() || password.empty()) return std::nullopt;
    while (url->path.size() > 1 && url->path.back() == '/') url->path.pop_back();
    if (url->path == "/") url->path.clear();
    Source source;
    source.type = SourceType::Xtream; source.name = username; source.url = urlString(*url);
    source.username = std::move(username); source.password = std::move(password);
    return source;
}
std::optional<Source> fromPlaylist(std::string url) {
    auto parsed = parseUrl(url);
    if (!parsed) return std::nullopt;
    Source source; source.type = SourceType::M3U; source.name = parsed->host; source.url = std::move(url);
    return source;
}
std::optional<Source> fromQuery(std::string_view query) {
    auto values = queryPairs(query);
    if (!values) return std::nullopt;
    if (auto m3u = first(*values, "m3u")) return fromPlaylist(*m3u);
    auto server = first(*values, "server"), username = first(*values, "username"), password = first(*values, "password");
    if (!server || !username || !password) return std::nullopt;
    return fromXtream(*server, *username, *password);
}
bool universalJoin(const Url& url) {
    return url.scheme == "https" && !url.hasFragment &&
        (url.host == "brunovolpato.com" || url.host == "bvolpato.github.io") &&
        url.authority == url.host && url.path == "/brutv/join.html";
}

std::int64_t daysFromCivil(int year, unsigned month, unsigned day) {
    year -= month <= 2;
    const int era = (year >= 0 ? year : year - 399) / 400;
    const unsigned yoe = static_cast<unsigned>(year - era * 400);
    const unsigned adjusted = month > 2 ? month - 3 : month + 9;
    const unsigned doy = (153U * adjusted + 2U) / 5U + day - 1U;
    const unsigned doe = yoe * 365U + yoe / 4U - yoe / 100U + doy;
    return static_cast<std::int64_t>(era) * 146097 + doe - 719468;
}
std::int64_t parseDate(std::string_view s) {
    if (s.size() < 19) return 0;
    auto num = [&](std::size_t p, std::size_t n) {
        int value = 0; auto r = std::from_chars(s.data() + p, s.data() + p + n, value);
        return r.ec == std::errc{} && r.ptr == s.data() + p + n ? value : -1;
    };
    int y = num(0,4), m = num(5,2), d = num(8,2), h = num(11,2), mi = num(14,2), sec = num(17,2);
    if (y < 0 || m < 1 || m > 12 || d < 1 || d > 31 || h < 0 || h > 23 || mi < 0 || mi > 59 || sec < 0 || sec > 60) return 0;
    return daysFromCivil(y, static_cast<unsigned>(m), static_cast<unsigned>(d)) * 86400 + h * 3600 + mi * 60 + sec;
}
std::int64_t parseXmltvTimestamp(std::string_view s) {
    auto trimmed = trim(s);
    if (trimmed.size() < 14) return 0;
    auto num = [&](std::size_t p, std::size_t n) {
        int value = 0;
        auto r = std::from_chars(trimmed.data() + p, trimmed.data() + p + n, value);
        return r.ec == std::errc{} && r.ptr == trimmed.data() + p + n ? value : -1;
    };
    const int y = num(0, 4), m = num(4, 2), d = num(6, 2), h = num(8, 2), mi = num(10, 2), sec = num(12, 2);
    if (y < 1970 || m < 1 || m > 12 || d < 1 || d > 31 || h < 0 || h > 23 || mi < 0 || mi > 59 || sec < 0 || sec > 60)
        return 0;
    std::int64_t epoch = daysFromCivil(y, static_cast<unsigned>(m), static_cast<unsigned>(d)) * 86400 +
                         h * 3600 + mi * 60 + sec;
    // Optional timezone offset: +HHMM or -HHMM
    const auto tzPos = trimmed.find_first_of("+-", 14);
    if (tzPos != std::string::npos && tzPos + 5 <= trimmed.size()) {
        const int tzH = num(tzPos + 1, 2);
        const int tzM = num(tzPos + 3, 2);
        if (tzH >= 0 && tzH <= 23 && tzM >= 0 && tzM <= 59) {
            const std::int64_t offsetSec = static_cast<std::int64_t>(tzH) * 3600 + tzM * 60;
            epoch += (trimmed[tzPos] == '+') ? -offsetSec : offsetSec;
        }
    }
    return epoch;
}
std::string decodeXmlEntities(std::string_view input) {
    std::string out;
    out.reserve(input.size());
    for (std::size_t i = 0; i < input.size(); ++i) {
        if (input[i] == '&') {
            auto semi = input.find(';', i + 1);
            if (semi != std::string_view::npos && semi - i <= 10) {
                auto entity = input.substr(i + 1, semi - i - 1);
                if (entity == "amp") { out.push_back('&'); i = semi; continue; }
                if (entity == "lt") { out.push_back('<'); i = semi; continue; }
                if (entity == "gt") { out.push_back('>'); i = semi; continue; }
                if (entity == "quot") { out.push_back('"'); i = semi; continue; }
                if (entity == "apos") { out.push_back('\''); i = semi; continue; }
                if (!entity.empty() && entity[0] == '#') {
                    unsigned code = 0;
                    bool ok = false;
                    if (entity.size() > 2 && (entity[1] == 'x' || entity[1] == 'X')) {
                        auto r = std::from_chars(entity.data() + 2, entity.data() + entity.size(), code, 16);
                        ok = r.ec == std::errc{} && r.ptr == entity.data() + entity.size();
                    } else if (entity.size() > 1) {
                        auto r = std::from_chars(entity.data() + 1, entity.data() + entity.size(), code, 10);
                        ok = r.ec == std::errc{} && r.ptr == entity.data() + entity.size();
                    }
                    if (ok && code >= 0x20 && code < 0x80) {
                        out.push_back(static_cast<char>(code));
                        i = semi;
                        continue;
                    }
                }
            }
        }
        out.push_back(input[i]);
    }
    return out;
}
std::string xmlAttr(std::string_view tag, std::string_view attrName) {
    std::size_t pos = 0;
    while (pos < tag.size()) {
        auto found = tag.find(attrName, pos);
        if (found == std::string_view::npos) return {};
        const bool boundaryBefore = found == 0 || ws(tag[found - 1]);
        std::size_t after = found + attrName.size();
        while (after < tag.size() && ws(tag[after])) ++after;
        if (boundaryBefore && after < tag.size() && tag[after] == '=') {
            ++after;
            while (after < tag.size() && ws(tag[after])) ++after;
            if (after < tag.size() && (tag[after] == '"' || tag[after] == '\'')) {
                const char q = tag[after++];
                const auto end = tag.find(q, after);
                if (end != std::string_view::npos) {
                    return decodeXmlEntities(tag.substr(after, end - after));
                }
            }
        }
        pos = found + attrName.size();
    }
    return {};
}
std::string xmlElementText(std::string_view block, std::string_view tagName) {
    const std::string openPrefix = "<" + std::string(tagName);
    const std::string closeTag = "</" + std::string(tagName) + ">";
    auto start = block.find(openPrefix);
    if (start == std::string_view::npos) return {};
    auto tagEnd = block.find('>', start + openPrefix.size());
    if (tagEnd == std::string_view::npos) return {};
    auto close = block.find(closeTag, tagEnd + 1);
    if (close == std::string_view::npos) return {};
    return trim(decodeXmlEntities(block.substr(tagEnd + 1, close - tagEnd - 1)));
}
std::unordered_map<std::string, std::vector<EpgEntry>> parseXmltv(std::string_view xml) {
    std::unordered_map<std::string, std::vector<EpgEntry>> byChannel;
    if (xml.size() > kMaxResponse) return byChannel;
    xml = stripBom(xml);
    std::size_t pos = 0;
    while (pos < xml.size()) {
        const auto progStart = xml.find("<programme", pos);
        if (progStart == std::string_view::npos) break;
        const auto openEnd = xml.find('>', progStart + 10);
        if (openEnd == std::string_view::npos) break;
        const auto progEnd = xml.find("</programme>", openEnd + 1);
        if (progEnd == std::string_view::npos) break;
        const std::string_view openTag = xml.substr(progStart + 10, openEnd - progStart - 10);
        const std::string_view body = xml.substr(openEnd + 1, progEnd - openEnd - 1);
        pos = progEnd + 12;

        std::string channel = xmlAttr(openTag, "channel");
        if (channel.empty()) continue;
        auto& list = byChannel[channel];
        if (list.size() >= kMaxEpgEntries) continue;
        EpgEntry entry;
        entry.title = xmlElementText(body, "title");
        if (entry.title.empty()) continue;
        entry.description = xmlElementText(body, "desc");
        entry.startEpochSeconds = parseXmltvTimestamp(xmlAttr(openTag, "start"));
        entry.endEpochSeconds = parseXmltvTimestamp(xmlAttr(openTag, "stop"));
        if (entry.startEpochSeconds > 0) {
            list.push_back(std::move(entry));
        }
    }
    for (auto& [ch, entries] : byChannel) {
        std::sort(entries.begin(), entries.end(), [](const EpgEntry& a, const EpgEntry& b) {
            return a.startEpochSeconds < b.startEpochSeconds;
        });
    }
    return byChannel;
}

std::string decodeBase64(std::string value) {
    static constexpr std::string_view alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    if (value.size() < 8 || value.size() > 1'000'000 || value.find_first_of(" \t\r\n") != std::string::npos) return value;
    const bool hadPadding = value.find('=') != std::string::npos;
    while (!value.empty() && value.back() == '=') value.pop_back();
    if (value.size() % 4 == 1) return value;
    bool hint = hadPadding || value.find_first_of("0123456789+/") != std::string::npos;
    std::string out;
    std::uint32_t buffer = 0; int bits = 0;
    for (char c : value) {
        auto idx = alphabet.find(c);
        if (idx == std::string_view::npos) return value;
        buffer = (buffer << 6U) | static_cast<std::uint32_t>(idx); bits += 6;
        if (bits >= 8) { bits -= 8; out.push_back(static_cast<char>((buffer >> bits) & 0xffU)); }
    }
    if (out.empty() || (!hint && std::all_of(out.begin(), out.end(), [](unsigned char c) { return std::isalnum(c) != 0; }))) return value;
    if (std::any_of(out.begin(), out.end(), [](unsigned char c) { return c == 0 || (c < 0x20 && c != '\n' && c != '\r' && c != '\t'); })) return value;
    return out;
}
std::vector<EpgEntry> epgEntries(const Json& root) {
    if (!root.is_object() || !root.contains("epg_listings") || !root["epg_listings"].is_array()) return {};
    const auto& listings = root["epg_listings"];
    std::vector<EpgEntry> out;
    out.reserve(std::min<std::size_t>(listings.size(), kMaxEpgEntries));
    for (const auto& item : listings) {
        if (out.size() >= kMaxEpgEntries) break;
        if (!item.is_object()) continue;
        EpgEntry epg; epg.title = js(item, "title");
        if (epg.title.empty()) epg.title = js(item, "name");
        if (epg.title.empty()) continue;
        epg.description = js(item, "description");
        epg.startEpochSeconds = ji(item, "start_timestamp");
        if (!epg.startEpochSeconds) epg.startEpochSeconds = parseDate(js(item, "start"));
        epg.endEpochSeconds = ji(item, "stop_timestamp");
        if (!epg.endEpochSeconds) epg.endEpochSeconds = parseDate(js(item, "end"));
        epg.title = decodeBase64(std::move(epg.title));
        epg.description = decodeBase64(std::move(epg.description));
        out.push_back(std::move(epg));
    }
    return out;
}
std::vector<std::string> objectKeys(const Json& object) {
    std::vector<std::string> keys;
    if (!object.is_object()) return keys;
    for (auto it = object.begin(); it != object.end(); ++it) keys.push_back(it.key());
    auto numeric = [](const std::string& value) -> std::optional<unsigned long long> {
        unsigned long long number = 0; auto r = std::from_chars(value.data(), value.data()+value.size(), number);
        if (r.ec != std::errc{} || r.ptr != value.data()+value.size()) return std::nullopt;
        return number;
    };
    std::stable_sort(keys.begin(), keys.end(), [&](const auto& a, const auto& b) {
        auto x = numeric(a), y = numeric(b);
        if (x && y) return *x < *y;
        if (x) return true;
        if (y) return false;
        return a < b;
    });
    return keys;
}

bool writeAll(int fd, const char* data, std::size_t size) {
    std::size_t offset = 0;
    while (offset < size) {
        auto written = ::write(fd, data + offset, size - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return false;
        offset += static_cast<std::size_t>(written);
    }
    return true;
}

// Compact binary on-disk catalog cache (TTL + fingerprint verified, mode 0600).
constexpr std::array<char, 4> kDiskCacheMagic = {'B', 'T', 'V', 'K'};
constexpr std::uint32_t kDiskCacheVersion = 1U;

struct BinWriter {
    std::string buf;
    template <typename T>
    void writePod(const T& v) {
        buf.append(reinterpret_cast<const char*>(&v), sizeof(T));
    }
    void writeStr(std::string_view s) {
        const std::uint32_t len = static_cast<std::uint32_t>(s.size());
        writePod(len);
        buf.append(s.data(), s.size());
    }
};

struct BinReader {
    std::string_view buf;
    std::size_t pos = 0;
    template <typename T>
    bool readPod(T& out) {
        if (sizeof(T) > buf.size() - pos) return false;
        std::memcpy(&out, buf.data() + pos, sizeof(T));
        pos += sizeof(T);
        return true;
    }
    bool readStr(std::string& out, std::size_t maxLen = 65536) {
        std::uint32_t len = 0;
        if (!readPod(len) || len > maxLen || len > buf.size() - pos) return false;
        out.assign(buf.data() + pos, len);
        pos += len;
        return true;
    }
};

std::filesystem::path diskCachePath(const std::filesystem::path& dir, const std::string& sid, MediaKind kind) {
    return dir / ("catalog-" + hash64(sid + "|" + kindName(kind)) + ".bin");
}

std::string catalogFingerprint(const Source& source, const std::string& liveFormat) {
    return hash64(typeName(source.type) + "|" + source.url + "|" + source.username + "|" +
                  source.password + "|" + liveFormat);
}

std::optional<Catalog> readDiskCache(const std::filesystem::path& path,
                                     const std::string& expectedFingerprint,
                                     std::chrono::seconds ttl) {
    if (ttl.count() <= 0) return std::nullopt;
    std::error_code ec;
    const auto sz = std::filesystem::file_size(path, ec);
    if (ec || sz < 16 || sz > kMaxResponse) return std::nullopt;
    std::ifstream in(path, std::ios::binary);
    if (!in) return std::nullopt;
    std::string bytes(static_cast<std::size_t>(sz), '\0');
    in.read(bytes.data(), static_cast<std::streamsize>(sz));
    if (!in) return std::nullopt;

    BinReader r{bytes, 0};
    std::array<char, 4> magic{};
    std::uint32_t version = 0;
    std::int64_t savedAt = 0;
    std::string fingerprint;
    if (!r.readPod(magic) || magic != kDiskCacheMagic ||
        !r.readPod(version) || version != kDiskCacheVersion ||
        !r.readPod(savedAt) || !r.readStr(fingerprint, 64)) {
        return std::nullopt;
    }
    const auto now = static_cast<std::int64_t>(std::time(nullptr));
    if (fingerprint != expectedFingerprint || now < savedAt || (now - savedAt) > ttl.count()) {
        return std::nullopt;
    }
    std::uint32_t catCount = 0;
    if (!r.readPod(catCount) || catCount > kMaxItems) return std::nullopt;
    Catalog catalog;
    catalog.categories.reserve(catCount);
    for (std::uint32_t i = 0; i < catCount; ++i) {
        Category c;
        std::uint8_t k = 0;
        if (!r.readStr(c.id, 1024) || !r.readStr(c.name, 4096) || !r.readPod(k) || k > 3)
            return std::nullopt;
        c.kind = static_cast<MediaKind>(k);
        catalog.categories.push_back(std::move(c));
    }
    std::uint32_t itemCount = 0;
    if (!r.readPod(itemCount) || itemCount > kMaxItems) return std::nullopt;
    catalog.items.reserve(itemCount);
    for (std::uint32_t i = 0; i < itemCount; ++i) {
        MediaItem item;
        std::uint8_t k = 0;
        std::uint32_t hdrCount = 0;
        if (!r.readStr(item.id, 1024) || !r.readStr(item.sourceId, 256) ||
            !r.readStr(item.providerId, 1024) || !r.readStr(item.title, 4096) ||
            !r.readPod(k) || k > 3 || !r.readStr(item.categoryId, 1024) ||
            !r.readStr(item.categoryName, 4096) || !r.readStr(item.mediaUrl, 8192) ||
            !r.readStr(item.logoUrl, 8192) || !r.readStr(item.description, 16384) ||
            !r.readStr(item.rating, 256) || !r.readStr(item.epgId, 1024) ||
            !r.readPod(hdrCount) || hdrCount > 64) {
            return std::nullopt;
        }
        item.kind = static_cast<MediaKind>(k);
        for (std::uint32_t h = 0; h < hdrCount; ++h) {
            std::string hk, hv;
            if (!r.readStr(hk, 128) || !r.readStr(hv, 4096)) return std::nullopt;
            item.requestHeaders.emplace(std::move(hk), std::move(hv));
        }
        catalog.items.push_back(std::move(item));
    }
    return catalog;
}

void writeDiskCache(const std::filesystem::path& path, const std::string& fingerprint,
                    const Catalog& catalog) {
    try {
        std::error_code ec;
        std::filesystem::create_directories(path.parent_path(), ec);
        if (ec) return;
        BinWriter w;
        w.buf.reserve(catalog.items.size() * 256 + 1024);
        w.writePod(kDiskCacheMagic);
        w.writePod(kDiskCacheVersion);
        w.writePod(static_cast<std::int64_t>(std::time(nullptr)));
        w.writeStr(fingerprint);
        w.writePod(static_cast<std::uint32_t>(catalog.categories.size()));
        for (const auto& c : catalog.categories) {
            w.writeStr(c.id);
            w.writeStr(c.name);
            w.writePod(static_cast<std::uint8_t>(c.kind));
        }
        w.writePod(static_cast<std::uint32_t>(catalog.items.size()));
        for (const auto& item : catalog.items) {
            w.writeStr(item.id);
            w.writeStr(item.sourceId);
            w.writeStr(item.providerId);
            w.writeStr(item.title);
            w.writePod(static_cast<std::uint8_t>(item.kind));
            w.writeStr(item.categoryId);
            w.writeStr(item.categoryName);
            w.writeStr(item.mediaUrl);
            w.writeStr(item.logoUrl);
            w.writeStr(item.description);
            w.writeStr(item.rating);
            w.writeStr(item.epgId);
            w.writePod(static_cast<std::uint32_t>(item.requestHeaders.size()));
            for (const auto& [hk, hv] : item.requestHeaders) {
                w.writeStr(hk);
                w.writeStr(hv);
            }
        }
        if (w.buf.size() > kMaxResponse) return;
        std::string tmp = path.string() + ".tmp.XXXXXX";
        std::vector<char> tmpName(tmp.begin(), tmp.end());
        tmpName.push_back('\0');
        int fd = ::mkstemp(tmpName.data());
        if (fd < 0) return;
        bool ok = (::fchmod(fd, S_IRUSR | S_IWUSR) == 0 || errno == ENOSYS || errno == EPERM) &&
                  writeAll(fd, w.buf.data(), w.buf.size());
        if (::close(fd) != 0) ok = false;
        if (!ok || ::rename(tmpName.data(), path.c_str()) != 0) {
            (void)::unlink(tmpName.data());
        }
    } catch (...) {
        // On-disk cache is best-effort; ignore storage errors.
    }
}
} // namespace

struct CatalogClient::CacheState {
    struct CachedM3u {
        std::shared_ptr<const ParsedPlaylist> playlist;
        std::chrono::steady_clock::time_point fetchedAt{};
    };
    struct CachedXmltv {
        std::unordered_map<std::string, std::vector<EpgEntry>> byChannel;
        std::chrono::steady_clock::time_point fetchedAt{};
    };
    mutable std::mutex mutex;
    std::unordered_map<std::string, CachedM3u> m3uByKey;
    std::unordered_map<std::string, std::string> xmltvBySource;
    std::unordered_map<std::string, CachedXmltv> xmltvData;
    std::filesystem::path diskDir;
    std::chrono::seconds diskTtl{0};

    std::shared_ptr<const ParsedPlaylist> getOrFetchM3u(const HttpGet& httpGet, const Source& source) {
        const std::string sid = sourceId(source);
        const std::string key = sid + "|" + source.url;
        const auto now = std::chrono::steady_clock::now();
        {
            std::lock_guard<std::mutex> lock(mutex);
            auto it = m3uByKey.find(key);
            if (it != m3uByKey.end() && (now - it->second.fetchedAt) < kM3uMemoryCacheTtl &&
                it->second.playlist) {
                return it->second.playlist;
            }
        }
        if (!validSource(source)) throw CatalogError("The playlist address is invalid.");
        if (!httpGet) throw CatalogError("No HTTP transport is configured.");
        std::string response;
        try { response = httpGet(source.url); }
        catch (...) { throw CatalogError("Could not connect to the provider."); }
        auto parsed = std::make_shared<ParsedPlaylist>(parsePlaylist(response, source));
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (m3uByKey.size() >= 4) m3uByKey.clear();
            m3uByKey[key] = {parsed, std::chrono::steady_clock::now()};
            if (!parsed->xmltvUrl.empty()) {
                xmltvBySource[sid] = parsed->xmltvUrl;
            }
        }
        return parsed;
    }
};

std::string sourceId(const Source& source) {
    if (!source.id.empty()) return source.id;
    std::string identity = typeName(source.type) + "|" + trim(source.url);
    if (source.type == SourceType::Xtream) identity += "|" + trim(source.username);
    return "source:" + hash64(identity);
}
std::optional<Source> parseLoginLink(const std::string& input) {
    if (input.size() > 8192) return std::nullopt;
    std::string text = trim(input);
    while (text.size() >= 2 && ((text.front() == '"' && text.back() == '"') || (text.front() == '\'' && text.back() == '\'')))
        text = trim(std::string_view(text).substr(1, text.size() - 2));
    if (text.empty()) return std::nullopt;
    if (starts(text, "brutv:")) {
        std::string_view rest(text); rest.remove_prefix(6);
        while (!rest.empty() && rest.front() == '/') rest.remove_prefix(1);
        auto end = rest.find_first_of("?#");
        auto route = rest.substr(0, end);
        while (!route.empty() && route.back() == '/') route.remove_suffix(1);
        if (!ieq(route, "login") || end == std::string_view::npos || rest[end] != '?') return std::nullopt;
        auto query = rest.substr(end + 1);
        auto fragment = query.find('#');
        if (fragment != std::string_view::npos) query = query.substr(0, fragment);
        return fromQuery(query);
    }
    auto url = parseUrl(text);
    if (!url) return std::nullopt;
    if (universalJoin(*url)) return fromQuery(url->query);
    auto path = lower(url->path);
    auto getPhp = path.rfind("get.php");
    if (getPhp != std::string::npos && getPhp + 7 == path.size()) {
        auto query = queryPairs(url->query);
        if (query) {
            auto username = first(*query, "username"), password = first(*query, "password");
            if (username && password) {
                url->path.resize(getPhp);
                while (!url->path.empty() && url->path.back() == '/') url->path.pop_back();
                url->hasQuery = url->hasFragment = false; url->query.clear(); url->fragment.clear();
                return fromXtream(urlString(*url), *username, *password);
            }
        }
    }
    return fromPlaylist(text);
}

std::optional<std::string> alternateXtreamLiveUrl(const std::string& url) {
    if (url.empty() || url.size() > 8192) return std::nullopt;
    for (unsigned char c : url) {
        if (c <= 0x20 || c == 0x7f || c == '\\') return std::nullopt;
    }
    const std::string_view view(url);
    const std::size_t schemeEnd = view.find("://");
    if (schemeEnd == std::string_view::npos) return std::nullopt;
    const std::string_view scheme = view.substr(0, schemeEnd);
    if (!ieq(scheme, "http") && !ieq(scheme, "https")) return std::nullopt;
    const std::size_t authStart = schemeEnd + 3;
    const std::size_t pathStart = view.find('/', authStart);
    if (pathStart == std::string_view::npos || pathStart == authStart) return std::nullopt;
    const std::size_t suffixStart = view.find_first_of("?#", pathStart);
    const std::size_t pathEnd = suffixStart == std::string_view::npos ? view.size() : suffixStart;
    const std::string_view path = view.substr(pathStart, pathEnd - pathStart);
    const std::string_view suffix =
        suffixStart == std::string_view::npos ? std::string_view{} : view.substr(suffixStart);

    std::vector<std::string_view> segments;
    std::size_t pos = 1;
    while (pos <= path.size()) {
        const std::size_t slash = path.find('/', pos);
        const std::size_t end = slash == std::string_view::npos ? path.size() : slash;
        segments.push_back(path.substr(pos, end - pos));
        if (slash == std::string_view::npos) break;
        pos = slash + 1;
    }
    if (segments.size() < 3) return std::nullopt;
    for (const auto segment : segments) {
        if (segment.empty()) return std::nullopt;
    }
    const std::size_t count = segments.size();
    const bool hasLivePrefix = count >= 4 && ieq(segments[count - 4], "live");
    const auto isNonLiveRoot = [](std::string_view root) {
        return ieq(root, "movie") || ieq(root, "series") || ieq(root, "timeshift") ||
               ieq(root, "vod") || ieq(root, "hls") || ieq(root, "streams") ||
               ieq(root, "static") || ieq(root, "assets");
    };
    const bool isShortXtreamLive = count == 3 && !isNonLiveRoot(segments[0]);
    if (!hasLivePrefix && !isShortXtreamLive) {
        return std::nullopt;
    }
    const std::string_view leaf = segments[count - 1];
    std::size_t extLength = 0;
    std::string_view replacementExt;
    if (leaf.size() > 5 && ieq(leaf.substr(leaf.size() - 5), ".m3u8")) {
        extLength = 5;
        replacementExt = ".ts";
    } else if (leaf.size() > 3 && ieq(leaf.substr(leaf.size() - 3), ".ts")) {
        extLength = 3;
        replacementExt = ".m3u8";
    } else {
        return std::nullopt;
    }

    std::string out;
    out.reserve(url.size() + 2);
    out.append(view.substr(0, pathEnd - extLength));
    out.append(replacementExt);
    out.append(suffix);
    return out;
}

CatalogClient::CatalogClient(HttpGet httpGet, bool allowParallelFetch)
    : httpGet_(std::move(httpGet)),
      allowParallelFetch_(allowParallelFetch),
      cache_(std::make_unique<CacheState>()) {}

CatalogClient::~CatalogClient() = default;

void CatalogClient::setCacheDirectory(std::filesystem::path directory, std::chrono::seconds ttl) {
    std::lock_guard<std::mutex> lock(cache_->mutex);
    cache_->diskDir = std::move(directory);
    cache_->diskTtl = ttl;
}

void CatalogClient::invalidateCache(const std::string& sourceKey) const {
    std::filesystem::path dir;
    {
        std::lock_guard<std::mutex> lock(cache_->mutex);
        cache_->m3uByKey.clear();
        cache_->xmltvData.clear();
        if (sourceKey.empty()) {
            cache_->xmltvBySource.clear();
        } else {
            cache_->xmltvBySource.erase(sourceKey);
        }
        dir = cache_->diskDir;
    }
    if (dir.empty()) return;
    std::error_code ec;
    if (sourceKey.empty()) {
        std::filesystem::remove_all(dir, ec);
    } else {
        for (const auto kind : {MediaKind::Live, MediaKind::Movie, MediaKind::Series}) {
            std::filesystem::remove(diskCachePath(dir, sourceKey, kind), ec);
        }
    }
}

std::string CatalogClient::xmltvUrl(const Source& source) const {
    std::lock_guard<std::mutex> lock(cache_->mutex);
    const auto it = cache_->xmltvBySource.find(sourceId(source));
    return it == cache_->xmltvBySource.end() ? std::string{} : it->second;
}

std::string CatalogClient::preferredLiveFormat(const Source& source) const {
    std::lock_guard<std::mutex> lock(formatMutex_);
    const auto found = preferredLiveFormats_.find(sourceId(source));
    if (found != preferredLiveFormats_.end() && !found->second.empty()) {
        return found->second;
    }
    return "m3u8";
}

void CatalogClient::setPreferredLiveFormat(const Source& source, std::string format) {
    format = lower(trim(format));
    if (format == "hls") format = "m3u8";
    else if (format == "mpegts") format = "ts";
    if (format != "m3u8" && format != "ts") return;
    std::lock_guard<std::mutex> lock(formatMutex_);
    preferredLiveFormats_[sourceId(source)] = std::move(format);
}

void CatalogClient::authenticate(const Source& source) const {
    if (source.type == SourceType::M3U) {
        auto parsed = cache_->getOrFetchM3u(httpGet_, source);
        if (parsed->entries.empty()) throw CatalogError("The playlist contains no supported HTTP streams.");
        return;
    }
    const auto response = requestJson(httpGet_, source, {});
    if (!response.is_object() || !response.contains("user_info") || !response["user_info"].is_object())
        throw CatalogError("The provider returned an invalid sign-in response.");
    const auto& user = response["user_info"];
    const auto auth = lower(js(user, "auth"));
    const auto status = lower(js(user, "status"));
    if ((auth != "1" && auth != "true") || status == "disabled" || status == "expired")
        throw CatalogError("The provider rejected this sign-in.");
    if (user.contains("allowed_output_formats") && user["allowed_output_formats"].is_array()) {
        bool allowsM3u8 = false;
        bool allowsTs = false;
        for (const auto& entry : user["allowed_output_formats"]) {
            if (!entry.is_string()) continue;
            const auto fmt = lower(trim(entry.get<std::string>()));
            if (fmt == "m3u8" || fmt == "hls") allowsM3u8 = true;
            else if (fmt == "ts" || fmt == "mpegts") allowsTs = true;
        }
        if (allowsM3u8 || allowsTs) {
            std::lock_guard<std::mutex> lock(formatMutex_);
            preferredLiveFormats_[sourceId(source)] = allowsM3u8 ? "m3u8" : "ts";
        }
    }
}

Catalog CatalogClient::load(const Source& source, MediaKind kind) const {
    Catalog result;
    const std::string sid = sourceId(source);
    const std::string liveFmt = preferredLiveFormat(source);

    std::filesystem::path cacheDir;
    std::chrono::seconds cacheTtl{0};
    {
        std::lock_guard<std::mutex> lock(cache_->mutex);
        cacheDir = cache_->diskDir;
        cacheTtl = cache_->diskTtl;
    }
    const std::string fingerprint = catalogFingerprint(source, liveFmt);
    if (!cacheDir.empty() && cacheTtl.count() > 0 && kind != MediaKind::Episode) {
        if (auto cached = readDiskCache(diskCachePath(cacheDir, sid, kind), fingerprint, cacheTtl)) {
            return *cached;
        }
    }

    if (source.type == SourceType::M3U) {
        auto parsed = cache_->getOrFetchM3u(httpGet_, source);
        std::unordered_set<std::string> categories;
        result.items.reserve(parsed->entries.size());
        for (const auto& entry : parsed->entries) {
            if (entry.item.kind != kind) continue;
            if (categories.insert(entry.group).second) {
                result.categories.push_back({entry.group, entry.group, kind});
            }
            result.items.push_back(entry.item);
        }
        if (!cacheDir.empty() && cacheTtl.count() > 0 && kind != MediaKind::Episode) {
            writeDiskCache(diskCachePath(cacheDir, sid, kind), fingerprint, result);
        }
        return result;
    }

    const char* categoryAction = nullptr;
    const char* itemAction = nullptr;
    switch (kind) {
        case MediaKind::Live: categoryAction = "get_live_categories"; itemAction = "get_live_streams"; break;
        case MediaKind::Movie: categoryAction = "get_vod_categories"; itemAction = "get_vod_streams"; break;
        case MediaKind::Series: categoryAction = "get_series_categories"; itemAction = "get_series"; break;
        case MediaKind::Episode: return result;
    }

    // Hoist URL base & encoded credentials once before parsing all items.
    const std::string base = serverBase(source);
    const std::string encUser = encode(source.username);
    const std::string encPass = encode(source.password);
    const std::string livePrefix = base + "/live/" + encUser + "/" + encPass + "/";
    const std::string moviePrefix = base + "/movie/" + encUser + "/" + encPass + "/";

    std::string categoryBody;
    std::string itemBody;
    if (allowParallelFetch_ && httpGet_) {
        const std::string catUrl = apiUrl(source, {{"action", categoryAction}});
        const std::string itmUrl = apiUrl(source, {{"action", itemAction}});
        auto catFuture = std::async(std::launch::async, [this, catUrl]() {
            try { return httpGet_(catUrl); }
            catch (...) { throw CatalogError("Could not connect to the provider."); }
        });
        try {
            itemBody = httpGet_(itmUrl);
        } catch (...) {
            try { (void)catFuture.get(); } catch (...) {}
            throw CatalogError("Could not connect to the provider.");
        }
        categoryBody = catFuture.get();
    } else {
        categoryBody = requestRaw(httpGet_, source, {{"action", categoryAction}});
        itemBody = requestRaw(httpGet_, source, {{"action", itemAction}});
    }

    std::unordered_map<std::string, std::string> categoryNames;
    {
        XtreamCategorySax catSax(kind, result.categories, categoryNames);
        runXtreamSax(categoryBody, catSax, "The provider returned an invalid category response.");
    }
    categoryBody.clear();
    categoryBody.shrink_to_fit();

    {
        XtreamItemSax itemSax(kind, sid, kindName(kind), livePrefix, liveFmt, moviePrefix,
                              categoryNames, result.items);
        runXtreamSax(itemBody, itemSax, "The provider returned an invalid catalog response.");
    }
    itemBody.clear();
    itemBody.shrink_to_fit();

    if (!cacheDir.empty() && cacheTtl.count() > 0) {
        writeDiskCache(diskCachePath(cacheDir, sid, kind), fingerprint, result);
    }
    return result;
}

std::vector<MediaItem> CatalogClient::loadEpisodes(const Source& source, const std::string& seriesId) const {
    if (source.type != SourceType::Xtream || seriesId.empty() || seriesId.size() > 1024) return {};
    const auto root = requestJson(httpGet_, source, {{"action", "get_series_info"}, {"series_id", seriesId}});
    if (!root.is_object() || !root.contains("episodes") || !root["episodes"].is_object()) return {};
    const auto& seasons = root["episodes"];
    if (seasons.size() > 1000) throw CatalogError("The provider returned too many seasons.");
    const auto sid = sourceId(source);
    const std::string seriesPrefix = serverBase(source) + "/series/" + encode(source.username) +
                                     "/" + encode(source.password) + "/";
    std::vector<MediaItem> result;
    std::unordered_set<std::string> seen;
    for (const auto& seasonKey : objectKeys(seasons)) {
        const auto& episodes = seasons[seasonKey];
        if (!episodes.is_array()) continue;
        if (episodes.size() > kMaxItems - result.size()) throw CatalogError("The provider returned too many episodes.");
        int season = -1;
        auto parsedSeason = std::from_chars(seasonKey.data(), seasonKey.data() + seasonKey.size(), season);
        if (parsedSeason.ec != std::errc{} || parsedSeason.ptr != seasonKey.data() + seasonKey.size()) season = -1;
        for (const auto& episode : episodes) {
            if (!episode.is_object()) continue;
            auto providerId = js(episode, "id");
            if (providerId.empty()) providerId = js(episode, "episode_id");
            if (providerId.empty() || !seen.insert(providerId).second) continue;
            auto numberText = js(episode, "episode_num");
            int number = -1;
            if (!numberText.empty()) {
                auto parsed = std::from_chars(numberText.data(), numberText.data() + numberText.size(), number);
                if (parsed.ec != std::errc{} || parsed.ptr != numberText.data() + numberText.size()) number = -1;
            }
            auto extension = js(episode, "container_extension");
            if (extension.empty()) extension = "mp4";
            const Json info = episode.contains("info") && episode["info"].is_object() ? episode["info"] : Json::object();
            MediaItem item;
            item.id = sid + ":episode:" + providerId;
            item.sourceId = sid;
            item.providerId = providerId;
            item.kind = MediaKind::Episode;
            item.title = js(episode, "title");
            if (item.title.empty()) {
                std::ostringstream title;
                title << "Series " << seriesId << " - S" << (season < 0 ? 0 : season) << "E" << (number < 0 ? 0 : number);
                item.title = title.str();
            }
            item.mediaUrl = streamUrlWithPrefix(seriesPrefix, providerId, extension);
            item.logoUrl = js(info, "movie_image");
            item.description = js(info, "plot");
            item.rating = js(info, "rating");
            EpisodeDetails details;
            if (season >= 0) details.seasonNumber = season;
            if (number >= 0) details.episodeNumber = number;
            details.plot = item.description;
            details.durationSeconds = ji(info, "duration_secs");
            details.airDate = js(info, "releasedate");
            item.episodeDetails = std::move(details);
            result.push_back(std::move(item));
        }
    }
    return result;
}

std::vector<EpgEntry> CatalogClient::loadEpg(const Source& source, const std::string& streamId) const {
    if (streamId.empty() || streamId.size() > 1024) return {};
    if (source.type == SourceType::M3U) {
        std::string tvgUrl = xmltvUrl(source);
        if (tvgUrl.empty()) {
            // Ensure M3U header has been parsed at least once for url-tvg.
            try {
                auto parsed = cache_->getOrFetchM3u(httpGet_, source);
                tvgUrl = parsed->xmltvUrl;
            } catch (...) {
                return {};
            }
        }
        if (tvgUrl.empty() || !httpGet_) return {};
        const auto now = std::chrono::steady_clock::now();
        {
            std::lock_guard<std::mutex> lock(cache_->mutex);
            auto it = cache_->xmltvData.find(tvgUrl);
            if (it != cache_->xmltvData.end() && (now - it->second.fetchedAt) < kXmltvMemoryCacheTtl) {
                auto ch = it->second.byChannel.find(streamId);
                return ch == it->second.byChannel.end() ? std::vector<EpgEntry>{} : ch->second;
            }
        }
        std::string xml;
        try { xml = httpGet_(tvgUrl); }
        catch (...) { throw CatalogError("Could not fetch XMLTV guide."); }
        auto parsed = parseXmltv(xml);
        std::vector<EpgEntry> out;
        if (auto ch = parsed.find(streamId); ch != parsed.end()) out = ch->second;
        {
            std::lock_guard<std::mutex> lock(cache_->mutex);
            if (cache_->xmltvData.size() >= 2) cache_->xmltvData.clear();
            cache_->xmltvData[tvgUrl] = {std::move(parsed), std::chrono::steady_clock::now()};
        }
        return out;
    }
    auto root = requestJson(httpGet_, source, {{"action", "get_short_epg"}, {"stream_id", streamId}, {"limit", "24"}});
    return epgEntries(root);
}

namespace {
Json sourceJson(const Source& source) {
    return Json{{"id", source.id}, {"name", source.name}, {"type", typeName(source.type)},
                {"url", source.url}, {"username", source.username}, {"password", source.password}};
}
std::optional<Source> sourceFromJson(const Json& value) {
    if (!value.is_object()) return std::nullopt;
    Source source;
    source.id = js(value, "id");
    source.name = js(value, "name");
    auto type = js(value, "type");
    if (type == "m3u") source.type = SourceType::M3U;
    else if (type == "xtream") source.type = SourceType::Xtream;
    else return std::nullopt;
    source.url = js(value, "url");
    source.username = js(value, "username");
    source.password = js(value, "password");
    if (source.name.size() > 256 || source.id.size() > 256 || source.url.size() > 8192 ||
        source.username.size() > 1024 || source.password.size() > 4096) return std::nullopt;
    return source;
}
Json mediaJson(const MediaItem& item) {
    Json headers = Json::object();
    for (const auto& [key, value] : item.requestHeaders) headers[key] = value;
    Json details = nullptr;
    if (item.episodeDetails) {
        const auto& d = *item.episodeDetails;
        details = Json{{"seasonNumber", d.seasonNumber ? Json(*d.seasonNumber) : Json(nullptr)},
                       {"episodeNumber", d.episodeNumber ? Json(*d.episodeNumber) : Json(nullptr)},
                       {"plot", d.plot}, {"durationSeconds", d.durationSeconds}, {"airDate", d.airDate}};
    }
    return Json{{"id", item.id}, {"sourceId", item.sourceId}, {"providerId", item.providerId},
                {"title", item.title}, {"kind", kindName(item.kind)}, {"categoryId", item.categoryId},
                {"categoryName", item.categoryName}, {"mediaUrl", item.mediaUrl}, {"logoUrl", item.logoUrl},
                {"description", item.description}, {"rating", item.rating}, {"epgId", item.epgId},
                {"requestHeaders", headers}, {"episodeDetails", details}};
}
std::optional<MediaItem> mediaFromJson(const Json& value) {
    if (!value.is_object()) return std::nullopt;
    MediaItem item;
    item.id = js(value, "id"); item.sourceId = js(value, "sourceId"); item.providerId = js(value, "providerId");
    item.title = js(value, "title"); item.kind = kindValue(js(value, "kind"));
    item.categoryId = js(value, "categoryId"); item.categoryName = js(value, "categoryName");
    item.mediaUrl = js(value, "mediaUrl"); item.logoUrl = js(value, "logoUrl");
    item.description = js(value, "description"); item.rating = js(value, "rating"); item.epgId = js(value, "epgId");
    if (item.id.empty() || item.id.size() > 1024 || item.sourceId.size() > 256 || item.title.size() > 4096 ||
        item.mediaUrl.size() > 8192 || item.logoUrl.size() > 8192 || item.description.size() > 16384) return std::nullopt;
    if (value.contains("requestHeaders")) {
        const auto& headers = value["requestHeaders"];
        if (!headers.is_object() || headers.size() > 64) return std::nullopt;
        for (auto it = headers.begin(); it != headers.end(); ++it) {
            if (!it.value().is_string()) return std::nullopt;
            auto headerValue = it.value().get<std::string>();
            if (it.key().size() > 128 || headerValue.size() > 8192) return std::nullopt;
            item.requestHeaders.emplace(it.key(), std::move(headerValue));
        }
    }
    if (value.contains("episodeDetails") && !value["episodeDetails"].is_null()) {
        const auto& details = value["episodeDetails"];
        if (!details.is_object()) return std::nullopt;
        EpisodeDetails d;
        if (details.contains("seasonNumber") && !details["seasonNumber"].is_null()) {
            if (!details["seasonNumber"].is_number_integer()) return std::nullopt;
            d.seasonNumber = details["seasonNumber"].get<int>();
        }
        if (details.contains("episodeNumber") && !details["episodeNumber"].is_null()) {
            if (!details["episodeNumber"].is_number_integer()) return std::nullopt;
            d.episodeNumber = details["episodeNumber"].get<int>();
        }
        d.plot = js(details, "plot"); d.durationSeconds = ji(details, "durationSeconds"); d.airDate = js(details, "airDate");
        if (d.durationSeconds < 0 || d.plot.size() > 16384 || d.airDate.size() > 256) return std::nullopt;
        item.episodeDetails = std::move(d);
    }
    return item;
}
bool validSourceFields(const Source& s) {
    return s.id.size() <= 256 && s.name.size() <= 256 && s.url.size() <= 8192 &&
           s.username.size() <= 1024 && s.password.size() <= 4096;
}
bool validSettings(const Settings& settings) {
    if (!std::isfinite(settings.volume) || settings.volume < 0 || settings.volume > 1 || settings.locale.size() > 32) return false;
    if (settings.source && !validSourceFields(*settings.source)) return false;
    if (settings.savedSources.size() > 32) return false;
    for (const auto& saved : settings.savedSources) {
        if (!validSourceFields(saved)) return false;
    }
    if (settings.favoritesBySource.size() > 100 || settings.recentsBySource.size() > 100 ||
        settings.resumePositionsBySource.size() > 100) return false;
    for (const auto& [sid, ids] : settings.favoritesBySource) {
        if (sid.empty() || sid.size() > 256 || ids.size() > kMaxItems) return false;
        for (const auto& id : ids) if (id.empty() || id.size() > 1024) return false;
    }
    for (const auto& [sid, items] : settings.recentsBySource) {
        if (sid.empty() || sid.size() > 256 || items.size() > 100) return false;
        for (const auto& item : items) if (item.sourceId != sid || item.id.empty()) return false;
    }
    for (const auto& [sid, positions] : settings.resumePositionsBySource) {
        if (sid.empty() || sid.size() > 256 || positions.size() > 500) return false;
        for (const auto& [itemId, seconds] : positions) {
            if (itemId.empty() || itemId.size() > 1024 || !std::isfinite(seconds) || seconds < 0.0) return false;
        }
    }
    return true;
}
Settings settingsFromJson(const Json& value) {
    Settings result;
    if (!value.is_object() || !value.contains("version") || !value["version"].is_number_integer() || value["version"].get<int>() != 1) return result;
    if (value.contains("source") && !value["source"].is_null()) {
        auto source = sourceFromJson(value["source"]);
        if (!source) return Settings{};
        result.source = std::move(*source);
    }
    if (value.contains("savedSources") && !value["savedSources"].is_null()) {
        const auto& saved = value["savedSources"];
        if (!saved.is_array() || saved.size() > 32) return Settings{};
        for (const auto& entry : saved) {
            auto source = sourceFromJson(entry);
            if (!source) return Settings{};
            result.savedSources.push_back(std::move(*source));
        }
    }
    if (value.contains("volume")) {
        if (!value["volume"].is_number()) return Settings{};
        result.volume = value["volume"].get<float>();
    }
    if (value.contains("locale")) {
        if (!value["locale"].is_string()) return Settings{};
        result.locale = value["locale"].get<std::string>();
    }
    if (value.contains("favoritesBySource")) {
        const auto& favorites = value["favoritesBySource"];
        if (!favorites.is_object() || favorites.size() > 100) return Settings{};
        for (auto it = favorites.begin(); it != favorites.end(); ++it) {
            if (!it.value().is_array() || it.value().size() > kMaxItems) return Settings{};
            auto& target = result.favoritesBySource[it.key()];
            for (const auto& id : it.value()) {
                if (!id.is_string()) return Settings{};
                target.insert(id.get<std::string>());
            }
        }
    }
    if (value.contains("recentsBySource")) {
        const auto& recents = value["recentsBySource"];
        if (!recents.is_object() || recents.size() > 100) return Settings{};
        for (auto it = recents.begin(); it != recents.end(); ++it) {
            if (!it.value().is_array() || it.value().size() > 100) return Settings{};
            auto& target = result.recentsBySource[it.key()];
            for (const auto& jsonItem : it.value()) {
                auto item = mediaFromJson(jsonItem);
                if (!item || item->sourceId != it.key()) return Settings{};
                target.push_back(std::move(*item));
            }
        }
    }
    if (value.contains("resumePositionsBySource") && !value["resumePositionsBySource"].is_null()) {
        const auto& resumes = value["resumePositionsBySource"];
        if (!resumes.is_object() || resumes.size() > 100) return Settings{};
        for (auto it = resumes.begin(); it != resumes.end(); ++it) {
            if (!it.value().is_object() || it.value().size() > 500) return Settings{};
            auto& target = result.resumePositionsBySource[it.key()];
            for (auto posIt = it.value().begin(); posIt != it.value().end(); ++posIt) {
                if (!posIt.value().is_number()) return Settings{};
                const double secs = posIt.value().get<double>();
                if (!std::isfinite(secs) || secs < 0.0) return Settings{};
                target[posIt.key()] = secs;
            }
        }
    }
    return validSettings(result) ? result : Settings{};
}
Json settingsJson(const Settings& settings) {
    Json out{{"version", 1}, {"source", settings.source ? sourceJson(*settings.source) : Json(nullptr)},
             {"volume", settings.volume}, {"locale", settings.locale}};
    if (!settings.savedSources.empty()) {
        out["savedSources"] = Json::array();
        for (const auto& saved : settings.savedSources) out["savedSources"].push_back(sourceJson(saved));
    }
    out["favoritesBySource"] = Json::object();
    for (const auto& [sid, favorites] : settings.favoritesBySource) out["favoritesBySource"][sid] = favorites;
    out["recentsBySource"] = Json::object();
    for (const auto& [sid, recents] : settings.recentsBySource) {
        out["recentsBySource"][sid] = Json::array();
        for (const auto& item : recents) out["recentsBySource"][sid].push_back(mediaJson(item));
    }
    if (!settings.resumePositionsBySource.empty()) {
        out["resumePositionsBySource"] = Json::object();
        for (const auto& [sid, positions] : settings.resumePositionsBySource) {
            out["resumePositionsBySource"][sid] = Json::object();
            for (const auto& [itemId, secs] : positions) {
                out["resumePositionsBySource"][sid][itemId] = secs;
            }
        }
    }
    return out;
}
} // namespace

SettingsStore::SettingsStore(std::filesystem::path path) : path_(std::move(path)) {}
Settings SettingsStore::load() const {
    try {
        std::error_code error;
        auto size = std::filesystem::file_size(path_, error);
        if (error || size > kMaxSettings) return {};
        std::ifstream input(path_, std::ios::binary);
        if (!input) return {};
        std::string bytes(static_cast<std::size_t>(size), '\0');
        if (size) input.read(bytes.data(), static_cast<std::streamsize>(size));
        if (input.bad()) return {};
        if (!jsonDepthWithin(bytes)) return {};
        auto json = Json::parse(bytes, nullptr, false);
        if (json.is_discarded()) return {};
        return settingsFromJson(json);
    } catch (...) { return {}; }
}
void SettingsStore::save(const Settings& settings) const {
    if (path_.empty() || !validSettings(settings)) throw CatalogError("Settings are invalid.");
    std::string bytes;
    try { bytes = settingsJson(settings).dump(2); }
    catch (...) { throw CatalogError("Settings could not be encoded."); }
    if (bytes.size() > kMaxSettings) throw CatalogError("Settings exceed the size limit.");
    auto parent = path_.parent_path().empty() ? std::filesystem::path(".") : path_.parent_path();
    std::error_code error;
    std::filesystem::create_directories(parent, error);
    if (error) throw CatalogError("Settings could not be saved.");
    std::string temporary = path_.string() + ".tmp.XXXXXX";
    std::vector<char> tempName(temporary.begin(), temporary.end());
    tempName.push_back('\0');
    int fd = ::mkstemp(tempName.data());
    if (fd < 0) throw CatalogError("Settings could not be saved.");
    bool ok = ::fchmod(fd, S_IRUSR | S_IWUSR) == 0 && writeAll(fd, bytes.data(), bytes.size()) && ::fsync(fd) == 0;
    if (::close(fd) != 0) ok = false;
    if (!ok || ::rename(tempName.data(), path_.c_str()) != 0) {
        (void)::unlink(tempName.data());
        throw CatalogError("Settings could not be saved.");
    }
    const int directory = ::open(parent.c_str(), O_RDONLY | O_DIRECTORY);
    if (directory >= 0) { (void)::fsync(directory); (void)::close(directory); }
}

} // namespace brutv
