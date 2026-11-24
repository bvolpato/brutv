import {resilientFetch} from './http';
import {apiURL, httpURL, LoginSource, streamURLFromPrefix, streamURLPrefix} from './login';
import {parseM3U, PlaylistEntry} from './m3u';
import {utf8ByteLength} from './preferences';

export type Section = 'live' | 'movie' | 'series';

export interface ContentItem {
  id: string;
  name: string;
  group: string;
  kind: Section;
  url?: string;
  logo?: string;
  tvgID?: string;
  streamID?: string;
  extension?: string;
}

export interface Catalog {
  sections: Record<Section, ContentItem[]>;
  categories: Record<Section, string[]>;
  loadedSections: Record<Section, boolean>;
  items: ContentItem[];
  seriesSource?: Extract<LoginSource, {kind: 'xtream'}>;
  liveExtension?: string;
}

export interface SectionResult {
  items: ContentItem[];
  categories: string[];
}

export interface EpgEntry {
  id: string;
  title: string;
  description?: string;
  startTimestamp?: number;
  stopTimestamp?: number;
  start?: string;
  end?: string;
}

export interface ShortEPG {
  now?: EpgEntry;
  next?: EpgEntry;
  entries: EpgEntry[];
}

export interface CatalogLoadOptions {
  maxBytes?: number;
}

export const MAX_CATALOG_BYTES = 32 * 1024 * 1024;
const PER_REQUEST_TIMEOUT_MS = 45_000;
const CATALOG_TOO_LARGE_ERROR = 'The provider catalog exceeds the supported size limit.';

function appendAll<T>(target: T[], source: readonly T[]): void {
  for (let index = 0; index < source.length; index++) {
    target.push(source[index]);
  }
}

export function flattenCatalogSections(sections: Record<Section, ContentItem[]>): ContentItem[] {
  const combined: ContentItem[] = [];
  appendAll(combined, sections.live);
  appendAll(combined, sections.movie);
  appendAll(combined, sections.series);
  return combined;
}

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

function checkDeclaredLength(response: Response, maxBytes: number): void {
  const header = response.headers?.get?.('content-length');
  if (header !== null && header !== undefined && header !== '') {
    const trimmed = header.trim();
    if (/^\d+$/.test(trimmed)) {
      const declared = Number(trimmed);
      if (Number.isFinite(declared) && declared > maxBytes) {
        void response.body?.cancel?.().catch(() => {});
        throw new Error(CATALOG_TOO_LARGE_ERROR);
      }
    }
  }
}

async function readBoundedText(response: Response, maxBytes: number): Promise<string> {
  checkDeclaredLength(response, maxBytes);
  const body = response.body as {getReader?: () => {read(): Promise<{done: boolean; value?: Uint8Array}>; cancel(): Promise<void>}} | null | undefined;
  if (body && typeof body.getReader === 'function') {
    const reader = body.getReader();
    const chunks: Uint8Array[] = [];
    let totalBytes = 0;
    try {
      while (true) {
        const {done, value} = await reader.read();
        if (done) break;
        if (!value || value.byteLength === 0) continue;
        totalBytes += value.byteLength;
        if (totalBytes > maxBytes) {
          await reader.cancel().catch(() => {});
          throw new Error(CATALOG_TOO_LARGE_ERROR);
        }
        chunks.push(value);
      }
    } catch (error) {
      await reader.cancel().catch(() => {});
      throw error;
    }
    const merged = new Uint8Array(totalBytes);
    let offset = 0;
    for (let index = 0; index < chunks.length; index++) {
      merged.set(chunks[index], offset);
      offset += chunks[index].byteLength;
    }
    if (typeof TextDecoder !== 'undefined') {
      return new TextDecoder('utf-8').decode(merged);
    }
    return decodeUtf8Bytes(merged);
  }
  const text = await response.text();
  if (utf8ByteLength(text) > maxBytes) {
    throw new Error(CATALOG_TOO_LARGE_ERROR);
  }
  return text;
}

function decodeUtf8Bytes(bytes: Uint8Array): string {
  const parts: string[] = [];
  let i = 0;
  const len = bytes.length;
  while (i < len) {
    const c = bytes[i++];
    if (c < 0x80) {
      parts.push(String.fromCharCode(c));
    } else if (c >= 0xc0 && c < 0xe0 && i < len) {
      parts.push(String.fromCharCode(((c & 0x1f) << 6) | (bytes[i++] & 0x3f)));
    } else if (c >= 0xe0 && c < 0xf0 && i + 1 < len) {
      parts.push(String.fromCharCode(((c & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f)));
    } else if (c >= 0xf0 && i + 2 < len) {
      const cp = (((c & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f)) - 0x10000;
      parts.push(String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff)));
    }
  }
  return parts.join('');
}

async function requestJSON(url: string, signal?: AbortSignal, maxBytes = MAX_CATALOG_BYTES): Promise<unknown> {
  return withDeadline(async requestSignal => {
    const response = await fetchChecked(url, requestSignal);
    const text = await readBoundedText(response, maxBytes);
    return JSON.parse(text);
  }, signal, PER_REQUEST_TIMEOUT_MS);
}

async function requestText(url: string, signal?: AbortSignal, maxBytes = MAX_CATALOG_BYTES): Promise<string> {
  return withDeadline(async requestSignal => {
    const response = await fetchChecked(url, requestSignal);
    return readBoundedText(response, maxBytes);
  }, signal, PER_REQUEST_TIMEOUT_MS);
}

function list(value: unknown): Record<string, unknown>[] {
  if (!Array.isArray(value)) throw new Error('The provider returned an invalid catalog.');
  const result: Record<string, unknown>[] = [];
  for (let index = 0; index < value.length; index++) {
    const entry = value[index];
    if (entry && typeof entry === 'object') result.push(entry as Record<string, unknown>);
  }
  return result;
}

function optionalList(value: unknown): Record<string, unknown>[] {
  if (!Array.isArray(value)) return [];
  const result: Record<string, unknown>[] = [];
  for (let index = 0; index < value.length; index++) {
    const entry = value[index];
    if (entry && typeof entry === 'object') result.push(entry as Record<string, unknown>);
  }
  return result;
}

function string(value: unknown): string {
  return typeof value === 'string' || typeof value === 'number' ? String(value) : '';
}

export function selectLiveOutputFormat(allowed: unknown): string {
  const raw: string[] = [];
  if (Array.isArray(allowed)) {
    for (let i = 0; i < allowed.length; i++) {
      if (typeof allowed[i] === 'string') raw.push(allowed[i]);
    }
  } else if (typeof allowed === 'string') {
    for (const part of allowed.split(',')) raw.push(part);
  }
  const normalized: string[] = [];
  for (let i = 0; i < raw.length; i++) {
    const cleaned = raw[i].trim().replace(/^\.+/, '').toLowerCase();
    if (cleaned) normalized.push(cleaned);
  }
  if (!normalized.length) return 'm3u8';
  if (normalized.includes('m3u8') || normalized.includes('hls')) return 'm3u8';
  if (normalized.includes('mpd')) return 'mpd';
  if (normalized.includes('mp4')) return 'mp4';
  return normalized[0];
}

interface InFlightEntry {
  promise: Promise<SectionResult>;
  controller: AbortController;
  waiters: number;
}

const inFlightSections = new Map<string, InFlightEntry>();

function sectionFlightKey(source: Extract<LoginSource, {kind: 'xtream'}>, section: Section): string {
  return `${source.server.replace(/\/+$/, '')}|${source.username}|${section}`;
}

async function fetchSectionUncached(
  source: Extract<LoginSource, {kind: 'xtream'}>,
  section: Section,
  signal: AbortSignal,
  liveExtension: string,
  maxBytes: number,
): Promise<SectionResult> {
  const prefix = section === 'movie' ? 'vod' : section;
  const action = section === 'series' ? 'get_series' : `get_${prefix}_streams`;
  const [rawCategories, rawStreams] = await Promise.all([
    requestJSON(apiURL(source, `get_${prefix}_categories`), signal, maxBytes).catch(error => {
      if (signal.aborted) throw error;
      return [];
    }),
    requestJSON(apiURL(source, action), signal, maxBytes),
  ]);

  const categories = optionalList(rawCategories);
  const groups = new Map<string, string>();
  const providerCategoryOrder: string[] = [];
  const seenCategoryNames = new Set<string>();
  for (let index = 0; index < categories.length; index++) {
    const cat = categories[index];
    const catId = string(cat.category_id);
    const catName = string(cat.category_name).trim();
    if (catId && catName) {
      groups.set(catId, catName);
      if (!seenCategoryNames.has(catName)) {
        seenCategoryNames.add(catName);
        providerCategoryOrder.push(catName);
      }
    }
  }

  const streams = list(rawStreams);
  const items: ContentItem[] = [];
  const seenIds = new Set<string>();
  const presentCategories = new Set<string>();
  const extraCategories: string[] = [];
  const urlPrefix = section === 'series' ? '' : streamURLPrefix(source, section);

  for (let index = 0; index < streams.length; index++) {
    const item = streams[index];
    const streamID = string(section === 'series' ? item.series_id : item.stream_id);
    if (!streamID) continue;
    const id = `${section}:${streamID}`;
    if (seenIds.has(id)) continue;
    seenIds.add(id);

    const group = groups.get(string(item.category_id)) || 'Uncategorized';
    if (!presentCategories.has(group)) {
      presentCategories.add(group);
      if (!seenCategoryNames.has(group)) {
        seenCategoryNames.add(group);
        extraCategories.push(group);
      }
    }

    const extension = section === 'live'
      ? liveExtension
      : section === 'movie'
        ? (string(item.container_extension).trim().replace(/^\.+/, '') || 'mp4')
        : undefined;

    items.push({
      id,
      kind: section,
      name: string(item.name) || 'Untitled',
      group,
      logo: string(section === 'series' ? item.cover : item.stream_icon) || undefined,
      tvgID: string(item.epg_channel_id) || undefined,
      streamID,
      extension,
      url: extension ? streamURLFromPrefix(urlPrefix, streamID, extension) : undefined,
    });
  }

  const orderedCategories: string[] = [];
  for (let index = 0; index < providerCategoryOrder.length; index++) {
    const name = providerCategoryOrder[index];
    if (presentCategories.has(name)) orderedCategories.push(name);
  }
  appendAll(orderedCategories, extraCategories);

  return {items, categories: orderedCategories};
}

export async function loadSection(
  source: Extract<LoginSource, {kind: 'xtream'}>,
  section: Section,
  signal?: AbortSignal,
  options?: {liveExtension?: string; maxBytes?: number},
): Promise<SectionResult> {
  if (signal?.aborted) throw new Error('The request was aborted.');
  const key = sectionFlightKey(source, section);
  let entry = inFlightSections.get(key);
  if (!entry) {
    const controller = new AbortController();
    const liveExtension = options?.liveExtension || 'm3u8';
    const maxBytes = options?.maxBytes ?? MAX_CATALOG_BYTES;
    const promise = fetchSectionUncached(source, section, controller.signal, liveExtension, maxBytes).finally(() => {
      if (inFlightSections.get(key) === entry) {
        inFlightSections.delete(key);
      }
    });
    entry = {promise, controller, waiters: 0};
    inFlightSections.set(key, entry);
  }

  entry.waiters++;
  const activeEntry = entry;
  return new Promise<SectionResult>((resolve, reject) => {
    let settled = false;
    const cleanup = () => {
      signal?.removeEventListener('abort', onAbort);
    };
    const onAbort = () => {
      if (settled) return;
      settled = true;
      cleanup();
      activeEntry.waiters = Math.max(0, activeEntry.waiters - 1);
      if (activeEntry.waiters === 0) {
        activeEntry.controller.abort();
      }
      reject(new Error('The request was aborted.'));
    };
    if (signal) {
      if (signal.aborted) {
        onAbort();
        return;
      }
      signal.addEventListener('abort', onAbort, {once: true});
    }
    activeEntry.promise.then(
      result => {
        if (settled) return;
        settled = true;
        cleanup();
        activeEntry.waiters = Math.max(0, activeEntry.waiters - 1);
        resolve(result);
      },
      error => {
        if (settled) return;
        settled = true;
        cleanup();
        activeEntry.waiters = Math.max(0, activeEntry.waiters - 1);
        reject(error);
      },
    );
  });
}

export function withCatalogSection(catalog: Catalog, section: Section, result: SectionResult): Catalog {
  const sections: Record<Section, ContentItem[]> = {
    ...catalog.sections,
    [section]: result.items,
  };
  const categories: Record<Section, string[]> = {
    ...catalog.categories,
    [section]: result.categories,
  };
  const loadedSections: Record<Section, boolean> = {
    ...catalog.loadedSections,
    [section]: true,
  };
  return {
    ...catalog,
    sections,
    categories,
    loadedSections,
    items: flattenCatalogSections(sections),
  };
}

export async function loadCatalogSection(
  catalog: Catalog,
  section: Section,
  signal?: AbortSignal,
  options?: CatalogLoadOptions,
): Promise<Catalog> {
  if (catalog.loadedSections[section] || !catalog.seriesSource) {
    return catalog;
  }
  const result = await loadSection(catalog.seriesSource, section, signal, {
    liveExtension: catalog.liveExtension,
    maxBytes: options?.maxBytes,
  });
  return withCatalogSection(catalog, section, result);
}

export async function loadCatalog(
  source: LoginSource,
  signal?: AbortSignal,
  options?: CatalogLoadOptions,
): Promise<Catalog> {
  const maxBytes = options?.maxBytes ?? MAX_CATALOG_BYTES;
  if (source.kind === 'm3u') {
    const text = await requestText(source.url, signal, maxBytes);
    if (/#EXT-X-(?:TARGETDURATION|STREAM-INF|MEDIA-SEQUENCE):/.test(text.slice(0, 4096))) {
      throw new Error('This is a playback manifest. Add an IPTV channel playlist instead.');
    }
    const entries: PlaylistEntry[] = parseM3U(text);
    if (!entries.length) throw new Error('The playlist contains no channels.');
    const sections: Record<Section, ContentItem[]> = {live: [], movie: [], series: []};
    const categories: Record<Section, string[]> = {live: [], movie: [], series: []};
    const seenCats: Record<Section, Set<string>> = {live: new Set(), movie: new Set(), series: new Set()};
    for (let index = 0; index < entries.length; index++) {
      const entry = entries[index];
      sections[entry.kind].push(entry);
      if (entry.group && !seenCats[entry.kind].has(entry.group)) {
        seenCats[entry.kind].add(entry.group);
        categories[entry.kind].push(entry.group);
      }
    }
    return {
      sections,
      categories,
      loadedSections: {live: true, movie: true, series: true},
      items: entries,
    };
  }

  const authResponse = await requestJSON(apiURL(source), signal, maxBytes) as {
    user_info?: {auth?: unknown; status?: unknown; allowed_output_formats?: unknown};
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

  const liveExtension = selectLiveOutputFormat(authResponse?.user_info?.allowed_output_formats);
  // Load Live first; Movies and Series load lazily when the user opens those tabs.
  const liveResult = await loadSection(source, 'live', signal, {liveExtension, maxBytes});
  const sections: Record<Section, ContentItem[]> = {
    live: liveResult.items,
    movie: [],
    series: [],
  };
  const categories: Record<Section, string[]> = {
    live: liveResult.categories,
    movie: [],
    series: [],
  };
  return {
    sections,
    categories,
    loadedSections: {live: true, movie: false, series: false},
    items: liveResult.items,
    seriesSource: source,
    liveExtension,
  };
}

function numericSortValue(raw: string): number {
  const num = Number(raw);
  return Number.isFinite(num) ? num : Number.MAX_SAFE_INTEGER;
}

export async function loadEpisodes(
  source: Extract<LoginSource, {kind: 'xtream'}>,
  seriesID: string,
  signal?: AbortSignal,
  options?: CatalogLoadOptions,
): Promise<ContentItem[]> {
  const maxBytes = options?.maxBytes ?? MAX_CATALOG_BYTES;
  const info = await requestJSON(apiURL(source, 'get_series_info', seriesID), signal, maxBytes) as {episodes?: unknown} | null;
  if (!info?.episodes || typeof info.episodes !== 'object') throw new Error('The provider returned no episodes.');
  const urlPrefix = streamURLPrefix(source, 'series');
  const seenIds = new Set<string>();
  const seasonEntries = Object.entries(info.episodes as Record<string, unknown>).sort(([seasonA], [seasonB]) => {
    const diff = numericSortValue(seasonA) - numericSortValue(seasonB);
    return diff !== 0 ? diff : seasonA.localeCompare(seasonB);
  });

  const result: ContentItem[] = [];
  for (let s = 0; s < seasonEntries.length; s++) {
    const [season, value] = seasonEntries[s];
    const seasonEpisodes = optionalList(value).sort((a, b) => {
      const numA = numericSortValue(string(a.episode_num));
      const numB = numericSortValue(string(b.episode_num));
      return numA - numB;
    });
    for (let e = 0; e < seasonEpisodes.length; e++) {
      const episode = seasonEpisodes[e];
      const epId = string(episode.id).trim();
      if (!epId) continue;
      const itemId = `episode:${epId}`;
      if (seenIds.has(itemId)) continue;
      seenIds.add(itemId);
      const ext = string(episode.container_extension).trim().replace(/^\.+/, '') || 'mp4';
      const episodeInfo = episode.info && typeof episode.info === 'object' ? (episode.info as Record<string, unknown>) : undefined;
      const logo = string(episodeInfo?.movie_image) || string(episode.movie_image) || string(episode.cover) || undefined;
      result.push({
        id: itemId,
        kind: 'series',
        name: string(episode.title) || `Episode ${string(episode.episode_num) || e + 1}`,
        group: `Season ${season}`,
        logo,
        streamID: epId,
        extension: ext,
        url: streamURLFromPrefix(urlPrefix, epId, ext),
      });
    }
  }
  return result;
}

const B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const B64_DECODE = new Uint8Array(256).fill(255);
for (let i = 0; i < B64_ALPHABET.length; i++) B64_DECODE[B64_ALPHABET.charCodeAt(i)] = i;

export function decodeBase64UTF8(input: string): string {
  const trimmed = input.trim();
  if (!trimmed) return '';
  if ((trimmed.length & 3) !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(trimmed)) {
    return trimmed;
  }
  const pad = (trimmed.endsWith('=') ? 1 : 0) + (trimmed.endsWith('==') ? 1 : 0);
  const out = new Uint8Array((trimmed.length >>> 2) * 3 - pad);
  let pos = 0;
  for (let i = 0; i < trimmed.length; i += 4) {
    const v0 = B64_DECODE[trimmed.charCodeAt(i)];
    const v1 = B64_DECODE[trimmed.charCodeAt(i + 1)];
    const v2 = trimmed.charCodeAt(i + 2) === 61 ? 0 : B64_DECODE[trimmed.charCodeAt(i + 2)];
    const v3 = trimmed.charCodeAt(i + 3) === 61 ? 0 : B64_DECODE[trimmed.charCodeAt(i + 3)];
    if (((v0 | v1 | v2 | v3) & 0x80) !== 0) return trimmed;
    const bits = (v0 << 18) | (v1 << 12) | (v2 << 6) | v3;
    if (pos < out.length) out[pos++] = (bits >>> 16) & 0xff;
    if (pos < out.length) out[pos++] = (bits >>> 8) & 0xff;
    if (pos < out.length) out[pos++] = bits & 0xff;
  }
  try {
    if (typeof TextDecoder !== 'undefined') {
      return new TextDecoder('utf-8', {fatal: true}).decode(out);
    }
    return decodeUtf8Bytes(out);
  } catch {
    return trimmed;
  }
}

export async function loadShortEPG(
  source: Extract<LoginSource, {kind: 'xtream'}>,
  streamID: string,
  signal?: AbortSignal,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<ShortEPG> {
  const payload = await requestJSON(
    apiURL(source, 'get_short_epg', undefined, {stream_id: streamID, limit: '4'}),
    signal,
    512 * 1024,
  ) as {epg_listings?: unknown} | null;
  const listings = optionalList(payload?.epg_listings);
  const entries: EpgEntry[] = [];
  for (let i = 0; i < listings.length; i++) {
    const raw = listings[i];
    const title = decodeBase64UTF8(string(raw.title));
    if (!title) continue;
    const description = decodeBase64UTF8(string(raw.description)) || undefined;
    const startTs = Number(raw.start_timestamp);
    const stopTs = Number(raw.stop_timestamp);
    entries.push({
      id: string(raw.id) || String(i),
      title,
      description,
      startTimestamp: Number.isFinite(startTs) && startTs > 0 ? startTs : undefined,
      stopTimestamp: Number.isFinite(stopTs) && stopTs > 0 ? stopTs : undefined,
      start: string(raw.start) || undefined,
      end: string(raw.end) || undefined,
    });
  }
  if (!entries.length) return {entries: []};
  let nowIndex = entries.findIndex(entry =>
    entry.startTimestamp !== undefined
    && entry.stopTimestamp !== undefined
    && entry.startTimestamp <= nowSeconds
    && nowSeconds < entry.stopTimestamp,
  );
  if (nowIndex < 0) nowIndex = 0;
  return {
    now: entries[nowIndex],
    next: entries[nowIndex + 1],
    entries,
  };
}

export function hydrateCachedItems(
  source: Extract<LoginSource, {kind: 'xtream'}>,
  section: Section,
  items: ContentItem[],
  liveExtension = 'm3u8',
): ContentItem[] {
  if (section === 'series') return items;
  const urlPrefix = streamURLPrefix(source, section);
  const hydrated: ContentItem[] = [];
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    const streamID = item.streamID || item.id.split(':')[1];
    if (!streamID) continue;
    const ext = item.extension || (section === 'live' ? liveExtension : 'mp4');
    hydrated.push({
      ...item,
      streamID,
      extension: ext,
      url: streamURLFromPrefix(urlPrefix, streamID, ext),
    });
  }
  return hydrated;
}

export function browse(items: ContentItem[], section: Section, query: string, group?: string): ContentItem[] {
  const term = query.trim().toLocaleLowerCase();
  return items.filter(item => item.kind === section && (!group || item.group === group) && (!term || item.name.toLocaleLowerCase().includes(term)));
}
