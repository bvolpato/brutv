import {LoginSource} from './login';
import {stableID} from './m3u';

export interface LibrarySelection {favorites: string[]; recent: string[]}
export interface Preferences {version: 1; language: 'pt' | 'en'; libraries: Record<string, LibrarySelection>}
export const emptyPreferences = (): Preferences => ({version: 1, language: 'pt', libraries: {}});

export function libraryKey(source: LoginSource): string {
  // Source identity is not a credential vault; no provider URLs or passwords are serialized.
  return stableID(JSON.stringify(source.kind === 'm3u' ? ['m3u', source.url]
    : ['xtream', source.server.replace(/\/+$/, ''), source.username]));
}

function identifiers(value: unknown, limit: number): string[] {
  if (!Array.isArray(value)) return [];
  return [...new Set(value.filter((id): id is string => typeof id === 'string'
    && /^(?:[0-9a-f]{16}|(?:live|movie|series|episode):[0-9]+)$/.test(id)))].slice(0, limit);
}

export function readPreferences(text: string): Preferences {
  const value = JSON.parse(text);
  if (value?.version !== 1 || !value.libraries || typeof value.libraries !== 'object' || Array.isArray(value.libraries)) {
    throw new Error('Unsupported saved-library data.');
  }
  const libraries: Preferences['libraries'] = {};
  for (const [key, library] of Object.entries(value.libraries).slice(-16)) {
    if (!/^[0-9a-f]{16}$/.test(key) || !library || typeof library !== 'object') continue;
    const selection = library as Partial<LibrarySelection>;
    libraries[key] = {favorites: identifiers(selection.favorites, 1000), recent: identifiers(selection.recent, 50)};
  }
  return {version: 1, language: value.language === 'en' ? 'en' : 'pt', libraries};
}

export function updateLibrary(preferences: Preferences, key: string, update: (selection: LibrarySelection) => LibrarySelection): Preferences {
  const libraries = {...preferences.libraries};
  const selection = update(libraries[key] || {favorites: [], recent: []});
  delete libraries[key];
  libraries[key] = {favorites: identifiers(selection.favorites, 1000), recent: identifiers(selection.recent, 50)};
  return {...preferences, libraries: Object.fromEntries(Object.entries(libraries).slice(-16))};
}
