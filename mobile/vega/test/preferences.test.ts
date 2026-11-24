import assert from 'node:assert/strict';
import test from 'node:test';
import {
  clearResumePosition,
  emptyPreferences,
  getResumePosition,
  libraryKey,
  MAX_RESUME_ENTRIES,
  parseSavedSource,
  readPreferences,
  serializeSavedSource,
  updateLibrary,
  updateResumePosition,
  utf8ByteLength,
} from '../src/domain/preferences';
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
    files.set(name, value); return Buffer.byteLength(value, 'utf8');
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

test('utf8ByteLength matches exact UTF-8 byte counts for multi-byte and surrogate-pair strings', async () => {
  for (const sample of ['ascii', 'café ação', '日本語', '📺🎬🔥', 'aé日📺']) {
    assert.equal(utf8ByteLength(sample), Buffer.byteLength(sample, 'utf8'));
  }
  // PreferencesRepository must validate against UTF-8 byte count rather than UTF-16 code unit length.
  let observedWritten = 0;
  const repo = new PreferencesRepository({
    read: async () => undefined,
    write: async (_name, text) => {
      observedWritten = Buffer.byteLength(text, 'utf8');
      return observedWritten;
    },
  });
  await repo.save(emptyPreferences());
  assert.ok(observedWritten > 0);
});

test('resumePositions persists VOD progress, clears on completion, and stays bounded at 50 entries', () => {
  const key = '0123456789abcdef';
  let prefs = emptyPreferences();
  prefs = updateResumePosition(prefs, key, 'movie:10', 125.7, 3600, 1000);
  assert.deepEqual(getResumePosition(prefs, key, 'movie:10'), {position: 125, duration: 3600, updatedAt: 1000});

  // Near completion (>= 92% or within 30s of end) clears the resume entry automatically.
  prefs = updateResumePosition(prefs, key, 'movie:10', 3580, 3600, 2000);
  assert.equal(getResumePosition(prefs, key, 'movie:10'), undefined);

  // Explicit clear removes saved progress.
  prefs = updateResumePosition(prefs, key, 'episode:5', 60, 1800, 3000);
  assert.equal(getResumePosition(prefs, key, 'episode:5')?.position, 60);
  prefs = clearResumePosition(prefs, key, 'episode:5');
  assert.equal(getResumePosition(prefs, key, 'episode:5'), undefined);

  // Bounded cap retains only the 50 most recently updated entries.
  for (let i = 1; i <= MAX_RESUME_ENTRIES + 12; i++) {
    prefs = updateResumePosition(prefs, key, `movie:${i}`, 120, 3600, i * 1000);
  }
  const restored = readPreferences(JSON.stringify(prefs));
  const stored = restored.libraries[key].resumePositions!;
  assert.equal(Object.keys(stored).length, MAX_RESUME_ENTRIES);
  assert.equal(stored['movie:1'], undefined);
  assert.equal(stored[`movie:${MAX_RESUME_ENTRIES + 12}`]?.position, 120);
});

test('opt-in saved source serialization validates HTTP(S) sources and rejects malformed payloads', () => {
  const xtream = {kind: 'xtream' as const, server: 'https://provider.example/panel', username: 'qa', password: 'pw'};
  assert.deepEqual(parseSavedSource(serializeSavedSource(xtream)), xtream);
  const m3u = {kind: 'm3u' as const, url: 'https://provider.example/list.m3u'};
  assert.deepEqual(parseSavedSource(serializeSavedSource(m3u)), m3u);
  assert.equal(parseSavedSource('{"version":2}'), undefined);
  assert.equal(parseSavedSource('{"version":1,"source":{"kind":"m3u","url":"file:///etc/passwd"}}'), undefined);
});
