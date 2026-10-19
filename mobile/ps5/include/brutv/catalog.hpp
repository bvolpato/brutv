#pragma once

#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

namespace brutv {

enum class SourceType { M3U, Xtream };
enum class MediaKind { Live, Movie, Series, Episode };

struct Source {
    std::string id;
    std::string name;
    SourceType type{SourceType::M3U};
    // For M3U, url is the playlist address. For Xtream, it is the server base URL.
    std::string url;
    std::string username;
    std::string password;
};

struct EpisodeDetails {
    std::optional<int> seasonNumber;
    std::optional<int> episodeNumber;
    std::string plot;
    std::int64_t durationSeconds{0};
    std::string airDate;
};

struct Category {
    std::string id;
    std::string name;
    MediaKind kind{MediaKind::Live};
};

struct MediaItem {
    std::string id;
    std::string sourceId;
    std::string providerId;
    std::string title;
    MediaKind kind{MediaKind::Live};
    std::string categoryId;
    std::string categoryName;
    std::string mediaUrl;
    std::string logoUrl;
    std::string description;
    std::string rating;
    std::string epgId;
    std::unordered_map<std::string, std::string> requestHeaders;
    std::optional<EpisodeDetails> episodeDetails;
};

struct Catalog {
    std::vector<Category> categories;
    std::vector<MediaItem> items;
};

struct EpgEntry {
    std::string title;
    std::string description;
    std::int64_t startEpochSeconds{0};
    std::int64_t endEpochSeconds{0};
};

struct Settings {
    std::optional<Source> source;
    // The outer key is sourceId(source); values are MediaItem::id values.
    std::map<std::string, std::set<std::string>> favoritesBySource;
    // Recent items are kept separately for each source.
    std::map<std::string, std::vector<MediaItem>> recentsBySource;
    float volume{1.0F};
    std::string locale{"system"};
};

class CatalogError : public std::runtime_error {
public:
    explicit CatalogError(const std::string& message) : std::runtime_error(message) {}
};

// Xtream request URLs contain credentials. Implementations must never log URLs.
using HttpGet = std::function<std::string(const std::string&)>;

// Return a caller-provided profile ID, or derive a stable ID without using its password.
std::string sourceId(const Source& source);

// Accepts BruTV deep links, supported BruTV join links, direct M3U URLs, and Xtream get.php URLs.
// Invalid or unsupported input returns std::nullopt.
std::optional<Source> parseLoginLink(const std::string& input);

class CatalogClient {
public:
    explicit CatalogClient(HttpGet httpGet);

    void authenticate(const Source& source) const;
    Catalog load(const Source& source, MediaKind kind) const;
    std::vector<MediaItem> loadEpisodes(const Source& source, const std::string& seriesId) const;
    std::vector<EpgEntry> loadEpg(const Source& source, const std::string& streamId) const;

private:
    HttpGet httpGet_;
};

class SettingsStore {
public:
    explicit SettingsStore(std::filesystem::path path);

    // Missing, malformed, oversized, or incompatible files produce default settings.
    Settings load() const;
    // Writes a mode-0600 file by atomic replacement in the same directory.
    void save(const Settings& settings) const;

private:
    std::filesystem::path path_;
};

} // namespace brutv
