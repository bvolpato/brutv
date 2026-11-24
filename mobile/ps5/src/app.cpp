// SPDX-License-Identifier: MIT
#include "brutv/app.hpp"

#include "brutv/artwork.hpp"
#include "brutv/gfx.hpp"
#include "brutv/player.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <ctime>
#include <filesystem>
#include <future>
#include <map>
#include <mutex>
#include <set>
#include <sstream>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>

namespace brutv {
namespace {

constexpr float kWidth = 1920.0F;
constexpr float kHeight = 1080.0F;
constexpr auto kHudAutoHideDelay = std::chrono::seconds(5);
constexpr auto kBrowseEpgDebounce = std::chrono::milliseconds(300);
constexpr auto kEpgSuccessTtl = std::chrono::seconds(120);
constexpr auto kEpgFailureTtl = std::chrono::seconds(60);
constexpr auto kResumeSaveInterval = std::chrono::seconds(10);

Color rgb(int r, int g, int b, float a = 1.0F) {
    return {static_cast<float>(r) / 255.0F, static_cast<float>(g) / 255.0F,
            static_cast<float>(b) / 255.0F, a};
}

const Color kBackground = rgb(7, 13, 24);
const Color kPanel = rgb(13, 23, 39);
const Color kPanelRaised = rgb(19, 33, 53);
const Color kPanelSelected = rgb(24, 55, 73);
const Color kBorder = rgb(38, 58, 77);
const Color kText = rgb(240, 246, 252);
const Color kMuted = rgb(143, 164, 184);
const Color kCyan = rgb(53, 214, 224);
const Color kBlue = rgb(66, 148, 255);
const Color kGreen = rgb(87, 214, 157);
const Color kRed = rgb(255, 112, 123);

char asciiLowerChar(char c) {
    return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c;
}

std::string lower(std::string value) {
    for (char &c : value)
        c = asciiLowerChar(c);
    return value;
}

bool caseInsensitiveLess(std::string_view a, std::string_view b) {
    const std::size_t n = std::min(a.size(), b.size());
    for (std::size_t i = 0; i < n; ++i) {
        const char ca = asciiLowerChar(a[i]);
        const char cb = asciiLowerChar(b[i]);
        if (ca != cb)
            return ca < cb;
    }
    return a.size() < b.size();
}

// Allocation-free case-insensitive substring search.
bool containsCaseInsensitive(std::string_view haystack, std::string_view needle) {
    if (needle.empty())
        return true;
    if (needle.size() > haystack.size())
        return false;
    const char first = asciiLowerChar(needle[0]);
    const std::size_t limit = haystack.size() - needle.size();
    for (std::size_t i = 0; i <= limit; ++i) {
        if (asciiLowerChar(haystack[i]) != first)
            continue;
        bool match = true;
        for (std::size_t j = 1; j < needle.size(); ++j) {
            if (asciiLowerChar(haystack[i + j]) != asciiLowerChar(needle[j])) {
                match = false;
                break;
            }
        }
        if (match)
            return true;
    }
    return false;
}

std::string shortened(const std::string &value, std::size_t maxLength) {
    if (value.size() <= maxLength)
        return value;
    if (maxLength < 4)
        return value.substr(0, maxLength);
    return value.substr(0, maxLength - 3) + "...";
}

std::string formatTime(double seconds) {
    const auto total = static_cast<long long>(std::max(0.0, seconds));
    const auto hours = total / 3600;
    const auto minutes = (total / 60) % 60;
    const auto remainder = total % 60;
    std::ostringstream out;
    if (hours > 0)
        out << hours << ':' << (minutes < 10 ? "0" : "");
    out << minutes << ':' << (remainder < 10 ? "0" : "") << remainder;
    return out.str();
}

std::string formatClockHm(std::int64_t epochSeconds) {
    if (epochSeconds <= 0)
        return {};
    const std::time_t ts = static_cast<std::time_t>(epochSeconds);
    std::tm tmVal{};
    gmtime_r(&ts, &tmVal);
    char buf[16]{};
    std::snprintf(buf, sizeof(buf), "%02d:%02d", tmVal.tm_hour, tmVal.tm_min);
    return buf;
}

std::string sourceScopedItemKey(const MediaItem &item) { return item.sourceId + "\n" + item.id; }

std::string maskString(std::size_t length) { return std::string(length, '*'); }

bool isBruTvJoinLink(const std::string &value) {
    std::string normalized = lower(value);
    const auto first = normalized.find_first_not_of(" \t\r\n");
    if (first == std::string::npos)
        return false;
    normalized.erase(0, first);
    return normalized.rfind("brutv:", 0) == 0 ||
           normalized.rfind("https://brunovolpato.com/brutv/join.html", 0) == 0 ||
           normalized.rfind("https://bvolpato.github.io/brutv/join.html", 0) == 0;
}

void eraseLastCodepoint(std::string &value) {
    if (value.empty())
        return;
    std::size_t position = value.size() - 1;
    while (position > 0 && (static_cast<unsigned char>(value[position]) & 0xC0U) == 0x80U)
        --position;
    value.erase(position);
}

// Fast incremental word wrapper without std::istringstream or per-word line copies.
void wrappedText(Gfx &gfx, const std::string &text, float x, float y, float size, Color color,
                 float maxWidth, int maxLines = 2) {
    if (text.empty() || maxWidth <= 0 || maxLines <= 0)
        return;
    const float spaceW = gfx.textWidth(" ", size);
    const std::string_view view(text);
    std::string line;
    float lineW = 0.0F;
    int lineIndex = 0;
    std::size_t pos = 0;
    while (pos < view.size()) {
        while (pos < view.size() && (view[pos] == ' ' || view[pos] == '\t' || view[pos] == '\r' ||
                                     view[pos] == '\n'))
            ++pos;
        if (pos >= view.size())
            break;
        std::size_t end = pos;
        while (end < view.size() && view[end] != ' ' && view[end] != '\t' && view[end] != '\r' &&
               view[end] != '\n')
            ++end;
        const std::string word(view.substr(pos, end - pos));
        pos = end;
        const float wordW = gfx.textWidth(word, size);
        if (!line.empty() && lineW + spaceW + wordW > maxWidth) {
            gfx.text(line, x, y + static_cast<float>(lineIndex) * (size + 8.0F), size, color,
                     maxWidth);
            ++lineIndex;
            if (lineIndex >= maxLines)
                return;
            line = word;
            lineW = wordW;
        } else {
            if (!line.empty()) {
                line.push_back(' ');
                lineW += spaceW;
            }
            line += word;
            lineW += wordW;
        }
    }
    if (!line.empty() && lineIndex < maxLines)
        gfx.text(line, x, y + static_cast<float>(lineIndex) * (size + 8.0F), size, color, maxWidth);
}

std::string kindName(MediaKind kind) {
    switch (kind) {
    case MediaKind::Live:
        return "Live TV";
    case MediaKind::Movie:
        return "Movies";
    case MediaKind::Series:
        return "Series";
    case MediaKind::Episode:
        return "Episode";
    }
    return "Media";
}

struct NowNextEpg {
    const EpgEntry *now = nullptr;
    const EpgEntry *next = nullptr;
};

NowNextEpg findNowNext(const std::vector<EpgEntry> &entries) {
    NowNextEpg result;
    if (entries.empty())
        return result;
    const auto now = static_cast<std::int64_t>(std::time(nullptr));
    auto current = std::find_if(entries.begin(), entries.end(), [now](const EpgEntry &entry) {
        return entry.startEpochSeconds <= now && entry.endEpochSeconds > now;
    });
    if (current != entries.end()) {
        result.now = &(*current);
        auto nextIt = std::find_if(std::next(current), entries.end(),
                                   [&](const EpgEntry &entry) {
                                       return entry.startEpochSeconds >= current->endEpochSeconds ||
                                              entry.startEpochSeconds > now;
                                   });
        if (nextIt != entries.end())
            result.next = &(*nextIt);
        return result;
    }
    // Fallback when clocks differ or schedule has only upcoming items: pick first entry as now/next.
    auto upcoming = std::find_if(entries.begin(), entries.end(),
                                 [now](const EpgEntry &entry) { return entry.startEpochSeconds > now; });
    if (upcoming != entries.end()) {
        result.next = &(*upcoming);
        if (upcoming != entries.begin()) {
            result.now = &(*std::prev(upcoming));
        }
    } else {
        result.now = &entries.front();
        if (entries.size() > 1)
            result.next = &entries[1];
    }
    return result;
}

} // namespace

struct App::Impl {
    enum class Tab { Live, Movies, Series, Favorites, Settings };
    enum class Focus { Sidebar, Categories, Items, Settings };
    enum class EditField { None, Search, Name, Url, Username, Password, JoinLink };
    enum class Modal { None, Keyboard, ClearSource };

    struct CatalogJobResult {
        std::map<MediaKind, Catalog> catalogs;
        std::map<MediaKind, std::string> failures;
        std::string sourceId;
        std::string sourceIdentity;
        std::string preferredLiveFormat;
        std::uint64_t sourceGeneration = 0;
        bool authenticated = false;
        bool authenticationFailed = false;
    };

    struct EpisodeResult {
        std::vector<MediaItem> items;
        std::string seriesId;
        std::uint64_t sourceGeneration = 0;
        bool ok = true;
    };

    struct EpgResult {
        std::vector<EpgEntry> entries;
        std::string itemId;
        std::uint64_t sourceGeneration = 0;
        bool ok = true;
    };

    struct CachedEpg {
        std::vector<EpgEntry> entries;
        std::chrono::steady_clock::time_point fetchedAt{};
        bool ok = false;
    };

    Platform &platform;
    Gfx &gfx;
    HttpGet httpGet;
    std::shared_ptr<CatalogClient> catalogClient;
    ArtworkCache artwork;
    SettingsStore store;
    std::filesystem::path settingsPath;
    Settings settings;
    Source draft;
    std::string draftIdentity;
    bool preview;
    std::uint64_t sourceGeneration = 0;
    std::unique_ptr<Player> player;
    VideoFrame activeVideoFrame;
    bool quit = false;
    Tab tab = Tab::Live;
    Tab lastContentTab = Tab::Live;
    Focus focus = Focus::Sidebar;
    int sidebarIndex = 0;
    int categoryIndex = 0;
    int itemIndex = 0;
    int settingIndex = 0;
    int savedSourceIndex = 0;
    int gridColumns = 3;
    bool episodesOpen = false;
    std::string searchQuery;
    std::string banner;
    std::string joinLink;

    // Single-copy catalog storage (pre-sorted on background thread); no duplicated library map.
    std::map<MediaKind, Catalog> catalogs;
    std::set<MediaKind> catalogLoaded;
    std::set<MediaKind> catalogLoadingKinds;
    std::set<MediaKind> catalogFailed;
    bool sourceAuthenticated = false;
    std::string sourceLiveFormat;
    std::future<CatalogJobResult> catalogFuture;
    bool catalogJobRunning = false;
    std::future<EpisodeResult> episodesFuture;
    bool episodesJobRunning = false;
    std::future<EpgResult> epgFuture;
    bool epgJobRunning = false;
    std::string epgInFlightItemId;
    std::uint64_t epgInFlightGeneration = 0;
    std::unordered_map<std::string, CachedEpg> epgCache;
    std::string browseEpgTargetKey;
    std::chrono::steady_clock::time_point browseEpgDueAt{};
    bool browseEpgScheduled = false;

    std::uint64_t catalogDataVersion = 1;
    mutable bool categoriesCacheValid = false;
    mutable Tab cachedCategoriesTab = Tab::Live;
    mutable std::uint64_t cachedCategoriesVersion = 0;
    mutable std::vector<std::string> cachedCategories;
    mutable bool visibleCacheValid = false;
    mutable Tab cachedVisibleTab = Tab::Live;
    mutable int cachedVisibleCategory = -1;
    mutable std::string cachedVisibleSearch;
    mutable std::string cachedVisibleSourceId;
    mutable std::uint64_t cachedVisibleVersion = 0;
    mutable std::vector<const MediaItem *> cachedVisibleItems;

    // Background debounced SettingsStore writer so UI thread never calls fsync() on launch/favorite.
    std::mutex saveMutex;
    std::condition_variable saveCv;
    std::thread saveWorker;
    Settings pendingSaveSettings;
    bool savePending = false;
    bool saveStopping = false;
    std::chrono::steady_clock::time_point saveDueAt{};
    std::chrono::steady_clock::time_point lastResumeSaveAt{};

    std::vector<MediaItem> episodes;
    std::vector<int> episodeSeasons;
    int selectedSeasonIndex = 0;
    std::optional<MediaItem> pendingEpisodeSeries;
    std::string selectedSeriesId;
    int episodeIndex = 0;
    std::vector<EpgEntry> epgEntries;
    std::string playbackTitle;
    std::string playbackSubtitle;
    std::optional<MediaItem> playingItem;
    bool playingLive = true;
    bool showPlayerHud = true;
    std::chrono::steady_clock::time_point hudHideAt{};
    bool hasVideoFrame = false;
    bool playerScreen = false;
    Player::Status playerStatus;
    Modal modal = Modal::None;
    EditField editField = EditField::None;
    Focus keyboardReturnFocus = Focus::Items;
    std::string keyboardBuffer;
    int keyboardRow = 0;
    int keyboardColumn = 0;
    bool keyboardUppercase = true;
    bool keyboardSymbols = false;
    std::string clearConfirmation;
    const std::vector<std::string> keyboardAlphaRows{"1234567890", "QWERTYUIOP", "ASDFGHJKL",
                                                     "ZXCVBNM", ":/?&=+#%-_.@"};
    const std::vector<std::string> keyboardSymbolRows{"!\"#$%&'()*+", ",-./:;<=>?@", "[\\]^_`{|}~"};
    std::vector<std::vector<std::string>> keyboardBottom{
        {"Space", "Shift", "Symbols", "Clear", "Delete", "Cancel", "Done"}};

    Impl(Platform &p, Gfx &g, std::string settingsFile, HttpGet get, bool previewMode,
         HttpGet artworkGet)
        : platform(p), gfx(g), httpGet(std::move(get)),
          catalogClient(std::make_shared<CatalogClient>(httpGet, true)),
          artwork(std::move(artworkGet)), store(settingsFile),
          settingsPath(std::move(settingsFile)), preview(previewMode),
          player(std::make_unique<Player>(platform.audio())) {
        if (!preview && !settingsPath.empty()) {
            const auto parent = settingsPath.parent_path().empty()
                                    ? std::filesystem::path(".")
                                    : settingsPath.parent_path();
            const std::string cacheFolder =
                settingsPath.filename() == "settings.json"
                    ? "catalog-cache"
                    : (settingsPath.stem().string() + "-catalog-cache");
            catalogClient->setCacheDirectory(parent / cacheFolder, std::chrono::seconds(900));
        }
        saveWorker = std::thread([this] { runSaveWorker(); });
        try {
            settings = store.load();
        } catch (...) {
            settings = Settings{};
        }
        settings.volume = std::clamp(settings.volume, 0.0F, 1.0F);
        player->setVolume(settings.volume);
        if (settings.source) {
            draft = *settings.source;
            draftIdentity = computedSourceId(draft);
            if (draft.id.empty())
                draft.id = draftIdentity;
            settings.source = draft;
            upsertSavedSource(draft);
            sourceAuthenticated = false;
        } else {
            draft.name = "My TV";
            draft.type = SourceType::M3U;
            draftIdentity = computedSourceId(draft);
        }
        if (preview) {
            draft = Source{};
            draft.id = "brutv-preview";
            draft.name = "Preview Catalog";
            draftIdentity = computedSourceId(draft);
            addPreviewCatalog();
            banner = "Preview mode | synthetic catalog only | streams are disabled";
        } else if (settings.source) {
            startCatalogJob({MediaKind::Live}, true);
        }
    }

    ~Impl() {
        recordCurrentResumePosition(true);
        flushSettingsSaveSync();
        {
            std::lock_guard<std::mutex> lock(saveMutex);
            saveStopping = true;
        }
        saveCv.notify_all();
        if (saveWorker.joinable())
            saveWorker.join();
        if (catalogFuture.valid())
            catalogFuture.wait();
        if (episodesFuture.valid())
            episodesFuture.wait();
        if (epgFuture.valid())
            epgFuture.wait();
        if (player)
            player->stop();
    }

    void runSaveWorker() {
        for (;;) {
            Settings snapshot;
            {
                std::unique_lock<std::mutex> lock(saveMutex);
                saveCv.wait(lock, [this] { return saveStopping || savePending; });
                if (saveStopping && !savePending)
                    return;
                while (savePending && !saveStopping &&
                       std::chrono::steady_clock::now() < saveDueAt) {
                    saveCv.wait_until(lock, saveDueAt);
                }
                if (!savePending) {
                    if (saveStopping)
                        return;
                    continue;
                }
                snapshot = pendingSaveSettings;
                savePending = false;
            }
            try {
                store.save(snapshot);
            } catch (...) {
                // Storage failures are best-effort for background saves.
            }
        }
    }

    void scheduleSettingsSave(std::chrono::milliseconds delay = std::chrono::milliseconds(500)) {
        if (preview)
            return;
        settings.volume = std::clamp(settings.volume, 0.0F, 1.0F);
        {
            std::lock_guard<std::mutex> lock(saveMutex);
            pendingSaveSettings = settings;
            savePending = true;
            saveDueAt = std::chrono::steady_clock::now() + delay;
        }
        saveCv.notify_one();
    }

    void flushSettingsSaveSync() {
        if (preview)
            return;
        {
            std::lock_guard<std::mutex> lock(saveMutex);
            savePending = false;
        }
        try {
            settings.volume = std::clamp(settings.volume, 0.0F, 1.0F);
            store.save(settings);
        } catch (...) {
            banner = "Settings could not be saved. Check available storage.";
        }
    }

    void upsertSavedSource(const Source &source) {
        if (source.url.empty())
            return;
        const std::string sid = source.id.empty() ? computedSourceId(source) : source.id;
        for (auto &existing : settings.savedSources) {
            const std::string eid = existing.id.empty() ? computedSourceId(existing) : existing.id;
            if (eid == sid) {
                existing = source;
                existing.id = sid;
                return;
            }
        }
        Source copy = source;
        copy.id = sid;
        if (settings.savedSources.size() >= 32)
            settings.savedSources.erase(settings.savedSources.begin());
        settings.savedSources.push_back(std::move(copy));
    }

    static std::vector<Tab> tabs() {
        return {Tab::Live, Tab::Movies, Tab::Series, Tab::Favorites, Tab::Settings};
    }

    static std::string computedSourceId(const Source &source) {
        Source identity = source;
        identity.id.clear();
        return brutv::sourceId(identity);
    }

    const std::vector<std::string> &activeKeyboardRows() const {
        return keyboardSymbols ? keyboardSymbolRows : keyboardAlphaRows;
    }

    static int indexOf(Tab value) {
        const auto all = tabs();
        const auto it = std::find(all.begin(), all.end(), value);
        return it == all.end() ? 0 : static_cast<int>(std::distance(all.begin(), it));
    }

    static Tab tabAt(int index) {
        const auto all = tabs();
        return all[static_cast<std::size_t>(
            (index % static_cast<int>(all.size()) + static_cast<int>(all.size())) %
            static_cast<int>(all.size()))];
    }

    static std::string tabLabel(Tab value) {
        switch (value) {
        case Tab::Live:
            return "Live TV";
        case Tab::Movies:
            return "Movies";
        case Tab::Series:
            return "Series";
        case Tab::Favorites:
            return "Favorites";
        case Tab::Settings:
            return "Settings";
        }
        return "Live TV";
    }

    static MediaKind kindForTab(Tab value) {
        switch (value) {
        case Tab::Live:
            return MediaKind::Live;
        case Tab::Movies:
            return MediaKind::Movie;
        case Tab::Series:
            return MediaKind::Series;
        case Tab::Favorites:
        case Tab::Settings:
            return MediaKind::Live;
        }
        return MediaKind::Live;
    }

    void invalidateCatalogCache() {
        ++catalogDataVersion;
        categoriesCacheValid = false;
        visibleCacheValid = false;
    }

    void persistDraft() {
        if (preview || (draft.name.empty() && draft.url.empty() && draft.username.empty() &&
                        draft.password.empty()))
            return;
        const bool connectionChanged =
            settings.source &&
            (settings.source->type != draft.type || settings.source->url != draft.url ||
             settings.source->username != draft.username ||
             settings.source->password != draft.password);
        if (connectionChanged) {
            ++sourceGeneration;
            catalogClient->invalidateCache();
            epgCache.clear();
            if (player)
                player->clearFormatCache();
        }
        const std::string identity = computedSourceId(draft);
        if (draft.id.empty() || identity != draftIdentity)
            draft.id = identity;
        draftIdentity = identity;
        settings.source = draft;
        invalidateCatalogCache();
        flushSettingsSaveSync();
    }

    bool hasSource() const { return preview || (settings.source && !settings.source->url.empty()); }

    Source currentSource() const {
        if (preview)
            return draft;
        if (settings.source)
            return *settings.source;
        return draft;
    }

    void addPreviewCatalog() {
        const std::vector<std::pair<MediaKind, std::vector<std::string>>> groups{
            {MediaKind::Live,
             {"World News", "BruTV Sports", "Brazil 24", "Nature Live", "Cinema Now", "Music Mix",
              "Travel HD", "City Radio", "Kids World"}},
            {MediaKind::Movie,
             {"The Last Horizon", "Blue Meridian", "Letters from Rio", "Night Signal",
              "The Quiet Coast", "Wild Earth", "Glass City", "Second Sunrise",
              "The Long Way Home"}},
            {MediaKind::Series,
             {"Open Skies", "The Archive", "Harbor Lights", "Signal Lost", "Northbound",
              "Small Wonders", "After the Rain", "The Green Room", "New Neighbors"}}};
        for (const auto &[kind, titles] : groups) {
            Catalog catalog;
            catalog.categories = {{"featured", "Featured", kind},
                                  {"popular", "Popular", kind},
                                  {"recent", "Recently added", kind}};
            for (std::size_t i = 0; i < titles.size(); ++i) {
                MediaItem item;
                item.id =
                    "preview-" + std::to_string(static_cast<int>(kind)) + "-" + std::to_string(i);
                item.sourceId = draft.id.empty() ? "brutv-preview" : draft.id;
                item.providerId = item.id;
                item.title = titles[i];
                item.kind = kind;
                item.categoryId = i % 3 == 0 ? "featured" : (i % 3 == 1 ? "popular" : "recent");
                item.categoryName =
                    i % 3 == 0 ? "Featured" : (i % 3 == 1 ? "Popular" : "Recently added");
                item.description = "Sample artwork and details shown for layout preview. Connect "
                                   "your own authorized source to load its catalog.";
                item.rating = i % 2 == 0 ? "PG-13" : "TV-14";
                if (kind == MediaKind::Live)
                    item.epgId = item.id;
                catalog.items.push_back(item);
                if (i == 0 || i == 3)
                    settings.favoritesBySource[item.sourceId].insert(item.id);
            }
            std::stable_sort(catalog.items.begin(), catalog.items.end(),
                             [](const MediaItem &a, const MediaItem &b) {
                                 return caseInsensitiveLess(a.title, b.title);
                             });
            catalogs[kind] = std::move(catalog);
            catalogLoaded.insert(kind);
        }
        invalidateCatalogCache();
    }

    void startCatalogJob(const std::vector<MediaKind> &kinds, bool authenticateFirst) {
        if (preview || !settings.source || catalogJobRunning || kinds.empty())
            return;
        Source source = *settings.source;
        auto client = catalogClient;
        const std::string liveFormat = sourceLiveFormat;
        catalogLoadingKinds.clear();
        catalogFailed.clear();
        for (const auto kind : kinds) {
            if (catalogLoaded.count(kind) == 0)
                catalogLoadingKinds.insert(kind);
        }
        if (catalogLoadingKinds.empty())
            return;
        const auto requested =
            std::vector<MediaKind>(catalogLoadingKinds.begin(), catalogLoadingKinds.end());
        const auto generation = sourceGeneration;
        catalogJobRunning = true;
        banner.clear();
        catalogFuture = std::async(
            std::launch::async,
            [client, source, requested, authenticateFirst, generation, liveFormat]() {
                CatalogJobResult result;
                result.sourceId = source.id.empty() ? brutv::sourceId(source) : source.id;
                result.sourceIdentity = computedSourceId(source);
                result.sourceGeneration = generation;
                try {
                    if (!liveFormat.empty())
                        client->setPreferredLiveFormat(source, liveFormat);
                    if (authenticateFirst)
                        client->authenticate(source);
                    result.preferredLiveFormat = client->preferredLiveFormat(source);
                    result.authenticated = true;
                    for (const auto kind : requested) {
                        try {
                            Catalog loaded = client->load(source, kind);
                            // Pre-sort on background thread so UI thread never sorts!
                            std::stable_sort(loaded.items.begin(), loaded.items.end(),
                                             [](const MediaItem &a, const MediaItem &b) {
                                                 return caseInsensitiveLess(a.title, b.title);
                                             });
                            result.catalogs.emplace(kind, std::move(loaded));
                        } catch (...) {
                            result.failures[kind] = "Catalog unavailable";
                        }
                    }
                } catch (...) {
                    result.authenticationFailed = authenticateFirst;
                    for (const auto kind : requested)
                        result.failures[kind] = "Connection failed";
                }
                return result;
            });
    }

    void ensureCatalogForTab() {
        if (preview || tab == Tab::Settings || !settings.source || catalogJobRunning)
            return;
        if (tab == Tab::Favorites) {
            std::vector<MediaKind> missing;
            for (const auto kind : {MediaKind::Live, MediaKind::Movie, MediaKind::Series})
                if (catalogLoaded.count(kind) == 0 && catalogFailed.count(kind) == 0)
                    missing.push_back(kind);
            if (!missing.empty())
                startCatalogJob(missing, !sourceAuthenticated);
            return;
        }
        const auto kind = kindForTab(tab);
        if (catalogLoaded.count(kind) == 0 && catalogFailed.count(kind) == 0)
            startCatalogJob({kind}, !sourceAuthenticated);
    }

    void retryCatalogForTab() {
        if (preview || !settings.source)
            return;
        catalogClient->invalidateCache(
            settings.source->id.empty() ? sourceId(*settings.source) : settings.source->id);
        if (tab == Tab::Favorites) {
            for (const auto kind : {MediaKind::Live, MediaKind::Movie, MediaKind::Series}) {
                if (catalogFailed.count(kind) != 0)
                    catalogFailed.erase(kind);
            }
        } else {
            catalogFailed.erase(kindForTab(tab));
        }
        banner.clear();
        ensureCatalogForTab();
    }

    void pollCatalog() {
        if (!catalogJobRunning || !catalogFuture.valid() ||
            catalogFuture.wait_for(std::chrono::seconds(0)) != std::future_status::ready)
            return;
        CatalogJobResult result;
        try {
            result = catalogFuture.get();
        } catch (...) {
            result.authenticationFailed = true;
        }
        catalogJobRunning = false;
        catalogLoadingKinds.clear();
        const std::string currentSourceId =
            settings.source
                ? (settings.source->id.empty() ? sourceId(*settings.source) : settings.source->id)
                : std::string{};
        const std::string currentSourceIdentity =
            settings.source ? computedSourceId(*settings.source) : std::string{};
        if (currentSourceId.empty() || result.sourceId != currentSourceId ||
            result.sourceIdentity != currentSourceIdentity ||
            result.sourceGeneration != sourceGeneration) {
            ensureCatalogForTab();
            return;
        }
        if (result.authenticated) {
            sourceAuthenticated = true;
            if (!result.preferredLiveFormat.empty())
                sourceLiveFormat = result.preferredLiveFormat;
        }
        const bool wasVisibleEmpty = tab != Tab::Settings && visibleItems().empty();
        bool affectedCurrentTab = false;
        for (auto &[kind, catalog] : result.catalogs) {
            if (tab == Tab::Favorites ||
                (tab != Tab::Settings && kind == kindForTab(tab))) {
                affectedCurrentTab = true;
            }
            for (auto &item : catalog.items) {
                if (item.sourceId.empty() && settings.source)
                    item.sourceId = sourceId(*settings.source);
            }
            catalogs[kind] = std::move(catalog);
            catalogLoaded.insert(kind);
            catalogFailed.erase(kind);
        }
        if (!result.catalogs.empty())
            invalidateCatalogCache();
        for (const auto &[kind, failure] : result.failures) {
            (void)failure;
            catalogFailed.insert(kind);
        }
        if (catalogFailed.count(kindForTab(tab)) != 0 ||
            (tab == Tab::Favorites && !catalogFailed.empty())) {
            banner = result.authenticationFailed
                         ? "Could not sign in. Check the source details and try again."
                         : "Could not load the catalog. Check the source and network, then retry.";
        }
        if (!result.catalogs.empty() && (affectedCurrentTab || wasVisibleEmpty)) {
            itemIndex = 0;
            categoryIndex = 0;
        }
        ensureCatalogForTab();
    }

    void rebuildEpisodeSeasons() {
        episodeSeasons.clear();
        std::set<int> seasons;
        for (const auto &ep : episodes) {
            if (ep.episodeDetails && ep.episodeDetails->seasonNumber)
                seasons.insert(*ep.episodeDetails->seasonNumber);
        }
        for (int s : seasons)
            episodeSeasons.push_back(s);
        selectedSeasonIndex = 0;
        episodeIndex = 0;
    }

    std::vector<const MediaItem *> filteredEpisodes() const {
        std::vector<const MediaItem *> out;
        if (episodes.empty())
            return out;
        if (episodeSeasons.size() <= 1 || selectedSeasonIndex < 0 ||
            selectedSeasonIndex >= static_cast<int>(episodeSeasons.size())) {
            out.reserve(episodes.size());
            for (const auto &ep : episodes)
                out.push_back(&ep);
            return out;
        }
        const int targetSeason = episodeSeasons[static_cast<std::size_t>(selectedSeasonIndex)];
        for (const auto &ep : episodes) {
            if (ep.episodeDetails && ep.episodeDetails->seasonNumber &&
                *ep.episodeDetails->seasonNumber == targetSeason) {
                out.push_back(&ep);
            }
        }
        return out;
    }

    void startEpisodes(const MediaItem &series) {
        if (preview) {
            banner =
                "Preview mode has no playable episodes. Connect a source to browse its series.";
            return;
        }
        if (!settings.source)
            return;
        selectedSeriesId = series.providerId.empty() ? series.id : series.providerId;
        episodesOpen = true;
        episodeIndex = 0;
        selectedSeasonIndex = 0;
        episodeSeasons.clear();
        episodes.clear();
        if (episodesJobRunning) {
            pendingEpisodeSeries = series;
            return;
        }
        const Source source = *settings.source;
        auto client = catalogClient;
        const std::string id = selectedSeriesId;
        const auto generation = sourceGeneration;
        episodesJobRunning = true;
        pendingEpisodeSeries.reset();
        episodesFuture = std::async(std::launch::async, [client, source, id, generation]() {
            EpisodeResult result;
            result.seriesId = id;
            result.sourceGeneration = generation;
            try {
                result.items = client->loadEpisodes(source, id);
            } catch (...) {
                result.ok = false;
            }
            return result;
        });
        banner.clear();
    }

    void pollEpisodes() {
        if (!episodesJobRunning || !episodesFuture.valid() ||
            episodesFuture.wait_for(std::chrono::seconds(0)) != std::future_status::ready)
            return;
        EpisodeResult result;
        try {
            result = episodesFuture.get();
        } catch (...) {
            result.ok = false;
        }
        episodesJobRunning = false;
        if (result.sourceGeneration != sourceGeneration || result.seriesId != selectedSeriesId ||
            !episodesOpen) {
            if (pendingEpisodeSeries && settings.source && episodesOpen) {
                const MediaItem pending = *pendingEpisodeSeries;
                pendingEpisodeSeries.reset();
                startEpisodes(pending);
            }
            return;
        }
        pendingEpisodeSeries.reset();
        episodes = std::move(result.items);
        if (!result.ok)
            banner = "Could not load episodes. Check the source and retry.";
        else if (episodes.empty())
            banner = "No episodes were returned for this series.";
        else
            banner.clear();
        for (auto &item : episodes) {
            if (item.sourceId.empty() && settings.source)
                item.sourceId = sourceId(*settings.source);
        }
        rebuildEpisodeSeasons();
    }

    std::string epgQueryId(const Source &source, const MediaItem &item) const {
        if (source.type == SourceType::Xtream)
            return item.providerId.empty() ? item.id : item.providerId;
        if (source.type == SourceType::M3U && !item.epgId.empty() &&
            !catalogClient->xmltvUrl(source).empty())
            return item.epgId;
        return {};
    }

    const std::vector<EpgEntry> *cachedEpgFor(const MediaItem &item) const {
        const auto it = epgCache.find(sourceScopedItemKey(item));
        if (it == epgCache.end() || !it->second.ok)
            return nullptr;
        return &it->second.entries;
    }

    void startEpg(const MediaItem &item, bool forceRefresh = false) {
        if (preview || !settings.source || item.kind != MediaKind::Live) {
            if (playingItem && sourceScopedItemKey(*playingItem) == sourceScopedItemKey(item))
                epgEntries.clear();
            return;
        }
        const std::string itemId = sourceScopedItemKey(item);
        const auto now = std::chrono::steady_clock::now();
        if (!forceRefresh) {
            auto cached = epgCache.find(itemId);
            if (cached != epgCache.end()) {
                const auto ttl = cached->second.ok ? kEpgSuccessTtl : kEpgFailureTtl;
                if (now - cached->second.fetchedAt < ttl) {
                    if (playingItem && sourceScopedItemKey(*playingItem) == itemId) {
                        epgEntries = cached->second.ok ? cached->second.entries
                                                       : std::vector<EpgEntry>{};
                    }
                    return;
                }
            }
        }
        const Source source = *settings.source;
        const std::string queryId = epgQueryId(source, item);
        if (queryId.empty()) {
            if (playingItem && sourceScopedItemKey(*playingItem) == itemId)
                epgEntries.clear();
            return;
        }
        if (epgJobRunning)
            return;
        auto client = catalogClient;
        const auto generation = sourceGeneration;
        epgInFlightItemId = itemId;
        epgInFlightGeneration = generation;
        epgJobRunning = true;
        epgFuture = std::async(std::launch::async, [client, source, queryId, itemId, generation]() {
            EpgResult result;
            result.itemId = itemId;
            result.sourceGeneration = generation;
            try {
                result.entries = client->loadEpg(source, queryId);
            } catch (...) {
                result.ok = false;
            }
            return result;
        });
    }

    void pollEpg() {
        if (!epgJobRunning || !epgFuture.valid() ||
            epgFuture.wait_for(std::chrono::seconds(0)) != std::future_status::ready)
            return;
        EpgResult result;
        try {
            result = epgFuture.get();
        } catch (...) {
            result.ok = false;
            result.itemId = epgInFlightItemId;
            result.sourceGeneration = epgInFlightGeneration;
        }
        epgJobRunning = false;
        if (result.sourceGeneration != sourceGeneration)
            return;
        if (epgCache.size() >= 128)
            epgCache.clear();
        epgCache[result.itemId] = {result.entries, std::chrono::steady_clock::now(), result.ok};
        if (playingItem && playingLive) {
            const std::string activeKey = sourceScopedItemKey(*playingItem);
            if (result.itemId == activeKey) {
                epgEntries = result.ok ? std::move(result.entries) : std::vector<EpgEntry>{};
            } else {
                startEpg(*playingItem);
            }
        }
    }

    void scheduleBrowseEpgForFocusedItem() {
        if (preview || playerScreen || episodesOpen || focus != Focus::Items || tab == Tab::Settings)
            return;
        const auto &items = visibleItems();
        if (items.empty() || itemIndex < 0 || itemIndex >= static_cast<int>(items.size()))
            return;
        const MediaItem &selected = *items[static_cast<std::size_t>(itemIndex)];
        if (selected.kind != MediaKind::Live)
            return;
        const std::string key = sourceScopedItemKey(selected);
        if (key == browseEpgTargetKey && browseEpgScheduled)
            return;
        browseEpgTargetKey = key;
        browseEpgDueAt = std::chrono::steady_clock::now() + kBrowseEpgDebounce;
        browseEpgScheduled = true;
    }

    void setTab(Tab next) {
        if (next == Tab::Settings) {
            if (tab != Tab::Settings)
                lastContentTab = tab;
            tab = next;
            focus = Focus::Settings;
            settingIndex = 0;
        } else {
            tab = next;
            lastContentTab = next;
            focus = Focus::Sidebar;
            episodesOpen = false;
        }
        sidebarIndex = indexOf(tab);
        categoryIndex = 0;
        itemIndex = 0;
        searchQuery.clear();
        banner.clear();
        browseEpgScheduled = false;
        ensureCatalogForTab();
    }

    const std::vector<std::string> &categoryNames() const {
        if (categoriesCacheValid && cachedCategoriesTab == tab &&
            cachedCategoriesVersion == catalogDataVersion) {
            return cachedCategories;
        }
        cachedCategories.clear();
        if (tab == Tab::Favorites) {
            cachedCategories = {"All favorites", "Recently played", "Live TV", "Movies", "Series"};
            categoriesCacheValid = true;
            cachedCategoriesTab = tab;
            cachedCategoriesVersion = catalogDataVersion;
            return cachedCategories;
        }
        cachedCategories.emplace_back("All");
        std::unordered_set<std::string> seen{"All"};
        const auto kind = kindForTab(tab);
        auto found = catalogs.find(kind);
        if (found != catalogs.end()) {
            for (const auto &category : found->second.categories) {
                if (category.kind == kind && !category.name.empty() &&
                    seen.insert(category.name).second)
                    cachedCategories.push_back(category.name);
            }
            if (cachedCategories.size() == 1) {
                for (const auto &item : found->second.items) {
                    if (!item.categoryName.empty() && seen.insert(item.categoryName).second)
                        cachedCategories.push_back(item.categoryName);
                }
            }
        }
        categoriesCacheValid = true;
        cachedCategoriesTab = tab;
        cachedCategoriesVersion = catalogDataVersion;
        return cachedCategories;
    }

    const std::vector<const MediaItem *> &visibleItems() const {
        const auto source = currentSource();
        const std::string activeSourceId = source.id.empty() ? sourceId(source) : source.id;
        const auto &categories = categoryNames();
        const int clampedCategory =
            categories.empty()
                ? 0
                : std::clamp(categoryIndex, 0, static_cast<int>(categories.size()) - 1);
        if (visibleCacheValid && cachedVisibleTab == tab &&
            cachedVisibleCategory == clampedCategory && cachedVisibleSearch == searchQuery &&
            cachedVisibleSourceId == activeSourceId &&
            cachedVisibleVersion == catalogDataVersion) {
            return cachedVisibleItems;
        }
        cachedVisibleItems.clear();
        const std::string selectedCategory =
            categories.empty() ? "All" : categories[static_cast<std::size_t>(clampedCategory)];
        const std::string_view queryView(searchQuery);
        auto matchesQuery = [&](const MediaItem &item) {
            if (queryView.empty())
                return true;
            return containsCaseInsensitive(item.title, queryView) ||
                   containsCaseInsensitive(item.categoryName, queryView) ||
                   containsCaseInsensitive(item.description, queryView);
        };

        if (tab != Tab::Favorites && tab != Tab::Settings) {
            // Live / Movies / Series: items are already pre-sorted on the background thread!
            const auto kind = kindForTab(tab);
            const auto found = catalogs.find(kind);
            if (found != catalogs.end()) {
                const auto &items = found->second.items;
                cachedVisibleItems.reserve(selectedCategory == "All" && queryView.empty()
                                               ? items.size()
                                               : std::min<std::size_t>(items.size(), 1024));
                for (const auto &item : items) {
                    if (!source.id.empty() && item.sourceId != source.id)
                        continue;
                    if (source.id.empty() && !item.sourceId.empty() &&
                        item.sourceId != activeSourceId)
                        continue;
                    if (selectedCategory != "All" && item.categoryName != selectedCategory)
                        continue;
                    if (!matchesQuery(item))
                        continue;
                    cachedVisibleItems.push_back(&item);
                }
            }
        } else if (tab == Tab::Favorites) {
            if (selectedCategory == "Recently played") {
                const auto recent = settings.recentsBySource.find(activeSourceId);
                if (recent != settings.recentsBySource.end()) {
                    for (const auto &item : recent->second) {
                        if (matchesQuery(item))
                            cachedVisibleItems.push_back(&item);
                    }
                }
            } else {
                const auto favoritesIt = settings.favoritesBySource.find(activeSourceId);
                const std::set<std::string> *favorites =
                    favoritesIt == settings.favoritesBySource.end() ? nullptr
                                                                    : &favoritesIt->second;
                if (favorites && !favorites->empty()) {
                    std::unordered_set<std::string_view> seenIds;
                    auto collectFrom = [&](const std::vector<MediaItem> &items) {
                        for (const auto &item : items) {
                            if (favorites->count(item.id) == 0)
                                continue;
                            if (selectedCategory == "Live TV" && item.kind != MediaKind::Live)
                                continue;
                            if (selectedCategory == "Movies" && item.kind != MediaKind::Movie)
                                continue;
                            if (selectedCategory == "Series" && item.kind != MediaKind::Series)
                                continue;
                            if (!matchesQuery(item))
                                continue;
                            if (seenIds.insert(item.id).second)
                                cachedVisibleItems.push_back(&item);
                        }
                    };
                    for (const auto &[k, cat] : catalogs) {
                        (void)k;
                        collectFrom(cat.items);
                    }
                    if (const auto rec = settings.recentsBySource.find(activeSourceId);
                        rec != settings.recentsBySource.end()) {
                        collectFrom(rec->second);
                    }
                    std::stable_sort(cachedVisibleItems.begin(), cachedVisibleItems.end(),
                                     [](const MediaItem *a, const MediaItem *b) {
                                         return caseInsensitiveLess(a->title, b->title);
                                     });
                }
            }
        }

        visibleCacheValid = true;
        cachedVisibleTab = tab;
        cachedVisibleCategory = clampedCategory;
        cachedVisibleSearch = searchQuery;
        cachedVisibleSourceId = activeSourceId;
        cachedVisibleVersion = catalogDataVersion;
        return cachedVisibleItems;
    }

    void clampItemSelection() {
        if (episodesOpen)
            return;
        const auto &items = visibleItems();
        itemIndex =
            items.empty() ? 0 : std::clamp(itemIndex, 0, static_cast<int>(items.size()) - 1);
    }

    void addRecent(const MediaItem &item) {
        if (item.sourceId.empty())
            return;
        auto &recents = settings.recentsBySource[item.sourceId];
        recents.erase(
            std::remove_if(recents.begin(), recents.end(),
                           [&item](const MediaItem &existing) { return existing.id == item.id; }),
            recents.end());
        recents.insert(recents.begin(), item);
        if (recents.size() > 30)
            recents.resize(30);
        // Only invalidate browse cache when viewing Favorites/Recents (saves full rebuild on Live/Movies/Series).
        if (tab == Tab::Favorites) {
            visibleCacheValid = false;
            clampItemSelection();
        }
        scheduleSettingsSave();
    }

    void toggleFavorite(const MediaItem &item) {
        if (item.sourceId.empty())
            return;
        auto &favorites = settings.favoritesBySource[item.sourceId];
        const auto found = favorites.find(item.id);
        if (found == favorites.end()) {
            favorites.insert(item.id);
            banner = "Added to favorites";
        } else {
            favorites.erase(found);
            banner = "Removed from favorites";
        }
        if (tab == Tab::Favorites) {
            visibleCacheValid = false;
            clampItemSelection();
        }
        scheduleSettingsSave();
    }

    bool isFavorite(const MediaItem &item) const {
        const auto found = settings.favoritesBySource.find(item.sourceId);
        return found != settings.favoritesBySource.end() && found->second.count(item.id) != 0;
    }

    double savedResumePosition(const MediaItem &item) const {
        if (item.kind == MediaKind::Live || item.sourceId.empty())
            return 0.0;
        const auto srcIt = settings.resumePositionsBySource.find(item.sourceId);
        if (srcIt == settings.resumePositionsBySource.end())
            return 0.0;
        const auto posIt = srcIt->second.find(item.id);
        return posIt == srcIt->second.end() ? 0.0 : posIt->second;
    }

    void recordCurrentResumePosition(bool forceSave) {
        if (preview || !playingItem || playingLive || playingItem->sourceId.empty())
            return;
        const double duration = playerStatus.durationSeconds;
        const double current = playerStatus.currentSeconds;
        auto &positions = settings.resumePositionsBySource[playingItem->sourceId];
        if (playerStatus.state == Player::State::Ended ||
            (duration > 0.0 && current / duration >= 0.95)) {
            if (positions.erase(playingItem->id) > 0) {
                if (positions.empty())
                    settings.resumePositionsBySource.erase(playingItem->sourceId);
                scheduleSettingsSave();
            }
            return;
        }
        if (current >= 10.0 && (duration <= 0.0 || current / duration < 0.95)) {
            const auto now = std::chrono::steady_clock::now();
            if (!forceSave && now - lastResumeSaveAt < kResumeSaveInterval)
                return;
            lastResumeSaveAt = now;
            if (positions.size() >= 500 && positions.find(playingItem->id) == positions.end()) {
                positions.erase(positions.begin());
            }
            positions[playingItem->id] = current;
            scheduleSettingsSave();
        }
    }

    void touchHud() {
        showPlayerHud = true;
        hudHideAt = std::chrono::steady_clock::now() + kHudAutoHideDelay;
    }

    void launchItem(const MediaItem &item) {
        if (item.kind == MediaKind::Series) {
            focus = Focus::Items;
            startEpisodes(item);
            return;
        }
        if (preview) {
            banner =
                "Preview only. Connect your own authorized M3U or Xtream source to play streams.";
            return;
        }
        if (item.mediaUrl.empty()) {
            banner = "This item has no playable stream URL.";
            return;
        }
        recordCurrentResumePosition(true);
        playingItem = item;
        playbackTitle = item.title;
        playbackSubtitle = item.categoryName;
        playingLive = item.kind == MediaKind::Live;
        const double startOffset = playingLive ? 0.0 : savedResumePosition(item);
        beginPlayback(item.mediaUrl, playingLive, item.requestHeaders, startOffset);
        addRecent(item);
        if (playingLive)
            startEpg(item);
    }

    void beginPlayback(const std::string &url, bool live,
                       const std::unordered_map<std::string, std::string> &requestHeaders = {},
                       double startSeconds = 0.0) {
        if (preview) {
            banner = "Preview only. Playback is disabled.";
            return;
        }
        if (url.empty()) {
            banner = "No stream URL was provided.";
            return;
        }
        player->setVolume(settings.volume);
        player->open(url, live, requestHeaders, startSeconds);
        playerScreen = true;
        playerStatus = player->status();
        hasVideoFrame = false;
        lastResumeSaveAt = std::chrono::steady_clock::now();
        touchHud();
        banner.clear();
    }

    void zapChannel(int direction) {
        if (!playingLive || !playingItem || tab == Tab::Settings)
            return;
        const auto &items = visibleItems();
        if (items.size() < 2)
            return;
        int currentIdx = -1;
        for (std::size_t i = 0; i < items.size(); ++i) {
            if (items[i]->id == playingItem->id && items[i]->sourceId == playingItem->sourceId) {
                currentIdx = static_cast<int>(i);
                break;
            }
        }
        if (currentIdx < 0)
            currentIdx = std::clamp(itemIndex, 0, static_cast<int>(items.size()) - 1);
        const int n = static_cast<int>(items.size());
        for (int step = 1; step <= n; ++step) {
            const int candidateIdx = ((currentIdx + direction * step) % n + n) % n;
            const MediaItem *candidate = items[static_cast<std::size_t>(candidateIdx)];
            if (candidate->kind == MediaKind::Live && !candidate->mediaUrl.empty()) {
                itemIndex = candidateIdx;
                const MediaItem copy = *candidate;
                launchItem(copy);
                return;
            }
        }
    }

    void startSelectedPlayback() {
        if (episodesOpen) {
            const auto list = filteredEpisodes();
            if (list.empty() || episodeIndex < 0 || episodeIndex >= static_cast<int>(list.size()))
                return;
            const MediaItem selected = *list[static_cast<std::size_t>(episodeIndex)];
            launchItem(selected);
            return;
        }
        const auto &items = visibleItems();
        if (items.empty() || itemIndex < 0 || itemIndex >= static_cast<int>(items.size()))
            return;
        const MediaItem selected = *items[static_cast<std::size_t>(itemIndex)];
        launchItem(selected);
    }

    void toggleSelectedFavorite() {
        if (episodesOpen) {
            const auto list = filteredEpisodes();
            if (episodeIndex >= 0 && episodeIndex < static_cast<int>(list.size())) {
                const MediaItem selected = *list[static_cast<std::size_t>(episodeIndex)];
                toggleFavorite(selected);
            }
            return;
        }
        const auto &items = visibleItems();
        if (itemIndex >= 0 && itemIndex < static_cast<int>(items.size())) {
            const MediaItem selected = *items[static_cast<std::size_t>(itemIndex)];
            toggleFavorite(selected);
        }
    }

    void playUrlValue(const std::string &url, bool live) {
        if (preview) {
            banner = "Preview only. Playback is disabled.";
            return;
        }
        playingItem.reset();
        playbackTitle = "Direct stream";
        playbackSubtitle.clear();
        playingLive = live;
        beginPlayback(url, live);
    }

    void connectSource(Source source) {
        if (preview) {
            banner = "Preview mode does not connect to IPTV sources.";
            return;
        }
        recordCurrentResumePosition(true);
        const std::string sourceIdentity = computedSourceId(source);
        const bool retainedIdentity = settings.source && !source.id.empty() &&
                                      source.id == settings.source->id &&
                                      sourceIdentity == computedSourceId(*settings.source);
        if (!retainedIdentity)
            source.id = sourceIdentity;
        ++sourceGeneration;
        if (source.name.empty())
            source.name = source.type == SourceType::Xtream ? "Xtream source" : "M3U playlist";
        draft = source;
        draftIdentity = sourceIdentity;
        settings.source = source;
        upsertSavedSource(source);
        sourceAuthenticated = false;
        sourceLiveFormat.clear();
        catalogClient->invalidateCache(source.id);
        catalogLoaded.clear();
        catalogs.clear();
        catalogFailed.clear();
        epgCache.clear();
        browseEpgScheduled = false;
        invalidateCatalogCache();
        episodes.clear();
        episodeSeasons.clear();
        episodesOpen = false;
        pendingEpisodeSeries.reset();
        selectedSeriesId.clear();
        player->stop();
        player->clearFormatCache();
        playerScreen = false;
        playingItem.reset();
        epgEntries.clear();
        flushSettingsSaveSync();
        tab = Tab::Live;
        lastContentTab = Tab::Live;
        sidebarIndex = indexOf(tab);
        focus = Focus::Items;
        itemIndex = 0;
        categoryIndex = 0;
        banner = "Connecting to source...";
        startCatalogJob({MediaKind::Live}, true);
    }

    void connectDraft() {
        if (preview) {
            banner = "Preview mode does not connect to IPTV sources.";
            return;
        }
        std::optional<Source> imported;
        if (!joinLink.empty()) {
            imported = parseLoginLink(joinLink);
            if (!imported) {
                banner = "Enter a valid BruTV join link.";
                return;
            }
        } else if (!draft.url.empty()) {
            const auto candidate = parseLoginLink(draft.url);
            if (draft.type == SourceType::M3U ||
                (candidate && candidate->type == SourceType::Xtream) ||
                isBruTvJoinLink(draft.url)) {
                imported = candidate;
            }
        }
        Source source = imported ? *imported : draft;
        if (source.type == SourceType::M3U && source.url.empty()) {
            banner = "Enter an M3U playlist URL or a BruTV join link.";
            return;
        }
        if (source.type == SourceType::Xtream &&
            (source.url.empty() || source.username.empty() || source.password.empty())) {
            banner = "Enter the Xtream server, username, and password.";
            return;
        }
        joinLink.clear();
        connectSource(std::move(source));
    }

    void clearSavedSource() {
        if (preview) {
            banner = "Preview mode cannot change the saved source.";
            modal = Modal::None;
            return;
        }
        const std::string removedSourceId =
            settings.source ? (settings.source->id.empty() ? computedSourceId(*settings.source)
                                                           : settings.source->id)
                            : std::string{};
        ++sourceGeneration;
        if (!removedSourceId.empty()) {
            settings.favoritesBySource.erase(removedSourceId);
            settings.recentsBySource.erase(removedSourceId);
            settings.resumePositionsBySource.erase(removedSourceId);
            settings.savedSources.erase(
                std::remove_if(settings.savedSources.begin(), settings.savedSources.end(),
                               [&](const Source &s) {
                                   const std::string sid = s.id.empty() ? computedSourceId(s) : s.id;
                                   return sid == removedSourceId;
                               }),
                settings.savedSources.end());
            catalogClient->invalidateCache(removedSourceId);
        }
        settings.source.reset();
        draft = Source{};
        draft.name = "My TV";
        draftIdentity = computedSourceId(draft);
        savedSourceIndex = 0;
        catalogLoaded.clear();
        catalogs.clear();
        catalogFailed.clear();
        epgCache.clear();
        browseEpgScheduled = false;
        sourceAuthenticated = false;
        sourceLiveFormat.clear();
        invalidateCatalogCache();
        player->stop();
        player->clearFormatCache();
        playerScreen = false;
        playingItem.reset();
        epgEntries.clear();
        episodes.clear();
        episodeSeasons.clear();
        episodesOpen = false;
        pendingEpisodeSeries.reset();
        selectedSeriesId.clear();
        flushSettingsSaveSync();
        banner = "Saved source cleared";
        modal = Modal::None;
        tab = Tab::Settings;
        focus = Focus::Settings;
        sidebarIndex = indexOf(tab);
    }

    std::string fieldValue(EditField field) const {
        switch (field) {
        case EditField::Search:
            return searchQuery;
        case EditField::Name:
            return draft.name;
        case EditField::Url:
            return draft.url;
        case EditField::Username:
            return draft.username;
        case EditField::Password:
            return draft.password;
        case EditField::JoinLink:
            return joinLink;
        case EditField::None:
            break;
        }
        return {};
    }

    void setFieldValue(EditField field, std::string value) {
        switch (field) {
        case EditField::Search:
            searchQuery = std::move(value);
            itemIndex = 0;
            break;
        case EditField::Name:
            draft.name = std::move(value);
            persistDraft();
            break;
        case EditField::Url:
            draft.url = std::move(value);
            persistDraft();
            break;
        case EditField::Username:
            draft.username = std::move(value);
            persistDraft();
            break;
        case EditField::Password:
            draft.password = std::move(value);
            persistDraft();
            break;
        case EditField::JoinLink:
            joinLink = std::move(value);
            break;
        case EditField::None:
            break;
        }
    }

    void beginKeyboard(EditField field) {
        keyboardReturnFocus = focus;
        editField = field;
        keyboardBuffer = fieldValue(field);
        keyboardRow = 0;
        keyboardColumn = 0;
        keyboardUppercase = true;
        keyboardSymbols = false;
        modal = Modal::Keyboard;
        focus = Focus::Settings;
    }

    void closeKeyboard() {
        modal = Modal::None;
        editField = EditField::None;
        focus = keyboardReturnFocus;
    }

    int keyboardRowLength(int row) const {
        const auto &rows = activeKeyboardRows();
        if (row >= 0 && row < static_cast<int>(rows.size()))
            return static_cast<int>(rows[static_cast<std::size_t>(row)].size());
        return static_cast<int>(keyboardBottom.front().size());
    }

    void keyboardMove(Key key) {
        const int rows = static_cast<int>(activeKeyboardRows().size()) + 1;
        const int rowLen = keyboardRowLength(keyboardRow);
        if (key == Key::Left)
            keyboardColumn = (keyboardColumn - 1 + rowLen) % rowLen;
        if (key == Key::Right)
            keyboardColumn = (keyboardColumn + 1) % rowLen;
        if (key == Key::Up)
            keyboardRow = (keyboardRow - 1 + rows) % rows;
        if (key == Key::Down)
            keyboardRow = (keyboardRow + 1) % rows;
        keyboardColumn = std::min(keyboardColumn, keyboardRowLength(keyboardRow) - 1);
    }

    void acceptKeyboardKey() {
        const int keyCount = keyboardRowLength(keyboardRow);
        if (keyboardColumn < 0 || keyboardColumn >= keyCount)
            return;
        const auto &rows = activeKeyboardRows();
        if (keyboardRow < static_cast<int>(rows.size())) {
            char character = rows[static_cast<std::size_t>(keyboardRow)]
                                 [static_cast<std::size_t>(keyboardColumn)];
            if (!keyboardUppercase && character >= 'A' && character <= 'Z')
                character = static_cast<char>(character - 'A' + 'a');
            keyboardBuffer.push_back(character);
            return;
        }
        const std::string &value = keyboardBottom.front()[static_cast<std::size_t>(keyboardColumn)];
        if (value == "Space")
            keyboardBuffer.push_back(' ');
        else if (value == "Shift")
            keyboardUppercase = !keyboardUppercase;
        else if (value == "Symbols") {
            keyboardSymbols = !keyboardSymbols;
            keyboardRow = 0;
            keyboardColumn = 0;
        } else if (value == "Clear")
            keyboardBuffer.clear();
        else if (value == "Delete") {
            eraseLastCodepoint(keyboardBuffer);
        } else if (value == "Cancel") {
            closeKeyboard();
        } else if (value == "Done") {
            setFieldValue(editField, keyboardBuffer);
            closeKeyboard();
        } else {
            keyboardBuffer += value;
        }
    }

    void handleText(const std::string &text) {
        if (text.empty())
            return;
        if (modal == Modal::Keyboard) {
            keyboardBuffer += text;
        } else if (focus == Focus::Settings && tab == Tab::Settings) {
            const EditField field = fieldForSetting(settingIndex);
            if (field != EditField::None) {
                std::string value = fieldValue(field);
                value += text;
                setFieldValue(field, std::move(value));
            }
        } else if (!searchQuery.empty() || focus == Focus::Items) {
            searchQuery += text;
            itemIndex = 0;
        }
    }

    static EditField fieldForSetting(int index) {
        switch (index) {
        case 1:
            return EditField::Name;
        case 2:
            return EditField::Url;
        case 3:
            return EditField::Username;
        case 4:
            return EditField::Password;
        case 5:
            return EditField::JoinLink;
        default:
            return EditField::None;
        }
    }

    void backspaceCurrent() {
        if (modal == Modal::Keyboard) {
            eraseLastCodepoint(keyboardBuffer);
            return;
        }
        if (tab == Tab::Settings && focus == Focus::Settings) {
            const auto field = fieldForSetting(settingIndex);
            std::string value = fieldValue(field);
            eraseLastCodepoint(value);
            setFieldValue(field, std::move(value));
        } else if (!searchQuery.empty()) {
            eraseLastCodepoint(searchQuery);
            itemIndex = 0;
        }
    }

    void moveTab(int direction) {
        if (playerScreen)
            return;
        const Tab next = tabAt(indexOf(tab) + direction);
        setTab(next);
    }

    void changeVolume(float delta) {
        settings.volume = std::clamp(settings.volume + delta, 0.0F, 1.0F);
        player->setVolume(settings.volume);
        scheduleSettingsSave(std::chrono::milliseconds(500));
    }

    void handleSettingsKey(Key key) {
        const int lastRow = settings.savedSources.empty() ? 8 : 9;
        if (key == Key::Up)
            settingIndex = std::max(0, settingIndex - 1);
        else if (key == Key::Down)
            settingIndex = std::min(lastRow, settingIndex + 1);
        else if (key == Key::Left || key == Key::Right) {
            if (settingIndex == 0) {
                draft.type = draft.type == SourceType::M3U ? SourceType::Xtream : SourceType::M3U;
                persistDraft();
            } else if (settingIndex == 6) {
                changeVolume(key == Key::Right ? 0.05F : -0.05F);
            } else if (settingIndex == 9 && !settings.savedSources.empty()) {
                const int n = static_cast<int>(settings.savedSources.size());
                savedSourceIndex =
                    ((savedSourceIndex + (key == Key::Right ? 1 : -1)) % n + n) % n;
            }
        } else if (key == Key::Confirm) {
            if (settingIndex == 0) {
                draft.type = draft.type == SourceType::M3U ? SourceType::Xtream : SourceType::M3U;
                persistDraft();
            } else if (settingIndex >= 1 && settingIndex <= 5) {
                beginKeyboard(fieldForSetting(settingIndex));
            } else if (settingIndex == 6) {
                changeVolume(0.05F);
            } else if (settingIndex == 7) {
                connectDraft();
            } else if (settingIndex == 8) {
                if (preview) {
                    banner = "Preview mode cannot change the saved source.";
                } else if (settings.source) {
                    modal = Modal::ClearSource;
                    clearConfirmation = "Clear this source, its saved items, and stop playback?";
                } else {
                    banner = "No saved source to clear.";
                }
            } else if (settingIndex == 9 && !settings.savedSources.empty()) {
                const int idx = std::clamp(savedSourceIndex, 0,
                                           static_cast<int>(settings.savedSources.size()) - 1);
                connectSource(settings.savedSources[static_cast<std::size_t>(idx)]);
            }
        }
    }

    void moveCategory(int delta) {
        const auto &categories = categoryNames();
        if (categories.empty())
            return;
        categoryIndex =
            std::clamp(categoryIndex + delta, 0, static_cast<int>(categories.size()) - 1);
        itemIndex = 0;
    }

    void moveItem(int delta) {
        if (episodesOpen) {
            const auto list = filteredEpisodes();
            if (list.empty())
                return;
            episodeIndex =
                std::clamp(episodeIndex + delta, 0, static_cast<int>(list.size()) - 1);
            return;
        }
        const auto &items = visibleItems();
        if (items.empty())
            return;
        itemIndex = std::clamp(itemIndex + delta, 0, static_cast<int>(items.size()) - 1);
        scheduleBrowseEpgForFocusedItem();
    }

    void handleContentKey(Key key) {
        if (focus == Focus::Sidebar) {
            if (key == Key::Up) {
                setTab(tabAt(indexOf(tab) - 1));
            } else if (key == Key::Down) {
                setTab(tabAt(indexOf(tab) + 1));
            } else if (key == Key::Right || key == Key::Confirm) {
                focus = tab == Tab::Settings ? Focus::Settings : Focus::Categories;
            }
        } else if (focus == Focus::Categories) {
            if (key == Key::Up)
                moveCategory(-1);
            else if (key == Key::Down)
                moveCategory(1);
            else if (key == Key::Rewind)
                moveCategory(-10);
            else if (key == Key::Forward)
                moveCategory(10);
            else if (key == Key::Left)
                focus = Focus::Sidebar;
            else if (key == Key::Right || key == Key::Confirm) {
                focus = Focus::Items;
                scheduleBrowseEpgForFocusedItem();
            }
        } else if (focus == Focus::Items) {
            if (episodesOpen) {
                if (key == Key::Up)
                    moveItem(-1);
                else if (key == Key::Down)
                    moveItem(1);
                else if (key == Key::Rewind)
                    moveItem(-8);
                else if (key == Key::Forward)
                    moveItem(8);
                else if ((key == Key::Left || key == Key::Right) && episodeSeasons.size() > 1) {
                    const int n = static_cast<int>(episodeSeasons.size());
                    selectedSeasonIndex =
                        ((selectedSeasonIndex + (key == Key::Right ? 1 : -1)) % n + n) % n;
                    episodeIndex = 0;
                } else if (key == Key::Confirm)
                    startSelectedPlayback();
                return;
            }
            if (key == Key::Left) {
                if (itemIndex % gridColumns == 0)
                    focus = Focus::Categories;
                else
                    moveItem(-1);
            } else if (key == Key::Right) {
                moveItem(1);
            } else if (key == Key::Up) {
                moveItem(-gridColumns);
            } else if (key == Key::Down) {
                moveItem(gridColumns);
            } else if (key == Key::Rewind) {
                moveItem(-9);
            } else if (key == Key::Forward) {
                moveItem(9);
            } else if (key == Key::Confirm) {
                if (visibleItems().empty() && !catalogFailed.empty())
                    retryCatalogForTab();
                else
                    startSelectedPlayback();
            }
        }
    }

    bool isPlayerActive() const { return playerScreen; }

    void handlePlayerKey(Key key) {
        if (key == Key::Back) {
            recordCurrentResumePosition(true);
            player->stop();
            playerStatus = player->status();
            playingItem.reset();
            playingLive = true;
            playerScreen = false;
            showPlayerHud = false;
        } else if (key == Key::Confirm) {
            player->togglePause();
            recordCurrentResumePosition(true);
            touchHud();
        } else if (key == Key::Rewind) {
            player->seekRelative(-10.0);
            touchHud();
        } else if (key == Key::Forward) {
            player->seekRelative(playingLive ? 10.0 : 30.0);
            touchHud();
        } else if (key == Key::Left) {
            if (playingLive)
                zapChannel(-1);
            else
                player->seekRelative(-10.0);
            touchHud();
        } else if (key == Key::Right) {
            if (playingLive)
                zapChannel(1);
            else
                player->seekRelative(10.0);
            touchHud();
        } else if (key == Key::PreviousTab) {
            player->cycleAudioTrack();
            touchHud();
        } else if (key == Key::NextTab) {
            player->cycleSubtitleTrack();
            touchHud();
        } else if (key == Key::Search && playingLive) {
            player->goLive();
            touchHud();
        } else if (key == Key::Up) {
            changeVolume(0.05F);
            touchHud();
        } else if (key == Key::Down) {
            changeVolume(-0.05F);
            touchHud();
        } else if (key == Key::Favorite && playingItem) {
            toggleFavorite(*playingItem);
            touchHud();
        } else if (key == Key::Options) {
            if (showPlayerHud)
                showPlayerHud = false;
            else
                touchHud();
        } else if (key == Key::Quit) {
            quit = true;
        }
    }

    void handle(Input input) {
        handleText(input.text);
        for (const auto key : input.pressed) {
            if (key == Key::Quit) {
                quit = true;
                continue;
            }
            if (modal == Modal::ClearSource) {
                if (key == Key::Confirm)
                    clearSavedSource();
                else if (key == Key::Back)
                    modal = Modal::None;
                continue;
            }
            if (modal == Modal::Keyboard) {
                if (key == Key::Back) {
                    closeKeyboard();
                } else if (key == Key::Backspace || key == Key::Favorite) {
                    // Square = Delete shortcut on DualSense
                    eraseLastCodepoint(keyboardBuffer);
                } else if (key == Key::Search) {
                    // Triangle = Space shortcut on DualSense
                    keyboardBuffer.push_back(' ');
                } else if (key == Key::Options) {
                    // Options = Done shortcut on DualSense
                    setFieldValue(editField, keyboardBuffer);
                    closeKeyboard();
                } else if (key == Key::Confirm) {
                    acceptKeyboardKey();
                } else if (key == Key::Up || key == Key::Down || key == Key::Left ||
                           key == Key::Right) {
                    keyboardMove(key);
                }
                continue;
            }
            if (key == Key::Backspace) {
                backspaceCurrent();
                continue;
            }
            if (isPlayerActive()) {
                handlePlayerKey(key);
                continue;
            }
            if (key == Key::PreviousTab) {
                moveTab(-1);
                continue;
            }
            if (key == Key::NextTab) {
                moveTab(1);
                continue;
            }
            if (key == Key::Options) {
                if (tab == Tab::Settings)
                    setTab(lastContentTab);
                else
                    setTab(Tab::Settings);
                continue;
            }
            if (key == Key::Search) {
                beginKeyboard(EditField::Search);
                continue;
            }
            if (key == Key::Favorite) {
                toggleSelectedFavorite();
                continue;
            }
            if (key == Key::Back) {
                if (episodesOpen) {
                    episodesOpen = false;
                    episodeIndex = 0;
                    selectedSeasonIndex = 0;
                    banner.clear();
                } else if (focus == Focus::Items) {
                    focus = Focus::Categories;
                    browseEpgScheduled = false;
                } else if (focus == Focus::Categories || focus == Focus::Settings) {
                    focus = Focus::Sidebar;
                } else if (!searchQuery.empty()) {
                    searchQuery.clear();
                }
                continue;
            }
            if (tab == Tab::Settings && focus == Focus::Settings)
                handleSettingsKey(key);
            else
                handleContentKey(key);
        }
    }

    void tick() {
        const auto now = std::chrono::steady_clock::now();
        pollCatalog();
        pollEpisodes();
        pollEpg();
        ensureCatalogForTab();
        if (browseEpgScheduled && now >= browseEpgDueAt) {
            browseEpgScheduled = false;
            if (!playerScreen && !episodesOpen && focus == Focus::Items && tab != Tab::Settings) {
                const auto &items = visibleItems();
                if (itemIndex >= 0 && itemIndex < static_cast<int>(items.size())) {
                    const MediaItem &selected = *items[static_cast<std::size_t>(itemIndex)];
                    if (selected.kind == MediaKind::Live &&
                        sourceScopedItemKey(selected) == browseEpgTargetKey) {
                        startEpg(selected);
                    }
                }
            }
        }
        if (player) {
            playerStatus = player->status();
            if (player->takeFrame(activeVideoFrame) && activeVideoFrame.width > 0 &&
                activeVideoFrame.height > 0) {
                if (activeVideoFrame.format == VideoFrame::Format::Yuv420p &&
                    !activeVideoFrame.yPlane.empty() && !activeVideoFrame.uPlane.empty() &&
                    !activeVideoFrame.vPlane.empty()) {
                    gfx.videoYuv(activeVideoFrame.yPlane.data(), activeVideoFrame.uPlane.data(),
                                 activeVideoFrame.vPlane.data(), activeVideoFrame.width,
                                 activeVideoFrame.height, activeVideoFrame.displayWidth,
                                 activeVideoFrame.displayHeight,
                                 static_cast<int>(activeVideoFrame.colorSpace),
                                 activeVideoFrame.fullRange);
                    hasVideoFrame = true;
                } else if (!activeVideoFrame.rgba.empty()) {
                    gfx.video(activeVideoFrame.rgba.data(), activeVideoFrame.width,
                              activeVideoFrame.height);
                    hasVideoFrame = true;
                }
            }
            if (playerScreen) {
                // Auto-hide HUD after 5s of inactivity while actively playing video.
                if (showPlayerHud && hasVideoFrame &&
                    playerStatus.state == Player::State::Playing && now >= hudHideAt) {
                    showPlayerHud = false;
                }
                // Periodic VOD/Series resume tracking and completion clear.
                if (!playingLive && playingItem) {
                    recordCurrentResumePosition(playerStatus.state == Player::State::Ended);
                }
                // Refresh live EPG automatically when current program expires and cache TTL passed.
                if (playingLive && playingItem && !epgEntries.empty() && !epgJobRunning) {
                    const auto nowEpoch = static_cast<std::int64_t>(std::time(nullptr));
                    const auto nn = findNowNext(epgEntries);
                    if (nn.now && nn.now->endEpochSeconds > 0 &&
                        nowEpoch >= nn.now->endEpochSeconds) {
                        startEpg(*playingItem, false);
                    }
                }
            }
        }
    }

    void drawArtwork(const MediaItem &item, float x, float y, float width, float height,
                     bool poster = false) {
        gfx.rect(x, y, width, height, rgb(9, 18, 31), 10);
        const float inset = poster ? 0.0F : 9.0F;
        if (!item.logoUrl.empty() && gfx.hasImage(item.logoUrl)) {
            // Fast GPU cache hit: skip ArtworkCache mutex lookup completely.
            gfx.image(item.logoUrl, nullptr, 0, 0, x + inset, y + inset, width - inset * 2,
                      height - inset * 2, poster, 8);
            return;
        }
        if (const auto image = artwork.request(item.logoUrl)) {
            gfx.image(item.logoUrl, image->rgba.data(), image->width, image->height, x + inset,
                      y + inset, width - inset * 2, height - inset * 2, poster, 8);
            artwork.releaseCpu(item.logoUrl);
        } else {
            const auto icon = item.kind == MediaKind::Live    ? Icon::Live
                              : item.kind == MediaKind::Movie ? Icon::Movies
                                                              : Icon::Series;
            const float size = std::min(width, height) * 0.42F;
            gfx.icon(icon, x + (width - size) / 2, y + (height - size) / 2, size,
                     rgb(76, 109, 135));
        }
    }

    static Color buttonColor(Button button) {
        switch (button) {
        case Button::Cross:
            return rgb(116, 177, 255);
        case Button::Circle:
            return rgb(255, 133, 143);
        case Button::Square:
            return rgb(230, 160, 232);
        case Button::Triangle:
            return rgb(112, 225, 188);
        default:
            return kMuted;
        }
    }

    float controlHint(Button button, const std::string &label, float x, float y,
                      float textSize = 19.0F) {
        gfx.button(button, x, y, 29, buttonColor(button));
        gfx.text(label, x + 40, y + 3, textSize, kMuted);
        return 40 + gfx.textWidth(label, textSize);
    }

    void renderShell() {
        gfx.rect(0, 0, kWidth, kHeight, kBackground);
        gfx.rect(0, 0, kWidth, 6, kCyan);
        gfx.rect(38, 28, 254, 94, kPanel, 18);
        gfx.icon(Icon::Live, 59, 46, 39, kCyan);
        gfx.text("BRU", 110, 43, 29, kCyan);
        gfx.text("TV", 174, 43, 29, kText);
        gfx.text("YOUR TV, YOUR WAY", 62, 91, 14, kMuted, 210);
        gfx.text(tabLabel(tab), 330, 40, 34, kText, 700);
        if (!preview) {
            gfx.rect(1430, 37, 182, 40, kPanelRaised, 20);
            gfx.button(Button::Triangle, 1443, 44, 25, buttonColor(Button::Triangle));
            gfx.text("Search", 1480, 47, 19, kText, 87);
            gfx.icon(Icon::Search, 1575, 47, 19, kMuted);
        }
        if (preview) {
            gfx.rect(1436, 37, 194, 40, rgb(89, 47, 91), 20);
            gfx.text("PREVIEW ONLY", 1458, 48, 17, rgb(255, 215, 255), 155);
        } else if (settings.source) {
            gfx.rect(1645, 37, 235, 40, kPanelRaised, 20);
            gfx.rect(1661, 52, 10, 10, sourceAuthenticated ? kGreen : kMuted, 5);
            gfx.text(shortened(settings.source->name, 22), 1683, 47, 18, kText, 180);
        } else {
            gfx.rect(1657, 37, 222, 40, kPanelRaised, 20);
            gfx.rect(1674, 52, 10, 10, kMuted, 5);
            gfx.text("No source connected", 1695, 47, 16, kMuted, 170);
        }
        gfx.rect(38, 144, 254, 816, kPanel, 18);
        const std::array<Tab, 5> allTabs{Tab::Live, Tab::Movies, Tab::Series, Tab::Favorites,
                                         Tab::Settings};
        const std::array<std::string, 5> names{"Live TV", "Movies", "Series", "Favorites",
                                               "Settings"};
        const std::array<Icon, 5> icons{Icon::Live, Icon::Movies, Icon::Series, Icon::Heart,
                                        Icon::Settings};
        for (std::size_t i = 0; i < allTabs.size(); ++i) {
            const float y = 180.0F + static_cast<float>(i) * 88.0F;
            const bool active = tab == allTabs[i];
            const bool selected = focus == Focus::Sidebar && active;
            if (active)
                gfx.rect(53, y, 224, 68, selected ? kPanelSelected : kPanelRaised, 14);
            if (selected)
                gfx.rect(53, y + 10, 4, 48, kCyan, 2);
            gfx.icon(icons[i], 76, y + 18, 31, active ? kCyan : kMuted);
            gfx.text(names[i], 131, y + 16, 26, active ? kText : kMuted, 145);
        }
        gfx.rect(59, 731, 211, 1, kBorder);
        gfx.button(Button::L1, 64, 754, 27, kMuted);
        gfx.button(Button::R1, 99, 754, 27, kMuted);
        gfx.text("Tabs", 141, 759, 18, kMuted);
        controlHint(Button::Options, "Settings", 64, 794, 18);
        controlHint(Button::Square, "Favorite", 64, 834, 18);
        controlHint(Button::Triangle, "Search", 64, 874, 18);
        controlHint(Button::Circle, "Back", 64, 914, 18);
        gfx.rect(318, 144, 251, 816, kPanel, 18);
        gfx.rect(587, 144, 1292, 816, kPanel, 18);
        if (!searchQuery.empty()) {
            gfx.rect(1430, 164, 420, 46, kPanelRaised, 22);
            gfx.icon(Icon::Search, 1448, 176, 22, kCyan);
            gfx.text(shortened(searchQuery, 30), 1481, 175, 19, kText, 345);
        }
    }

    void renderFooter(const std::string &hint) {
        gfx.rect(318, 978, 1561, 69, kPanel, 16);
        std::istringstream segments(hint);
        std::string segment;
        float x = 347;
        while (std::getline(segments, segment, '|')) {
            const auto first = segment.find_first_not_of(' ');
            if (first == std::string::npos)
                continue;
            segment.erase(0, first);
            segment.erase(segment.find_last_not_of(' ') + 1);
            struct HintButton {
                const char *prefix;
                Button button;
            };
            const std::array<HintButton, 7> buttons{{{"X ", Button::Cross},
                                                     {"O ", Button::Circle},
                                                     {"SQUARE ", Button::Square},
                                                     {"TRIANGLE ", Button::Triangle},
                                                     {"OPTIONS ", Button::Options},
                                                     {"L2 ", Button::L2},
                                                     {"R2 ", Button::R2}}};
            bool drawn = false;
            for (const auto &button : buttons) {
                const std::string prefix(button.prefix);
                if (segment.rfind(prefix, 0) == 0) {
                    x += controlHint(button.button, segment.substr(prefix.size()), x, 998) + 26;
                    drawn = true;
                    break;
                }
            }
            if (drawn)
                continue;
            if (segment.rfind("D-pad ", 0) == 0 || segment.rfind("LEFT / RIGHT ", 0) == 0) {
                const std::size_t prefix = segment.rfind("D-pad ", 0) == 0 ? 6 : 13;
                gfx.icon(Icon::Dpad, x, 998, 29, kMuted);
                const auto label = segment.substr(prefix);
                gfx.text(label, x + 40, 1001, 19, kMuted);
                x += 66 + gfx.textWidth(label, 19);
            } else {
                gfx.text(segment, x, 1001, 19, kMuted, 1845 - x);
                x += gfx.textWidth(segment, 19) + 26;
            }
        }
    }

    void renderCategories() {
        gfx.text(tab == Tab::Favorites ? "FILTER" : "CATEGORIES", 344, 168, 17, kMuted, 210);
        const auto &names = categoryNames();
        const int start = categoryIndex >= 12 ? categoryIndex - 11 : 0;
        for (int i = start; i < static_cast<int>(names.size()) && i < start + 13; ++i) {
            const float y = 212.0F + static_cast<float>(i - start) * 53.0F;
            const bool selected = i == categoryIndex;
            if (selected)
                gfx.rect(333, y, 221, 44,
                         focus == Focus::Categories ? kPanelSelected : kPanelRaised, 11);
            gfx.text(shortened(names[static_cast<std::size_t>(i)], 22), 350, y + 8, 22,
                     selected ? kText : kMuted, 185);
        }
        if (focus == Focus::Categories)
            gfx.rect(545, 220 + static_cast<float>(categoryIndex - start) * 53.0F, 3, 28, kCyan, 2);
    }

    void renderItems() {
        renderCategories();
        const float contentX = 610.0F;
        if (episodesOpen) {
            gfx.text("EPISODES", contentX, 169, 17, kMuted, 200);
            float listTop = 214.0F;
            if (episodeSeasons.size() > 1) {
                float sx = contentX + 130.0F;
                const int seasonStart =
                    selectedSeasonIndex >= 6 ? selectedSeasonIndex - 5 : 0;
                for (int i = seasonStart;
                     i < static_cast<int>(episodeSeasons.size()) && i < seasonStart + 8; ++i) {
                    const bool active = i == selectedSeasonIndex;
                    const std::string label =
                        "Season " + std::to_string(episodeSeasons[static_cast<std::size_t>(i)]);
                    const float pillW = std::max(108.0F, gfx.textWidth(label, 16) + 28.0F);
                    if (sx + pillW > contentX + 1204.0F)
                        break;
                    gfx.rect(sx, 160, pillW, 34, active ? kPanelSelected : kPanelRaised, 10);
                    gfx.text(label, sx + 14, 168, 16, active ? kCyan : kMuted, pillW - 20);
                    sx += pillW + 10.0F;
                }
                listTop = 214.0F;
            }
            const auto visibleEps = filteredEpisodes();
            if (episodesJobRunning) {
                gfx.text("Loading episodes...", contentX, 227, 25, kText, 600);
            } else if (visibleEps.empty()) {
                gfx.text(banner.empty() ? "No episodes available." : banner, contentX, 227, 20,
                         kMuted, 1050);
            } else {
                const int visible = 8;
                episodeIndex =
                    std::clamp(episodeIndex, 0, static_cast<int>(visibleEps.size()) - 1);
                const int start = episodeIndex >= visible ? episodeIndex - visible + 1 : 0;
                for (int i = start; i < static_cast<int>(visibleEps.size()) && i < start + visible;
                     ++i) {
                    const float y = listTop + static_cast<float>(i - start) * 78.0F;
                    const bool selected = i == episodeIndex;
                    gfx.rect(contentX, y, 1204, 66, selected ? kPanelSelected : kPanelRaised, 12);
                    const auto &episode = *visibleEps[static_cast<std::size_t>(i)];
                    drawArtwork(episode, contentX + 10, y + 8, 64, 50, true);
                    std::string prefix;
                    if (episode.episodeDetails) {
                        if (episode.episodeDetails->seasonNumber)
                            prefix += "S" + std::to_string(*episode.episodeDetails->seasonNumber);
                        if (episode.episodeDetails->episodeNumber)
                            prefix += " E" + std::to_string(*episode.episodeDetails->episodeNumber);
                    }
                    gfx.text(prefix.empty() ? "EPISODE" : prefix, contentX + 88, y + 22, 17, kCyan,
                             110);
                    gfx.text(shortened(episode.title, 82), contentX + 215, y + 7, 22, kText, 950);
                    const double resumePos = savedResumePosition(episode);
                    if (resumePos >= 10.0) {
                        gfx.text("Resume " + formatTime(resumePos), contentX + 1020, y + 10, 15,
                                 kCyan, 170);
                    }
                    if (episode.episodeDetails && !episode.episodeDetails->plot.empty())
                        gfx.text(shortened(episode.episodeDetails->plot, 112), contentX + 215,
                                 y + 37, 18, kMuted, 950);
                }
            }
            renderFooter(episodeSeasons.size() > 1
                             ? "X Play | LEFT / RIGHT Season | SQUARE Favorite | L2 Page | O Back"
                             : "X Play episode | SQUARE Favorite | D-pad Browse | O Back");
            return;
        }

        if (!hasSource()) {
            gfx.text("Start with a playlist or provider", contentX, 237, 29, kText, 1020);
            gfx.text("Add an M3U playlist or Xtream account in Settings. BruTV does not include "
                     "channels or subscriptions.",
                     contentX, 292, 22, kMuted, 1130);
            gfx.rect(contentX, 356, 562, 225, kPanelRaised, 20);
            gfx.text("M3U PLAYLIST", contentX + 28, 384, 17, kCyan, 250);
            gfx.text("Paste an authorized playlist URL", contentX + 28, 419, 25, kText, 485);
            wrappedText(gfx,
                        "Press OPTIONS to open Settings, choose the playlist field, then enter a "
                        "URL or BruTV join link.",
                        contentX + 28, 467, 21, kMuted, 493, 3);
            gfx.rect(contentX + 586, 356, 560, 225, kPanelRaised, 20);
            gfx.text("XTREAM CODES", contentX + 614, 384, 17, kCyan, 250);
            gfx.text("Use your provider details", contentX + 614, 419, 25, kText, 485);
            wrappedText(gfx,
                        "BruTV keeps your provider credentials on this device and does not bundle "
                        "a service.",
                        contentX + 614, 467, 21, kMuted, 492, 3);
            renderFooter("OPTIONS Settings | TRIANGLE Search catalog | O Return");
            return;
        }

        const auto &items = visibleItems();
        itemIndex =
            items.empty() ? 0 : std::clamp(itemIndex, 0, static_cast<int>(items.size()) - 1);
        if (catalogJobRunning && catalogLoaded.count(kindForTab(tab)) == 0 &&
            tab != Tab::Favorites) {
            gfx.text("Loading " + lower(tabLabel(tab)) + "...", contentX, 214, 25, kText, 800);
            gfx.text("The catalog is loading in the background. You can move between sections "
                     "while it finishes.",
                     contentX, 256, 21, kMuted, 1050);
            renderFooter("Loading source catalog... | OPTIONS Settings | TRIANGLE Search");
            return;
        }
        if (items.empty()) {
            if (!banner.empty())
                gfx.text(banner, contentX, 216, 19, kRed, 1150);
            else if (catalogFailed.count(kindForTab(tab)) != 0 ||
                     (tab == Tab::Favorites && !catalogFailed.empty()))
                gfx.text("Could not load catalog. Press X to retry.", contentX, 216, 23, kRed,
                         1150);
            else
                gfx.text(searchQuery.empty() ? "No items in this section yet."
                                             : "No matches. Clear search to see all items.",
                         contentX, 216, 21, kMuted, 1100);
            if (catalogFailed.count(kindForTab(tab)) != 0) {
                gfx.rect(contentX, 264, 200, 55, kPanelRaised, 13);
                gfx.text("X  Retry", contentX + 22, 281, 21, kCyan, 160);
            }
            renderFooter("X Retry catalog | TRIANGLE Search | OPTIONS Settings");
            return;
        }

        const int pageSize = 9;
        const int pageStart = (itemIndex / pageSize) * pageSize;
        constexpr float cardWidth = 389.0F;
        constexpr float cardHeight = 176.0F;
        constexpr float gapX = 18.0F;
        constexpr float gapY = 18.0F;
        gfx.text(tab == Tab::Live     ? "YOUR CHANNELS"
                 : tab == Tab::Movies ? "MOVIES"
                 : tab == Tab::Series ? "SERIES"
                                      : "YOUR FAVORITES",
                 contentX, 169, 17, kMuted, 360);
        for (int cell = 0; cell < pageSize && pageStart + cell < static_cast<int>(items.size());
             ++cell) {
            const int index = pageStart + cell;
            const int row = cell / gridColumns;
            const int col = cell % gridColumns;
            const float x = contentX + static_cast<float>(col) * (cardWidth + gapX);
            const float y = 211.0F + static_cast<float>(row) * (cardHeight + gapY);
            const auto &item = *items[static_cast<std::size_t>(index)];
            const bool selected = itemIndex == index;
            if (selected && focus == Focus::Items)
                gfx.rect(x - 3, y - 3, cardWidth + 6, cardHeight + 6, kCyan, 18);
            gfx.rect(x, y, cardWidth, cardHeight,
                     selected && focus == Focus::Items ? kPanelSelected : kPanelRaised, 15);
            const bool live = item.kind == MediaKind::Live;
            drawArtwork(item, x + 15, y + 16, live ? 122 : 104, 144, !live);
            if (!live) {
                const double resumePos = savedResumePosition(item);
                if (resumePos >= 10.0) {
                    gfx.rect(x + 15, y + 156, 104, 4, rgb(32, 52, 72), 2);
                    gfx.rect(x + 15, y + 156, 52, 4, kCyan, 2);
                }
            }
            const float textX = x + 153;
            wrappedText(gfx, item.title, textX, y + 26, 25, kText, cardWidth - 179, 2);
            gfx.text(item.categoryName.empty() ? kindName(item.kind) : item.categoryName, textX,
                     y + 101, 17, kMuted, cardWidth - 179);
            gfx.rect(textX, y + 133, live ? 68 : 83, 24, live ? rgb(20, 64, 56) : rgb(30, 49, 78),
                     7);
            if (live)
                gfx.rect(textX + 9, y + 142, 6, 6, kGreen, 3);
            gfx.text(live                            ? "LIVE"
                     : item.kind == MediaKind::Movie ? "MOVIE"
                                                     : "SERIES",
                     textX + (live ? 22 : 11), y + 138, 13, live ? kGreen : kBlue, 65);
            if (isFavorite(item))
                gfx.icon(Icon::Heart, x + cardWidth - 32, y + 12, 19, kCyan);
            gfx.rect(x + cardWidth - 47, y + 125, 33, 33,
                     selected ? rgb(34, 85, 102) : rgb(26, 43, 62), 17);
            gfx.icon(item.kind == MediaKind::Series ? Icon::ChevronRight : Icon::Play,
                     x + cardWidth - 40, y + 132, 19, selected ? kCyan : kMuted);
        }

        const auto &selected = *items[static_cast<std::size_t>(itemIndex)];
        const float detailsY = 808.0F;
        gfx.rect(contentX, detailsY, 1206, 133, kPanelRaised, 15);
        drawArtwork(selected, contentX + 17, detailsY + 17, 99, 99,
                    selected.kind != MediaKind::Live);
        gfx.text(shortened(selected.title, 56), contentX + 138, detailsY + 13, 29, kText, 900);
        std::string meta =
            selected.categoryName.empty() ? kindName(selected.kind) : selected.categoryName;
        if (!selected.rating.empty())
            meta += "  |  " + selected.rating;
        if (selected.episodeDetails && selected.episodeDetails->durationSeconds > 0)
            meta +=
                "  |  " + formatTime(static_cast<double>(selected.episodeDetails->durationSeconds));
        const double resumePos = savedResumePosition(selected);
        if (resumePos >= 10.0)
            meta += "  |  Resume at " + formatTime(resumePos);
        gfx.text(meta, contentX + 138, detailsY + 51, 19, kCyan, 900);
        std::string detailLine =
            selected.description.empty() ? "Select to open this item." : selected.description;
        if (selected.kind == MediaKind::Live) {
            if (const auto *entries = cachedEpgFor(selected)) {
                const auto nn = findNowNext(*entries);
                if (nn.now) {
                    detailLine = "NOW: " + nn.now->title;
                    if (nn.next) {
                        const auto hm = formatClockHm(nn.next->startEpochSeconds);
                        detailLine += "   |   NEXT" + (hm.empty() ? std::string{} : " (" + hm + ")") +
                                      ": " + nn.next->title;
                    }
                }
            }
        }
        wrappedText(gfx, detailLine, contentX + 138, detailsY + 83, 18, kMuted, 1008, 1);
        const std::string pageInfo =
            std::to_string(itemIndex + 1) + " / " + std::to_string(items.size());
        gfx.text(pageInfo, contentX + 1084, detailsY + 17, 13, kMuted, 92);
        renderFooter(
            "X Play | SQUARE Favorite | TRIANGLE Search | L2 Page Up | R2 Page Down | OPTIONS Settings");
    }

    void renderSettings() {
        gfx.text("SOURCE & PLAYBACK", 350, 174, 13, kMuted, 300);
        gfx.text("Connect a service you are authorized to use", 350, 205, 27, kText, 1000);
        gfx.text("Credentials stay in this device's protected settings file. BruTV does not "
                 "provide channels or subscriptions.",
                 350, 244, 20, kMuted, 1130);
        const bool hasSavedSources = !settings.savedSources.empty();
        const int rowCount = hasSavedSources ? 10 : 9;
        std::string savedSourceValue = "No saved sources";
        if (hasSavedSources) {
            const int idx = std::clamp(savedSourceIndex, 0,
                                       static_cast<int>(settings.savedSources.size()) - 1);
            const auto &s = settings.savedSources[static_cast<std::size_t>(idx)];
            savedSourceValue = s.name + " (" + std::to_string(idx + 1) + "/" +
                               std::to_string(settings.savedSources.size()) +
                               ") | Left/Right to select, X to switch";
        }
        const std::array<std::string, 10> labels{"Source type",
                                                 "Source name",
                                                 draft.type == SourceType::M3U ? "Playlist URL"
                                                                               : "Server URL",
                                                 "Username",
                                                 "Password",
                                                 "BruTV join link",
                                                 "Volume",
                                                 "Connect / save source",
                                                 "Clear saved source",
                                                 "Switch saved source"};
        const std::array<std::string, 10> values{
            draft.type == SourceType::M3U ? "M3U playlist" : "Xtream Codes",
            draft.name.empty() ? "Enter a name" : draft.name,
            draft.url.empty() ? (draft.type == SourceType::M3U ? "https://.../playlist.m3u"
                                                               : "https://provider.example")
                              : draft.url,
            draft.username.empty() ? "Enter username" : draft.username,
            draft.password.empty() ? "Enter password" : maskString(draft.password.size()),
            joinLink.empty() ? "Paste brutv:// or supported HTTPS join link"
                             : "Sign-in link entered | " + maskString(8),
            std::to_string(static_cast<int>(std::round(settings.volume * 100.0F))) + "%",
            "Validate source and load catalog",
            preview
                ? "Preview does not change saved source"
                : (settings.source ? "Remove saved source from this device" : "No saved source"),
            savedSourceValue};
        const float rowStride = hasSavedSources ? 61.0F : 67.0F;
        const float rowHeight = hasSavedSources ? 52.0F : 56.0F;
        for (int i = 0; i < rowCount; ++i) {
            const float y = 290.0F + static_cast<float>(i) * rowStride;
            const bool selected = settingIndex == i && focus == Focus::Settings;
            gfx.rect(347, y, 1136, rowHeight, selected ? kPanelSelected : kPanelRaised, 11);
            gfx.text(labels[static_cast<std::size_t>(i)], 367, y + 14, 18,
                     selected ? kText : kMuted, 252);
            const std::string shownValue =
                i == 4 && !draft.password.empty()
                    ? maskString(std::min<std::size_t>(draft.password.size(), 22))
                    : values[static_cast<std::size_t>(i)];
            gfx.text(shortened(shownValue, i == 2 || i == 5 ? 72 : 60), 632, y + 13, 18,
                     i == 7 || i == 9 ? kCyan : (i == 8 ? kRed : kText), 820);
            if (selected)
                gfx.rect(1464, y + 10, 3, rowHeight - 20, kCyan, 2);
        }
        if (banner.empty()) {
            gfx.text("Select a field, then press Cross to open its keyboard. Left / right adjusts "
                     "type, volume, or saved source.",
                     350, 919, 17, kMuted, 1100);
        } else {
            gfx.text(shortened(banner, 128), 350, 919, 18,
                     banner.find("Could not") != std::string::npos || banner.find("Enter ") == 0
                         ? kRed
                         : kCyan,
                     1100);
        }
        renderFooter(
            "X Edit / connect | TRIANGLE Search | LEFT / RIGHT Adjust | OPTIONS Return");
    }

    std::string playerStateText() const {
        switch (playerStatus.state) {
        case Player::State::Idle:
            return "Stopped";
        case Player::State::Opening:
            return "Opening stream...";
        case Player::State::Buffering:
            return "Buffering...";
        case Player::State::Playing:
            return "Playing";
        case Player::State::Paused:
            return "Paused";
        case Player::State::Ended:
            return "Playback ended";
        case Player::State::Error:
            return "Playback failed. Check the source and try again.";
        }
        return "";
    }

    void renderPlayer() {
        gfx.rect(0, 0, kWidth, kHeight, rgb(0, 0, 0));
        if (hasVideoFrame)
            gfx.drawVideo(0, 0, kWidth, kHeight);
        else {
            gfx.rect(0, 0, kWidth, kHeight, rgb(5, 10, 17));
            gfx.text("BRU", 860, 330, 44, kCyan, 100);
            gfx.text("TV", 949, 330, 44, kText, 80);
            gfx.text(playerStateText(), 660, 425, 22,
                     playerStatus.state == Player::State::Error ? kRed : kMuted, 600);
        }
        if (!playerStatus.subtitleText.empty()) {
            std::vector<std::string> lines;
            std::istringstream words(playerStatus.subtitleText);
            std::string word;
            std::string line;
            while (words >> word && lines.size() < 3) {
                const std::string next = line.empty() ? word : line + " " + word;
                if (!line.empty() && gfx.textWidth(next, 32) > 1450) {
                    lines.push_back(line);
                    line = word;
                } else {
                    line = next;
                }
            }
            if (!line.empty() && lines.size() < 3) lines.push_back(line);
            const float bottom = showPlayerHud ? 811.0F : 1000.0F;
            const float top = bottom - static_cast<float>(lines.size()) * 43.0F;
            gfx.rect(200, top - 10, 1520, bottom - top + 22, {0, 0, 0, 0.78F}, 8);
            for (std::size_t index = 0; index < lines.size(); ++index) {
                const float width = gfx.textWidth(lines[index], 32);
                gfx.text(lines[index], (kWidth - width) * 0.5F,
                    top + static_cast<float>(index) * 43.0F, 32, kText, 1480);
            }
        }
        if (!showPlayerHud && hasVideoFrame)
            return;
        gfx.rect(0, 0, kWidth, 174, {0.015F, 0.025F, 0.045F, 0.92F});
        gfx.rect(0, 837, kWidth, 243, {0.015F, 0.025F, 0.045F, 0.94F});
        const float titleX = playingItem ? 218.0F : 80.0F;
        if (playingItem)
            drawArtwork(*playingItem, 77, 35, 112, 108, playingItem->kind != MediaKind::Live);
        gfx.text(shortened(playbackTitle, 68), titleX, 49, 33, kText, 1400);
        gfx.icon(playerStatus.state == Player::State::Paused ? Icon::Pause : Icon::Play, titleX,
                 106, 21, kCyan);
        gfx.text(playerStateText(), titleX + 34, 104, 20,
                 playerStatus.state == Player::State::Error ? kRed : kCyan, 660);
        if (!playbackSubtitle.empty())
            gfx.text(playbackSubtitle, 870, 107, 18, kMuted, 660);
        if (playerStatus.hasVideo) {
            const std::string dimensions =
                std::to_string(playerStatus.width) + " x " + std::to_string(playerStatus.height);
            gfx.text(dimensions, 1650, 103, 18, kMuted, 190);
        }
        const std::string message = !playerStatus.rewindMessage.empty()
            ? playerStatus.rewindMessage : playerStatus.message;
        const auto nn = playingLive ? findNowNext(epgEntries) : NowNextEpg{};
        if (playerStatus.durationSeconds > 0.0 && !playingLive) {
            const float progress = static_cast<float>(
                std::clamp(playerStatus.currentSeconds / playerStatus.durationSeconds, 0.0, 1.0));
            gfx.rect(79, 876, 1760, 5, rgb(65, 83, 99), 3);
            gfx.rect(79, 876, 1760.0F * progress, 5, kCyan, 3);
            gfx.text(formatTime(playerStatus.currentSeconds) + "  /  " +
                         formatTime(playerStatus.durationSeconds),
                     80, 897, 18, kMuted, 300);
        } else if (playingLive && playerStatus.liveRewind) {
            if (nn.now) {
                gfx.text("NOW", 80, 845, 17, kCyan, 60);
                gfx.text(shortened(nn.now->title, 54), 140, 844, 20, kText, 840);
                if (nn.next) {
                    const auto hm = formatClockHm(nn.next->startEpochSeconds);
                    gfx.text("NEXT", 1020, 845, 17, kMuted, 65);
                    gfx.text(shortened((hm.empty() ? std::string{} : hm + " ") + nn.next->title, 48),
                             1090, 844, 19, kMuted, 750);
                }
                if (message.empty() && !nn.now->description.empty()) {
                    gfx.text(shortened(nn.now->description, 120), 80, 938, 17, kMuted, 1700);
                }
            } else if (epgJobRunning) {
                gfx.text("Loading guide...", 80, 845, 17, kMuted, 300);
            }
            const double window = playerStatus.windowEndSeconds - playerStatus.windowStartSeconds;
            const float progress = static_cast<float>(window > 0 ? std::clamp(
                (playerStatus.currentSeconds - playerStatus.windowStartSeconds) / window, 0.0, 1.0) : 1.0);
            gfx.rect(79, 876, 1760, 5, rgb(65, 83, 99), 3);
            gfx.rect(79, 876, 1760.0F * progress, 5, kCyan, 3);
            const double behind = std::max(0.0, playerStatus.windowEndSeconds - playerStatus.currentSeconds);
            gfx.text(formatTime(window) + " saved | " + formatTime(behind) + " behind live | " +
                std::to_string(playerStatus.recordedBytes / 1024 / 1024) + " MiB", 80, 897, 18, kMuted, 900);
            controlHint(Button::Triangle, "Go live", 1430, 897);
        } else if (nn.now) {
            gfx.text("NOW", 80, 855, 17, kCyan, 60);
            gfx.text(shortened(nn.now->title, 54), 145, 853, 21, kText, 830);
            if (nn.next) {
                const auto hm = formatClockHm(nn.next->startEpochSeconds);
                gfx.text("NEXT", 1020, 855, 17, kMuted, 65);
                gfx.text(shortened((hm.empty() ? std::string{} : hm + " ") + nn.next->title, 48),
                         1090, 854, 19, kMuted, 750);
            }
            if (!nn.now->description.empty())
                gfx.text(shortened(nn.now->description, 120), 80, 896, 18, kMuted, 1700);
        } else if (playingLive && epgJobRunning) {
            gfx.text("Loading guide...", 80, 884, 18, kMuted, 300);
        }
        controlHint(Button::Options, "HUD", 80, 974);
        controlHint(Button::Cross, playerStatus.state == Player::State::Paused ? "Resume" : "Pause",
                    240, 974);
        const Color seekColor = playingLive && !playerStatus.liveRewind ? rgb(84, 101, 116) : kMuted;
        gfx.button(Button::L2, 470, 974, 29, seekColor);
        gfx.button(Button::R2, 511, 974, 29, seekColor);
        gfx.text("Seek", 554, 977, 19, seekColor, 100);
        if (playingLive) {
            gfx.icon(Icon::Dpad, 690, 975, 28, kMuted);
            gfx.text("Ch +/-", 730, 977, 19, kMuted, 120);
        }
        gfx.icon(Icon::Volume, 955, 975, 28, kMuted);
        gfx.icon(Icon::Dpad, 997, 975, 28, kMuted);
        gfx.text("Volume " +
                     std::to_string(static_cast<int>(std::round(settings.volume * 100.0F))) + "%",
                 1038, 977, 19, kMuted, 300);
        controlHint(Button::Circle, "Stop / return", 1498, 974);
        auto selectedTrack = [](const auto& tracks, int selected, const char* fallback) {
            const auto found = std::find_if(tracks.begin(), tracks.end(), [selected](const auto& track) {
                return track.id == selected;
            });
            return found == tracks.end() ? std::string(fallback) : found->label;
        };
        controlHint(Button::L1, "Audio: " + selectedTrack(playerStatus.audioTracks, playerStatus.audioTrack, "None"), 80, 1030);
        controlHint(Button::R1, "Subtitles: " + selectedTrack(playerStatus.subtitleTracks, playerStatus.subtitleTrack, "Off"), 730, 1030);
        if (!message.empty()) gfx.text(shortened(message, 130), 80, 940, 17, kMuted, 1700);
        if (playingLive)
            gfx.text("LIVE", 1705, 53, 17, kRed, 75);
    }

    void renderKeyboard() {
        gfx.rect(0, 0, kWidth, kHeight, {0.0F, 0.0F, 0.0F, 0.54F});
        gfx.rect(347, 370, 1227, 603, kPanel, 22);
        gfx.text(editField == EditField::Password ? "PASSWORD" : "ON-SCREEN KEYBOARD", 382, 395, 18,
                 kMuted, 520);
        std::string shown = keyboardBuffer;
        if (editField == EditField::Password || editField == EditField::JoinLink)
            shown = maskString(keyboardBuffer.size());
        gfx.rect(381, 427, 1157, 53, kPanelRaised, 12);
        gfx.text(shown.empty() ? "Type with the controller or keyboard" : shortened(shown, 100),
                 399, 444, 21, kText, 1120);
        const auto &rows = activeKeyboardRows();
        const float top = 500.0F + static_cast<float>(5 - rows.size()) * 27.0F;
        for (int row = 0; row < static_cast<int>(rows.size()); ++row) {
            const auto &keys = rows[static_cast<std::size_t>(row)];
            const float keyW = keys.size() >= 11 ? 69.0F : 82.0F;
            const float gap = keys.size() >= 11 ? 7.0F : 8.0F;
            const float rowWidth =
                static_cast<float>(keys.size()) * keyW + static_cast<float>(keys.size() - 1) * gap;
            const float rowLeft = (kWidth - rowWidth) / 2.0F;
            for (int col = 0; col < static_cast<int>(keys.size()); ++col) {
                const float x = rowLeft + static_cast<float>(col) * (keyW + gap);
                const float y = top + static_cast<float>(row) * 54.0F;
                const bool selected = keyboardRow == row && keyboardColumn == col;
                gfx.rect(x, y, keyW, 45, selected ? kPanelSelected : kPanelRaised, 9);
                char label = keys[static_cast<std::size_t>(col)];
                if (!keyboardUppercase && label >= 'A' && label <= 'Z')
                    label = static_cast<char>(label - 'A' + 'a');
                gfx.text(std::string(1, label), x + keyW * 0.4F, y + 10, 22,
                         selected ? kCyan : kText, 25);
            }
        }
        const auto &bottom = keyboardBottom.front();
        const float bottomY = 779.0F;
        const float bottomWidth = 179.0F;
        const float bottomGap = 11.0F;
        const float bottomLeft = (kWidth - (static_cast<float>(bottom.size()) * bottomWidth +
                                            static_cast<float>(bottom.size() - 1) * bottomGap)) /
                                 2.0F;
        for (int col = 0; col < static_cast<int>(bottom.size()); ++col) {
            const float x = bottomLeft + static_cast<float>(col) * (bottomWidth + bottomGap);
            const bool selected =
                keyboardRow == static_cast<int>(rows.size()) && keyboardColumn == col;
            gfx.rect(x, bottomY, bottomWidth, 54, selected ? kPanelSelected : kPanelRaised, 10);
            const auto &label = bottom[static_cast<std::size_t>(col)];
            gfx.text(label == "Space"     ? "SPACE"
                     : label == "Shift"   ? (keyboardUppercase ? "SHIFT ON" : "SHIFT OFF")
                     : label == "Symbols" ? (keyboardSymbols ? "ABC" : "SYM")
                                          : label,
                     x + 12, bottomY + 18, 16, selected ? kCyan : kText, bottomWidth - 24);
        }
        float hx = 382.0F;
        hx += controlHint(Button::Cross, "Type", hx, 859, 18) + 22.0F;
        hx += controlHint(Button::Triangle, "Space", hx, 859, 18) + 22.0F;
        hx += controlHint(Button::Square, "Delete", hx, 859, 18) + 22.0F;
        hx += controlHint(Button::Options, "Done", hx, 859, 18) + 22.0F;
        controlHint(Button::Circle, "Cancel", hx, 859, 18);
    }

    void renderClearConfirmation() {
        gfx.rect(0, 0, kWidth, kHeight, {0.0F, 0.0F, 0.0F, 0.67F});
        gfx.rect(560, 399, 800, 260, kPanel, 22);
        gfx.text("Clear saved source?", 606, 438, 30, kText, 650);
        gfx.text(clearConfirmation, 606, 490, 21, kMuted, 700);
        gfx.rect(606, 558, 316, 55, kPanelSelected, 12);
        controlHint(Button::Cross, "Clear source", 631, 572);
        controlHint(Button::Circle, "Cancel", 1010, 572);
    }

    void render() {
        if (playerScreen) {
            renderPlayer();
        } else {
            renderShell();
            if (tab == Tab::Settings)
                renderSettings();
            else
                renderItems();
            if (!banner.empty() && tab != Tab::Settings && hasSource() && !preview) {
                gfx.rect(605, 920, 1198, 31, {0.025F, 0.045F, 0.075F, 0.95F}, 8);
                gfx.text(shortened(banner, 140), 620, 928, 13,
                         banner.find("Could not") != std::string::npos ? kRed : kCyan, 1160);
            }
        }
        if (modal == Modal::Keyboard)
            renderKeyboard();
        else if (modal == Modal::ClearSource)
            renderClearConfirmation();
    }
};

App::App(Platform &platform, Gfx &gfx, std::string settingsFile, HttpGet httpGet, bool preview,
         HttpGet artworkGet)
    : impl_(std::make_unique<Impl>(platform, gfx, std::move(settingsFile), std::move(httpGet),
                                   preview, std::move(artworkGet))) {}

App::~App() = default;

void App::handle(Input input) { impl_->handle(std::move(input)); }
void App::tick() { impl_->tick(); }
void App::render() { impl_->render(); }
bool App::shouldQuit() const { return impl_->quit; }
void App::connect(Source source) { impl_->connectSource(std::move(source)); }
void App::playUrl(std::string url, bool live) { impl_->playUrlValue(url, live); }

} // namespace brutv
