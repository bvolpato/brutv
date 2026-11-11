import assert from 'node:assert/strict';
import test from 'node:test';
import {MediaAdapter, MediaElement, PlaybackPosition, PlaybackSession, PlaybackStatus, PlaybackTimeline} from '../src/media/PlaybackSession';
import {RecordingFallback} from '../src/media/RecordingFallback';
import {SystemMediaSession} from '../src/media/SystemMediaSession';

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

test('explicit pause and play are idempotent and preserve pause requested during initialization', async () => {
  const media = new FakeMedia();
  let initialize!: () => void;
  media.initializeGate = new Promise(resolve => {initialize = resolve;});
  const session = new PlaybackSession(media, () => ({load: async () => {}, destroy: async () => {}}), () => {});
  session.surfaceCreated('screen');
  const started = session.start('https://example.test/video.mp4');
  await session.pause(); await session.pause();
  initialize(); await started;
  assert.equal(media.plays, 0);
  assert.equal(media.paused, true);
  await session.play(); await session.play();
  assert.equal(media.plays, 1);
  await session.pause(); await session.pause();
  assert.equal(media.paused, true);
  media.paused = false;
  await session.pause();
  assert.equal(media.paused, true);
  await session.close();
});

test('system media controls expose the real seek window, preserve paused seek and clear exited sessions', async () => {
  const media = new FakeMedia();
  const range: PlaybackTimeline = {start: 20, end: 100, live: true, liveTarget: 95};
  const session = new PlaybackSession(media, () => ({load: async () => {}, destroy: async () => {}, timeline: () => range}), () => {});
  session.surfaceCreated('screen'); await session.start('https://example.test/live.m3u8');
  media.currentTime = 50;
  let states: unknown[] = [];
  let exits = 0;
  const controls = new SystemMediaSession(session, {id: 'live:1', kind: 'live', name: 'Channel', group: ''}, () => {exits++;},
    {updateMediaSessionStates: value => {states = value;}});
  controls.update('playing', {...range, position: 50, paused: false, expired: false});
  const [state] = await controls.handler.handleGetSessionState();
  assert.equal(state.playbackState.playbackStatus, 'PLAYING');
  assert.equal(state.mediaInfo?.seekRangeStart?.seconds, 20);
  assert.equal(state.mediaInfo?.duration, undefined);
  assert.equal(state.capabilities.actions.some(action => action.name === 'SEEK'), true);
  await controls.handler.handlePause();
  await controls.handler.handleSeek({seconds: 73, nanoseconds: 500000000});
  assert.equal(media.currentTime, 73.5);
  assert.equal(media.paused, true);
  await assert.rejects(controls.handler.handleSeek({seconds: 101, nanoseconds: 0}), {name: 'SeekOutOfRangeError'});
  await assert.rejects(controls.handler.handleSeek({seconds: 25, nanoseconds: -1}), {name: 'InvalidArgumentError'});
  await assert.rejects(controls.handler.handlePlay({id: 9}), {name: 'InvalidStateError'});
  await assert.rejects(controls.handler.handleNext(), {name: 'NotAllowedError'});
  await controls.handler.handleStop();
  assert.equal(exits, 1); assert.equal(media.releases, 1); assert.deepEqual(states, []);
  assert.deepEqual(await controls.handler.handleGetSessionState(), []);
  await assert.rejects(controls.handler.handlePlay(), {name: 'InvalidStateError'});
});

test('a failed system state update does not prevent decoder release or restart closed playback', async () => {
  const media = new FakeMedia();
  const session = new PlaybackSession(media, () => ({load: async () => {}, destroy: async () => {}}), () => {});
  await session.start('https://example.test/video.mp4');
  const controls = new SystemMediaSession(session, {id: 'movie:1', kind: 'movie', name: 'Movie', group: ''}, () => {},
    {updateMediaSessionStates: () => {throw new Error('Service stopped');}});
  controls.update('playing');
  await controls.handler.handleStop();
  assert.equal(media.releases, 1);
  await assert.rejects(controls.handler.handlePlay(), {name: 'InvalidStateError'});
});

test('live seek uses the finite adapter range, preserves pause and Go live resumes at normal holdback', async () => {
  const media = new FakeMedia(); media.duration = Infinity;
  const range: PlaybackTimeline = {start: 40, end: 100, live: true, liveTarget: 96, recording: true};
  const session = new PlaybackSession(media, () => ({load: async () => {}, destroy: async () => {}, timeline: () => range}), () => {});
  session.surfaceCreated('screen'); await session.start('https://provider.test/live.m3u8');
  media.currentTime = 80;
  await session.toggle(); assert.equal(media.paused, true);
  session.seek(-100); assert.equal(media.currentTime, 40); assert.equal(media.paused, true);
  session.seek(100); assert.equal(media.currentTime, 100); assert.equal(media.paused, true);
  await session.goLive(); assert.equal(media.currentTime, 96); assert.equal(media.paused, false);
  await session.close();
});

test('a paused retry reloads content without resuming playback', async () => {
  const media = new FakeMedia(); media.duration = Infinity;
  let loads = 0;
  const session = new PlaybackSession(media, () => ({load: async () => {loads++;}, destroy: async () => {},
    timeline: () => ({start: 20, end: 100, live: true, liveTarget: 95})}), () => {});
  session.surfaceCreated('screen'); await session.start('https://provider.test/live.m3u8');
  media.currentTime = 70; await session.toggle();
  const plays = media.plays; media.emit('error');
  await new Promise(resolve => setTimeout(resolve, 1100));
  assert.equal(loads, 2); assert.equal(media.plays, plays); assert.equal(media.paused, true); assert.equal(media.currentTime, 70);
  await session.close();
});

test('expired pause moves to the saved window start with visible feedback and stays paused', async () => {
  const media = new FakeMedia(); media.duration = Infinity;
  const range: PlaybackTimeline = {start: 20, end: 100, live: true, liveTarget: 95};
  let reported: PlaybackPosition | undefined;
  const session = new PlaybackSession(media, () => ({load: async () => {}, destroy: async () => {}, timeline: () => range}),
    () => {}, value => {reported = value;});
  session.surfaceCreated('screen'); await session.start('https://provider.test/live.m3u8');
  media.currentTime = 30; await session.toggle();
  range.start = 45; media.emit('timeupdate');
  assert.equal(media.currentTime, 45); assert.equal(media.paused, true); assert.equal(reported?.expired, true);
  await session.toggle(); assert.equal(media.currentTime, 45); assert.equal(media.paused, false);
  await session.close();
});

test('retry remaps a paused content anchor when loading the retained manifest rebases player time', async () => {
  const media = new FakeMedia(); media.duration = Infinity;
  let loads = 0;
  let origin = 100;
  const session = new PlaybackSession(media, () => ({load: async () => {if (++loads > 1) origin = 120;},
    destroy: async () => {}, timeline: () => ({start: 0, end: 60, live: true, liveTarget: 56, recordingOrigin: origin})}), () => {});
  session.surfaceCreated('screen'); await session.start('https://provider.test/live.m3u8');
  media.currentTime = 40; await session.toggle(); media.emit('error');
  await new Promise(resolve => setTimeout(resolve, 1100));
  assert.equal(origin + media.currentTime, 140);
  assert.equal(media.currentTime, 20); assert.equal(media.paused, true);
  await session.close();
});

test('an incompatible recording closes before loading the original source and never reopens on retry', async () => {
  const fallback = new RecordingFallback();
  const calls: string[] = [];
  let directAttempts = 0;
  const recorded = async () => {calls.push('recorded'); throw new Error('Unsupported rendition codec');};
  const release = async () => {calls.push('closed');};
  const original = async () => {calls.push('original'); if (++directAttempts === 1) throw new Error('Provider connection failed');};
  await assert.rejects(fallback.load(recorded, release, original), /Provider connection failed/);
  await fallback.load(recorded, release, original);
  assert.deepEqual(calls, ['recorded', 'closed', 'original', 'original']);
  assert.equal(fallback.disabled, true); assert.equal(fallback.request(), false);
});

test('a critical recorded-media failure falls back once while keeping a paused viewer paused', async () => {
  const media = new FakeMedia(); media.duration = Infinity;
  const fallback = new RecordingFallback();
  let recordedLoads = 0; let directLoads = 0; let closed = 0; let failure!: () => void;
  const session = new PlaybackSession(media, onError => {
    failure = onError;
    return {load: () => fallback.load(async () => {recordedLoads++;}, async () => {closed++;}, async () => {directLoads++;}),
      destroy: async () => {}, timeline: () => ({start: 0, end: 100, live: true, liveTarget: 95})};
  }, () => {});
  session.surfaceCreated('screen'); await session.start('https://provider.test/master.m3u8');
  media.currentTime = 40; await session.toggle(); const plays = media.plays;
  assert.equal(fallback.request(), true); failure();
  await new Promise(resolve => setTimeout(resolve, 1100));
  assert.equal(recordedLoads, 1); assert.equal(directLoads, 1); assert.equal(closed, 1);
  assert.equal(media.plays, plays); assert.equal(media.paused, true); assert.equal(media.currentTime, 40);
  await session.close();
});
