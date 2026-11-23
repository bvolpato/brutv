import {resilientFetch} from './http';
import {apiURL, httpURL, LoginSource, streamURL} from './login';
import {parseM3U, PlaylistEntry} from './m3u';

export type Section = 'live' | 'movie' | 'series';
export interface ContentItem {
  id: string;
  name: string;
  group: string;
  kind: Section;
  url?: string;
  logo?: string;
}
export interface Catalog {items: ContentItem[]; seriesSource?: Extract<LoginSource, {kind: 'xtream'}>}

const PER_REQUEST_TIMEOUT_MS = 45_000;

async function fetchChecked(url: string, signal: AbortSignal): Promise<Response> {
  httpURL(url);
  const {response} = await resilientFetch(url, {signal});
  if (!response.ok) throw new Error(`The provider returned HTTP ${response.status}.`);
  return response;
}

export async function request(url: string, signal?: AbortSignal): Promise<Response> {
  return withDeadline(requestSignal => fetchChecked(url, requestSignal), signal, PER_REQUEST_TIMEOUT_MS);
}

export async function withDeadline<T>(
  work: (signal: AbortSignal) => Promise<T>,
  outer?: AbortSignal,
  timeoutMs = PER_REQUEST_TIMEOUT_MS,
): Promise<T> {
  const controller = new AbortController();
  const abort = () => controller.abort();
  outer?.addEventListener('abort', abort);
  if (outer?.aborted) controller.abort();
  const timer = setTimeout(abort, timeoutMs);
  try { return await work(controller.signal); }
  finally { clearTimeout(timer); outer?.removeEventListener('abort', abort); }
}

async function requestJSON(url: string, signal?: AbortSignal): Promise<unknown> {
  return withDeadline(async requestSignal => {
    const response = await fetchChecked(url, requestSignal);
    return response.json();
  }, signal, PER_REQUEST_TIMEOUT_MS);
}

async function requestText(url: string, signal?: AbortSignal): Promise<string> {
  return withDeadline(async requestSignal => {
    const response = await fetchChecked(url, requestSignal);
    return response.text();
  }, signal, PER_REQUEST_TIMEOUT_MS);
}

function list(value: unknown): Record<string, unknown>[] {
  if (!Array.isArray(value)) throw new Error('The provider returned an invalid catalog.');
  return value.filter((item): item is Record<string, unknown> => !!item && typeof item === 'object');
}
function optionalList(value: unknown): Record<string, unknown>[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is Record<string, unknown> => !!item && typeof item === 'object');
}
function string(value: unknown): string { return typeof value === 'string' || typeof value === 'number' ? String(value) : ''; }

async function loadSection(
  source: Extract<LoginSource, {kind: 'xtream'}>,
  section: Section,
  signal?: AbortSignal,
): Promise<ContentItem[]> {
  const prefix = section === 'movie' ? 'vod' : section;
  const rawCategories = await requestJSON(apiURL(source, `get_${prefix}_categories`), signal);
  const categories = optionalList(rawCategories);
  const groups = new Map(categories.map(item => [string(item.category_id), string(item.category_name)]));
  const action = section === 'series' ? 'get_series' : `get_${prefix}_streams`;
  const streams = list(await requestJSON(apiURL(source, action), signal));
  const items: ContentItem[] = [];
  for (const item of streams) {
    const id = string(section === 'series' ? item.series_id : item.stream_id);
    if (!id) continue;
    const extension = section === 'live' ? 'm3u8' : (string(item.container_extension).trim().replace(/^\.+/, '') || 'mp4');
    items.push({
      id: `${section}:${id}`,
      kind: section,
      name: string(item.name) || 'Untitled',
      group: groups.get(string(item.category_id)) || 'Uncategorized',
      logo: string(section === 'series' ? item.cover : item.stream_icon) || undefined,
      url: section === 'series' ? undefined : streamURL(source, section, id, extension),
    });
  }
  return items;
}

export async function loadCatalog(source: LoginSource, signal?: AbortSignal): Promise<Catalog> {
  if (source.kind === 'm3u') {
    const text = await requestText(source.url, signal);
    if (/#EXT-X-(?:TARGETDURATION|STREAM-INF|MEDIA-SEQUENCE):/.test(text)) {
      throw new Error('This is a playback manifest. Add an IPTV channel playlist instead.');
    }
    const entries: PlaylistEntry[] = parseM3U(text);
    if (!entries.length) throw new Error('The playlist contains no channels.');
    return {items: entries};
  }
  const authResponse = await requestJSON(apiURL(source), signal) as {
    user_info?: {auth?: unknown; status?: unknown};
  } | null;
  const authValue = authResponse?.user_info?.auth;
  const authenticated = authValue === 1
    || authValue === '1'
    || authValue === true
    || (typeof authValue === 'string' && authValue.trim().toLowerCase() === 'true');
  const accountStatus = typeof authResponse?.user_info?.status === 'string'
    ? authResponse.user_info.status.trim().toLowerCase()
    : '';
  if (!authenticated || accountStatus === 'disabled' || accountStatus === 'expired') {
    throw new Error('The provider rejected the sign-in details.');
  }
  const items: ContentItem[] = [];
  // Load Live first; do not burst parallel large responses onto a low-memory TV stick.
  items.push(...await loadSection(source, 'live', signal));
  for (const section of ['movie', 'series'] as const) {
    try {
      items.push(...await loadSection(source, section, signal));
    } catch (error) {
      if (signal?.aborted) throw error;
      // Tolerate failing or disabled VOD/Series endpoints without blocking Live TV.
    }
  }
  return {items, seriesSource: source};
}

export async function loadEpisodes(
  source: Extract<LoginSource, {kind: 'xtream'}>,
  seriesID: string,
  signal?: AbortSignal,
): Promise<ContentItem[]> {
  const info = await requestJSON(apiURL(source, 'get_series_info', seriesID), signal) as {episodes?: unknown} | null;
  if (!info?.episodes || typeof info.episodes !== 'object') throw new Error('The provider returned no episodes.');
  return Object.entries(info.episodes as Record<string, unknown>).flatMap(([season, value]) =>
    optionalList(value).map(episode => {
      const id = string(episode.id);
      return {
        id: `episode:${id}`,
        kind: 'series' as const,
        name: string(episode.title) || `Episode ${string(episode.episode_num)}`,
        group: `Season ${season}`,
        url: streamURL(source, 'series', id, string(episode.container_extension).trim().replace(/^\.+/, '') || 'mp4'),
      };
    }),
  );
}

export function browse(items: ContentItem[], section: Section, query: string, group?: string): ContentItem[] {
  const term = query.trim().toLocaleLowerCase();
  return items.filter(item => item.kind === section && (!group || item.group === group) && (!term || item.name.toLocaleLowerCase().includes(term)));
}
