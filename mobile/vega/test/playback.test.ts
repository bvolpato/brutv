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
  await session.close();
  assert.equal(media.releases, 1);
  initialized(); await start;
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

test('initial start failure recovers through bounded retry with surface attached and position updates active', async () => {
  const media = new FakeMedia();
  let loads = 0;
  let positionReports = 0;
  const states: PlaybackStatus[] = [];
  const session = new PlaybackSession(
    media,
    () => ({
      load: async () => {
        loads++;
        if (loads === 1) throw new Error('transient start failure');
      },
      destroy: async () => {},
      timeline: () => ({start: 0, end: 100, live: false}),
    }),
    state => states.push(state),
    () => { positionReports++; },
    {retryDelaysMs: [10, 20, 40, 80, 150], watchdogIntervalMs: 15},
  );
  session.surfaceCreated('screen');
  await session.start('https://example.test/video.m3u8');
  assert.equal(loads, 1);
  assert.equal(media.handles.length, 0);
  await new Promise(resolve => setTimeout(resolve, 40));
  assert.equal(loads, 2);
  assert.deepEqual(media.handles, ['screen']);
  assert.equal(media.plays, 1);
  assert.ok(positionReports >= 1);
  assert.ok(!states.includes('error'));
  await session.close();
});

test('stalled event and buffering watchdog trigger recovery without resetting timer on repeated stalls', async () => {
  const media = new FakeMedia();
  let loads = 0;
  let clock = 1000;
  const states: PlaybackStatus[] = [];
  const session = new PlaybackSession(
    media,
    () => ({load: async () => { loads++; }, destroy: async () => {}, timeline: () => ({start: 0, end: 100, live: true, liveTarget: 95})}),
    state => states.push(state),
    () => {},
    {live: true, bufferingTimeoutMs: 18_000, retryDelaysMs: [10, 20, 40, 80, 150], watchdogIntervalMs: 10, now: () => clock},
  );
  session.surfaceCreated('screen');
  await session.start('https://example.test/live.m3u8');
  media.emit('playing');
  media.emit('stalled');
  assert.equal(states[states.length - 1], 'buffering');
  clock += 10_000;
  media.emit('waiting');
  clock += 8_500;
  await new Promise(resolve => setTimeout(resolve, 40));
  assert.equal(loads, 2);
  await session.close();
});

test('frozen playhead watchdog recovers live and VOD streams while respecting paused state', async () => {
  const media = new FakeMedia();
  media.duration = Infinity;
  let loads = 0;
  let clock = 0;
  const session = new PlaybackSession(
    media,
    () => ({load: async () => { loads++; }, destroy: async () => {}, timeline: () => ({start: 0, end: 100, live: true, liveTarget: 95})}),
    () => {},
    () => {},
    {live: true, liveStallTimeoutMs: 10_000, vodStallTimeoutMs: 15_000, retryDelaysMs: [10, 20], watchdogIntervalMs: 10, now: () => clock},
  );
  session.surfaceCreated('screen');
  await session.start('https://example.test/live.m3u8');
  media.currentTime = 50;
  media.emit('playing');
  // Freeze playhead while playing.
  clock += 10_500;
  await new Promise(resolve => setTimeout(resolve, 40));
  assert.equal(loads, 2);

  // Pause must not trigger watchdog recovery even after long idle.
  await session.pause();
  clock += 60_000;
  await new Promise(resolve => setTimeout(resolve, 35));
  assert.equal(loads, 2);
  await session.close();
});

test('live ended event triggers recovery whereas VOD ended stays ended', async () => {
  const liveMedia = new FakeMedia();
  liveMedia.duration = Infinity;
  let liveLoads = 0;
  const liveStates: PlaybackStatus[] = [];
  const liveSession = new PlaybackSession(
    liveMedia,
    () => ({load: async () => { liveLoads++; }, destroy: async () => {}, timeline: () => ({start: 0, end: 100, live: true, liveTarget: 95})}),
    state => liveStates.push(state),
    () => {},
    {live: true, retryDelaysMs: [10]},
  );
  liveSession.surfaceCreated('screen');
  await liveSession.start('https://example.test/live.m3u8');
  liveMedia.emit('ended');
  await new Promise(resolve => setTimeout(resolve, 35));
  assert.equal(liveLoads, 2);
  assert.ok(!liveStates.includes('ended'));
  await liveSession.close();

  const vodMedia = new FakeMedia();
  const vodStates: PlaybackStatus[] = [];
  const vodSession = new PlaybackSession(
    vodMedia,
    () => ({load: async () => {}, destroy: async () => {}, timeline: () => ({start: 0, end: 100, live: false})}),
    state => vodStates.push(state),
    () => {},
    {live: false, retryDelaysMs: [10]},
  );
  vodSession.surfaceCreated('screen');
  await vodSession.start('https://example.test/movie.mp4');
  vodMedia.emit('ended');
  assert.equal(vodStates[vodStates.length - 1], 'ended');
  await vodSession.close();
});

test('retry budget enforces 5 attempts and resets only after sustained advancing playback', async () => {
  const media = new FakeMedia();
  let loads = 0;
  let clock = 0;
  const states: PlaybackStatus[] = [];
  const session = new PlaybackSession(
    media,
    () => ({load: async () => { loads++; }, destroy: async () => {}}),
    state => states.push(state),
    () => {},
    {retryDelaysMs: [5, 5, 5, 5, 5], healthyPlaybackMs: 30_000, now: () => clock},
  );
  session.surfaceCreated('screen');
  await session.start('https://example.test/live.m3u8');
  assert.equal(loads, 1);

  // 5 errors with fleeting playing events (< 30s) must NOT reset retry budget.
  for (let i = 0; i < 5; i++) {
    media.emit('error');
    await new Promise(resolve => setTimeout(resolve, 20));
    media.emit('playing');
    media.currentTime += 1;
    clock += 1000;
    media.emit('timeupdate');
  }
  assert.equal(loads, 6);
  // 6th error exhausts the 5-retry budget -> terminal error.
  media.emit('error');
  assert.equal(states[states.length - 1], 'error');
  await session.close();

  // Sustained >= 30s advancing playback DOES reset retry budget.
  const media2 = new FakeMedia();
  let loads2 = 0;
  let clock2 = 0;
  const states2: PlaybackStatus[] = [];
  const session2 = new PlaybackSession(
    media2,
    () => ({load: async () => { loads2++; }, destroy: async () => {}}),
    state => states2.push(state),
    () => {},
    {retryDelaysMs: [5, 5, 5, 5, 5], healthyPlaybackMs: 30_000, now: () => clock2},
  );
  session2.surfaceCreated('screen');
  await session2.start('https://example.test/live.m3u8');
  for (let i = 0; i < 4; i++) {
    media2.emit('error');
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.equal(loads2, 5);
  media2.emit('playing');
  clock2 += 31_000;
  media2.currentTime += 31;
  media2.emit('timeupdate');
  // Budget was reset; 2 more errors must still recover without reaching 'error'.
  for (let i = 0; i < 2; i++) {
    media2.emit('error');
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.equal(loads2, 7);
  assert.ok(!states2.includes('error'));
  await session2.close();
});

test('SystemMediaSession skips redundant IPC updates during smooth playback and publishes material changes', async () => {
  const media = new FakeMedia();
  const session = new PlaybackSession(media, () => ({load: async () => {}, destroy: async () => {}}), () => {});
  await session.start('https://example.test/movie.mp4');
  let clock = 10_000;
  let publishes = 0;
  const controls = new SystemMediaSession(
    session,
    {id: 'movie:1', kind: 'movie', name: 'Movie', group: ''},
    () => {},
    {updateMediaSessionStates: () => { publishes++; }},
    () => clock,
  );
  // Simulate 4Hz smooth playback for 5 seconds -> only initial publish should fire.
  for (let i = 0; i < 20; i++) {
    controls.update('playing', {start: 0, end: 100, live: false, position: 10 + i * 0.25, paused: false, expired: false});
    clock += 250;
  }
  assert.equal(publishes, 1);
  // Seek jump (+20s) publishes immediately.
  controls.update('playing', {start: 0, end: 100, live: false, position: 35, paused: false, expired: false});
  assert.equal(publishes, 2);
  // Status transition publishes immediately.
  controls.update('paused', {start: 0, end: 100, live: false, position: 35, paused: true, expired: false});
  assert.equal(publishes, 3);
  controls.close();
  await session.close();
});

test('backward live playhead discontinuity rebases watchdog without triggering false stall', async () => {
  const media = new FakeMedia();
  let clock = 0;
  let loads = 0;
  const session = new PlaybackSession(
    media,
    () => ({load: async () => { loads++; }, destroy: async () => {}}),
    () => {},
    () => {},
    {live: true, liveStallTimeoutMs: 10_000, watchdogIntervalMs: 10, now: () => clock},
  );
  session.surfaceCreated('screen');
  await session.start('https://example.test/live.m3u8');
  media.emit('playing');
  media.currentTime = 100;
  media.emit('timeupdate');
  // Discontinuity moves timeline backward to 5s.
  clock += 2_000;
  media.currentTime = 5;
  media.emit('timeupdate');
  // Subsequent forward progress from 5s -> 15s must not trigger a stall.
  for (let i = 1; i <= 12; i++) {
    clock += 1_000;
    media.currentTime = 5 + i;
    media.emit('timeupdate');
    await new Promise(resolve => setTimeout(resolve, 15));
  }
  assert.equal(loads, 1);
  await session.close();
});

test('retry unloads before backoff and on terminal error while ignoring stale in-flight loads', async () => {
  const media = new FakeMedia();
  const events: string[] = [];
  let releaseFirstLoad!: () => void;
  let loads = 0;
  let clock = 0;
  const states: PlaybackStatus[] = [];
  const session = new PlaybackSession(
    media,
    () => ({
      load: async () => {
        loads++;
        events.push(`load:${loads}`);
        if (loads === 1) {
          await new Promise<void>(resolve => { releaseFirstLoad = resolve; });
          return;
        }
        throw new Error('upstream down');
      },
      unload: async () => { events.push('unload'); },
      destroy: async () => {},
    }),
    state => states.push(state),
    () => {},
    {bufferingTimeoutMs: 24_000, retryDelaysMs: [30], watchdogIntervalMs: 10, now: () => clock},
  );
  session.surfaceCreated('screen');
  const started = session.start('https://example.test/live.m3u8');
  await Promise.resolve();
  await Promise.resolve();
  assert.deepEqual(events, ['load:1']);

  // Trigger buffering timeout -> retry must call unload() immediately BEFORE the 30ms backoff elapses.
  clock += 24_500;
  await new Promise(resolve => setTimeout(resolve, 18));
  assert.deepEqual(events, ['load:1', 'unload']);
  assert.equal(media.paused, true);

  // Stale first load resolving during backoff must be ignored (must not call media.play()).
  releaseFirstLoad();
  await started;
  assert.equal(media.plays, 0);

  // After backoff, retry #1 runs load:2, fails, exhausts budget, calls unload() again, and enters terminal error.
  await new Promise(resolve => setTimeout(resolve, 40));
  assert.deepEqual(events, ['load:1', 'unload', 'load:2', 'unload']);
  assert.equal(states[states.length - 1], 'error');
  assert.equal(media.plays, 0);
  await session.close();
});

test('pausing during retry backoff and pressing play later triggers an immediate reload', async () => {
  const media = new FakeMedia();
  let loads = 0;
  let unloads = 0;
  const states: PlaybackStatus[] = [];
  const session = new PlaybackSession(
    media,
    () => ({
      load: async () => { loads++; },
      unload: async () => { unloads++; },
      destroy: async () => {},
      timeline: () => ({start: 0, end: 100, live: false}),
    }),
    state => states.push(state),
    () => {},
    {retryDelaysMs: [5000]},
  );
  session.surfaceCreated('screen');
  await session.start('https://example.test/movie.mp4');
  media.currentTime = 42;
  assert.equal(loads, 1);
  assert.equal(media.plays, 1);

  media.emit('error');
  assert.equal(unloads, 1);
  assert.equal(states[states.length - 1], 'buffering');

  // Pause cancels the 5s retry timer while adapter remains unloaded.
  await session.pause();
  assert.equal(states[states.length - 1], 'paused');
  assert.equal(loads, 1);

  // Subsequent play must reload immediately instead of calling media.play() on an unloaded adapter.
  await session.play();
  assert.equal(loads, 2);
  assert.equal(media.plays, 2);
  assert.equal(media.currentTime, 42);
  assert.equal(media.paused, false);
  await session.close();
});

test('cumulative healthy playback resets retry budget across brief micro-rebuffers', async () => {
  const media = new FakeMedia();
  let loads = 0;
  let clock = 0;
  const states: PlaybackStatus[] = [];
  const session = new PlaybackSession(
    media,
    () => ({load: async () => { loads++; }, destroy: async () => {}}),
    state => states.push(state),
    () => {},
    {retryDelaysMs: [5, 5, 5], healthyPlaybackMs: 30_000, now: () => clock},
  );
  session.surfaceCreated('screen');
  await session.start('https://example.test/live.m3u8');

  // Use 2 of 3 retries.
  for (let i = 0; i < 2; i++) {
    media.emit('error');
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.equal(loads, 3);

  // Play 31s total split by brief waiting/stalled micro-rebuffers (12s + 10s + 9s).
  media.emit('playing');
  for (let i = 0; i < 12; i++) {
    clock += 1000; media.currentTime += 1; media.emit('timeupdate');
  }
  media.emit('waiting');
  clock += 2000;
  media.emit('playing');
  for (let i = 0; i < 10; i++) {
    clock += 1000; media.currentTime += 1; media.emit('timeupdate');
  }
  media.emit('stalled');
  clock += 1500;
  media.emit('playing');
  for (let i = 0; i < 9; i++) {
    clock += 1000; media.currentTime += 1; media.emit('timeupdate');
  }

  // Retry budget was reset across micro-rebuffers; 2 more errors must recover without hitting 'error'.
  for (let i = 0; i < 2; i++) {
    media.emit('error');
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.equal(loads, 5);
  assert.ok(!states.includes('error'));
  await session.close();
});

test('retry does not resume playback while surface is destroyed and resumes when surface returns', async () => {
  const media = new FakeMedia();
  let loads = 0;
  const session = new PlaybackSession(
    media,
    () => ({load: async () => { loads++; }, destroy: async () => {}}),
    () => {},
    () => {},
    {retryDelaysMs: [15]},
  );
  session.surfaceCreated('screen1');
  await session.start('https://example.test/live.m3u8');
  assert.equal(media.plays, 1);

  media.emit('error');
  session.surfaceDestroyed('screen1');
  await new Promise(resolve => setTimeout(resolve, 35));
  assert.equal(loads, 2);
  assert.equal(media.plays, 1);
  assert.equal(media.paused, true);

  session.surfaceCreated('screen2');
  assert.deepEqual(media.handles, ['screen2']);
  assert.equal(media.plays, 2);
  assert.equal(media.paused, false);
  await session.close();
});
