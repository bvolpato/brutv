import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp, readFile, readdir, rm, unlink, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {cleanStaleRecordings, decodeBytes, DVR_LIMITS, encodeBytes, HlsRecorder, masterVariant, parseMediaPlaylist, RecordingUnavailable, TempStore} from '../src/media/HlsRecorder';
import {MediaElement, PlaybackSession} from '../src/media/PlaybackSession';

class FakeStore implements TempStore {
  files = new Map<string, string>();
  maxBytes = 0;
  reads = 0;
  writeGate = Promise.resolve();
  async entries() {return [...this.files.keys()];}
  async write(name: string, content: string) {
    await this.writeGate;
    this.files.set(name, content);
    this.maxBytes = Math.max(this.maxBytes, [...this.files.values()].reduce((sum, value) => sum + value.length, 0));
  }
  async read(name: string) {this.reads++; const value = this.files.get(name); if (value === undefined) throw new Error('Missing file'); return value;}
  async remove(name: string) {this.files.delete(name);}
}
function playlist(first: number, count = 3, extra = ''): string {
  return `#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:${first}\n${extra}` +
    Array.from({length: count}, (_, index) => `#EXTINF:2,\nsegment-${first + index}.ts\n`).join('');
}
function response(value: string | Uint8Array, url: string, headers: Record<string, string> = {}): Response {
  const bytes = typeof value === 'string' ? new TextEncoder().encode(value) : value;
  return {ok: true, url, headers: new Headers({'content-length': String(bytes.length), ...headers}),
    arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)} as Response;
}
function fixture(limits = DVR_LIMITS) {
  const store = new FakeStore();
  let manifest = playlist(10);
  const requests: string[] = [];
  const recorder = new HlsRecorder(store, 'https://provider.test/live.m3u8?password=private', 'session1', async input => {
    const url = String(input); requests.push(url);
    return response(url.includes('.m3u8') ? manifest : new Uint8Array([1, 2, 3, 4, 5]), url);
  }, limits);
  return {store, recorder, requests, setManifest(value: string) {manifest = value;}};
}

test('recording advances without a playback consumer, serves live-edge from memory ring and older segments from disk', async () => {
  const {store, recorder, setManifest} = fixture({...DVR_LIMITS, memorySegments: 2});
  try {
    await recorder.start();
    setManifest(playlist(11));
    await new Promise(resolve => setTimeout(resolve, 1100));
    assert.equal(recorder.info.recording, true);
    assert.equal(recorder.info.seconds, 8);
    const manifest = recorder.manifest();
    assert.match(manifest, /#EXT-X-MEDIA-SEQUENCE:10/);
    assert.equal(manifest.includes('provider.test'), false);
    assert.equal(manifest.includes('private'), false);
    const segmentURIs = manifest.trim().split('\n').filter(line => line.startsWith('brutv-timeshift:'));
    // Latest segment hits in-memory Uint8Array tail ring with 0 disk reads.
    const latest = await recorder.response(segmentURIs[segmentURIs.length - 1]);
    assert.deepEqual([...latest.data], [1, 2, 3, 4, 5]);
    assert.equal(store.reads, 0);
    // Older segment evicted from the 2-segment RAM ring falls back to disk read.
    const oldest = await recorder.response(segmentURIs[0]);
    assert.deepEqual([...oldest.data], [1, 2, 3, 4, 5]);
    assert.equal(store.reads, 1);
    assert.ok(store.files.size > 0);
    assert.ok([...store.files.values()].every(value => !value.includes('provider.test')));
  } finally {await recorder.close();}
  assert.equal(store.files.size, 0);
});

test('time retention deletes old files and refuses reads of expired segments', async () => {
  const {store, recorder, setManifest} = fixture({...DVR_LIMITS, seconds: 6});
  try {
    await recorder.start();
    const expiredURI = recorder.manifest().split('\n').find(line => line.startsWith('brutv-timeshift:'))!;
    setManifest(playlist(12)); await recorder.refresh();
    assert.equal(recorder.info.seconds, 6);
    assert.equal(store.files.size, 3);
    assert.match(recorder.manifest(), /#EXT-X-MEDIA-SEQUENCE:12/);
    assert.equal((await recorder.response(recorder.manifestURL)).origin, 4);
    await assert.rejects(recorder.response(expiredURI), /expired/);
  } finally {await recorder.close();}
});

test('generated target covers retained and incoming durations when the provider changes its declaration', async () => {
  const {recorder, setManifest} = fixture();
  try {
    setManifest(playlist(0).replace('TARGETDURATION:2', 'TARGETDURATION:8').replace(/#EXTINF:2,/g, '#EXTINF:7.25,'));
    await recorder.start();
    assert.match(recorder.manifest(), /#EXT-X-TARGETDURATION:8/);
    setManifest(playlist(2)); await recorder.refresh();
    assert.match(recorder.manifest(), /#EXT-X-TARGETDURATION:8/);
    assert.match(recorder.manifest(), /#EXTINF:7.25,/);
    setManifest(playlist(4).replace('TARGETDURATION:2', 'TARGETDURATION:3').replace(/#EXTINF:2,/g, '#EXTINF:9.1,'));
    await recorder.refresh();
    assert.match(recorder.manifest(), /#EXT-X-TARGETDURATION:10/);
    setManifest(playlist(6)); await recorder.refresh();
    assert.match(recorder.manifest(), /#EXT-X-TARGETDURATION:10/);
    assert.equal(recorder.info.recording, true);
  } finally {await recorder.close();}
});

test('encoded bytes, including a retained fMP4 initialization segment, never exceed the disk cap', async () => {
  const {store, recorder, setManifest} = fixture({...DVR_LIMITS, bytes: 24});
  try {
    setManifest(playlist(10, 3, '#EXT-X-MAP:URI="init.mp4"\n'));
    await recorder.start();
    assert.equal(recorder.info.bytes, 24);
    assert.equal(store.files.size, 3);
    setManifest(playlist(13, 3, '#EXT-X-MAP:URI="init.mp4"\n')); await recorder.refresh();
    assert.ok(store.maxBytes <= 24);
    assert.equal(recorder.info.bytes, 24);
    assert.match(recorder.manifest(), /#EXT-X-MAP:URI="brutv-timeshift:\/\/session1\/brutv-timeshift-session1-0.b64.mp4"/);
  } finally {await recorder.close();}
  assert.equal(store.files.size, 0);
});

test('a failed storage eviction stops recording before writing beyond the cap', async () => {
  const {store, recorder, setManifest} = fixture({...DVR_LIMITS, bytes: 8});
  const remove = store.remove.bind(store);
  let blocked = false;
  store.remove = async name => {if (blocked) throw new Error('Storage unavailable'); await remove(name);};
  try {
    setManifest(playlist(10, 1)); await recorder.start();
    blocked = true; setManifest(playlist(11, 1)); await recorder.refresh();
    assert.equal(recorder.info.recording, false);
    assert.match(recorder.info.message!, /could not reclaim/);
    await recorder.refresh();
    assert.equal(store.files.size, 1); assert.equal(store.maxBytes, 8);
  } finally {blocked = false; await recorder.close();}
});

test('recording refuses oversized and compressed downloads before allocating the body and bounds chunked responses', async () => {
  for (const headers of [
    new Headers({'content-length': String(DVR_LIMITS.manifestBytes + 1)}),
    new Headers({'content-length': '10', 'content-encoding': 'gzip'}),
  ]) {
    let reads = 0;
    const recorder = new HlsRecorder(new FakeStore(), 'https://provider.test/live.m3u8', 'bounded', async () =>
      ({ok: true, headers, arrayBuffer: async () => {reads++; return new ArrayBuffer(10);}} as Response));
    await assert.rejects(recorder.start(), RecordingUnavailable);
    await recorder.close();
    assert.equal(reads, 0);
  }

  // Chunked response (no Content-Length) within cap succeeds.
  const store = new FakeStore();
  const chunkedRecorder = new HlsRecorder(store, 'https://provider.test/live.m3u8', 'chunkedok', async input => {
    const url = String(input);
    const bytes = url.includes('.m3u8') ? new TextEncoder().encode(playlist(10, 2)) : new Uint8Array([9, 8, 7]);
    return {ok: true, url, headers: new Headers(), arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)} as Response;
  });
  try {
    await chunkedRecorder.start();
    assert.equal(chunkedRecorder.info.recording, true);
    assert.equal(store.files.size, 2);
  } finally {await chunkedRecorder.close();}

  // Oversized chunked response is rejected without writing to disk.
  const overflowStore = new FakeStore();
  const overflowRecorder = new HlsRecorder(overflowStore, 'https://provider.test/live.m3u8', 'chunkedbig', async () =>
    ({ok: true, headers: new Headers(), arrayBuffer: async () => new ArrayBuffer(128)} as Response),
    {...DVR_LIMITS, manifestBytes: 64});
  await assert.rejects(overflowRecorder.start(), RecordingUnavailable);
  await overflowRecorder.close();
  assert.equal(overflowStore.files.size, 0);
});

test('closing during a disk write waits, removes the late file, and prevents rescheduling', async () => {
  const {store, recorder} = fixture();
  let release!: () => void;
  store.writeGate = new Promise(resolve => {release = resolve;});
  const started = recorder.start();
  await new Promise(resolve => setTimeout(resolve, 10));
  const closing = recorder.close(); release();
  await assert.rejects(started, /closed/); await closing;
  assert.equal(store.files.size, 0);
  assert.equal(recorder.info.recording, false);
  await recorder.refresh();
  assert.equal(store.files.size, 0);
});

test('closing cancels an in-flight provider request without leaving temporary files', async () => {
  const store = new FakeStore();
  let aborted = false;
  const recorder = new HlsRecorder(store, 'https://provider.test/live.m3u8', 'cancel', (_input, options) =>
    new Promise((_resolve, reject) => options!.signal!.addEventListener('abort', () => {aborted = true; reject(new Error('aborted'));})));
  const started = recorder.start();
  const closing = recorder.close();
  await assert.rejects(started, /aborted/); await closing;
  assert.equal(aborted, true);
  assert.equal(store.files.size, 0);
});

test('small provider gaps preserve media sequence and discontinuity identity without fabricating media files', async () => {
  const {store, recorder, setManifest} = fixture();
  try {
    await recorder.start();
    setManifest(playlist(15, 2, '#EXT-X-DISCONTINUITY-SEQUENCE:1\n'));
    await recorder.refresh();
    assert.match(recorder.manifest(), /#EXT-X-GAP\n#EXT-X-PROGRAM-DATE-TIME:[^\n]+\n#EXTINF:2,\nbrutv-timeshift:\/\/session1\/gap-13.ts/);
    assert.match(recorder.manifest(), /#EXT-X-DISCONTINUITY\n#EXT-X-PROGRAM-DATE-TIME/);
    assert.equal(store.files.size, 5);
    assert.equal(recorder.info.seconds, 10);
  } finally {await recorder.close();}
});

test('unsupported encryption, byte ranges, separate renditions and changing initialization fail closed', async () => {
  for (const extra of ['#EXT-X-KEY:METHOD=AES-128,URI="key"\n', '#EXT-X-BYTERANGE:100@0\n', '#EXT-X-ENDLIST\n']) {
    assert.throws(() => parseMediaPlaylist(playlist(0, 3, extra), 'https://provider.test/live.m3u8'), RecordingUnavailable);
  }
  assert.throws(() => masterVariant('#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="a.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="a"\nv.m3u8', 'https://provider.test/master.m3u8'), RecordingUnavailable);
  const {recorder, setManifest} = fixture();
  try {
    setManifest(playlist(10, 3, '#EXT-X-MAP:URI="init.mp4"\n')); await recorder.start();
    setManifest(playlist(11, 3, '#EXT-X-MAP:URI="new-init.mp4"\n')); await recorder.refresh();
    assert.equal(recorder.info.recording, false);
    assert.match(recorder.info.message!, /Changing HLS initialization/);
  } finally {await recorder.close();}
});

test('binary disk encoding round-trips byte values and rejects corrupted encoding', () => {
  for (const length of [0, 1, 2, 3, 255, 16385]) {
    const bytes = Uint8Array.from({length}, (_, index) => index % 256);
    assert.deepEqual(decodeBytes(encodeBytes(bytes)), bytes);
  }
  for (const bad of ['malformed=', 'AA=A', 'A=AA', '====', 'AAA!', 'AAA\u0100', 'AA==AAAA']) {
    assert.throws(() => decodeBytes(bad), RecordingUnavailable);
  }
});

test('HLS playlist resolves relative, absolute-path, parent, and port+@ segment URLs via RFC 3986', () => {
  const text = '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:1\n#EXTINF:4,\nseg1.ts\n#EXTINF:4,\n/abs/seg2.ts\n#EXTINF:4,\n../seg3.ts\n';
  const parsed = parseMediaPlaylist(text, 'https://host.example:8080/live/user@domain/p/42.m3u8?token=abc');
  assert.deepEqual(parsed.segments.map(s => s.url), [
    'https://host.example:8080/live/user@domain/p/seg1.ts',
    'https://host.example:8080/abs/seg2.ts',
    'https://host.example:8080/live/user@domain/seg3.ts',
  ]);
});

test('startup downloads only the latest 3 segments of a deeper live playlist', async () => {
  const store = new FakeStore();
  const downloaded: string[] = [];
  const recorder = new HlsRecorder(store, 'https://provider.test/live.m3u8', 'faststart', async input => {
    const url = String(input);
    if (url.endsWith('.ts')) downloaded.push(url);
    return response(url.includes('.m3u8') ? playlist(10, 6) : new Uint8Array([1, 2, 3]), url);
  });
  try {
    await recorder.start();
    assert.deepEqual(downloaded, [
      'https://provider.test/segment-13.ts',
      'https://provider.test/segment-14.ts',
      'https://provider.test/segment-15.ts',
    ]);
  } finally {await recorder.close();}
});

test('expired 302 edge URL resets to originalURL and re-resolves a fresh edge', async () => {
  const store = new FakeStore();
  let generation = 1;
  let edge1Expired = false;
  const requests: string[] = [];
  const recorder = new HlsRecorder(store, 'https://entry.example/live.m3u8', 'edge', async input => {
    const url = String(input);
    requests.push(url);
    if (url === 'https://entry.example/live.m3u8') {
      return new Response('', {status: 302, headers: {Location: `https://edge${generation}.example/stream.m3u8`}});
    }
    if (url === 'https://edge1.example/stream.m3u8') {
      if (edge1Expired) return new Response('', {status: 403});
      return response(playlist(10, 2), url);
    }
    if (url === 'https://edge2.example/stream.m3u8') {
      return response(playlist(11, 2), url);
    }
    return response(new Uint8Array([4, 5, 6]), url);
  });
  try {
    await recorder.start();
    assert.equal(recorder.info.recording, true);
    edge1Expired = true;
    generation = 2;
    // First refresh hits expired edge1 (403) and resets mediaURL to originalURL.
    await recorder.refresh();
    assert.equal(recorder.info.recording, true);
    assert.match(recorder.info.message!, /Reconnecting/);
    // Next refresh re-requests entry.example, redirects to edge2, and recovers.
    await recorder.refresh();
    assert.equal(recorder.info.recording, true);
    assert.equal(recorder.info.message, undefined);
    assert.ok(requests.includes('https://edge2.example/stream.m3u8'));
  } finally {await recorder.close();}
});

test('frozen live playlist with unchanging media sequence resets mediaURL and escalates failure', async () => {
  const store = new FakeStore();
  let clock = 1000;
  let entryHits = 0;
  const recorder = new HlsRecorder(
    store,
    'https://entry.example/live.m3u8',
    'stale',
    async input => {
      const url = String(input);
      if (url === 'https://entry.example/live.m3u8') {
        entryHits++;
        return new Response('', {status: 302, headers: {Location: 'https://edge.example/live.m3u8'}});
      }
      return response(url.includes('.m3u8') ? playlist(10, 2) : new Uint8Array([1, 2]), url);
    },
    DVR_LIMITS,
    () => {},
    () => clock,
  );
  try {
    await recorder.start();
    assert.equal(entryHits, 1);
    // Still within stale window: stays healthy.
    clock += 5_000;
    await recorder.refresh();
    assert.equal(recorder.info.recording, true);
    assert.equal(recorder.info.message, undefined);
    // Past stale window (>= 20s) without advancing sequence: escalates and resets to originalURL.
    clock += 20_000;
    await recorder.refresh();
    assert.match(recorder.info.message!, /Reconnecting/);
    await recorder.refresh();
    assert.equal(entryHits, 2);
    await recorder.refresh();
    assert.equal(recorder.info.recording, false);
    assert.match(recorder.info.message!, /repeated provider errors/);
  } finally {await recorder.close();}
});

test('startup removes only owned temporary recording files', async () => {
  const store = new FakeStore();
  store.files.set('brutv-timeshift-stale-0.b64', 'AAAA');
  store.files.set('other-app-file', 'keep');
  store.files.set('brutv-timeshift-not/a/file.b64', 'keep');
  await cleanStaleRecordings(store);
  assert.deepEqual([...store.files.keys()], ['other-app-file', 'brutv-timeshift-not/a/file.b64']);
});

test('paused playback continues recording actual temporary disk files and can rewind or resume live', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'brutv-vega-dvr-'));
  const store: TempStore = {
    entries: () => readdir(directory),
    write: (name, value) => writeFile(join(directory, name), value, 'utf8'),
    read: name => readFile(join(directory, name), 'utf8'),
    remove: name => unlink(join(directory, name)),
  };
  let manifest = playlist(0);
  const recorder = new HlsRecorder(store, 'https://provider.test/live.m3u8', 'disk', async input =>
    response(String(input).includes('.m3u8') ? manifest : new Uint8Array([0, 128, 255]), String(input)));
  const media: MediaElement = {
    currentTime: 0, duration: Infinity, paused: true,
    initialize: async () => {}, deinitialize: async () => {},
    async play() {media.paused = false;}, pause() {media.paused = true;},
    setSurfaceHandle: () => {}, clearSurfaceHandle: () => {}, addEventListener: () => {}, removeEventListener: () => {},
  };
  const session = new PlaybackSession(media, () => ({load: () => recorder.start(), destroy: () => recorder.close(),
    timeline: () => ({start: 0, end: recorder.info.seconds, live: true, liveTarget: recorder.info.seconds - 2, recording: recorder.info.recording})}), () => {});
  try {
    session.surfaceCreated('screen'); await session.start('https://provider.test/live.m3u8');
    media.currentTime = 4; await session.toggle();
    manifest = playlist(1); await recorder.refresh();
    assert.equal(media.paused, true); assert.equal(media.currentTime, 4);
    assert.equal((await readdir(directory)).length, 4);
    const latestURI = recorder.manifest().trim().split('\n').pop()!;
    assert.deepEqual([...(await recorder.response(latestURI)).data], [0, 128, 255]);
    session.seek(-10); assert.equal(media.currentTime, 0); assert.equal(media.paused, true);
    await session.goLive(); assert.equal(media.currentTime, 6); assert.equal(media.paused, false);
  } finally {await session.close(); await recorder.close();}
  assert.deepEqual(await readdir(directory), []);
  await rm(directory, {recursive: true});
});

test('playlist parser accepts fractional target duration and short ad-splice EXTINF durations', () => {
  const text = '#EXTM3U\n#EXT-X-TARGETDURATION:4.5\n#EXT-X-MEDIA-SEQUENCE:7\n#EXTINF:0.12,\nsplice.ts\n#EXTINF:4.4,\nmain.ts\n';
  const parsed = parseMediaPlaylist(text, 'https://provider.test/live.m3u8');
  assert.equal(parsed.target, 5);
  assert.equal(parsed.segments.length, 2);
  assert.equal(parsed.segments[0].duration, 0.12);
  assert.equal(parsed.segments[1].duration, 4.4);
});

test('masterVariant strips UTF-8 BOM and skips blank or comment lines before variant URI', () => {
  const master = '\uFEFF#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2500000\n\n# variant comment\nlow/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=5000000\n#EXT-X-INDEPENDENT-SEGMENTS\nhigh/index.m3u8\n';
  assert.equal(masterVariant(master, 'https://provider.test/master.m3u8'), 'https://provider.test/high/index.m3u8');

  const broken = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2500000\n#EXT-X-STREAM-INF:BANDWIDTH=5000000\nhigh/index.m3u8\n';
  assert.throws(() => masterVariant(broken, 'https://provider.test/master.m3u8'), RecordingUnavailable);
});

test('recorder tolerates small CDN edge sequence skew, sends no-cache header, and caps startup download duration', async () => {
  const store = new FakeStore();
  let manifest = '#EXTM3U\n#EXT-X-TARGETDURATION:8\n#EXT-X-MEDIA-SEQUENCE:20\n#EXTINF:8,\nseg-20.ts\n#EXTINF:8,\nseg-21.ts\n#EXTINF:8,\nseg-22.ts\n';
  const downloadedSegments: string[] = [];
  const cacheControlHeaders: (string | undefined)[] = [];
  const recorder = new HlsRecorder(store, 'https://provider.test/live.m3u8', 'skew', async (input, init) => {
    const url = String(input);
    const headers = init?.headers as Record<string, string> | undefined;
    cacheControlHeaders.push(headers?.['Cache-Control']);
    if (url.endsWith('.ts')) downloadedSegments.push(url);
    return response(url.includes('.m3u8') ? manifest : new Uint8Array([1, 2, 3]), url);
  });
  try {
    await recorder.start();
    // 8s segments exceed 6s startup cap, so only the latest 1 segment is fetched at startup.
    assert.deepEqual(downloadedSegments, ['https://provider.test/seg-22.ts']);
    assert.ok(cacheControlHeaders.length >= 2);
    assert.ok(cacheControlHeaders.every(value => value === 'no-cache'));

    // Edge responds 2 segments behind (last sequence 20 vs 22): must stay healthy without throwing.
    manifest = '#EXTM3U\n#EXT-X-TARGETDURATION:8\n#EXT-X-MEDIA-SEQUENCE:18\n#EXTINF:8,\nseg-18.ts\n#EXTINF:8,\nseg-19.ts\n#EXTINF:8,\nseg-20.ts\n';
    await recorder.refresh();
    assert.equal(recorder.info.recording, true);
    assert.equal(recorder.info.message, undefined);

    // Next refresh catches up and ingests new segment 23.
    manifest = '#EXTM3U\n#EXT-X-TARGETDURATION:8\n#EXT-X-MEDIA-SEQUENCE:21\n#EXTINF:8,\nseg-21.ts\n#EXTINF:8,\nseg-22.ts\n#EXTINF:8,\nseg-23.ts\n';
    await recorder.refresh();
    assert.equal(recorder.info.recording, true);
    assert.deepEqual(downloadedSegments, ['https://provider.test/seg-22.ts', 'https://provider.test/seg-23.ts']);

    // Large timeline restart (> 3 segments behind) still fails closed.
    manifest = '#EXTM3U\n#EXT-X-TARGETDURATION:8\n#EXT-X-MEDIA-SEQUENCE:1\n#EXTINF:8,\nseg-1.ts\n#EXTINF:8,\nseg-2.ts\n';
    await recorder.refresh();
    assert.equal(recorder.info.recording, false);
    assert.match(recorder.info.message!, /restarted its live timeline/);
  } finally {await recorder.close();}
});

test('session directory mode stores under brutv-ts-<token>/ and cleans up in a single removeDir call', async () => {
  const dirsRemoved: string[] = [];
  const filesRemoved: string[] = [];
  const files = new Map<string, string>();
  const dirStore: TempStore = {
    entries: async () => ['brutv-ts-stale99', 'brutv-timeshift-old-0.b64', 'other-file'],
    write: async (name, value) => { files.set(name, value); },
    read: async name => { const v = files.get(name); if (v === undefined) throw new Error('missing'); return v; },
    remove: async name => { filesRemoved.push(name); files.delete(name); },
    removeDir: async name => {
      dirsRemoved.push(name);
      for (const key of [...files.keys()]) {
        if (key.startsWith(`${name}/`)) files.delete(key);
      }
    },
  };

  await cleanStaleRecordings(dirStore);
  assert.deepEqual(dirsRemoved, ['brutv-ts-stale99']);
  assert.deepEqual(filesRemoved, ['brutv-timeshift-old-0.b64']);

  dirsRemoved.length = 0;
  filesRemoved.length = 0;
  const recorder = new HlsRecorder(dirStore, 'https://provider.test/live.m3u8', 'sess42', async input => {
    const url = String(input);
    return response(url.includes('.m3u8') ? playlist(10, 3) : new Uint8Array([7, 8, 9]), url);
  });
  await recorder.start();
  assert.ok([...files.keys()].every(key => key.startsWith('brutv-ts-sess42/')));
  // Manifest lines are cached stably across repeated polls.
  assert.equal(recorder.manifest(), recorder.manifest());
  await recorder.close();
  assert.deepEqual(dirsRemoved, ['brutv-ts-sess42']);
  assert.equal(filesRemoved.length, 0);
  assert.equal(files.size, 0);
});
