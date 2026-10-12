import assert from 'node:assert/strict';
import test from 'node:test';
import {MediaAdapter, MediaElement, PlaybackSession, PlaybackStatus} from '../src/media/PlaybackSession';

class FakeMedia implements MediaElement {
  currentTime = 0; duration = 100; paused = true;
  initializes = 0; releases = 0; plays = 0;
  handles: string[] = [];
  listeners = new Map<string, Set<() => void>>();
  initializeGate = Promise.resolve();
  async initialize() { this.initializes++; await this.initializeGate; }
  async deinitialize() { this.releases++; }
  async play() { this.plays++; this.paused = false; }
  pause() { this.paused = true; }
  setSurfaceHandle(handle: string) { this.handles.push(handle); }
  clearSurfaceHandle(handle: string) { this.handles = this.handles.filter(value => value !== handle); }
  addEventListener(event: string, listener: () => void) { const set = this.listeners.get(event) || new Set(); set.add(listener); this.listeners.set(event, set); }
  removeEventListener(event: string, listener: () => void) { this.listeners.get(event)?.delete(listener); }
  emit(event: string) { for (const listener of this.listeners.get(event) || []) listener(); }
}

test('does not start playing before initialize and media load complete', async () => {
  const media = new FakeMedia();
  let loaded!: () => void;
  const load = new Promise<void>(resolve => { loaded = resolve; });
  const adapter: MediaAdapter = {load: async () => load, destroy: async () => {}};
  const session = new PlaybackSession(media, () => adapter, () => {});
  session.surfaceCreated('screen');
  const start = session.start('https://example.test/video.m3u8');
  await Promise.resolve();
  assert.equal(media.plays, 0);
  loaded(); await start;
  assert.equal(media.plays, 1);
  assert.deepEqual(media.handles, ['screen']);
  await session.close();
  assert.equal(media.releases, 1);
  assert.equal([...media.listeners.values()].flatMap(set => [...set]).length, 0);
});

test('closing while initialize is pending releases the player without loading old content', async () => {
  const media = new FakeMedia();
  let initialized!: () => void;
  media.initializeGate = new Promise(resolve => { initialized = resolve; });
  let loads = 0;
  const session = new PlaybackSession(media, () => ({load: async () => { loads++; }, destroy: async () => {}}), () => {});
  const start = session.start('https://example.test/old.m3u8');
  await session.close(); initialized(); await start;
  assert.equal(loads, 0);
  assert.equal(media.plays, 0);
  assert.equal(media.releases, 1);
});

test('closing cancels scheduled retries and suppresses late playback updates', async () => {
  const media = new FakeMedia();
  let loads = 0;
  const states: PlaybackStatus[] = [];
  const session = new PlaybackSession(media, () => ({load: async () => { loads++; }, destroy: async () => {}}), state => states.push(state));
  await session.start('https://example.test/old.m3u8');
  media.emit('error');
  await session.close();
  const snapshot = states.slice();
  media.emit('playing');
  await new Promise(resolve => setTimeout(resolve, 1100));
  assert.equal(loads, 1);
  assert.deepEqual(states, snapshot);
});

test('seek clamps VOD range and skips live infinite-duration streams', async () => {
  const media = new FakeMedia();
  const session = new PlaybackSession(media, () => ({load: async () => {}, destroy: async () => {}}), () => {});
  await session.start('https://example.test/video.mp4');
  session.seek(-10); assert.equal(media.currentTime, 0);
  session.seek(150); assert.equal(media.currentTime, 100);
  media.duration = Infinity; session.seek(-10); assert.equal(media.currentTime, 100);
  await session.close();
});
