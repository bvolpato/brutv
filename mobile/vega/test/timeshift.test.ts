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

test('recording advances without a playback consumer and serves the latest segment from disk', async () => {
  const {store, recorder, setManifest} = fixture();
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
    const uri = manifest.trim().split('\n').pop()!;
    const read = await recorder.response(uri);
    assert.deepEqual([...read.data], [1, 2, 3, 4, 5]);
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

test('recording refuses unknown, oversized and compressed downloads before allocating the body', async () => {
  for (const headers of [new Headers(), new Headers({'content-length': String(DVR_LIMITS.manifestBytes + 1)}),
    new Headers({'content-length': '10', 'content-encoding': 'gzip'})]) {
    let reads = 0;
    const recorder = new HlsRecorder(new FakeStore(), 'https://provider.test/live.m3u8', 'bounded', async () =>
      ({ok: true, headers, arrayBuffer: async () => {reads++; return new ArrayBuffer(10);}} as Response));
    await assert.rejects(recorder.start(), RecordingUnavailable);
    await recorder.close();
    assert.equal(reads, 0);
  }
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
  assert.throws(() => decodeBytes('malformed='), RecordingUnavailable);
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
