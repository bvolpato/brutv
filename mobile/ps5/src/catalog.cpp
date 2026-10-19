#include "brutv/catalog.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cctype>
#include <charconv>
#include <cmath>
#include <fstream>
#include <limits>
#include <sstream>
#include <string_view>
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
constexpr std::string_view kUncategorized = "Uncategorized";

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
bool jsonDepthWithin(std::string_view input, std::size_t limit = 64) {
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
    bool hasQuery = question != std::string::npos;
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
    if (value.empty() || value.size() > 8192 || value.find_first_of("\r\n") != std::string::npos ||
        ieq(name, "host") || ieq(name, "connection") || ieq(name, "content-length")) return;
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
            if (!token || value.empty() || value.size() > 8192 || value.find_first_of("\r\n") != std::string::npos ||
                ieq(name, "host") || ieq(name, "connection") || ieq(name, "content-length")) continue;
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
    static const std::set<std::string> video{"mp4", "mkv", "avi", "mov", "webm", "m4v"};
    return video.count(ext) ? MediaKind::Movie : MediaKind::Live;
}
struct PlaylistEntry { MediaItem item; std::string group; };
std::vector<PlaylistEntry> parsePlaylist(std::string_view body, const Source& source) {
    if (body.size() > kMaxResponse) throw CatalogError("The playlist exceeds the size limit.");
    std::vector<PlaylistEntry> output;
    std::set<std::string> seen;
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
                if (title.empty()) title = attrs["tvg-name"];
                if (title.empty()) {
                    auto url = parseUrl(*resolved);
                    auto path = url ? url->path : *resolved;
                    auto slash = path.rfind('/');
                    title = path.substr(slash == std::string::npos ? 0 : slash + 1);
                    auto query = title.find('?');
                    if (query != std::string::npos) title.resize(query);
                }
                if (title.empty()) title = *resolved;
                auto group = attrs["group-title"];
                auto semi = group.find(';');
                if (semi != std::string::npos) group.resize(semi);
                if (group.empty()) group = fallbackGroup;
                if (group.empty()) group = std::string(kUncategorized);
                auto itemKey = "m3u:" + hash64(*resolved);
                if (seen.insert(itemKey).second) {
                    if (output.size() >= kMaxItems) throw CatalogError("The playlist has too many entries.");
                    MediaItem item;
                    item.sourceId = brutv::sourceId(source);
                    item.id = item.sourceId + ":" + itemKey;
                    item.providerId = itemKey;
                    item.title = std::move(title);
                    item.kind = classify(*resolved);
                    item.categoryId = group;
                    item.categoryName = group;
                    item.mediaUrl = *resolved;
                    item.logoUrl = attrs["tvg-logo"];
                    item.epgId = attrs["tvg-id"];
                    item.requestHeaders = headers;
                    output.push_back({std::move(item), std::move(group)});
                }
            }
            info.clear(); fallbackGroup.clear(); headers.clear();
        }
    }
    if (hls) throw CatalogError("This is an HLS media manifest, not an IPTV channel list.");
    return output;
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
std::string streamUrl(const Source& source, std::string_view type, std::string_view id, std::string extension) {
    if (extension.empty()) extension = "mp4";
    extension = lower(std::move(extension));
    std::string safe;
    for (unsigned char c : extension) if (std::isalnum(c)) safe.push_back(static_cast<char>(c));
    if (safe.empty()) safe = "mp4";
    return serverBase(source) + "/" + std::string(type) + "/" + encode(source.username) + "/" +
           encode(source.password) + "/" + encode(std::string(id) + "." + safe);
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
    if (!jsonDepthWithin(response)) throw CatalogError("The provider response exceeds the nesting limit.");
    try {
        auto value = Json::parse(response.begin(), response.end());
        if (value.is_object() && value.contains("error")) throw CatalogError("The provider rejected the request.");
        return value;
    } catch (const CatalogError&) { throw; }
    catch (...) { throw CatalogError("The provider returned invalid JSON."); }
}
Json requestJson(const HttpGet& get, const Source& source, const std::vector<std::pair<std::string, std::string>>& params) {
    if (!get) throw CatalogError("No HTTP transport is configured.");
    std::string response;
    try { response = get(apiUrl(source, params)); }
    catch (...) { throw CatalogError("Could not connect to the provider."); }
    return providerJson(response);
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

std::int64_t parseDate(std::string_view s);
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
    if (root["epg_listings"].size() > 1000) throw CatalogError("The provider returned too many guide entries.");
    std::vector<EpgEntry> out;
    for (const auto& item : root["epg_listings"]) {
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
} // namespace

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

CatalogClient::CatalogClient(HttpGet httpGet) : httpGet_(std::move(httpGet)) {}

void CatalogClient::authenticate(const Source& source) const {
    if (source.type == SourceType::M3U) {
        if (!validSource(source)) throw CatalogError("The playlist address is invalid.");
        if (!httpGet_) throw CatalogError("No HTTP transport is configured.");
        std::string response;
        try { response = httpGet_(source.url); }
        catch (...) { throw CatalogError("Could not connect to the provider."); }
        auto items = parsePlaylist(response, source);
        if (items.empty()) throw CatalogError("The playlist contains no supported HTTP streams.");
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
}

Catalog CatalogClient::load(const Source& source, MediaKind kind) const {
    Catalog result;
    if (source.type == SourceType::M3U) {
        if (!validSource(source)) throw CatalogError("The playlist address is invalid.");
        if (!httpGet_) throw CatalogError("No HTTP transport is configured.");
        std::string response;
        try { response = httpGet_(source.url); }
        catch (...) { throw CatalogError("Could not connect to the provider."); }
        auto playlist = parsePlaylist(response, source);
        std::set<std::string> categories;
        for (auto& parsed : playlist) {
            if (parsed.item.kind != kind) continue;
            if (categories.insert(parsed.group).second) result.categories.push_back({parsed.group, parsed.group, kind});
            result.items.push_back(std::move(parsed.item));
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
    const auto categoryJson = requestJson(httpGet_, source, {{"action", categoryAction}});
    const auto itemJson = requestJson(httpGet_, source, {{"action", itemAction}});
    if (!categoryJson.is_array()) throw CatalogError("The provider returned an invalid category response.");
    if (!itemJson.is_array()) throw CatalogError("The provider returned an invalid catalog response.");
    if (categoryJson.size() > kMaxItems || itemJson.size() > kMaxItems)
        throw CatalogError("The provider catalog exceeds the size limit.");

    std::set<std::string> seenCategories;
    std::unordered_map<std::string, std::string> categoryNames;
    for (const auto& value : categoryJson) {
        if (!value.is_object()) continue;
        auto id = js(value, "category_id");
        if (id.empty()) id = js(value, "id");
        if (id.empty() || !seenCategories.insert(id).second) continue;
        auto name = js(value, "category_name");
        if (name.empty()) name = std::string(kUncategorized);
        categoryNames.emplace(id, name);
        result.categories.push_back({std::move(id), std::move(name), kind});
    }

    const auto sid = sourceId(source);
    std::set<std::string> seenItems;
    for (const auto& value : itemJson) {
        if (!value.is_object()) continue;
        auto providerId = kind == MediaKind::Series ? js(value, "series_id") : js(value, "stream_id");
        if (providerId.empty()) providerId = js(value, "id");
        if (providerId.empty()) continue;
        const auto id = sid + ":" + kindName(kind) + ":" + providerId;
        if (!seenItems.insert(id).second) continue;
        MediaItem item;
        item.id = id;
        item.sourceId = sid;
        item.providerId = providerId;
        item.title = js(value, "name");
        if (item.title.empty()) item.title = js(value, "title");
        if (item.title.empty()) item.title = "Untitled";
        item.kind = kind;
        item.categoryId = js(value, "category_id");
        if (auto category = categoryNames.find(item.categoryId); category != categoryNames.end()) item.categoryName = category->second;
        if (kind == MediaKind::Live) item.mediaUrl = streamUrl(source, "live", providerId, "m3u8");
        else if (kind == MediaKind::Movie) {
            auto extension = js(value, "container_extension");
            item.mediaUrl = streamUrl(source, "movie", providerId, extension.empty() ? "mp4" : extension);
        }
        item.logoUrl = js(value, "stream_icon");
        if (item.logoUrl.empty()) item.logoUrl = js(value, "cover");
        if (item.logoUrl.empty()) item.logoUrl = js(value, "cover_big");
        item.description = js(value, "plot");
        item.rating = js(value, "rating");
        if (item.rating.empty()) item.rating = js(value, "rating_5based");
        item.epgId = js(value, "epg_channel_id");
        result.items.push_back(std::move(item));
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
    std::vector<MediaItem> result;
    std::set<std::string> seen;
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
            item.mediaUrl = streamUrl(source, "series", providerId, extension);
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
    if (source.type != SourceType::Xtream || streamId.empty() || streamId.size() > 1024) return {};
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
bool validSettings(const Settings& settings) {
    if (!std::isfinite(settings.volume) || settings.volume < 0 || settings.volume > 1 || settings.locale.size() > 32) return false;
    if (settings.source && (settings.source->id.size() > 256 || settings.source->name.size() > 256 ||
        settings.source->url.size() > 8192 || settings.source->username.size() > 1024 ||
        settings.source->password.size() > 4096)) return false;
    if (settings.favoritesBySource.size() > 100 || settings.recentsBySource.size() > 100) return false;
    for (const auto& [sid, ids] : settings.favoritesBySource) {
        if (sid.empty() || sid.size() > 256 || ids.size() > kMaxItems) return false;
        for (const auto& id : ids) if (id.empty() || id.size() > 1024) return false;
    }
    for (const auto& [sid, items] : settings.recentsBySource) {
        if (sid.empty() || sid.size() > 256 || items.size() > 100) return false;
        for (const auto& item : items) if (item.sourceId != sid || item.id.empty()) return false;
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
    return validSettings(result) ? result : Settings{};
}
Json settingsJson(const Settings& settings) {
    Json out{{"version", 1}, {"source", settings.source ? sourceJson(*settings.source) : Json(nullptr)},
             {"volume", settings.volume}, {"locale", settings.locale}};
    out["favoritesBySource"] = Json::object();
    for (const auto& [sid, favorites] : settings.favoritesBySource) out["favoritesBySource"][sid] = favorites;
    out["recentsBySource"] = Json::object();
    for (const auto& [sid, recents] : settings.recentsBySource) {
        out["recentsBySource"][sid] = Json::array();
        for (const auto& item : recents) out["recentsBySource"][sid].push_back(mediaJson(item));
    }
    return out;
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
