import React, {lazy, memo, Suspense, useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {ActivityIndicator, Animated, BackHandler, FlatList, Image, StyleSheet, Text, TextInput, TouchableOpacity, View} from 'react-native';
import {TVFocusGuideView} from '@amazon-devices/react-native-kepler';
import {
  Catalog,
  ContentItem,
  loadCatalog,
  loadCatalogSection,
  loadEpisodes,
  loadShortEPG,
  Section,
  ShortEPG,
  withCatalogSection,
} from './domain/catalog';
import {isUnsupportedPlaybackURL, LoginSource, normalizePlaybackURL, parseLogin} from './domain/login';
import {TVButton} from './TVButton';
import {
  clearResumePosition,
  emptyPreferences,
  getResumePosition,
  libraryKey,
  LibrarySelection,
  updateLibrary,
  updateResumePosition,
} from './domain/preferences';
import {
  clearSavedSource,
  loadCachedSection,
  loadPreferences,
  loadSavedSource,
  saveCachedSection,
  savePreferences,
  saveSavedSource,
} from './PreferencesStore';
import {formatPlaybackTime} from './media/playerCopy';

const LazyPlayerScreen = lazy(() => import('./media/PlayerScreen').then(mod => ({default: mod.PlayerScreen})));

type AppErrorKey =
  | 'loadCatalog'
  | 'loadSection'
  | 'invalidSignIn'
  | 'loadEpisodes'
  | 'invalidPlaybackUrl'
  | 'unsupportedFormat';

const ERROR_MESSAGES: Record<AppErrorKey, {pt: string; en: string}> = {
  loadCatalog: {
    pt: 'Não foi possível carregar o provedor. Verifique os dados e tente novamente.',
    en: 'Could not load the provider. Check the address and account, then try again.',
  },
  loadSection: {
    pt: 'Não foi possível carregar esta seção no provedor.',
    en: 'Could not load this section from the provider.',
  },
  invalidSignIn: {
    pt: 'Digite um endereço de servidor HTTP, uma URL M3U ou um link do BruTV.',
    en: 'Enter an HTTP provider address and account, an M3U URL, or a BruTV sign-in link.',
  },
  loadEpisodes: {
    pt: 'O provedor não pôde carregar os episódios.',
    en: 'The provider could not load the episodes.',
  },
  invalidPlaybackUrl: {
    pt: 'O provedor forneceu um endereço de reprodução inválido.',
    en: 'The provider supplied an invalid playback address.',
  },
  unsupportedFormat: {
    pt: 'O BruTV no Vega reproduz HLS, DASH e MP4. Escolha uma fonte compatível no provedor.',
    en: 'BruTV on Vega plays HLS, DASH, and MP4. Choose a supported source from your provider.',
  },
};

const CATEGORY_ROW_HEIGHT = 54;
const CONTENT_ROW_HEIGHT = 204;
const SEARCH_DEBOUNCE_MS = 180;
const EPG_CACHE_TTL_MS = 60_000;
const MAX_EPG_CACHE_ENTRIES = 64;

interface CategoryEntry {
  label: string;
  value: string | undefined;
  count: number;
}

const CategoryTVButton = memo(function CategoryTVButton({
  label,
  value,
  count,
  selected = false,
  onSelect,
}: {
  label: string;
  value: string | undefined;
  count: number;
  selected?: boolean;
  onSelect: (value: string | undefined) => void;
}) {
  const [focused, setFocused] = useState(false);
  const handlePress = useCallback(() => onSelect(value), [onSelect, value]);
  const handleFocus = useCallback(() => setFocused(true), []);
  const handleBlur = useCallback(() => setFocused(false), []);

  return (
    <TouchableOpacity
      accessibilityRole="button"
      accessibilityLabel={`${label}, ${count} items`}
      onFocus={handleFocus}
      onBlur={handleBlur}
      onPress={handlePress}
      activeOpacity={1}
      style={[
        styles.catButton,
        selected && styles.catSelected,
        focused && styles.catFocused,
      ]}
    >
      <View style={[styles.catIndicator, selected && styles.catIndicatorActive]} />
      <Text numberOfLines={1} style={[styles.catLabel, selected && styles.catLabelSelected]}>
        {label}
      </Text>
      {count > 0 && (
        <View style={[styles.catBadge, selected && styles.catBadgeSelected]}>
          <Text style={[styles.catBadgeText, selected && styles.catBadgeTextSelected]}>{count}</Text>
        </View>
      )}
    </TouchableOpacity>
  );
});

const ContentTVButton = memo(function ContentTVButton({
  item,
  onPressItem,
  onLongPressItem,
}: {
  item: ContentItem;
  onPressItem: (item: ContentItem) => void;
  onLongPressItem: (item: ContentItem) => void;
}) {
  const [focused, setFocused] = useState(false);
  const [imageFailed, setImageFailed] = useState(false);

  useEffect(() => {
    setImageFailed(false);
  }, [item.logo]);

  const handlePress = useCallback(() => onPressItem(item), [onPressItem, item]);
  const handleLongPress = useCallback(() => onLongPressItem(item), [onLongPressItem, item]);
  const handleFocus = useCallback(() => setFocused(true), []);
  const handleBlur = useCallback(() => setFocused(false), []);
  const handleImageError = useCallback(() => setImageFailed(true), []);

  return (
    <TouchableOpacity
      accessibilityRole="button"
      accessibilityLabel={item.group ? `${item.name}, ${item.group}` : item.name}
      onFocus={handleFocus}
      onBlur={handleBlur}
      onPress={handlePress}
      onLongPress={handleLongPress}
      activeOpacity={1}
      style={[styles.contentCard, focused && styles.contentCardFocused]}
    >
      {item.logo && !imageFailed
        ? <Image source={{uri: item.logo}} style={styles.contentArtwork} resizeMode="cover" fadeDuration={0} onError={handleImageError} />
        : <View style={styles.contentArtworkFallback}><Text style={styles.contentArtworkIcon}>▶</Text></View>}
      <Text numberOfLines={2} style={styles.contentTitle}>{item.name}</Text>
      {!!item.group && <Text numberOfLines={1} style={styles.contentGroup}>{item.group}</Text>}
    </TouchableOpacity>
  );
});

export default function App() {
  const [showSplash, setShowSplash] = useState(true);
  const splashOpacity = useRef(new Animated.Value(1)).current;

  const [preferences, setPreferences] = useState(emptyPreferences);
  const lastSavedPreferences = useRef(preferences);
  const [preferencesReady, setPreferencesReady] = useState(false);
  const [savedSourceChecked, setSavedSourceChecked] = useState(false);
  const [rememberSignIn, setRememberSignIn] = useState(false);
  const [storageError, setStorageError] = useState(false);
  const language = preferences.language;
  const [source, setSource] = useState<LoginSource>();
  const [catalog, setCatalog] = useState<Catalog>();
  const [input, setInput] = useState('');
  const [server, setServer] = useState('');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [section, setSection] = useState<Section>('live');
  const [query, setQuery] = useState('');
  const [debouncedQuery, setDebouncedQuery] = useState('');
  const [group, setGroup] = useState<string>();
  const [filter, setFilter] = useState<'all' | 'favorites' | 'recent'>('all');
  const sourceKey = useMemo(() => (source ? libraryKey(source) : undefined), [source]);
  const savedLibrary = sourceKey ? preferences.libraries[sourceKey] : undefined;
  const favorites = useMemo(() => new Set(savedLibrary?.favorites), [savedLibrary]);
  const recent = savedLibrary?.recent || [];
  const [episodes, setEpisodes] = useState<ContentItem[]>();
  const [selected, setSelected] = useState<ContentItem>();
  const [player, setPlayer] = useState<ContentItem>();
  const [playerStartPosition, setPlayerStartPosition] = useState<number>();
  const [loading, setLoading] = useState(false);
  const [errorKey, setErrorKey] = useState<AppErrorKey>();
  const [activeEpg, setActiveEpg] = useState<ShortEPG>();

  const requestController = useRef<AbortController>();
  const sectionController = useRef<AbortController>();
  const epgCacheRef = useRef(new Map<string, {epg: ShortEPG; fetchedAt: number}>());
  const contentListRef = useRef<FlatList<ContentItem>>(null);
  const initialBrowseFocusedRef = useRef(false);

  const isPt = language === 'pt';
  const error = errorKey ? ERROR_MESSAGES[errorKey][isPt ? 'pt' : 'en'] : '';

  // Dismiss splash as soon as preferences and optional saved source finish loading (no artificial 1500ms wait).
  useEffect(() => {
    if (!preferencesReady || !savedSourceChecked) return;
    Animated.timing(splashOpacity, {toValue: 0, duration: 160, useNativeDriver: true}).start(() => {
      setShowSplash(false);
    });
  }, [preferencesReady, savedSourceChecked, splashOpacity]);

  useEffect(() => {
    let active = true;
    void loadPreferences()
      .then(value => { if (active) { lastSavedPreferences.current = value; setPreferences(value); } })
      .catch(() => { if (active) setStorageError(true); })
      .finally(() => { if (active) setPreferencesReady(true); });
    void loadSavedSource()
      .then(saved => {
        if (active && saved) {
          setRememberSignIn(true);
          setSource(saved);
        }
      })
      .finally(() => { if (active) setSavedSourceChecked(true); });
    return () => { active = false; };
  }, []);

  useEffect(() => {
    if (!preferencesReady || lastSavedPreferences.current === preferences) return;
    lastSavedPreferences.current = preferences;
    void savePreferences(preferences).catch(() => setStorageError(true));
  }, [preferences, preferencesReady]);

  useEffect(() => {
    const timer = setTimeout(() => setDebouncedQuery(query), SEARCH_DEBOUNCE_MS);
    return () => clearTimeout(timer);
  }, [query]);

  const saveLibrary = useCallback((update: (selection: LibrarySelection) => LibrarySelection) => {
    if (sourceKey) setPreferences(previous => updateLibrary(previous, sourceKey, update));
  }, [sourceKey]);

  // Load initial catalog (Live first for Xtream, stale-while-revalidate from /data cache).
  useEffect(() => {
    if (!source) return;
    const controller = new AbortController();
    requestController.current = controller;
    setLoading(true);
    setErrorKey(undefined);
    let hydratedFromCache = false;
    const key = libraryKey(source);

    if (source.kind === 'xtream') {
      void loadCachedSection(source, key, 'live').then(cached => {
        if (controller.signal.aborted || !cached || !cached.result.items.length) return;
        hydratedFromCache = true;
        setCatalog(prev => prev ?? {
          sections: {live: cached.result.items, movie: [], series: []},
          categories: {live: cached.result.categories, movie: [], series: []},
          loadedSections: {live: true, movie: false, series: false},
          items: cached.result.items,
          seriesSource: source,
          liveExtension: cached.liveExtension,
        });
      });
    }

    void loadCatalog(source, controller.signal).then(value => {
      if (controller.signal.aborted) return;
      setCatalog(prev => {
        if (!prev || source.kind !== 'xtream') return value;
        return {
          ...value,
          sections: {
            live: value.sections.live,
            movie: prev.loadedSections.movie ? prev.sections.movie : [],
            series: prev.loadedSections.series ? prev.sections.series : [],
          },
          categories: {
            live: value.categories.live,
            movie: prev.loadedSections.movie ? prev.categories.movie : [],
            series: prev.loadedSections.series ? prev.categories.series : [],
          },
          loadedSections: {
            live: true,
            movie: prev.loadedSections.movie,
            series: prev.loadedSections.series,
          },
        };
      });
      setPassword('');
      setInput('');
      if (source.kind === 'xtream') {
        void saveCachedSection(key, 'live', {items: value.sections.live, categories: value.categories.live}, value.liveExtension);
      }
      if (rememberSignIn) {
        void saveSavedSource(source).catch(() => {});
      }
    }).catch(() => {
      if (!controller.signal.aborted && !hydratedFromCache) {
        setErrorKey('loadCatalog');
      }
    }).finally(() => {
      if (!controller.signal.aborted) setLoading(false);
    });

    return () => controller.abort();
  }, [source, rememberSignIn]);

  // Lazily load Movie / Series section when user switches tabs (with stale-while-revalidate cache).
  useEffect(() => {
    if (!catalog || !catalog.seriesSource || catalog.loadedSections[section] || episodes) return;
    sectionController.current?.abort();
    const controller = new AbortController();
    sectionController.current = controller;
    const activeSource = catalog.seriesSource;
    const key = libraryKey(activeSource);
    let hydratedFromCache = false;
    setLoading(true);
    setErrorKey(undefined);

    void loadCachedSection(activeSource, key, section).then(cached => {
      if (controller.signal.aborted || !cached || !cached.result.items.length) return;
      hydratedFromCache = true;
      setCatalog(prev => (prev && !prev.loadedSections[section] ? withCatalogSection(prev, section, cached.result) : prev));
    });

    void loadCatalogSection(catalog, section, controller.signal).then(updated => {
      if (controller.signal.aborted) return;
      setCatalog(prev => (prev ? withCatalogSection(prev, section, {
        items: updated.sections[section],
        categories: updated.categories[section],
      }) : updated));
      void saveCachedSection(key, section, {
        items: updated.sections[section],
        categories: updated.categories[section],
      }, updated.liveExtension);
    }).catch(() => {
      if (!controller.signal.aborted && !hydratedFromCache) {
        setErrorKey('loadSection');
      }
    }).finally(() => {
      if (!controller.signal.aborted) setLoading(false);
    });

    return () => controller.abort();
  }, [catalog, section, episodes]);

  // Fetch on-demand Now/Next EPG for the active live channel (PlayerScreen or detail view).
  const epgTarget = player?.kind === 'live' ? player : (selected?.kind === 'live' ? selected : undefined);
  useEffect(() => {
    const xtreamSource = catalog?.seriesSource;
    const streamID = epgTarget?.streamID || (epgTarget?.id.startsWith('live:') ? epgTarget.id.slice(5) : undefined);
    if (!xtreamSource || !streamID) {
      setActiveEpg(undefined);
      return;
    }
    const cached = epgCacheRef.current.get(streamID);
    if (cached && Date.now() - cached.fetchedAt < EPG_CACHE_TTL_MS) {
      setActiveEpg(cached.epg);
      return;
    }
    const controller = new AbortController();
    setActiveEpg(undefined);
    void loadShortEPG(xtreamSource, streamID, controller.signal)
      .then(result => {
        if (controller.signal.aborted) return;
        const cache = epgCacheRef.current;
        cache.set(streamID, {epg: result, fetchedAt: Date.now()});
        if (cache.size > MAX_EPG_CACHE_ENTRIES) {
          const oldest = cache.keys().next();
          if (!oldest.done) cache.delete(oldest.value);
        }
        setActiveEpg(result);
      })
      .catch(() => {
        if (!controller.signal.aborted) setActiveEpg(undefined);
      });
    return () => controller.abort();
  }, [catalog?.seriesSource, epgTarget?.id, epgTarget?.streamID]);

  useEffect(() => {
    const subscription = BackHandler.addEventListener('hardwareBackPress', () => {
      if (player) return false;
      if (selected) { setSelected(undefined); return true; }
      if (episodes) { setEpisodes(undefined); setGroup(undefined); return true; }
      return false;
    });
    return () => subscription.remove();
  }, [selected, episodes, player]);

  // Reset main content scroll position to top on category/section/filter change.
  useEffect(() => {
    contentListRef.current?.scrollToOffset({offset: 0, animated: false});
  }, [section, group, filter, episodes]);

  const sectionItems = useMemo(() => {
    if (episodes) return episodes;
    return catalog?.sections[section] || [];
  }, [episodes, catalog, section]);

  // Pre-index lowercase search keys once per loaded section instead of per keystroke.
  const indexedSectionItems = useMemo(() => {
    const result: {item: ContentItem; lowerName: string}[] = new Array(sectionItems.length);
    for (let i = 0; i < sectionItems.length; i++) {
      const item = sectionItems[i];
      result[i] = {item, lowerName: item.name.toLowerCase()};
    }
    return result;
  }, [sectionItems]);

  const filtered = useMemo(() => {
    const term = debouncedQuery.trim().toLowerCase();
    const matched: ContentItem[] = [];
    for (let i = 0; i < indexedSectionItems.length; i++) {
      const entry = indexedSectionItems[i];
      if (group && entry.item.group !== group) continue;
      if (term && !entry.lowerName.includes(term)) continue;
      if (filter === 'favorites' && !favorites.has(entry.item.id)) continue;
      matched.push(entry.item);
    }
    if (filter !== 'recent') return matched;
    const byId = new Map<string, ContentItem>();
    for (let i = 0; i < matched.length; i++) byId.set(matched[i].id, matched[i]);
    const ordered: ContentItem[] = [];
    for (let i = 0; i < recent.length; i++) {
      const hit = byId.get(recent[i]);
      if (hit) ordered.push(hit);
    }
    return ordered;
  }, [indexedSectionItems, debouncedQuery, group, filter, favorites, recent]);

  // Preserve provider category order instead of re-sorting alphabetically.
  const categoryData = useMemo<CategoryEntry[]>(() => {
    const countMap = new Map<string, number>();
    const discoveredOrder: string[] = [];
    for (let i = 0; i < indexedSectionItems.length; i++) {
      const g = indexedSectionItems[i].item.group;
      if (g) {
        if (!countMap.has(g)) discoveredOrder.push(g);
        countMap.set(g, (countMap.get(g) || 0) + 1);
      }
    }

    const providerOrder = !episodes && catalog?.categories[section]?.length
      ? catalog.categories[section]
      : discoveredOrder;
    const orderedGroups: string[] = [];
    const seen = new Set<string>();
    for (let i = 0; i < providerOrder.length; i++) {
      const g = providerOrder[i];
      if (!seen.has(g) && countMap.has(g)) {
        seen.add(g);
        orderedGroups.push(g);
      }
    }
    for (let i = 0; i < discoveredOrder.length; i++) {
      const g = discoveredOrder[i];
      if (!seen.has(g)) {
        seen.add(g);
        orderedGroups.push(g);
      }
    }

    const allLabel = isPt
      ? (section === 'live' ? 'Todos os Canais' : section === 'movie' ? 'Todos os Filmes' : 'Todas as Séries')
      : (section === 'live' ? 'All Channels' : section === 'movie' ? 'All Movies' : 'All Series');

    const result: CategoryEntry[] = [{label: allLabel, value: undefined, count: indexedSectionItems.length}];
    for (let i = 0; i < orderedGroups.length; i++) {
      const g = orderedGroups[i];
      result.push({label: g, value: g, count: countMap.get(g) || 0});
    }
    return result;
  }, [indexedSectionItems, episodes, catalog, section, isPt]);

  const signIn = useCallback(() => {
    try {
      const next = input.trim()
        ? parseLogin(input)
        : parseLogin(`brutv://login?server=${encodeURIComponent(server)}&username=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}`);
      setErrorKey(undefined);
      setSource(next);
    } catch {
      setErrorKey('invalidSignIn');
    }
  }, [input, server, username, password]);

  const signOut = useCallback(() => {
    requestController.current?.abort();
    sectionController.current?.abort();
    epgCacheRef.current.clear();
    void clearSavedSource();
    setRememberSignIn(false);
    setSource(undefined);
    setCatalog(undefined);
    setEpisodes(undefined);
    setSelected(undefined);
    setPlayer(undefined);
    setPlayerStartPosition(undefined);
    setPassword('');
    setUsername('');
    setServer('');
    setInput('');
    setQuery('');
    setDebouncedQuery('');
    setGroup(undefined);
    setErrorKey(undefined);
    setLoading(false);
    initialBrowseFocusedRef.current = false;
  }, []);

  const cancelLoading = useCallback(() => {
    requestController.current?.abort();
    sectionController.current?.abort();
    setLoading(false);
    if (!catalog) {
      signOut();
    }
  }, [catalog, signOut]);

  const closePlayer = useCallback(() => {
    setPlayer(undefined);
    setPlayerStartPosition(undefined);
  }, []);

  const startPlayback = useCallback((item: ContentItem, overrideStartPosition?: number) => {
    if (!item.url) {
      setErrorKey('invalidPlaybackUrl');
      return;
    }
    let normalizedURL: string;
    try {
      normalizedURL = normalizePlaybackURL(item.url);
    } catch {
      setErrorKey('invalidPlaybackUrl');
      return;
    }
    if (isUnsupportedPlaybackURL(normalizedURL)) {
      setErrorKey('unsupportedFormat');
      return;
    }
    setErrorKey(undefined);
    saveLibrary(previous => ({...previous, recent: [item.id, ...previous.recent.filter(id => id !== item.id)].slice(0, 50)}));
    const savedPos = item.kind !== 'live' && sourceKey
      ? getResumePosition(preferences, sourceKey, item.id)?.position
      : undefined;
    setPlayerStartPosition(overrideStartPosition !== undefined ? overrideStartPosition : savedPos);
    setPlayer(normalizedURL === item.url ? item : {...item, url: normalizedURL});
  }, [preferences, saveLibrary, sourceKey]);

  const toggleFavorite = useCallback((item: ContentItem) => {
    saveLibrary(previous => ({
      ...previous,
      favorites: previous.favorites.includes(item.id)
        ? previous.favorites.filter(id => id !== item.id)
        : [...previous.favorites, item.id],
    }));
  }, [saveLibrary]);

  const handleVodProgress = useCallback((item: ContentItem, pos: number, dur: number) => {
    if (!sourceKey || item.kind === 'live') return;
    setPreferences(previous => updateResumePosition(previous, sourceKey, item.id, pos, dur));
  }, [sourceKey]);

  const handleVodEnded = useCallback((item: ContentItem) => {
    if (!sourceKey || item.kind === 'live') return;
    setPreferences(previous => clearResumePosition(previous, sourceKey, item.id));
  }, [sourceKey]);

  const handleMemoryWarning = useCallback(() => {
    epgCacheRef.current.clear();
  }, []);

  const openItem = useCallback(async (item: ContentItem) => {
    // Live TV channels zap directly on card press for instant TV UX.
    if (item.kind === 'live' && item.url) {
      startPlayback(item);
      return;
    }
    if (item.url) {
      setSelected(item);
      return;
    }
    if (!catalog?.seriesSource) return;
    requestController.current?.abort();
    const controller = new AbortController();
    requestController.current = controller;
    setLoading(true);
    setErrorKey(undefined);
    try {
      const value = await loadEpisodes(catalog.seriesSource, item.streamID || item.id.split(':')[1], controller.signal);
      if (!controller.signal.aborted) {
        setEpisodes(value);
        setGroup(undefined);
        setQuery('');
        setDebouncedQuery('');
      }
    } catch {
      if (!controller.signal.aborted) setErrorKey('loadEpisodes');
    } finally {
      if (!controller.signal.aborted) setLoading(false);
    }
  }, [catalog?.seriesSource, startPlayback]);

  const inspectItem = useCallback((item: ContentItem) => {
    if (item.url) {
      setSelected(item);
    } else {
      void openItem(item);
    }
  }, [openItem]);

  // Quick channel zapping inside PlayerScreen across the currently browsed Live channel list.
  const liveChannels = useMemo(() => {
    if (section === 'live' && !episodes) return filtered;
    return catalog?.sections.live || [];
  }, [section, episodes, filtered, catalog]);

  const handleSwitchChannel = useCallback((delta: 1 | -1) => {
    if (!player || player.kind !== 'live' || liveChannels.length < 2) return;
    const currentIndex = liveChannels.findIndex(ch => ch.id === player.id);
    const nextIndex = currentIndex < 0
      ? 0
      : (currentIndex + delta + liveChannels.length) % liveChannels.length;
    const next = liveChannels[nextIndex];
    if (next && next.url) {
      startPlayback(next, 0);
    }
  }, [player, liveChannels, startPlayback]);

  const handleSelectCategory = useCallback((value: string | undefined) => {
    setGroup(value);
    setSelected(undefined);
  }, []);

  const handlePressContentItem = useCallback((item: ContentItem) => {
    void openItem(item);
  }, [openItem]);

  const renderCategoryItem = useCallback(({item}: {item: CategoryEntry}) => (
    <CategoryTVButton
      label={item.label}
      value={item.value}
      count={item.count}
      selected={item.value === group}
      onSelect={handleSelectCategory}
    />
  ), [group, handleSelectCategory]);

  const renderContentItem = useCallback(({item}: {item: ContentItem}) => (
    <View style={styles.card}>
      <ContentTVButton
        item={item}
        onPressItem={handlePressContentItem}
        onLongPressItem={inspectItem}
      />
    </View>
  ), [handlePressContentItem, inspectItem]);

  const categoryKeyExtractor = useCallback((item: CategoryEntry) => (
    item.value === undefined ? 'all' : `group:${item.value}`
  ), []);

  const contentKeyExtractor = useCallback((item: ContentItem) => item.id, []);

  const getCategoryItemLayout = useCallback((_data: ArrayLike<CategoryEntry> | null | undefined, index: number) => ({
    length: CATEGORY_ROW_HEIGHT,
    offset: CATEGORY_ROW_HEIGHT * index,
    index,
  }), []);

  const getContentItemLayout = useCallback((_data: ArrayLike<ContentItem> | null | undefined, index: number) => {
    const row = Math.floor(index / 3);
    return {
      length: CONTENT_ROW_HEIGHT,
      offset: CONTENT_ROW_HEIGHT * row,
      index,
    };
  }, []);

  const selectedResume = selected && selected.kind !== 'live' && sourceKey
    ? getResumePosition(preferences, sourceKey, selected.id)
    : undefined;

  // Trigger hasTVPreferredFocus only once when entering browse, never yanking focus back on detail close.
  const shouldPreferLiveTab = !!catalog && !initialBrowseFocusedRef.current && !selected && !player;
  useEffect(() => {
    if (catalog && !initialBrowseFocusedRef.current) {
      initialBrowseFocusedRef.current = true;
    }
  }, [catalog]);

  return (
    <View style={styles.root}>
      <View
        style={styles.screen}
        pointerEvents={player ? 'none' : 'auto'}
        importantForAccessibility={player ? 'no-hide-descendants' : 'auto'}
      >
        {!showSplash && <>
          <View style={styles.header}>
            <Text style={styles.brand}>BruTV</Text>
            <Text style={styles.subtitle}>{isPt ? 'IPTV simples e direto ao ponto' : 'IPTV that just works'}</Text>
            <View style={styles.headerSpacer} />
            <TVButton
              label={isPt ? '🇧🇷 Português' : '🇺🇸 English'}
              onPress={() => {if (preferencesReady) setPreferences(previous => ({...previous, language: previous.language === 'pt' ? 'en' : 'pt'}));}}
            />
          </View>

          {!catalog ? (
            <View style={styles.form}>
              <Text style={styles.title}>{isPt ? 'Sua TV. Seu provedor.' : 'Your TV. Your provider.'}</Text>
              <Text style={styles.help}>
                {isPt ? 'Insira sua conta, ou cole uma URL M3U ou o link gerado pelo QR code.' : 'Enter your account, or paste an M3U URL or the sign-in link encoded in an iPhone QR code.'}
              </Text>
              <TextInput
                style={styles.input}
                value={input}
                onChangeText={setInput}
                placeholder={isPt ? 'URL M3U ou link brutv://login' : 'M3U URL or brutv://login link'}
                placeholderTextColor="#8c9bb0"
                autoCapitalize="none"
                accessibilityLabel="Playlist or BruTV sign-in link"
              />
              <TextInput
                style={styles.input}
                value={server}
                onChangeText={setServer}
                placeholder={isPt ? 'https://seu-provedor.exemplo' : 'https://your-provider.example'}
                placeholderTextColor="#8c9bb0"
                autoCapitalize="none"
                accessibilityLabel="Provider address"
              />
              <View style={styles.row}>
                <TextInput
                  style={[styles.input, styles.half]}
                  value={username}
                  onChangeText={setUsername}
                  placeholder={isPt ? 'Usuário' : 'Username'}
                  placeholderTextColor="#8c9bb0"
                  autoCapitalize="none"
                  accessibilityLabel="Username"
                />
                <TextInput
                  style={[styles.input, styles.half]}
                  value={password}
                  onChangeText={setPassword}
                  placeholder={isPt ? 'Senha' : 'Password'}
                  placeholderTextColor="#8c9bb0"
                  secureTextEntry
                  accessibilityLabel="Password"
                />
              </View>
              <Text style={styles.help}>
                {rememberSignIn
                  ? (isPt ? 'Sua conta será salva no armazenamento privado desta TV.' : 'Your sign-in will be saved in app-private storage on this TV.')
                  : (isPt ? 'Suas credenciais ficam apenas na memória deste dispositivo.' : 'Your sign-in stays in memory unless you opt in below.')}
              </Text>
              <TVFocusGuideView autoFocus style={styles.row}>
                {!loading && preferencesReady && <TVButton label={isPt ? 'Entrar' : 'Sign in'} preferred onPress={signIn}/>}
                <TVButton
                  label={rememberSignIn
                    ? (isPt ? '✓ Lembrar conta nesta TV' : '✓ Remember sign-in on this TV')
                    : (isPt ? 'Lembrar conta nesta TV' : 'Remember sign-in on this TV')}
                  selected={rememberSignIn}
                  onPress={() => {
                    setRememberSignIn(prev => {
                      const next = !prev;
                      if (!next) void clearSavedSource();
                      return next;
                    });
                  }}
                />
              </TVFocusGuideView>
            </View>
          ) : (
            <>
              <TVFocusGuideView autoFocus={!player} style={styles.row}>
                {(['live', 'movie', 'series'] as Section[]).map(value => (
                  <TVButton
                    key={value}
                    label={value === 'live' ? (isPt ? 'TV ao Vivo' : 'Live TV') : value === 'movie' ? (isPt ? 'Filmes' : 'Movies') : (isPt ? 'Séries' : 'Series')}
                    preferred={shouldPreferLiveTab && value === 'live'}
                    selected={section === value}
                    onPress={() => {
                      setSection(value);
                      setEpisodes(undefined);
                      setSelected(undefined);
                      setGroup(undefined);
                      setErrorKey(undefined);
                    }}
                  />
                ))}
                <TVButton label={isPt ? 'Sair' : 'Sign out'} onPress={signOut}/>
              </TVFocusGuideView>

              <TextInput
                style={styles.input}
                value={query}
                onChangeText={setQuery}
                placeholder={isPt ? 'Buscar no catálogo' : 'Search your library'}
                placeholderTextColor="#8c9bb0"
                accessibilityLabel="Search your library"
              />

              <TVFocusGuideView autoFocus={!player} style={styles.row}>
                {(['all', 'favorites', 'recent'] as const).map(value => (
                  <TVButton
                    key={value}
                    label={value === 'all' ? (isPt ? 'Todos' : 'All content') : value === 'favorites' ? (isPt ? 'Favoritos' : 'Favorites') : (isPt ? 'Assistidos recentemente' : 'Recently watched')}
                    selected={filter === value}
                    onPress={() => setFilter(value)}
                  />
                ))}
                {episodes && <TVButton label={isPt ? 'Voltar às séries' : 'Back to series'} onPress={() => { setEpisodes(undefined); setGroup(undefined); }}/>}
              </TVFocusGuideView>

              {/* Main Content Area with Left Category Column */}
              <View style={styles.contentContainer}>
                {/* Left Category Sidebar */}
                <TVFocusGuideView autoFocus={!player} style={styles.sidebar}>
                  <View style={styles.sidebarHeader}>
                    <Text style={styles.sidebarTitle}>{isPt ? 'CATEGORIAS' : 'CATEGORIES'}</Text>
                    <View style={styles.sidebarTotalBadge}>
                      <Text style={styles.sidebarTotalText}>{categoryData.length}</Text>
                    </View>
                  </View>
                  <FlatList
                    data={categoryData}
                    keyExtractor={categoryKeyExtractor}
                    getItemLayout={getCategoryItemLayout}
                    initialNumToRender={14}
                    maxToRenderPerBatch={14}
                    windowSize={7}
                    showsVerticalScrollIndicator={false}
                    renderItem={renderCategoryItem}
                  />
                </TVFocusGuideView>

                {/* Right Content / Detail Area */}
                <TVFocusGuideView autoFocus={!player} style={styles.mainArea}>
                  {selected ? (
                    <View style={styles.detail}>
                      <Text style={styles.title}>{selected.name}</Text>
                      <Text style={styles.help}>{selected.group}</Text>
                      {selected.kind === 'live' && (activeEpg?.now || activeEpg?.next) && (
                        <View style={styles.detailEpg}>
                          {activeEpg.now && (
                            <Text style={styles.detailEpgNow}>
                              {isPt ? 'Agora: ' : 'Now: '}{activeEpg.now.title}
                            </Text>
                          )}
                          {activeEpg.next && (
                            <Text style={styles.detailEpgNext}>
                              {isPt ? 'A seguir: ' : 'Next: '}{activeEpg.next.title}
                            </Text>
                          )}
                        </View>
                      )}
                      {selectedResume && (
                        <Text style={styles.resumeHint}>
                          {isPt
                            ? `Continuar de ${formatPlaybackTime(selectedResume.position)} / ${formatPlaybackTime(selectedResume.duration)}`
                            : `Resume from ${formatPlaybackTime(selectedResume.position)} / ${formatPlaybackTime(selectedResume.duration)}`}
                        </Text>
                      )}
                      <TVFocusGuideView autoFocus={!player} style={styles.row}>
                        <TVButton
                          label={selectedResume ? (isPt ? 'Continuar' : 'Resume') : (isPt ? 'Assistir' : 'Play')}
                          preferred
                          onPress={() => startPlayback(selected)}
                        />
                        {selectedResume && (
                          <TVButton
                            label={isPt ? 'Do início' : 'Start over'}
                            onPress={() => startPlayback(selected, 0)}
                          />
                        )}
                        <TVButton
                          label={favorites.has(selected.id) ? (isPt ? 'Remover favorito' : 'Remove favorite') : (isPt ? 'Adicionar favorito' : 'Add favorite')}
                          onPress={() => toggleFavorite(selected)}
                        />
                        <TVButton label={isPt ? 'Voltar ao catálogo' : 'Back to content'} onPress={() => setSelected(undefined)}/>
                      </TVFocusGuideView>
                    </View>
                  ) : (
                    <FlatList
                      ref={contentListRef}
                      data={filtered}
                      numColumns={3}
                      keyExtractor={contentKeyExtractor}
                      getItemLayout={getContentItemLayout}
                      initialNumToRender={12}
                      maxToRenderPerBatch={12}
                      windowSize={5}
                      removeClippedSubviews
                      ListEmptyComponent={
                        <Text style={styles.help}>
                          {loading
                            ? (isPt ? 'Carregando…' : 'Loading…')
                            : (isPt ? 'Nenhum conteúdo encontrado. Escolha outra categoria ou faça uma busca.' : 'No matching content. Try another category or search.')}
                        </Text>
                      }
                      renderItem={renderContentItem}
                    />
                  )}
                </TVFocusGuideView>
              </View>
            </>
          )}

          {loading && (
            <View style={styles.row}>
              <ActivityIndicator color="#5eead4"/>
              <Text style={styles.help}>{isPt ? 'Carregando catálogo…' : 'Loading your library…'}</Text>
              <TVButton label={isPt ? 'Cancelar' : 'Cancel'} onPress={cancelLoading}/>
            </View>
          )}
          {!!error && <Text accessibilityRole="alert" style={styles.error}>{error}</Text>}
          {storageError && <Text accessibilityRole="alert" style={styles.error}>{isPt
            ? 'Não foi possível salvar ou restaurar sua biblioteca. Você ainda pode assistir nesta sessão.'
            : 'Your saved library could not be restored or updated. You can still watch in this session.'}</Text>}
        </>}
      </View>

      {player && (
        <View style={styles.playerOverlay}>
          <Suspense fallback={<View style={styles.playerLoading}><ActivityIndicator color="#5eead4" size="large" /></View>}>
            <LazyPlayerScreen
              item={player}
              language={language}
              onClose={closePlayer}
              startPosition={playerStartPosition}
              epg={player.kind === 'live' ? activeEpg : undefined}
              isFavorite={favorites.has(player.id)}
              onToggleFavorite={toggleFavorite}
              canSwitchChannel={player.kind === 'live' && liveChannels.length > 1}
              onSwitchChannel={handleSwitchChannel}
              onProgress={handleVodProgress}
              onEnded={handleVodEnded}
              onMemoryWarning={handleMemoryWarning}
            />
          </Suspense>
        </View>
      )}

      {showSplash && (
        <Animated.View style={[styles.splashContainer, {opacity: splashOpacity}]}>
          <View style={styles.splashGlow} />
          <View style={styles.splashContent}>
            <View style={styles.splashBadge}>
              <Text style={styles.splashPlayIcon}>▶</Text>
            </View>
            <Text style={styles.splashBrand}>BruTV</Text>
            <Text style={styles.splashTagline}>{isPt ? 'IPTV simples e direto ao ponto.' : 'IPTV that just works.'}</Text>
            <ActivityIndicator color="#5eead4" size="small" style={styles.splashSpinner} />
          </View>
        </Animated.View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: '#0b1220'},
  screen: {flex: 1, padding: 32, backgroundColor: '#0b1220'},
  playerOverlay: {...StyleSheet.absoluteFillObject, backgroundColor: '#000', zIndex: 50},
  playerLoading: {flex: 1, backgroundColor: '#000', justifyContent: 'center', alignItems: 'center'},
  header: {flexDirection: 'row', alignItems: 'center', marginBottom: 12},
  headerSpacer: {flex: 1},
  brand: {fontSize: 40, color: '#5eead4', fontWeight: '700'},
  subtitle: {fontSize: 22, color: '#cad7e6', marginLeft: 20},
  title: {fontSize: 30, color: '#fff', marginBottom: 16},
  help: {fontSize: 20, color: '#acbbd0', marginVertical: 12},
  form: {maxWidth: 950, alignSelf: 'center', width: '100%', paddingTop: 24},
  input: {color: '#fff', fontSize: 20, borderWidth: 2, borderColor: '#49637f', borderRadius: 12, padding: 16, margin: 6},
  row: {flexDirection: 'row', alignItems: 'center', flexWrap: 'wrap'},
  half: {flex: 1},
  card: {flex: 1, maxWidth: '33.333%', height: CONTENT_ROW_HEIGHT},
  contentCard: {height: CONTENT_ROW_HEIGHT - 16, margin: 8, padding: 10, backgroundColor: '#172233', borderRadius: 14, borderWidth: 3, borderColor: '#263b55'},
  contentCardFocused: {borderColor: '#5eead4', backgroundColor: '#254559'},
  contentArtwork: {width: '100%', height: 106, borderRadius: 9, backgroundColor: '#0c1626'},
  contentArtworkFallback: {width: '100%', height: 106, alignItems: 'center', justifyContent: 'center', borderRadius: 9, backgroundColor: '#0c1626'},
  contentArtworkIcon: {fontSize: 34, color: '#5eead4'},
  contentTitle: {fontSize: 17, color: '#fff', fontWeight: '600', marginTop: 8},
  contentGroup: {fontSize: 13, color: '#94a3b8', marginTop: 2},
  detail: {padding: 20, backgroundColor: '#172233', borderRadius: 16},
  detailEpg: {marginBottom: 12},
  detailEpgNow: {color: '#e2e8f0', fontSize: 19, fontWeight: '600'},
  detailEpgNext: {color: '#94a3b8', fontSize: 17, marginTop: 4},
  resumeHint: {color: '#5eead4', fontSize: 18, fontWeight: '600', marginBottom: 10},
  error: {color: '#ffb4a8', fontSize: 20, margin: 12},

  // Category sidebar layout
  contentContainer: {
    flex: 1,
    flexDirection: 'row',
    marginTop: 10,
  },
  sidebar: {
    width: 290,
    backgroundColor: '#0c1626',
    borderRadius: 14,
    borderWidth: 1.5,
    borderColor: '#1d2f47',
    padding: 8,
    marginRight: 16,
  },
  sidebarHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderBottomWidth: 1,
    borderBottomColor: '#1d2f47',
    marginBottom: 6,
  },
  sidebarTitle: {
    fontSize: 15,
    fontWeight: '700',
    color: '#94a3b8',
    letterSpacing: 1.2,
  },
  sidebarTotalBadge: {
    backgroundColor: 'rgba(94, 234, 212, 0.15)',
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: 8,
  },
  sidebarTotalText: {
    color: '#5eead4',
    fontSize: 13,
    fontWeight: '700',
  },
  mainArea: {
    flex: 1,
  },

  // Fixed-height category item button for getItemLayout
  catButton: {
    height: CATEGORY_ROW_HEIGHT - 6,
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 10,
    marginVertical: 3,
    borderRadius: 10,
    backgroundColor: '#131e2e',
    borderWidth: 2,
    borderColor: 'transparent',
  },
  catSelected: {
    backgroundColor: '#163c43',
    borderColor: '#2b7979',
  },
  catFocused: {
    borderColor: '#5eead4',
    backgroundColor: '#1a4550',
  },
  catIndicator: {
    width: 4,
    height: 22,
    borderRadius: 2,
    backgroundColor: 'transparent',
    marginRight: 10,
  },
  catIndicatorActive: {
    backgroundColor: '#5eead4',
  },
  catLabel: {
    flex: 1,
    color: '#cad7e6',
    fontSize: 18,
    fontWeight: '500',
  },
  catLabelSelected: {
    color: '#ffffff',
    fontWeight: '700',
  },
  catBadge: {
    backgroundColor: 'rgba(255, 255, 255, 0.08)',
    paddingHorizontal: 7,
    paddingVertical: 2,
    borderRadius: 6,
    marginLeft: 6,
  },
  catBadgeSelected: {
    backgroundColor: 'rgba(94, 234, 212, 0.2)',
  },
  catBadgeText: {
    color: '#8c9bb0',
    fontSize: 12,
    fontWeight: '600',
  },
  catBadgeTextSelected: {
    color: '#5eead4',
  },

  // Splash Screen
  splashContainer: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: '#080b11',
    justifyContent: 'center',
    alignItems: 'center',
    zIndex: 999,
  },
  splashGlow: {
    position: 'absolute',
    width: 320,
    height: 320,
    borderRadius: 160,
    backgroundColor: '#167e74',
    opacity: 0.18,
  },
  splashContent: {
    alignItems: 'center',
  },
  splashBadge: {
    width: 84,
    height: 84,
    borderRadius: 24,
    backgroundColor: '#167e74',
    borderWidth: 2,
    borderColor: '#5eead4',
    justifyContent: 'center',
    alignItems: 'center',
    marginBottom: 20,
    shadowColor: '#5eead4',
    shadowOpacity: 0.35,
    shadowRadius: 16,
    elevation: 10,
  },
  splashPlayIcon: {
    fontSize: 40,
    color: '#06201f',
    marginLeft: 4,
  },
  splashBrand: {
    fontSize: 40,
    color: '#ffffff',
    fontWeight: '800',
    letterSpacing: -0.5,
  },
  splashTagline: {
    fontSize: 18,
    color: '#5eead4',
    fontWeight: '600',
    marginTop: 8,
  },
  splashSpinner: {
    marginTop: 20,
  },
});
