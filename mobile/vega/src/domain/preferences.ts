import {httpURL, LoginSource} from './login';
import {stableID} from './m3u';

export interface ResumePosition {
  position: number;
  duration: number;
  updatedAt: number;
}

export interface LibrarySelection {
  favorites: string[];
  recent: string[];
  resumePositions?: Record<string, ResumePosition>;
}

export interface Preferences {
  version: 1;
  language: 'pt' | 'en';
  libraries: Record<string, LibrarySelection>;
}

export const MAX_RESUME_ENTRIES = 50;
const ITEM_ID_RE = /^(?:[0-9a-f]{16}|(?:live|movie|series|episode):[0-9]+)$/;

export const emptyPreferences = (): Preferences => ({version: 1, language: 'pt', libraries: {}});

export function utf8ByteLength(text: string): number {
  let bytes = 0;
  for (let index = 0; index < text.length; index++) {
    const code = text.charCodeAt(index);
    if (code < 0x80) {
      bytes += 1;
    } else if (code < 0x800) {
      bytes += 2;
    } else if (code >= 0xd800 && code <= 0xdbff && index + 1 < text.length) {
      const next = text.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4;
        index++;
      } else {
        bytes += 3;
      }
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

export function libraryKey(source: LoginSource): string {
  // Source identity is not a credential vault; no provider URLs or passwords are serialized.
  return stableID(JSON.stringify(source.kind === 'm3u' ? ['m3u', source.url]
    : ['xtream', source.server.replace(/\/+$/, ''), source.username]));
}

function identifiers(value: unknown, limit: number): string[] {
  if (!Array.isArray(value)) return [];
  const seen = new Set<string>();
  const result: string[] = [];
  for (let i = 0; i < value.length && result.length < limit; i++) {
    const id = value[i];
    if (typeof id === 'string' && ITEM_ID_RE.test(id) && !seen.has(id)) {
      seen.add(id);
      result.push(id);
    }
  }
  return result;
}

function sanitizeResumePositions(value: unknown): Record<string, ResumePosition> | undefined {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined;
  const entries: [string, ResumePosition][] = [];
  for (const [id, raw] of Object.entries(value as Record<string, unknown>)) {
    if (!ITEM_ID_RE.test(id) || !raw || typeof raw !== 'object' || Array.isArray(raw)) continue;
    const record = raw as Partial<ResumePosition>;
    const position = Number(record.position);
    const duration = Number(record.duration);
    const updatedAt = Number(record.updatedAt);
    if (!Number.isFinite(position) || position <= 0 || !Number.isFinite(duration) || duration <= 0) continue;
    if (position >= duration) continue;
    entries.push([id, {
      position: Math.floor(position),
      duration: Math.floor(duration),
      updatedAt: Number.isFinite(updatedAt) && updatedAt > 0 ? Math.floor(updatedAt) : 0,
    }]);
  }
  if (!entries.length) return undefined;
  entries.sort((a, b) => b[1].updatedAt - a[1].updatedAt);
  const bounded = entries.slice(0, MAX_RESUME_ENTRIES);
  return Object.fromEntries(bounded);
}

function sanitizeSelection(raw: unknown): LibrarySelection {
  const selection = (raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {}) as Partial<LibrarySelection>;
  const resumePositions = sanitizeResumePositions(selection.resumePositions);
  const result: LibrarySelection = {
    favorites: identifiers(selection.favorites, 1000),
    recent: identifiers(selection.recent, 50),
  };
  if (resumePositions) result.resumePositions = resumePositions;
  return result;
}

export function sanitizePreferences(raw: unknown): Preferences {
  const value = raw as Partial<Preferences> | null | undefined;
  if (value?.version !== 1 || !value.libraries || typeof value.libraries !== 'object' || Array.isArray(value.libraries)) {
    throw new Error('Unsupported saved-library data.');
  }
  const libraries: Preferences['libraries'] = {};
  for (const [key, library] of Object.entries(value.libraries).slice(-16)) {
    if (!/^[0-9a-f]{16}$/.test(key) || !library || typeof library !== 'object' || Array.isArray(library)) continue;
    libraries[key] = sanitizeSelection(library);
  }
  return {version: 1, language: value.language === 'en' ? 'en' : 'pt', libraries};
}

export function readPreferences(text: string): Preferences {
  return sanitizePreferences(JSON.parse(text));
}

export function updateLibrary(
  preferences: Preferences,
  key: string,
  update: (selection: LibrarySelection) => LibrarySelection,
): Preferences {
  const libraries = {...preferences.libraries};
  const current = libraries[key] || {favorites: [], recent: []};
  const next = sanitizeSelection(update(current));
  delete libraries[key];
  libraries[key] = next;
  return {...preferences, libraries: Object.fromEntries(Object.entries(libraries).slice(-16))};
}

export function shouldClearResume(position: number, duration: number): boolean {
  if (!Number.isFinite(position) || !Number.isFinite(duration) || duration <= 0) return true;
  if (position < 10) return true;
  if (position / duration >= 0.92) return true;
  if (duration >= 120 && duration - position <= 30) return true;
  return false;
}

export function updateResumePosition(
  preferences: Preferences,
  key: string,
  itemId: string,
  position: number,
  duration: number,
  now = Date.now(),
): Preferences {
  if (!ITEM_ID_RE.test(itemId)) return preferences;
  return updateLibrary(preferences, key, selection => {
    const nextPositions = {...(selection.resumePositions || {})};
    if (shouldClearResume(position, duration)) {
      delete nextPositions[itemId];
    } else {
      nextPositions[itemId] = {
        position: Math.floor(position),
        duration: Math.floor(duration),
        updatedAt: Math.floor(now),
      };
    }
    return {
      ...selection,
      resumePositions: Object.keys(nextPositions).length ? nextPositions : undefined,
    };
  });
}

export function clearResumePosition(preferences: Preferences, key: string, itemId: string): Preferences {
  return updateLibrary(preferences, key, selection => {
    if (!selection.resumePositions || !(itemId in selection.resumePositions)) return selection;
    const nextPositions = {...selection.resumePositions};
    delete nextPositions[itemId];
    return {
      ...selection,
      resumePositions: Object.keys(nextPositions).length ? nextPositions : undefined,
    };
  });
}

export function getResumePosition(preferences: Preferences, key: string, itemId: string): ResumePosition | undefined {
  return preferences.libraries[key]?.resumePositions?.[itemId];
}

export function serializeSavedSource(source: LoginSource): string {
  if (source.kind === 'm3u') {
    httpURL(source.url);
    return JSON.stringify({version: 1, source: {kind: 'm3u', url: source.url}});
  }
  httpURL(source.server);
  return JSON.stringify({
    version: 1,
    source: {kind: 'xtream', server: source.server, username: source.username, password: source.password},
  });
}

export function parseSavedSource(text: string): LoginSource | undefined {
  try {
    const parsed = JSON.parse(text) as {version?: unknown; source?: Partial<LoginSource>} | null;
    if (parsed?.version !== 1 || !parsed.source || typeof parsed.source !== 'object') return undefined;
    if (parsed.source.kind === 'm3u' && typeof parsed.source.url === 'string') {
      httpURL(parsed.source.url);
      return {kind: 'm3u', url: parsed.source.url};
    }
    if (
      parsed.source.kind === 'xtream'
      && typeof parsed.source.server === 'string'
      && typeof parsed.source.username === 'string'
      && typeof parsed.source.password === 'string'
      && parsed.source.username
      && parsed.source.password
    ) {
      httpURL(parsed.source.server);
      return {
        kind: 'xtream',
        server: parsed.source.server,
        username: parsed.source.username,
        password: parsed.source.password,
      };
    }
    return undefined;
  } catch {
    return undefined;
  }
}
