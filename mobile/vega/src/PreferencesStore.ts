import {KeplerFileSystem} from '@amazon-devices/kepler-file-system';
import {ContentItem, hydrateCachedItems, Section, SectionResult} from './domain/catalog';
import {LoginSource} from './domain/login';
import {
  parseSavedSource,
  Preferences,
  serializeSavedSource,
  utf8ByteLength,
} from './domain/preferences';
import {PreferencesRepository} from './domain/PreferencesRepository';

const SAVED_SOURCE_PATH = '/data/brutv-saved-source-v1.json';
const MAX_CACHE_BYTES = 4 * 1024 * 1024;
const CACHE_TTL_MS = 6 * 60 * 60 * 1000;

const repository = new PreferencesRepository({
  async read(name) {
    const path = `/data/${name}`;
    if (!(await KeplerFileSystem.exists(path))) return undefined;
    const metadata = await KeplerFileSystem.getMetadata(path, false);
    if (metadata.size > 512 * 1024) throw new Error('Saved-library data exceeds its size limit.');
    return KeplerFileSystem.readFileAsString(path, 'UTF-8');
  },
  write: (name, text) => KeplerFileSystem.writeStringToFile(`/data/${name}`, text, 'UTF-8'),
});

export const loadPreferences = (): Promise<Preferences> => repository.load();
export const savePreferences = (preferences: Preferences): Promise<void> => repository.save(preferences);

export async function loadSavedSource(): Promise<LoginSource | undefined> {
  try {
    if (!(await KeplerFileSystem.exists(SAVED_SOURCE_PATH))) return undefined;
    const metadata = await KeplerFileSystem.getMetadata(SAVED_SOURCE_PATH, false);
    if (metadata.size > 16 * 1024) return undefined;
    const text = await KeplerFileSystem.readFileAsString(SAVED_SOURCE_PATH, 'UTF-8');
    return parseSavedSource(text);
  } catch {
    return undefined;
  }
}

export async function saveSavedSource(source: LoginSource): Promise<void> {
  const text = serializeSavedSource(source);
  const written = await KeplerFileSystem.writeStringToFile(SAVED_SOURCE_PATH, text, 'UTF-8');
  if (written !== utf8ByteLength(text)) {
    throw new Error('Incomplete saved-source write.');
  }
}

export async function clearSavedSource(): Promise<void> {
  try {
    if (await KeplerFileSystem.exists(SAVED_SOURCE_PATH)) {
      await KeplerFileSystem.removeFile(SAVED_SOURCE_PATH);
    }
  } catch { /* Ignore cleanup failure on sign-out. */ }
}

interface CachedSectionPayload {
  version: 1;
  savedAt: number;
  liveExtension?: string;
  categories: string[];
  items: {
    id: string;
    name: string;
    group: string;
    kind: Section;
    logo?: string;
    tvgID?: string;
    streamID?: string;
    extension?: string;
  }[];
}

function sectionCachePath(sourceKey: string, section: Section): string {
  if (!/^[0-9a-f]{16}$/.test(sourceKey)) throw new Error('Invalid cache key.');
  return `/data/brutv-cache-${sourceKey}-${section}.json`;
}

export async function loadCachedSection(
  source: Extract<LoginSource, {kind: 'xtream'}>,
  sourceKey: string,
  section: Section,
): Promise<{result: SectionResult; liveExtension?: string; stale: boolean} | undefined> {
  try {
    const path = sectionCachePath(sourceKey, section);
    if (!(await KeplerFileSystem.exists(path))) return undefined;
    const metadata = await KeplerFileSystem.getMetadata(path, false);
    if (metadata.size > MAX_CACHE_BYTES) return undefined;
    const text = await KeplerFileSystem.readFileAsString(path, 'UTF-8');
    const parsed = JSON.parse(text) as Partial<CachedSectionPayload> | null;
    if (parsed?.version !== 1 || !Array.isArray(parsed.items) || !Array.isArray(parsed.categories)) return undefined;
    const savedAt = typeof parsed.savedAt === 'number' ? parsed.savedAt : 0;
    const stale = Date.now() - savedAt > CACHE_TTL_MS;
    const rawItems: ContentItem[] = [];
    for (let i = 0; i < parsed.items.length; i++) {
      const entry = parsed.items[i];
      if (!entry || typeof entry.id !== 'string' || typeof entry.name !== 'string') continue;
      rawItems.push({
        id: entry.id,
        name: entry.name,
        group: typeof entry.group === 'string' ? entry.group : 'Uncategorized',
        kind: section,
        logo: typeof entry.logo === 'string' ? entry.logo : undefined,
        tvgID: typeof entry.tvgID === 'string' ? entry.tvgID : undefined,
        streamID: typeof entry.streamID === 'string' ? entry.streamID : undefined,
        extension: typeof entry.extension === 'string' ? entry.extension : undefined,
      });
    }
    const items = hydrateCachedItems(source, section, rawItems, parsed.liveExtension);
    const categories = parsed.categories.filter((c): c is string => typeof c === 'string');
    return {result: {items, categories}, liveExtension: parsed.liveExtension, stale};
  } catch {
    return undefined;
  }
}

export async function saveCachedSection(
  sourceKey: string,
  section: Section,
  result: SectionResult,
  liveExtension?: string,
): Promise<void> {
  try {
    // Strip playback URLs so credentials are never written to catalog cache files.
    const strippedItems: CachedSectionPayload['items'] = [];
    for (let i = 0; i < result.items.length; i++) {
      const item = result.items[i];
      strippedItems.push({
        id: item.id,
        name: item.name,
        group: item.group,
        kind: item.kind,
        ...(item.logo ? {logo: item.logo} : {}),
        ...(item.tvgID ? {tvgID: item.tvgID} : {}),
        ...(item.streamID ? {streamID: item.streamID} : {}),
        ...(item.extension ? {extension: item.extension} : {}),
      });
    }
    const payload: CachedSectionPayload = {
      version: 1,
      savedAt: Date.now(),
      ...(liveExtension ? {liveExtension} : {}),
      categories: result.categories,
      items: strippedItems,
    };
    const text = JSON.stringify(payload);
    const byteLen = utf8ByteLength(text);
    if (byteLen > MAX_CACHE_BYTES) return;
    await KeplerFileSystem.writeStringToFile(sectionCachePath(sourceKey, section), text, 'UTF-8');
  } catch { /* Catalog cache is best-effort; never fail playback or browsing. */ }
}

export async function clearCachedSections(sourceKey: string): Promise<void> {
  for (const section of ['live', 'movie', 'series'] as const) {
    try {
      const path = sectionCachePath(sourceKey, section);
      if (await KeplerFileSystem.exists(path)) {
        await KeplerFileSystem.removeFile(path);
      }
    } catch { /* Ignore cache eviction failures. */ }
  }
}
