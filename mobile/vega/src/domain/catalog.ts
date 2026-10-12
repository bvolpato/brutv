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

export async function request(url: string, signal: AbortSignal): Promise<Response> {
  httpURL(url);
  const response = await fetch(url, {signal});
  if (!response.ok) throw new Error(`The provider returned HTTP ${response.status}.`);
  return response;
}

export async function withDeadline<T>(work: (signal: AbortSignal) => Promise<T>, outer?: AbortSignal): Promise<T> {
  const controller = new AbortController();
  const abort = () => controller.abort();
  outer?.addEventListener('abort', abort);
  if (outer?.aborted) controller.abort();
  const timer = setTimeout(abort, 20000);
  try { return await work(controller.signal); }
  finally { clearTimeout(timer); outer?.removeEventListener('abort', abort); }
}

function list(value: unknown): Record<string, unknown>[] {
  if (!Array.isArray(value)) throw new Error('The provider returned an invalid catalog.');
  return value.filter((item): item is Record<string, unknown> => !!item && typeof item === 'object');
}
function string(value: unknown): string { return typeof value === 'string' || typeof value === 'number' ? String(value) : ''; }

export async function loadCatalog(source: LoginSource, signal?: AbortSignal): Promise<Catalog> {
  return withDeadline(async requestSignal => {
    if (source.kind === 'm3u') {
      const response = await request(source.url, requestSignal);
      const text = await response.text();
      if (/#EXT-X-(?:TARGETDURATION|STREAM-INF|MEDIA-SEQUENCE):/.test(text)) {
        throw new Error('This is a playback manifest. Add an IPTV channel playlist instead.');
      }
      const entries: PlaylistEntry[] = parseM3U(text);
      if (!entries.length) throw new Error('The playlist contains no channels.');
      return {items: entries};
    }
    const auth = await (await request(apiURL(source), requestSignal)).json();
    if (String(auth?.user_info?.auth) !== '1') throw new Error('The provider rejected the sign-in details.');
    const sections: Section[] = ['live', 'movie', 'series'];
    const items: ContentItem[] = [];
    // Do not burst six parallel large responses onto a low-memory TV stick.
    for (const section of sections) {
      const prefix = section === 'movie' ? 'vod' : section;
      const categories = list(await (await request(apiURL(source, `get_${prefix}_categories`), requestSignal)).json());
      const groups = new Map(categories.map(item => [string(item.category_id), string(item.category_name)]));
      const action = section === 'series' ? 'get_series' : `get_${prefix}_streams`;
      const streams = list(await (await request(apiURL(source, action), requestSignal)).json());
      for (const item of streams) {
        const id = string(section === 'series' ? item.series_id : item.stream_id);
        if (!id) continue;
        const extension = section === 'live' ? 'm3u8' : string(item.container_extension) || 'mp4';
        items.push({
          id: `${section}:${id}`, kind: section, name: string(item.name) || 'Untitled',
          group: groups.get(string(item.category_id)) || 'Uncategorized',
          logo: string(section === 'series' ? item.cover : item.stream_icon) || undefined,
          url: section === 'series' ? undefined : streamURL(source, section, id, extension),
        });
      }
    }
    return {items, seriesSource: source};
  }, signal);
}

export async function loadEpisodes(source: Extract<LoginSource, {kind: 'xtream'}>, seriesID: string, signal?: AbortSignal): Promise<ContentItem[]> {
  return withDeadline(async requestSignal => {
    const info = await (await request(apiURL(source, 'get_series_info', seriesID), requestSignal)).json();
    if (!info?.episodes || typeof info.episodes !== 'object') throw new Error('The provider returned no episodes.');
    return Object.entries(info.episodes as Record<string, unknown>).flatMap(([season, value]) => list(value).map(episode => {
      const id = string(episode.id);
      return {
        id: `episode:${id}`, kind: 'series' as const, name: string(episode.title) || `Episode ${string(episode.episode_num)}`,
        group: `Season ${season}`, url: streamURL(source, 'series', id, string(episode.container_extension) || 'mp4'),
      };
    }));
  }, signal);
}

export function browse(items: ContentItem[], section: Section, query: string, group?: string): ContentItem[] {
  const term = query.trim().toLocaleLowerCase();
  return items.filter(item => item.kind === section && (!group || item.group === group) && (!term || item.name.toLocaleLowerCase().includes(term)));
}
