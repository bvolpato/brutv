import React, {memo, useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {ActivityIndicator, Animated, BackHandler, FlatList, Image, StyleSheet, Text, TextInput, TouchableOpacity, View} from 'react-native';
import {browse, Catalog, ContentItem, loadCatalog, loadEpisodes, Section} from './domain/catalog';
import {LoginSource, parseLogin} from './domain/login';
import {PlayerScreen} from './media/PlayerScreen';
import {TVButton} from './TVButton';

const CategoryTVButton = memo(function CategoryTVButton({
  label,
  icon,
  count,
  selected = false,
  preferred = false,
  onPress,
}: {
  label: string;
  icon?: string;
  count?: number;
  selected?: boolean;
  preferred?: boolean;
  onPress: () => void;
}) {
  const [focused, setFocused] = useState(false);
  const [imageFailed, setImageFailed] = useState(false);

  return (
    <TouchableOpacity
      accessibilityRole="button"
      accessibilityLabel={`${label}, ${count !== undefined ? count : 0} items`}
      hasTVPreferredFocus={preferred}
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      onPress={onPress}
      activeOpacity={1}
      style={[
        styles.catButton,
        selected && styles.catSelected,
        focused && styles.catFocused,
      ]}
    >
      <View style={[styles.catIndicator, selected && styles.catIndicatorActive]} />
      <View style={styles.catIconBox}>
        {icon && !imageFailed ? (
          <Image
            source={{uri: icon}}
            style={styles.catIcon}
            resizeMode="contain"
            onError={() => setImageFailed(true)}
          />
        ) : (
          <Text style={styles.catFallbackIcon}>📺</Text>
        )}
      </View>
      <Text numberOfLines={1} style={[styles.catLabel, selected && styles.catLabelSelected]}>
        {label}
      </Text>
      {count !== undefined && count > 0 && (
        <View style={[styles.catBadge, selected && styles.catBadgeSelected]}>
          <Text style={[styles.catBadgeText, selected && styles.catBadgeTextSelected]}>{count}</Text>
        </View>
      )}
    </TouchableOpacity>
  );
});

const ContentTVButton = memo(function ContentTVButton({item, onPress}: {item: ContentItem; onPress: () => void}) {
  const [focused, setFocused] = useState(false);
  const [imageFailed, setImageFailed] = useState(false);
  return <TouchableOpacity
    accessibilityRole="button"
    accessibilityLabel={item.group ? `${item.name}, ${item.group}` : item.name}
    onFocus={() => setFocused(true)}
    onBlur={() => setFocused(false)}
    onPress={onPress}
    activeOpacity={1}
    style={[styles.contentCard, focused && styles.contentCardFocused]}
  >
    {item.logo && !imageFailed
      ? <Image source={{uri: item.logo}} style={styles.contentArtwork} resizeMode="cover" onError={() => setImageFailed(true)} />
      : <View style={styles.contentArtworkFallback}><Text style={styles.contentArtworkIcon}>▶</Text></View>}
    <Text numberOfLines={2} style={styles.contentTitle}>{item.name}</Text>
    {!!item.group && <Text numberOfLines={1} style={styles.contentGroup}>{item.group}</Text>}
  </TouchableOpacity>;
});

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

  const [language, setLanguage] = useState<'pt' | 'en'>('pt');
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

  const isPt = language === 'pt';

  useEffect(() => {
    if (!source) return;
    const controller = new AbortController();
    requestController.current = controller;
    setLoading(true); setError('');
    void loadCatalog(source, controller.signal).then(value => {
      if (!controller.signal.aborted) { setCatalog(value); setPassword(''); setInput(''); }
    }).catch(() => {
      if (!controller.signal.aborted) {
        setError(isPt ? 'Não foi possível carregar o provedor. Verifique os dados e tente novamente.' : 'Could not load the provider. Check the address and account, then try again.');
      }
    }).finally(() => { if (!controller.signal.aborted) setLoading(false); });
    return () => controller.abort();
  }, [source, isPt]);

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

  const categoryData = useMemo(() => {
    const sectionItems = items.filter(item => item.kind === section);
    const countMap = new Map<string, number>();
    const iconMap = new Map<string, string>();
    let firstAllIcon: string | undefined;

    for (const item of sectionItems) {
      if (!firstAllIcon && item.logo) {
        firstAllIcon = item.logo;
      }
      const g = item.group;
      if (g) {
        countMap.set(g, (countMap.get(g) || 0) + 1);
        if (!iconMap.has(g) && item.logo) {
          iconMap.set(g, item.logo);
        }
      }
    }

    const allLabel = isPt
      ? (section === 'live' ? 'Todos os Canais' : section === 'movie' ? 'Todos os Filmes' : 'Todas as Séries')
      : (section === 'live' ? 'All Channels' : section === 'movie' ? 'All Movies' : 'All Series');

    const allItem = {
      label: allLabel,
      value: undefined as string | undefined,
      icon: firstAllIcon,
      count: sectionItems.length,
    };

    const catItems = groups.map(g => ({
      label: g,
      value: g as string | undefined,
      icon: iconMap.get(g),
      count: countMap.get(g) || 0,
    }));

    return [allItem, ...catItems];
  }, [items, section, groups, isPt]);

  const signIn = () => {
    try {
      const next = input.trim() ? parseLogin(input) : parseLogin(`brutv://login?server=${encodeURIComponent(server)}&username=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}`);
      setSource(next);
    } catch {
      setError(isPt ? 'Digite um endereço de servidor HTTP, uma URL M3U ou um link do BruTV.' : 'Enter an HTTP provider address and account, an M3U URL, or a BruTV sign-in link.');
    }
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
    } catch {
      if (!controller.signal.aborted) setError(isPt ? 'O provedor não pôde carregar os episódios.' : 'The provider could not load the episodes.');
    } finally {
      if (!controller.signal.aborted) setLoading(false);
    }
  };

  const startPlayback = (item: ContentItem) => {
    let path: string;
    try { path = item.url ? new URL(item.url).pathname.toLowerCase() : ''; }
    catch {
      setError(isPt ? 'O provedor forneceu um endereço de reprodução inválido.' : 'The provider supplied an invalid playback address.');
      return;
    }
    if (path.endsWith('.ts') || path.endsWith('.mkv')) {
      setError(isPt ? 'Este cliente suporta HLS, DASH e MP4. Escolha uma fonte compatível no provedor.' : 'This Vega starter plays HLS, DASH and MP4. Choose a supported source from your provider.');
      return;
    }
    setRecent(previous => [item.id, ...previous.filter(id => id !== item.id)].slice(0, 50));
    setPlayer(item);
  };

  if (player) return <PlayerScreen key={player.id} item={player} language={language} onClose={closePlayer}/>;

  return <View style={styles.screen}>
    <View style={styles.header}>
      <Text style={styles.brand}>BruTV</Text>
      <Text style={styles.subtitle}>{isPt ? 'IPTV simples e direto ao ponto' : 'IPTV that just works'}</Text>
      <View style={styles.headerSpacer} />
      <TVButton
        label={isPt ? '🇧🇷 Português' : '🇺🇸 English'}
        onPress={() => setLanguage(lang => lang === 'pt' ? 'en' : 'pt')}
      />
    </View>

    {!catalog ? <View style={styles.form}>
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
      <Text style={styles.help}>{isPt ? 'Suas credenciais ficam apenas na memória deste dispositivo.' : 'Your sign-in stays in memory and is not saved on this TV.'}</Text>
      {!loading && <TVButton label={isPt ? 'Entrar' : 'Sign in'} onPress={signIn}/>}
    </View> : <>
      <View style={styles.row}>
        {(['live', 'movie', 'series'] as Section[]).map(value => (
          <TVButton
            key={value}
            label={value === 'live' ? (isPt ? 'TV ao Vivo' : 'Live TV') : value === 'movie' ? (isPt ? 'Filmes' : 'Movies') : (isPt ? 'Séries' : 'Series')}
            preferred={value === 'live'}
            selected={section === value}
            onPress={() => { setSection(value); setEpisodes(undefined); setSelected(undefined); setGroup(undefined); }}
          />
        ))}
        <TVButton label={isPt ? 'Sair' : 'Sign out'} onPress={signOut}/>
      </View>

      <TextInput
        style={styles.input}
        value={query}
        onChangeText={setQuery}
        placeholder={isPt ? 'Buscar no catálogo' : 'Search your library'}
        placeholderTextColor="#8c9bb0"
        accessibilityLabel="Search your library"
      />

      <View style={styles.row}>
        {(['all', 'favorites', 'recent'] as const).map(value => (
          <TVButton
            key={value}
            label={value === 'all' ? (isPt ? 'Todos' : 'All content') : value === 'favorites' ? (isPt ? 'Favoritos' : 'Favorites') : (isPt ? 'Assistidos recentemente' : 'Recently watched')}
            selected={filter === value}
            onPress={() => setFilter(value)}
          />
        ))}
        {episodes && <TVButton label={isPt ? 'Voltar às séries' : 'Back to series'} onPress={() => { setEpisodes(undefined); setGroup(undefined); }}/>}
      </View>

      {/* Main Content Area with Left Category Column */}
      <View style={styles.contentContainer}>
        {/* Left Category Sidebar */}
        <View style={styles.sidebar}>
          <View style={styles.sidebarHeader}>
            <Text style={styles.sidebarTitle}>{isPt ? 'CATEGORIAS' : 'CATEGORIES'}</Text>
            <View style={styles.sidebarTotalBadge}>
              <Text style={styles.sidebarTotalText}>{categoryData.length}</Text>
            </View>
          </View>
          <FlatList
            data={categoryData}
            keyExtractor={item => item.value === undefined ? 'all' : `group:${item.value}`}
            initialNumToRender={14}
            maxToRenderPerBatch={14}
            showsVerticalScrollIndicator={false}
            renderItem={({item}) => (
              <CategoryTVButton
                label={item.label}
                icon={item.icon}
                count={item.count}
                selected={item.value === group}
                onPress={() => { setGroup(item.value); setSelected(undefined); }}
              />
            )}
          />
        </View>

        {/* Right Content / Detail Area */}
        <View style={styles.mainArea}>
          {selected ? (
            <View style={styles.detail}>
              <Text style={styles.title}>{selected.name}</Text>
              <Text style={styles.help}>{selected.group}</Text>
              <View style={styles.row}>
                <TVButton label={isPt ? 'Assistir' : 'Play'} preferred onPress={() => startPlayback(selected)}/>
                <TVButton
                  label={favorites.has(selected.id) ? (isPt ? 'Remover favorito' : 'Remove favorite') : (isPt ? 'Adicionar favorito' : 'Add favorite')}
                  onPress={() => setFavorites(previous => { const next = new Set(previous); next.has(selected.id) ? next.delete(selected.id) : next.add(selected.id); return next; })}
                />
                <TVButton label={isPt ? 'Voltar ao catálogo' : 'Back to content'} onPress={() => setSelected(undefined)}/>
              </View>
            </View>
          ) : (
            <FlatList
              data={filtered}
              numColumns={3}
              keyExtractor={item => item.id}
              initialNumToRender={12}
              maxToRenderPerBatch={12}
              windowSize={5}
              ListEmptyComponent={
                <Text style={styles.help}>
                  {isPt ? 'Nenhum conteúdo encontrado. Escolha outra categoria ou faça uma busca.' : 'No matching content. Try another category or search.'}
                </Text>
              }
              renderItem={({item}) => (
                <View style={styles.card}>
                  <ContentTVButton item={item} onPress={() => { void openItem(item); }}/>
                </View>
              )}
            />
          )}
        </View>
      </View>
    </>}

    {loading && (
      <View style={styles.row}>
        <ActivityIndicator color="#5eead4"/>
        <Text style={styles.help}>{isPt ? 'Carregando catálogo…' : 'Loading your library…'}</Text>
        <TVButton label={isPt ? 'Cancelar' : 'Cancel'} onPress={signOut}/>
      </View>
    )}
    {!!error && <Text accessibilityRole="alert" style={styles.error}>{error}</Text>}

    {showSplash && (
      <Animated.View style={[styles.splashContainer, { opacity: splashOpacity, transform: [{ scale: splashScale }] }]}>
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
  </View>;
}

const styles = StyleSheet.create({
  screen: {flex: 1, padding: 32, backgroundColor: '#0b1220'},
  header: {flexDirection: 'row', alignItems: 'center', marginBottom: 12},
  headerSpacer: {flex: 1},
  brand: {fontSize: 40, color: '#5eead4', fontWeight: '700'},
  subtitle: {fontSize: 22, color: '#cad7e6', marginLeft: 20},
  title: {fontSize: 30, color: '#fff', marginBottom: 16},
  help: {fontSize: 20, color: '#acbbd0', marginVertical: 12},
  form: {maxWidth: 950, alignSelf: 'center', width: '100%', paddingTop: 24},
  input: {color: '#fff', fontSize: 20, borderWidth: 2, borderColor: '#49637f', borderRadius: 12, padding: 16, margin: 6},
  row: {flexDirection: 'row', alignItems: 'center'},
  half: {flex: 1},
  card: {flex: 1, maxWidth: '33.333%'},
  contentCard: {minHeight: 182, margin: 8, padding: 10, backgroundColor: '#172233', borderRadius: 14, borderWidth: 3, borderColor: '#263b55'},
  contentCardFocused: {borderColor: '#5eead4', backgroundColor: '#254559'},
  contentArtwork: {width: '100%', height: 116, borderRadius: 9, backgroundColor: '#0c1626'},
  contentArtworkFallback: {width: '100%', height: 116, alignItems: 'center', justifyContent: 'center', borderRadius: 9, backgroundColor: '#0c1626'},
  contentArtworkIcon: {fontSize: 34, color: '#5eead4'},
  contentTitle: {fontSize: 18, color: '#fff', fontWeight: '600', marginTop: 9},
  contentGroup: {fontSize: 13, color: '#94a3b8', marginTop: 4},
  detail: {padding: 20, backgroundColor: '#172233', borderRadius: 16},
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

  // Category item button
  catButton: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 10,
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
    height: 24,
    borderRadius: 2,
    backgroundColor: 'transparent',
    marginRight: 8,
  },
  catIndicatorActive: {
    backgroundColor: '#5eead4',
  },
  catIconBox: {
    width: 32,
    height: 32,
    borderRadius: 6,
    backgroundColor: '#070d17',
    justifyContent: 'center',
    alignItems: 'center',
    marginRight: 10,
    overflow: 'hidden',
  },
  catIcon: {
    width: 28,
    height: 28,
  },
  catFallbackIcon: {
    fontSize: 16,
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
    paddingHorizontal: 6,
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
