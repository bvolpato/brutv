import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {ActivityIndicator, Animated, BackHandler, FlatList, StyleSheet, Text, TextInput, View} from 'react-native';
import {browse, Catalog, ContentItem, loadCatalog, loadEpisodes, Section} from './domain/catalog';
import {LoginSource, parseLogin} from './domain/login';
import {PlayerScreen} from './media/PlayerScreen';
import {TVButton} from './TVButton';

export default function App() {
  const [showSplash, setShowSplash] = useState(true);
  const splashOpacity = useRef(new Animated.Value(1)).current;
  const splashScale = useRef(new Animated.Value(1)).current;

  useEffect(() => {
    const timer = setTimeout(() => {
      Animated.parallel([
        Animated.timing(splashOpacity, { toValue: 0, duration: 400, useNativeDriver: true }),
        Animated.timing(splashScale, { toValue: 1.08, duration: 400, useNativeDriver: true }),
      ]).start(() => setShowSplash(false));
    }, 1500);
    return () => clearTimeout(timer);
  }, [splashOpacity, splashScale]);

  const [source, setSource] = useState<LoginSource>();
  const [catalog, setCatalog] = useState<Catalog>();
  const [input, setInput] = useState('');
  const [server, setServer] = useState('');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [section, setSection] = useState<Section>('live');
  const [query, setQuery] = useState('');
  const [group, setGroup] = useState<string>();
  const [filter, setFilter] = useState<'all' | 'favorites' | 'recent'>('all');
  const [favorites, setFavorites] = useState<Set<string>>(new Set());
  const [recent, setRecent] = useState<string[]>([]);
  const [episodes, setEpisodes] = useState<ContentItem[]>();
  const [selected, setSelected] = useState<ContentItem>();
  const [player, setPlayer] = useState<ContentItem>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const requestController = useRef<AbortController>();
  const closePlayer = useCallback(() => setPlayer(undefined), []);

  useEffect(() => {
    if (!source) return;
    const controller = new AbortController();
    requestController.current = controller;
    setLoading(true); setError('');
    void loadCatalog(source, controller.signal).then(value => {
      if (!controller.signal.aborted) { setCatalog(value); setPassword(''); setInput(''); }
    }).catch(() => { if (!controller.signal.aborted) setError('Could not load the provider. Check the address and account, then try again.'); })
      .finally(() => { if (!controller.signal.aborted) setLoading(false); });
    return () => controller.abort();
  }, [source]);

  useEffect(() => {
    const subscription = BackHandler.addEventListener('hardwareBackPress', () => {
      if (player) return false;
      if (selected) { setSelected(undefined); return true; }
      if (episodes) { setEpisodes(undefined); setGroup(undefined); return true; }
      return false;
    });
    return () => subscription.remove();
  }, [selected, episodes, player]);

  const items = episodes || catalog?.items || [];
  const filtered = useMemo(() => {
    const sectionItems = browse(items, section, query, group);
    return filter === 'favorites' ? sectionItems.filter(item => favorites.has(item.id))
      : filter === 'recent' ? recent.flatMap(id => sectionItems.find(item => item.id === id) || []) : sectionItems;
  }, [items, section, query, group, filter, favorites, recent]);
  const groups = useMemo(() => [...new Set(items.filter(item => item.kind === section).map(item => item.group))].sort(), [items, section]);

  const signIn = () => {
    try {
      const next = input.trim() ? parseLogin(input) : parseLogin(`brutv://login?server=${encodeURIComponent(server)}&username=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}`);
      setSource(next);
    } catch { setError('Enter an HTTP provider address and account, an M3U URL, or a BruTV sign-in link.'); }
  };
  const signOut = () => {
    requestController.current?.abort();
    setSource(undefined); setCatalog(undefined); setEpisodes(undefined); setSelected(undefined); setPlayer(undefined);
    setPassword(''); setUsername(''); setServer(''); setInput(''); setQuery(''); setGroup(undefined); setError('');
    setFavorites(new Set()); setRecent([]); setLoading(false);
  };
  const openItem = async (item: ContentItem) => {
    if (item.url) { setSelected(item); return; }
    if (!catalog?.seriesSource) return;
    requestController.current?.abort();
    const controller = new AbortController(); requestController.current = controller;
    setLoading(true); setError('');
    try {
      const value = await loadEpisodes(catalog.seriesSource, item.id.split(':')[1], controller.signal);
      if (!controller.signal.aborted) { setEpisodes(value); setGroup(undefined); setQuery(''); }
    } catch { if (!controller.signal.aborted) setError('The provider could not load the episodes.'); }
    finally { if (!controller.signal.aborted) setLoading(false); }
  };
  const startPlayback = (item: ContentItem) => {
    let path: string;
    try { path = item.url ? new URL(item.url).pathname.toLowerCase() : ''; }
    catch { setError('The provider supplied an invalid playback address.'); return; }
    if (path.endsWith('.ts') || path.endsWith('.mkv')) { setError('This Vega starter plays HLS, DASH and MP4. Choose a supported source from your provider.'); return; }
    setRecent(previous => [item.id, ...previous.filter(id => id !== item.id)].slice(0, 50));
    setPlayer(item);
  };
  if (player) return <PlayerScreen key={player.id} item={player} onClose={closePlayer}/>;

  return <View style={styles.screen}>
    <View style={styles.header}><Text style={styles.brand}>BruTV</Text><Text style={styles.subtitle}>IPTV that just works</Text></View>
    {!catalog ? <View style={styles.form}>
      <Text style={styles.title}>Your TV. Your provider.</Text>
      <Text style={styles.help}>Enter your account, or paste an M3U URL or the sign-in link encoded in an iPhone QR code.</Text>
      <TextInput style={styles.input} value={input} onChangeText={setInput} placeholder="M3U URL or brutv://login link" placeholderTextColor="#8c9bb0" autoCapitalize="none" accessibilityLabel="Playlist or BruTV sign-in link"/>
      <TextInput style={styles.input} value={server} onChangeText={setServer} placeholder="https://your-provider.example" placeholderTextColor="#8c9bb0" autoCapitalize="none" accessibilityLabel="Provider address"/>
      <View style={styles.row}>
        <TextInput style={[styles.input, styles.half]} value={username} onChangeText={setUsername} placeholder="Username" placeholderTextColor="#8c9bb0" autoCapitalize="none" accessibilityLabel="Username"/>
        <TextInput style={[styles.input, styles.half]} value={password} onChangeText={setPassword} placeholder="Password" placeholderTextColor="#8c9bb0" secureTextEntry accessibilityLabel="Password"/>
      </View>
      <Text style={styles.help}>Your sign-in stays in memory and is not saved on this TV.</Text>
      {!loading && <TVButton label="Sign in" onPress={signIn}/>}
    </View> : <>
      <View style={styles.row}>
        {(['live', 'movie', 'series'] as Section[]).map(value => <TVButton key={value} label={value === 'live' ? 'Live TV' : value === 'movie' ? 'Movies' : 'Series'} preferred={value === 'live'} selected={section === value} onPress={() => { setSection(value); setEpisodes(undefined); setSelected(undefined); setGroup(undefined); }}/>) }
        <TVButton label="Sign out" onPress={signOut}/>
      </View>
      <TextInput style={styles.input} value={query} onChangeText={setQuery} placeholder="Search your library" placeholderTextColor="#8c9bb0" accessibilityLabel="Search your library"/>
      <View style={styles.row}>
        {(['all', 'favorites', 'recent'] as const).map(value => <TVButton key={value} label={value === 'all' ? 'All content' : value === 'favorites' ? 'Favorites' : 'Recently watched'} selected={filter === value} onPress={() => setFilter(value)}/>) }
        {episodes && <TVButton label="Back to series" onPress={() => { setEpisodes(undefined); setGroup(undefined); }}/>}
      </View>
      <FlatList horizontal style={styles.groups} data={[{label: 'All categories', value: undefined}, ...groups.map(value => ({label: value, value}))]} keyExtractor={item => item.value === undefined ? 'all' : `group:${item.value}`}
        renderItem={({item}) => <TVButton label={item.label} selected={item.value === group} onPress={() => { setGroup(item.value); setSelected(undefined); }}/>} />
      {selected ? <View style={styles.detail}>
        <Text style={styles.title}>{selected.name}</Text><Text style={styles.help}>{selected.group}</Text>
        <View style={styles.row}>
          <TVButton label="Play" preferred onPress={() => startPlayback(selected)}/>
          <TVButton label={favorites.has(selected.id) ? 'Remove favorite' : 'Add favorite'} onPress={() => setFavorites(previous => { const next = new Set(previous); next.has(selected.id) ? next.delete(selected.id) : next.add(selected.id); return next; })}/>
          <TVButton label="Back to content" onPress={() => setSelected(undefined)}/>
        </View>
      </View> : <FlatList data={filtered} numColumns={3} keyExtractor={item => item.id} initialNumToRender={12} maxToRenderPerBatch={12} windowSize={5}
        ListEmptyComponent={<Text style={styles.help}>No matching content. Try another category or search.</Text>}
        renderItem={({item}) => <View style={styles.card}><TVButton label={item.name} onPress={() => { void openItem(item); }}/></View>}/>}
    </>}
    {loading && <View style={styles.row}><ActivityIndicator color="#5eead4"/><Text style={styles.help}>Loading your library…</Text><TVButton label="Cancel" onPress={signOut}/></View>}
    {!!error && <Text accessibilityRole="alert" style={styles.error}>{error}</Text>}
    {showSplash && (
      <Animated.View style={[styles.splashContainer, { opacity: splashOpacity, transform: [{ scale: splashScale }] }]}>
        <View style={styles.splashGlow} />
        <View style={styles.splashContent}>
          <View style={styles.splashBadge}>
            <Text style={styles.splashPlayIcon}>▶</Text>
          </View>
          <Text style={styles.splashBrand}>BruTV</Text>
          <Text style={styles.splashTagline}>IPTV that just works.</Text>
          <ActivityIndicator color="#5eead4" size="small" style={styles.splashSpinner} />
        </View>
      </Animated.View>
    )}
  </View>;
}

const styles = StyleSheet.create({
  screen: {flex: 1, padding: 36, backgroundColor: '#0b1220'}, header: {flexDirection: 'row', alignItems: 'baseline', marginBottom: 12},
  brand: {fontSize: 44, color: '#5eead4', fontWeight: '700'}, subtitle: {fontSize: 24, color: '#cad7e6', marginLeft: 24},
  title: {fontSize: 32, color: '#fff', marginBottom: 16}, help: {fontSize: 21, color: '#acbbd0', marginVertical: 12},
  form: {maxWidth: 950, alignSelf: 'center', width: '100%', paddingTop: 24}, input: {color: '#fff', fontSize: 22, borderWidth: 2, borderColor: '#49637f', borderRadius: 12, padding: 18, margin: 6},
  row: {flexDirection: 'row', alignItems: 'center'}, half: {flex: 1}, groups: {maxHeight: 92, flexGrow: 0}, card: {flex: 1, maxWidth: '33.333%'},
  detail: {padding: 20, backgroundColor: '#172233', borderRadius: 16}, error: {color: '#ffb4a8', fontSize: 21, margin: 12},
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
