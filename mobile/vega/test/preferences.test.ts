import assert from 'node:assert/strict';
import test from 'node:test';
import {emptyPreferences, libraryKey, readPreferences, updateLibrary} from '../src/domain/preferences';
import {PreferencesRepository} from '../src/domain/PreferencesRepository';

test('favorites and recent history survive serialization and stay separated by provider account', () => {
  const first = {kind: 'xtream' as const, server: 'https://one.test', username: 'user', password: 'secret'};
  const second = {...first, server: 'https://two.test'};
  const saved = updateLibrary(emptyPreferences(), libraryKey(first), () => ({favorites: ['live:1'], recent: ['movie:2']}));
  const restored = readPreferences(JSON.stringify(saved));
  assert.deepEqual(restored.libraries[libraryKey(first)], {favorites: ['live:1'], recent: ['movie:2']});
  assert.equal(restored.libraries[libraryKey(second)], undefined);
  assert.equal(libraryKey({...first, password: 'changed'}), libraryKey(first));
  assert.deepEqual(Object.keys(restored), ['version', 'language', 'libraries']);
});

test('saved-library decoding rejects invalid versions and excludes URLs, duplicates and unknown credential fields', () => {
  assert.throws(() => readPreferences('{"version":2,"libraries":{}}'), /Unsupported/);
  const key = '0123456789abcdef';
  const restored = readPreferences(JSON.stringify({version: 1, language: 'en', password: 'secret', libraries: {
    [key]: {favorites: ['live:1', 'live:1', 'https://provider.test/password'], recent: ['episode:2'], source: {password: 'secret'}},
    'https://provider.test': {favorites: ['live:3']},
  }}));
  assert.deepEqual(restored, {version: 1, language: 'en', libraries: {[key]: {favorites: ['live:1'], recent: ['episode:2']}}});
});

test('an interrupted library write preserves the previous complete snapshot and a later save can recover', async () => {
  const files = new Map<string, string>();
  let shortWrite = false;
  const storage = {read: async (name: string) => files.get(name), write: async (name: string, text: string) => {
    const value = shortWrite ? text.slice(0, 20) : text;
    files.set(name, value); return value.length;
  }};
  const repository = new PreferencesRepository(storage);
  assert.deepEqual(await repository.load(), emptyPreferences());
  const first = updateLibrary(emptyPreferences(), '0123456789abcdef', () => ({favorites: ['live:1'], recent: []}));
  await repository.save(first);
  shortWrite = true;
  await assert.rejects(repository.save({...first, language: 'en'}), /Incomplete/);
  const recovered = new PreferencesRepository(storage);
  assert.deepEqual(await recovered.load(), first);
  shortWrite = false;
  await recovered.save({...first, language: 'en'});
  assert.equal((await new PreferencesRepository(storage).load()).language, 'en');
});
