#include "brutv/app.hpp"

#include "brutv/artwork.hpp"
#include "brutv/gfx.hpp"
#include "brutv/player.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <ctime>
#include <future>
#include <map>
#include <set>
#include <sstream>
#include <utility>

namespace brutv {
namespace {

constexpr float kWidth = 1920.0F;
constexpr float kHeight = 1080.0F;

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

std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
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

void wrappedText(Gfx &gfx, const std::string &text, float x, float y, float size, Color color,
                 float maxWidth, int maxLines = 2) {
    if (text.empty() || maxWidth <= 0)
        return;
    std::istringstream words(text);
    std::string word;
    std::string line;
    int lineIndex = 0;
    while (words >> word) {
        const std::string candidate = line.empty() ? word : line + " " + word;
        if (!line.empty() && gfx.textWidth(candidate, size) > maxWidth) {
            gfx.text(line, x, y + static_cast<float>(lineIndex) * (size + 8.0F), size, color,
                     maxWidth);
            ++lineIndex;
            if (lineIndex >= maxLines)
                return;
            line = word;
        } else {
            line = candidate;
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

    Platform &platform;
    Gfx &gfx;
    HttpGet httpGet;
    ArtworkCache artwork;
    SettingsStore store;
    Settings settings;
    Source draft;
    std::string draftIdentity;
    bool preview;
    std::uint64_t sourceGeneration = 0;
    std::unique_ptr<Player> player;
    bool quit = false;
    Tab tab = Tab::Live;
    Tab lastContentTab = Tab::Live;
    Focus focus = Focus::Sidebar;
    int sidebarIndex = 0;
    int categoryIndex = 0;
    int itemIndex = 0;
    int settingIndex = 0;
    int gridColumns = 3;
    bool episodesOpen = false;
    std::string searchQuery;
    std::string banner;
    std::string joinLink;
    std::map<MediaKind, Catalog> catalogs;
    std::map<std::string, MediaItem> library;
    std::set<MediaKind> catalogLoaded;
    std::set<MediaKind> catalogLoadingKinds;
    std::set<MediaKind> catalogFailed;
    bool sourceAuthenticated = false;
    std::future<CatalogJobResult> catalogFuture;
    bool catalogJobRunning = false;
    std::future<EpisodeResult> episodesFuture;
    bool episodesJobRunning = false;
    std::future<EpgResult> epgFuture;
    bool epgJobRunning = false;
    std::vector<MediaItem> episodes;
    std::optional<MediaItem> pendingEpisodeSeries;
    std::string selectedSeriesId;
    int episodeIndex = 0;
    std::vector<EpgEntry> epgEntries;
    std::string playbackTitle;
    std::string playbackSubtitle;
    std::optional<MediaItem> playingItem;
    bool playingLive = true;
    bool showPlayerHud = true;
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
        : platform(p), gfx(g), httpGet(std::move(get)), artwork(std::move(artworkGet)),
          store(std::move(settingsFile)), preview(previewMode),
          player(std::make_unique<Player>(platform.audio())) {
        try {
            settings = store.load();
        } catch (...) {
            settings = Settings{};
        }
        settings.volume = std::clamp(settings.volume, 0.0F, 1.0F);
        if (settings.source) {
            draft = *settings.source;
            draftIdentity = computedSourceId(draft);
            if (draft.id.empty())
                draft.id = draftIdentity;
            settings.source = draft;
            sourceAuthenticated = false;
        } else {
            draft.name = "My TV";
            draft.type = SourceType::M3U;
            draftIdentity = computedSourceId(draft);
        }
        for (const auto &[sourceKey, recentItems] : settings.recentsBySource) {
            (void)sourceKey;
            for (auto item : recentItems) {
                if (item.sourceId.empty())
                    item.sourceId = sourceKey;
                library[sourceScopedItemKey(item)] = std::move(item);
            }
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
        if (catalogFuture.valid())
            catalogFuture.wait();
        if (episodesFuture.valid())
            episodesFuture.wait();
        if (epgFuture.valid())
            epgFuture.wait();
        if (player)
            player->stop();
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

    void saveSettings() {
        if (preview)
            return;
        try {
            settings.volume = std::clamp(settings.volume, 0.0F, 1.0F);
            store.save(settings);
        } catch (...) {
            banner = "Settings could not be saved. Check available storage.";
        }
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
        if (connectionChanged)
            ++sourceGeneration;
        const std::string identity = computedSourceId(draft);
        if (draft.id.empty() || identity != draftIdentity)
            draft.id = identity;
        draftIdentity = identity;
        settings.source = draft;
        saveSettings();
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
                library[sourceScopedItemKey(item)] = item;
                if (i == 0 || i == 3)
                    settings.favoritesBySource[item.sourceId].insert(item.id);
            }
            catalogs[kind] = std::move(catalog);
            catalogLoaded.insert(kind);
        }
    }

    void startCatalogJob(const std::vector<MediaKind> &kinds, bool authenticateFirst) {
        if (preview || !settings.source || catalogJobRunning || kinds.empty())
            return;
        Source source = *settings.source;
        const HttpGet get = httpGet;
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
            std::launch::async, [get, source, requested, authenticateFirst, generation]() {
                CatalogJobResult result;
                result.sourceId = source.id.empty() ? brutv::sourceId(source) : source.id;
                result.sourceIdentity = computedSourceId(source);
                result.sourceGeneration = generation;
                try {
                    CatalogClient client(get);
                    if (authenticateFirst)
                        client.authenticate(source);
                    result.authenticated = true;
                    for (const auto kind : requested) {
                        try {
                            result.catalogs.emplace(kind, client.load(source, kind));
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
        if (result.authenticated)
            sourceAuthenticated = true;
        for (auto &[kind, catalog] : result.catalogs) {
            for (auto &item : catalog.items) {
                if (item.sourceId.empty() && settings.source)
                    item.sourceId = sourceId(*settings.source);
                library[sourceScopedItemKey(item)] = item;
            }
            catalogs[kind] = std::move(catalog);
            catalogLoaded.insert(kind);
            catalogFailed.erase(kind);
        }
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
        itemIndex = 0;
        categoryIndex = 0;
        ensureCatalogForTab();
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
        episodes.clear();
        if (episodesJobRunning) {
            pendingEpisodeSeries = series;
            return;
        }
        const Source source = *settings.source;
        const HttpGet get = httpGet;
        const std::string id = selectedSeriesId;
        const auto generation = sourceGeneration;
        episodesJobRunning = true;
        pendingEpisodeSeries.reset();
        episodesFuture = std::async(std::launch::async, [get, source, id, generation]() {
            EpisodeResult result;
            result.seriesId = id;
            result.sourceGeneration = generation;
            try {
                result.items = CatalogClient(get).loadEpisodes(source, id);
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
            library[sourceScopedItemKey(item)] = item;
        }
    }

    void startEpg(const MediaItem &item) {
        epgEntries.clear();
        if (preview || !settings.source || settings.source->type != SourceType::Xtream ||
            item.kind != MediaKind::Live)
            return;
        const Source source = *settings.source;
        const HttpGet get = httpGet;
        const std::string stream = item.providerId.empty() ? item.id : item.providerId;
        if (epgJobRunning)
            return;
        const std::string itemId = sourceScopedItemKey(item);
        const auto generation = sourceGeneration;
        epgJobRunning = true;
        epgFuture = std::async(std::launch::async, [get, source, stream, itemId, generation]() {
            EpgResult result;
            result.itemId = itemId;
            result.sourceGeneration = generation;
            try {
                result.entries = CatalogClient(get).loadEpg(source, stream);
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
        }
        epgJobRunning = false;
        if (result.sourceGeneration != sourceGeneration) {
            if (playingItem && playingLive)
                startEpg(*playingItem);
            return;
        }
        if (result.ok && playingItem && result.itemId == sourceScopedItemKey(*playingItem)) {
            epgEntries = std::move(result.entries);
        } else if (playingItem && playingLive) {
            startEpg(*playingItem);
        }
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
        ensureCatalogForTab();
    }

    std::vector<std::string> categoryNames() const {
        std::vector<std::string> names{"All"};
        if (tab == Tab::Favorites) {
            names = {"All favorites", "Recently played", "Live TV", "Movies", "Series"};
            return names;
        }
        const auto kind = kindForTab(tab);
        auto found = catalogs.find(kind);
        if (found != catalogs.end()) {
            for (const auto &category : found->second.categories) {
                if (category.kind == kind && !category.name.empty() &&
                    std::find(names.begin(), names.end(), category.name) == names.end())
                    names.push_back(category.name);
            }
        }
        if (names.size() == 1) {
            for (const auto &[key, item] : library) {
                (void)key;
                if (item.kind == kind && !item.categoryName.empty() &&
                    std::find(names.begin(), names.end(), item.categoryName) == names.end())
                    names.push_back(item.categoryName);
            }
        }
        return names;
    }

    std::vector<MediaItem> visibleItems() const {
        std::vector<MediaItem> result;
        const auto source = currentSource();
        const auto favoritesIt =
            settings.favoritesBySource.find(source.id.empty() ? sourceId(source) : source.id);
        const std::set<std::string> *favorites =
            favoritesIt == settings.favoritesBySource.end() ? nullptr : &favoritesIt->second;
        const auto categories = categoryNames();
        const std::string selectedCategory =
            categories.empty() ? "All"
                               : categories[static_cast<std::size_t>(std::clamp(
                                     categoryIndex, 0, static_cast<int>(categories.size()) - 1))];
        const std::string query = lower(searchQuery);
        std::set<std::string> seen;
        for (const auto &[key, item] : library) {
            (void)key;
            const std::string itemId = item.id;
            if (!source.id.empty() && item.sourceId != source.id)
                continue;
            if (source.id.empty() && !item.sourceId.empty() && item.sourceId != sourceId(source))
                continue;
            bool kindMatches = false;
            if (tab == Tab::Live)
                kindMatches = item.kind == MediaKind::Live;
            else if (tab == Tab::Movies)
                kindMatches = item.kind == MediaKind::Movie;
            else if (tab == Tab::Series)
                kindMatches = item.kind == MediaKind::Series;
            else if (tab == Tab::Favorites) {
                if (selectedCategory == "Recently played") {
                    const auto recent = settings.recentsBySource.find(
                        source.id.empty() ? sourceId(source) : source.id);
                    kindMatches = recent != settings.recentsBySource.end() &&
                                  std::any_of(recent->second.begin(), recent->second.end(),
                                              [&itemId](const MediaItem &played) {
                                                  return played.id == itemId;
                                              });
                } else {
                    kindMatches = favorites && favorites->count(item.id) != 0;
                }
            }
            if (!kindMatches)
                continue;
            if (tab == Tab::Favorites && selectedCategory != "All favorites") {
                if (selectedCategory == "Recently played") {
                    const auto recent = settings.recentsBySource.find(
                        source.id.empty() ? sourceId(source) : source.id);
                    const bool isRecent = recent != settings.recentsBySource.end() &&
                                          std::any_of(recent->second.begin(), recent->second.end(),
                                                      [&itemId](const MediaItem &played) {
                                                          return played.id == itemId;
                                                      });
                    if (!isRecent)
                        continue;
                }
                if (selectedCategory == "Live TV" && item.kind != MediaKind::Live)
                    continue;
                if (selectedCategory == "Movies" && item.kind != MediaKind::Movie)
                    continue;
                if (selectedCategory == "Series" && item.kind != MediaKind::Series)
                    continue;
            } else if (tab != Tab::Favorites && selectedCategory != "All" &&
                       item.categoryName != selectedCategory) {
                continue;
            }
            if (!query.empty()) {
                const std::string haystack =
                    lower(item.title + " " + item.categoryName + " " + item.description);
                if (haystack.find(query) == std::string::npos)
                    continue;
            }
            const std::string scoped = sourceScopedItemKey(item);
            if (seen.insert(scoped).second)
                result.push_back(item);
        }
        std::stable_sort(result.begin(), result.end(), [](const MediaItem &a, const MediaItem &b) {
            return lower(a.title) < lower(b.title);
        });
        return result;
    }

    void clampItemSelection() {
        if (episodesOpen)
            return;
        const auto items = visibleItems();
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
        saveSettings();
        clampItemSelection();
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
        saveSettings();
        clampItemSelection();
    }

    bool isFavorite(const MediaItem &item) const {
        const auto found = settings.favoritesBySource.find(item.sourceId);
        return found != settings.favoritesBySource.end() && found->second.count(item.id) != 0;
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
        playingItem = item;
        playbackTitle = item.title;
        playbackSubtitle = item.categoryName;
        playingLive = item.kind == MediaKind::Live;
        beginPlayback(item.mediaUrl, playingLive, item.requestHeaders);
        addRecent(item);
        if (playingLive)
            startEpg(item);
    }

    void beginPlayback(const std::string &url, bool live,
                       const std::unordered_map<std::string, std::string> &requestHeaders = {}) {
        if (preview) {
            banner = "Preview only. Playback is disabled.";
            return;
        }
        if (url.empty()) {
            banner = "No stream URL was provided.";
            return;
        }
        player->open(url, live, requestHeaders);
        playerScreen = true;
        player->setVolume(settings.volume);
        playerStatus = player->status();
        hasVideoFrame = false;
        showPlayerHud = true;
        banner.clear();
    }

    void startSelectedPlayback() {
        if (episodesOpen) {
            if (episodes.empty() || episodeIndex < 0 ||
                episodeIndex >= static_cast<int>(episodes.size()))
                return;
            launchItem(episodes[static_cast<std::size_t>(episodeIndex)]);
            return;
        }
        const auto items = visibleItems();
        if (items.empty() || itemIndex < 0 || itemIndex >= static_cast<int>(items.size()))
            return;
        launchItem(items[static_cast<std::size_t>(itemIndex)]);
    }

    void toggleSelectedFavorite() {
        if (episodesOpen) {
            if (episodeIndex >= 0 && episodeIndex < static_cast<int>(episodes.size()))
                toggleFavorite(episodes[static_cast<std::size_t>(episodeIndex)]);
            return;
        }
        const auto items = visibleItems();
        if (itemIndex >= 0 && itemIndex < static_cast<int>(items.size()))
            toggleFavorite(items[static_cast<std::size_t>(itemIndex)]);
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
        sourceAuthenticated = false;
        catalogLoaded.clear();
        catalogs.clear();
        catalogFailed.clear();
        library.clear();
        episodes.clear();
        episodesOpen = false;
        pendingEpisodeSeries.reset();
        selectedSeriesId.clear();
        player->stop();
        playerScreen = false;
        playingItem.reset();
        epgEntries.clear();
        saveSettings();
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
            for (auto it = library.begin(); it != library.end();) {
                if (it->second.sourceId == removedSourceId)
                    it = library.erase(it);
                else
                    ++it;
            }
        }
        settings.source.reset();
        draft = Source{};
        draft.name = "My TV";
        draftIdentity = computedSourceId(draft);
        catalogLoaded.clear();
        catalogs.clear();
        catalogFailed.clear();
        sourceAuthenticated = false;
        player->stop();
        playerScreen = false;
        playingItem.reset();
        epgEntries.clear();
        episodes.clear();
        episodesOpen = false;
        pendingEpisodeSeries.reset();
        selectedSeriesId.clear();
        saveSettings();
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
        if (key == Key::Left)
            keyboardColumn = std::max(0, keyboardColumn - 1);
        if (key == Key::Right)
            keyboardColumn = std::min(keyboardRowLength(keyboardRow) - 1, keyboardColumn + 1);
        if (key == Key::Up)
            keyboardRow = std::max(0, keyboardRow - 1);
        if (key == Key::Down)
            keyboardRow = std::min(rows - 1, keyboardRow + 1);
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
            if (field != EditField::None && field != EditField::Password) {
                std::string value = fieldValue(field);
                value += text;
                setFieldValue(field, std::move(value));
            } else if (field == EditField::Password) {
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
            searchQuery.pop_back();
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
        saveSettings();
    }

    void handleSettingsKey(Key key) {
        constexpr int lastRow = 8;
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
            }
        }
    }

    void moveCategory(int delta) {
        const auto categories = categoryNames();
        if (categories.empty())
            return;
        categoryIndex =
            std::clamp(categoryIndex + delta, 0, static_cast<int>(categories.size()) - 1);
        itemIndex = 0;
    }

    void moveItem(int delta) {
        if (episodesOpen) {
            if (episodes.empty())
                return;
            episodeIndex =
                std::clamp(episodeIndex + delta, 0, static_cast<int>(episodes.size()) - 1);
            return;
        }
        const auto items = visibleItems();
        if (items.empty())
            return;
        itemIndex = std::clamp(itemIndex + delta, 0, static_cast<int>(items.size()) - 1);
    }

    void handleContentKey(Key key) {
        if (focus == Focus::Sidebar) {
            if (key == Key::Up) {
                setTab(tabAt(indexOf(tab) - 1));
            } else if (key == Key::Down) {
                setTab(tabAt(indexOf(tab) + 1));
            } else if (key == Key::Right) {
                focus = tab == Tab::Settings ? Focus::Settings : Focus::Categories;
            } else if (key == Key::Confirm) {
                focus = tab == Tab::Settings ? Focus::Settings : Focus::Categories;
            }
        } else if (focus == Focus::Categories) {
            if (key == Key::Up)
                moveCategory(-1);
            else if (key == Key::Down)
                moveCategory(1);
            else if (key == Key::Left)
                focus = Focus::Sidebar;
            else if (key == Key::Right || key == Key::Confirm)
                focus = Focus::Items;
        } else if (focus == Focus::Items) {
            if (episodesOpen) {
                if (key == Key::Up)
                    moveItem(-1);
                else if (key == Key::Down)
                    moveItem(1);
                else if (key == Key::Confirm)
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
            player->stop();
            playerStatus = player->status();
            playingItem.reset();
            playingLive = true;
            playerScreen = false;
            showPlayerHud = false;
        } else if (key == Key::Confirm) {
            player->togglePause();
            showPlayerHud = true;
        } else if (key == Key::Rewind) {
            player->seekRelative(-10.0);
            showPlayerHud = true;
        } else if (key == Key::Forward) {
            player->seekRelative(playingLive ? 10.0 : 30.0);
            showPlayerHud = true;
        } else if (key == Key::PreviousTab) {
            player->cycleAudioTrack();
            showPlayerHud = true;
        } else if (key == Key::NextTab) {
            player->cycleSubtitleTrack();
            showPlayerHud = true;
        } else if (key == Key::Search && playingLive) {
            player->goLive();
            showPlayerHud = true;
        } else if (key == Key::Up) {
            changeVolume(0.05F);
            showPlayerHud = true;
        } else if (key == Key::Down) {
            changeVolume(-0.05F);
            showPlayerHud = true;
        } else if (key == Key::Favorite && playingItem) {
            toggleFavorite(*playingItem);
            showPlayerHud = true;
        } else if (key == Key::Options) {
            showPlayerHud = !showPlayerHud;
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
                } else if (key == Key::Backspace) {
                    backspaceCurrent();
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
                    banner.clear();
                } else if (focus == Focus::Items) {
                    focus = Focus::Categories;
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
        pollCatalog();
        pollEpisodes();
        pollEpg();
        ensureCatalogForTab();
        if (player) {
            playerStatus = player->status();
            VideoFrame frame;
            if (player->takeFrame(frame) && frame.width > 0 && frame.height > 0 &&
                !frame.rgba.empty()) {
                gfx.video(frame.rgba.data(), frame.width, frame.height);
                hasVideoFrame = true;
            }
        }
    }

    void drawArtwork(const MediaItem &item, float x, float y, float width, float height,
                     bool poster = false) {
        gfx.rect(x, y, width, height, rgb(9, 18, 31), 10);
        if (const auto image = artwork.request(item.logoUrl)) {
            const float inset = poster ? 0.0F : 9.0F;
            gfx.image(item.logoUrl, image->rgba.data(), image->width, image->height, x + inset,
                      y + inset, width - inset * 2, height - inset * 2, poster, 8);
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
            const std::array<HintButton, 5> buttons{{{"X ", Button::Cross},
                                                     {"O ", Button::Circle},
                                                     {"SQUARE ", Button::Square},
                                                     {"TRIANGLE ", Button::Triangle},
                                                     {"OPTIONS ", Button::Options}}};
            bool drawn = false;
            for (const auto &button : buttons) {
                const std::string prefix(button.prefix);
                if (segment.rfind(prefix, 0) == 0) {
                    x += controlHint(button.button, segment.substr(prefix.size()), x, 998) + 30;
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
                x += 70 + gfx.textWidth(label, 19);
            } else {
                gfx.text(segment, x, 1001, 19, kMuted, 1845 - x);
                x += gfx.textWidth(segment, 19) + 30;
            }
        }
    }

    void renderCategories() {
        gfx.text(tab == Tab::Favorites ? "FILTER" : "CATEGORIES", 344, 168, 17, kMuted, 210);
        const auto names = categoryNames();
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
            gfx.text("EPISODES", contentX, 169, 17, kMuted, 230);
            if (episodesJobRunning) {
                gfx.text("Loading episodes...", contentX, 227, 25, kText, 600);
            } else if (episodes.empty()) {
                gfx.text(banner.empty() ? "No episodes available." : banner, contentX, 227, 20,
                         kMuted, 1050);
            } else {
                const int visible = 8;
                const int start = episodeIndex >= visible ? episodeIndex - visible + 1 : 0;
                for (int i = start; i < static_cast<int>(episodes.size()) && i < start + visible;
                     ++i) {
                    const float y = 214.0F + static_cast<float>(i - start) * 78.0F;
                    const bool selected = i == episodeIndex;
                    gfx.rect(contentX, y, 1204, 66, selected ? kPanelSelected : kPanelRaised, 12);
                    const auto &episode = episodes[static_cast<std::size_t>(i)];
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
                    if (episode.episodeDetails && !episode.episodeDetails->plot.empty())
                        gfx.text(shortened(episode.episodeDetails->plot, 112), contentX + 215,
                                 y + 37, 18, kMuted, 950);
                }
            }
            renderFooter("X Play episode | SQUARE Favorite | D-pad Browse | O Back");
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

        const auto items = visibleItems();
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
            const auto &item = items[static_cast<std::size_t>(index)];
            const bool selected = itemIndex == index;
            if (selected && focus == Focus::Items)
                gfx.rect(x - 3, y - 3, cardWidth + 6, cardHeight + 6, kCyan, 18);
            gfx.rect(x, y, cardWidth, cardHeight,
                     selected && focus == Focus::Items ? kPanelSelected : kPanelRaised, 15);
            const bool live = item.kind == MediaKind::Live;
            drawArtwork(item, x + 15, y + 16, live ? 122 : 104, 144, !live);
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

        const auto &selected = items[static_cast<std::size_t>(itemIndex)];
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
        gfx.text(meta, contentX + 138, detailsY + 51, 19, kCyan, 900);
        wrappedText(
            gfx, selected.description.empty() ? "Select to open this item." : selected.description,
            contentX + 138, detailsY + 83, 18, kMuted, 1008, 1);
        const std::string pageInfo =
            std::to_string(itemIndex + 1) + " / " + std::to_string(items.size());
        gfx.text(pageInfo, contentX + 1084, detailsY + 17, 13, kMuted, 92);
        renderFooter(
            "X Play / open | SQUARE Favorite | TRIANGLE Search | D-pad Browse | OPTIONS Settings");
    }

    void renderSettings() {
        gfx.text("SOURCE & PLAYBACK", 350, 174, 13, kMuted, 300);
        gfx.text("Connect a service you are authorized to use", 350, 205, 27, kText, 1000);
        gfx.text("Credentials stay in this device's protected settings file. BruTV does not "
                 "provide channels or subscriptions.",
                 350, 244, 20, kMuted, 1130);
        const std::array<std::string, 9> labels{"Source type",
                                                "Source name",
                                                draft.type == SourceType::M3U ? "Playlist URL"
                                                                              : "Server URL",
                                                "Username",
                                                "Password",
                                                "BruTV join link",
                                                "Volume",
                                                "Connect / save source",
                                                "Clear saved source"};
        const std::array<std::string, 9> values{
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
                : (settings.source ? "Remove saved source from this device" : "No saved source")};
        for (int i = 0; i < 9; ++i) {
            const float y = 296.0F + static_cast<float>(i) * 67.0F;
            const bool selected = settingIndex == i && focus == Focus::Settings;
            gfx.rect(347, y, 1136, 56, selected ? kPanelSelected : kPanelRaised, 11);
            gfx.text(labels[static_cast<std::size_t>(i)], 367, y + 15, 18,
                     selected ? kText : kMuted, 252);
            const std::string shownValue =
                i == 4 && !draft.password.empty()
                    ? maskString(std::min<std::size_t>(draft.password.size(), 22))
                    : values[static_cast<std::size_t>(i)];
            gfx.text(shortened(shownValue, i == 2 || i == 5 ? 72 : 54), 632, y + 14, 18,
                     i == 7 ? kCyan : (i == 8 ? kRed : kText), 820);
            if (selected)
                gfx.rect(1464, y + 12, 3, 32, kCyan, 2);
        }
        if (banner.empty()) {
            gfx.text("Select a field, then press Cross to open its keyboard. Left / right adjusts "
                     "type or volume.",
                     350, 919, 17, kMuted, 1100);
        } else {
            gfx.text(shortened(banner, 128), 350, 919, 18,
                     banner.find("Could not") != std::string::npos || banner.find("Enter ") == 0
                         ? kRed
                         : kCyan,
                     1100);
        }
        renderFooter(
            "X Edit / connect | TRIANGLE Search | LEFT / RIGHT Type or volume | OPTIONS Return");
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
        if (playerStatus.durationSeconds > 0.0 && !playingLive) {
            const float progress = static_cast<float>(
                std::clamp(playerStatus.currentSeconds / playerStatus.durationSeconds, 0.0, 1.0));
            gfx.rect(79, 876, 1760, 5, rgb(65, 83, 99), 3);
            gfx.rect(79, 876, 1760.0F * progress, 5, kCyan, 3);
            gfx.text(formatTime(playerStatus.currentSeconds) + "  /  " +
                         formatTime(playerStatus.durationSeconds),
                     80, 897, 18, kMuted, 300);
        } else if (playingLive && playerStatus.liveRewind) {
            const double window = playerStatus.windowEndSeconds - playerStatus.windowStartSeconds;
            const float progress = static_cast<float>(window > 0 ? std::clamp(
                (playerStatus.currentSeconds - playerStatus.windowStartSeconds) / window, 0.0, 1.0) : 1.0);
            gfx.rect(79, 876, 1760, 5, rgb(65, 83, 99), 3);
            gfx.rect(79, 876, 1760.0F * progress, 5, kCyan, 3);
            const double behind = std::max(0.0, playerStatus.windowEndSeconds - playerStatus.currentSeconds);
            gfx.text(formatTime(window) + " saved | " + formatTime(behind) + " behind live | " +
                std::to_string(playerStatus.recordedBytes / 1024 / 1024) + " MiB", 80, 897, 18, kMuted, 900);
            controlHint(Button::Triangle, "Go live", 1430, 897);
        } else if (playingLive && !epgEntries.empty()) {
            const auto now = static_cast<std::int64_t>(std::time(nullptr));
            auto current =
                std::find_if(epgEntries.begin(), epgEntries.end(), [now](const EpgEntry &entry) {
                    return entry.startEpochSeconds <= now && entry.endEpochSeconds > now;
                });
            if (current == epgEntries.end())
                current = epgEntries.begin();
            gfx.text("NOW", 80, 875, 17, kCyan, 80);
            gfx.text(shortened(current->title, 65), 80, 898, 22, kText, 670);
            if (!current->description.empty())
                gfx.text(shortened(current->description, 110), 80, 930, 18, kMuted, 1030);
        } else if (playingLive && epgJobRunning) {
            gfx.text("Loading guide...", 80, 884, 18, kMuted, 300);
        }
        controlHint(Button::Options, "HUD", 80, 974);
        controlHint(Button::Cross, playerStatus.state == Player::State::Paused ? "Resume" : "Pause",
                    260, 974);
        const Color seekColor = playingLive && !playerStatus.liveRewind ? rgb(84, 101, 116) : kMuted;
        gfx.button(Button::L2, 570, 974, 29, seekColor);
        gfx.button(Button::R2, 611, 974, 29, seekColor);
        gfx.text("Seek", 658, 977, 19, seekColor, 120);
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
        const std::string message = !playerStatus.rewindMessage.empty()
            ? playerStatus.rewindMessage : playerStatus.message;
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
        gfx.icon(Icon::Dpad, 382, 859, 29, kMuted);
        gfx.text("Move", 423, 863, 19, kMuted);
        controlHint(Button::Cross, "Select", 555, 859);
        controlHint(Button::Circle, "Cancel", 750, 859);
        gfx.text("You can also type with a connected keyboard", 974, 864, 17, kMuted, 560);
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
