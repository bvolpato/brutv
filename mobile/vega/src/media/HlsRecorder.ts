import {resilientFetch} from '../domain/http';
import {httpURL, resolveURL} from '../domain/login';

export const DVR_LIMITS = {
  seconds: 600,
  bytes: 256 * 1024 * 1024,
  segmentBytes: 8 * 1024 * 1024,
  manifestBytes: 1024 * 1024,
  memorySegments: 8,
  memoryBytes: 16 * 1024 * 1024,
};

const FILE_PREFIX = 'brutv-timeshift-';
const SESSION_DIR_PREFIX = 'brutv-ts-';

export interface TempStore {
  entries(): Promise<string[]>;
  write(name: string, value: string): Promise<void>;
  read(name: string): Promise<string>;
  remove(name: string): Promise<void>;
  removeDir?(name: string): Promise<void>;
}

export class RecordingUnavailable extends Error {}
export interface RecordedInfo {recording: boolean; seconds: number; bytes: number; message?: string}

type Segment = {sequence: number; duration: number; url: string; discontinuity: number; gap: boolean};
type Playlist = {target: number; segments: Segment[]; init?: string; independent: boolean};
type StoredSegment = Omit<Segment, 'url'> & {
  file?: string;
  bytes: number;
  start: number;
  pdtLine: string;
  extinfLine: string;
  uriLine: string;
};
type Limits = {
  seconds: number;
  bytes: number;
  segmentBytes: number;
  manifestBytes: number;
  memorySegments?: number;
  memoryBytes?: number;
};

function attributes(value: string): Map<string, string> {
  const result = new Map<string, string>();
  const pattern = /([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))(?:,|$)/g;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(value))) result.set(match[1], match[2] ?? match[3]);
  return result;
}
function sourceURL(value: string, base: string): string {return httpURL(resolveURL(value, base)).href;}
function number(value: string | undefined, fallback: number): number {
  const parsed = value === undefined ? fallback : Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new RecordingUnavailable('This HLS sequence is not supported for live rewind.');
  return parsed;
}

export function parseMediaPlaylist(text: string, base: string): Playlist {
  const lines = text.replace(/^\uFEFF/, '').trim().split(/\r?\n/).map(line => line.trim());
  if (lines[0] !== '#EXTM3U') throw new RecordingUnavailable('Live rewind requires an HLS playlist.');
  if (lines.some(line => /^#EXT-X-(ENDLIST|PLAYLIST-TYPE|BYTERANGE|I-FRAMES-ONLY|PART:|PRELOAD-HINT|SKIP:|SESSION-KEY)/.test(line))) {
    throw new RecordingUnavailable('This HLS format is not supported for live rewind.');
  }
  let sequence = number(lines.find(line => line.startsWith('#EXT-X-MEDIA-SEQUENCE:'))?.split(':')[1], 0);
  let discontinuity = number(lines.find(line => line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE:'))?.split(':')[1], 0);
  const rawTarget = lines.find(line => line.startsWith('#EXT-X-TARGETDURATION:'))?.split(':')[1];
  const parsedTarget = rawTarget === undefined ? NaN : Number(rawTarget.trim());
  if (!Number.isFinite(parsedTarget) || parsedTarget <= 0 || parsedTarget > 120) {
    throw new RecordingUnavailable('This HLS segment duration is not supported for live rewind.');
  }
  const target = Math.ceil(parsedTarget);
  const segments: Segment[] = [];
  let duration: number | undefined;
  let init: string | undefined;
  let gap = false;
  for (const line of lines) {
    if (line.startsWith('#EXT-X-KEY:') && attributes(line.slice(11)).get('METHOD') !== 'NONE') {
      throw new RecordingUnavailable('Encrypted streams play directly without local live rewind.');
    }
    if (line.startsWith('#EXT-X-MAP:')) {
      const attrs = attributes(line.slice(11));
      if (!attrs.get('URI') || attrs.has('BYTERANGE')) throw new RecordingUnavailable('This HLS initialization format is not supported for live rewind.');
      const next = sourceURL(attrs.get('URI')!, base);
      if (init && init !== next) throw new RecordingUnavailable('Changing HLS initialization is not supported for live rewind.');
      init = next;
    } else if (line === '#EXT-X-DISCONTINUITY') discontinuity++;
    else if (line === '#EXT-X-GAP') gap = true;
    else if (line.startsWith('#EXTINF:')) {
      duration = Number(line.slice(8).split(',')[0].trim());
      if (!Number.isFinite(duration) || duration <= 0 || duration > 120) throw new RecordingUnavailable('This HLS segment duration is not supported for live rewind.');
    } else if (line && !line.startsWith('#')) {
      if (duration === undefined) throw new RecordingUnavailable('This HLS playlist has an incomplete segment.');
      if (!Number.isSafeInteger(sequence)) throw new RecordingUnavailable('This HLS sequence is not supported for live rewind.');
      segments.push({sequence: sequence++, duration, url: sourceURL(line, base), discontinuity, gap});
      duration = undefined; gap = false;
    }
  }
  if (!segments.length || segments.length > 1200 || duration !== undefined) throw new RecordingUnavailable('This HLS playlist cannot provide a bounded live buffer.');
  return {target, segments, init, independent: lines.includes('#EXT-X-INDEPENDENT-SEGMENTS')};
}

export function masterVariant(text: string, base: string): string | undefined {
  const lines = text.replace(/^\uFEFF/, '').trim().split(/\r?\n/).map(line => line.trim());
  if (lines.some(line => line.startsWith('#EXT-X-SESSION-KEY:'))) throw new RecordingUnavailable('Encrypted streams play directly without local live rewind.');
  if (lines.some(line => line.startsWith('#EXT-X-MEDIA:') && attributes(line.slice(13)).has('URI'))) {
    throw new RecordingUnavailable('Separate HLS audio or subtitle renditions play directly without local live rewind.');
  }
  const variants: {url: string; bandwidth: number}[] = [];
  for (let index = 0; index < lines.length; index++) if (lines[index].startsWith('#EXT-X-STREAM-INF:')) {
    const attrs = attributes(lines[index].slice(18));
    if (attrs.has('AUDIO') || attrs.has('SUBTITLES') || attrs.has('VIDEO')) throw new RecordingUnavailable('Separate HLS renditions play directly without local live rewind.');
    let uri: string | undefined;
    for (let next = index + 1; next < lines.length; next++) {
      const candidate = lines[next];
      if (!candidate) continue;
      if (candidate.startsWith('#EXT-X-STREAM-INF:')) break;
      if (candidate.startsWith('#')) continue;
      uri = candidate;
      index = next;
      break;
    }
    const bandwidth = Number(attrs.get('BANDWIDTH'));
    if (!uri || !Number.isFinite(bandwidth) || bandwidth <= 0) throw new RecordingUnavailable('This HLS master playlist is not supported for live rewind.');
    variants.push({url: sourceURL(uri, base), bandwidth});
  }
  if (!variants.length) return undefined;
  variants.sort((left, right) => left.bandwidth - right.bandwidth);
  return (variants.filter(variant => variant.bandwidth <= 8_000_000).pop() || variants[0]).url;
}

const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const encodeCodes = Uint8Array.from(alphabet, ch => ch.charCodeAt(0));
const decodeTable = new Uint8Array(256).fill(255);
for (let i = 0; i < alphabet.length; i++) decodeTable[alphabet.charCodeAt(i)] = i;

export function encodeBytes(bytes: Uint8Array): string {
  const len = bytes.length;
  if (len === 0) return '';
  const chunks: string[] = [];
  const block: number[] = new Array(4096);
  let pos = 0;
  for (let index = 0; index < len; index += 3) {
    const has1 = index + 1 < len;
    const has2 = index + 2 < len;
    const value = (bytes[index] << 16) | ((has1 ? bytes[index + 1] : 0) << 8) | (has2 ? bytes[index + 2] : 0);
    block[pos++] = encodeCodes[(value >>> 18) & 63];
    block[pos++] = encodeCodes[(value >>> 12) & 63];
    block[pos++] = has1 ? encodeCodes[(value >>> 6) & 63] : 61;
    block[pos++] = has2 ? encodeCodes[value & 63] : 61;
    if (pos === 4096) {
      chunks.push(String.fromCharCode.apply(null, block));
      pos = 0;
    }
  }
  if (pos > 0) chunks.push(String.fromCharCode.apply(null, block.slice(0, pos)));
  return chunks.join('');
}

export function decodeBytes(value: string): Uint8Array {
  const len = value.length;
  if (len === 0) return new Uint8Array(0);
  if ((len & 3) !== 0) throw new RecordingUnavailable('The temporary live buffer could not be read.');
  const pad1 = value.charCodeAt(len - 1) === 61;
  const pad2 = value.charCodeAt(len - 2) === 61;
  if (pad2 && !pad1) throw new RecordingUnavailable('The temporary live buffer could not be read.');
  const padding = (pad1 ? 1 : 0) + (pad2 ? 1 : 0);
  const bytes = new Uint8Array((len >>> 2) * 3 - padding);
  const limit = padding > 0 ? len - 4 : len;
  let output = 0;

  for (let index = 0; index < limit; index += 4) {
    const c0 = value.charCodeAt(index);
    const c1 = value.charCodeAt(index + 1);
    const c2 = value.charCodeAt(index + 2);
    const c3 = value.charCodeAt(index + 3);
    if ((c0 | c1 | c2 | c3) > 255) throw new RecordingUnavailable('The temporary live buffer could not be read.');
    const v0 = decodeTable[c0];
    const v1 = decodeTable[c1];
    const v2 = decodeTable[c2];
    const v3 = decodeTable[c3];
    if (((v0 | v1 | v2 | v3) & 0x80) !== 0) throw new RecordingUnavailable('The temporary live buffer could not be read.');
    const bits = (v0 << 18) | (v1 << 12) | (v2 << 6) | v3;
    bytes[output++] = (bits >>> 16) & 255;
    bytes[output++] = (bits >>> 8) & 255;
    bytes[output++] = bits & 255;
  }

  if (padding > 0) {
    const c0 = value.charCodeAt(limit);
    const c1 = value.charCodeAt(limit + 1);
    if ((c0 | c1) > 255) throw new RecordingUnavailable('The temporary live buffer could not be read.');
    const v0 = decodeTable[c0];
    const v1 = decodeTable[c1];
    if (((v0 | v1) & 0x80) !== 0) throw new RecordingUnavailable('The temporary live buffer could not be read.');
    if (padding === 2) {
      bytes[output++] = ((v0 << 2) | (v1 >>> 4)) & 255;
    } else {
      const c2 = value.charCodeAt(limit + 2);
      if (c2 > 255) throw new RecordingUnavailable('The temporary live buffer could not be read.');
      const v2 = decodeTable[c2];
      if ((v2 & 0x80) !== 0) throw new RecordingUnavailable('The temporary live buffer could not be read.');
      bytes[output++] = ((v0 << 2) | (v1 >>> 4)) & 255;
      bytes[output++] = (((v1 & 0x0f) << 4) | (v2 >>> 2)) & 255;
    }
  }
  return bytes;
}

function encodeAsciiBytes(text: string): Uint8Array {
  const out = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    out[i] = text.charCodeAt(i) & 0xff;
  }
  return out;
}

export async function cleanStaleRecordings(store: TempStore): Promise<void> {
  for (const name of await store.entries()) {
    if (/^brutv-ts-[a-z0-9]+$/.test(name) && store.removeDir) {
      await store.removeDir(name);
    } else if (/^brutv-timeshift-[a-z0-9]+-[a-z0-9]+\.b64$/.test(name)) {
      await store.remove(name);
    }
  }
}

export class HlsRecorder {
  readonly manifestURL: string;
  private readonly originalURL: string;
  private readonly sessionDir?: string;
  private readonly maxMemorySegments: number;
  private readonly maxMemoryBytes: number;
  private segments: StoredSegment[] = [];
  private target = 0;
  private pollInterval = 1000;
  private independent = false;
  private initURL?: string;
  private initFile?: string;
  private initBytes?: Uint8Array;
  private files = new Set<string>();
  private memoryCache = new Map<string, Uint8Array>();
  private memoryBytes = 0;
  private bytes = 0;
  private closed = false;
  private started = false;
  private timer?: ReturnType<typeof setTimeout>;
  private active?: Promise<void>;
  private transfers = new Set<AbortController>();
  private mediaURL: string;
  private nextFile = 0;
  private lastSequence?: number;
  private lastDiscontinuity = 0;
  private lastAdvanceAt: number;
  private failures = 0;
  private recording = false;
  private message?: string;
  private readTail = Promise.resolve();
  private queuedReads = 0;
  private nextStart = 0;
  private epoch: number;

  constructor(private store: TempStore, url: string, readonly token: string,
    private fetcher: typeof fetch = fetch, private limits: Limits = DVR_LIMITS,
    private report: (info: RecordedInfo) => void = () => {},
    private now: () => number = Date.now) {
    if (!/^[a-z0-9]+$/.test(token)) throw new Error('Invalid live-buffer session token.');
    this.originalURL = httpURL(url).href;
    this.mediaURL = this.originalURL;
    this.manifestURL = `brutv-timeshift://${token}/live.m3u8`;
    this.sessionDir = store.removeDir ? `${SESSION_DIR_PREFIX}${token}` : undefined;
    this.maxMemorySegments = limits.memorySegments ?? DVR_LIMITS.memorySegments;
    this.maxMemoryBytes = limits.memoryBytes ?? DVR_LIMITS.memoryBytes;
    this.epoch = this.now() / 1000;
    this.lastAdvanceAt = this.now();
  }

  async start(): Promise<void> {
    if (this.closed) return;
    if (this.started) {await this.active; return;}
    this.started = true;
    this.active = this.startRecording();
    try {await this.active;} finally {this.active = undefined;}
  }

  private async fetchMediaPlaylist(): Promise<{text: string; url: string}> {
    let text = '';
    for (let depth = 0; depth < 3; depth++) {
      const response = await this.download(this.mediaURL, this.limits.manifestBytes);
      this.mediaURL = response.url;
      text = new TextDecoder().decode(response.bytes);
      const variant = masterVariant(text, this.mediaURL);
      if (!variant) return {text, url: this.mediaURL};
      if (depth === 2) throw new RecordingUnavailable('Nested HLS masters are not supported for live rewind.');
      this.mediaURL = variant;
    }
    throw new RecordingUnavailable('Nested HLS masters are not supported for live rewind.');
  }

  private selectStartupSegments(segments: Segment[]): Segment[] {
    const selected: Segment[] = [];
    let totalSeconds = 0;
    for (let index = segments.length - 1; index >= 0 && selected.length < 3; index--) {
      const segment = segments[index];
      if (selected.length > 0 && totalSeconds + segment.duration > 6) break;
      selected.push(segment);
      totalSeconds += segment.duration;
    }
    return selected.reverse();
  }

  private async startRecording(): Promise<void> {
    const {text, url} = await this.fetchMediaPlaylist();
    const playlist = parseMediaPlaylist(text, url);
    playlist.segments = this.selectStartupSegments(playlist.segments);
    this.epoch -= playlist.segments.reduce((sum, segment) => sum + segment.duration, 0);
    await this.ingest(playlist);
    if (this.closed) return;
    this.lastAdvanceAt = this.now();
    this.recording = true; this.publish(); this.schedule();
  }

  private async download(url: string, cap: number): Promise<{bytes: Uint8Array; url: string}> {
    const controller = new AbortController();
    this.transfers.add(controller);
    const timeout = setTimeout(() => controller.abort(), 15_000);
    try {
      const {response, url: finalURL} = await resilientFetch(url, {
        fetcher: this.fetcher,
        signal: controller.signal,
        headers: {'Accept-Encoding': 'identity', 'Cache-Control': 'no-cache'},
        maxRetries: 2,
        baseDelayMs: 300,
        maxDelayMs: 3000,
        now: this.now,
      });
      if (this.closed) throw new Error('Live buffer closed.');
      if (!response.ok) {controller.abort(); throw new Error('Live buffer provider request failed.');}
      const encoding = response.headers.get('content-encoding');
      if (encoding && encoding.toLowerCase() !== 'identity') {
        controller.abort();
        throw new RecordingUnavailable('This provider does not supply bounded downloads for live rewind.');
      }
      const header = response.headers.get('content-length');
      let declaredLength: number | undefined;
      if (header !== null && header !== '') {
        const parsed = /^\d+$/.test(header.trim()) ? Number(header.trim()) : NaN;
        if (!Number.isSafeInteger(parsed) || parsed <= 0 || parsed > cap) {
          controller.abort();
          throw new RecordingUnavailable('This provider does not supply bounded downloads for live rewind.');
        }
        declaredLength = parsed;
      }
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (this.closed) throw new Error('Live buffer closed.');
      if (bytes.length === 0 || bytes.length > cap || (declaredLength !== undefined && bytes.length !== declaredLength)) {
        throw new RecordingUnavailable('This provider exceeded the live-buffer download limit.');
      }
      return {bytes, url: finalURL};
    } finally {clearTimeout(timeout); this.transfers.delete(controller);}
  }

  private cacheSegmentInMemory(file: string, bytes: Uint8Array): void {
    if (this.maxMemorySegments <= 0 || this.maxMemoryBytes <= 0 || bytes.byteLength > this.maxMemoryBytes) {
      return;
    }
    this.memoryCache.set(file, bytes);
    this.memoryBytes += bytes.byteLength;
    while (this.memoryCache.size > this.maxMemorySegments || this.memoryBytes > this.maxMemoryBytes) {
      const oldest = this.memoryCache.keys().next();
      if (oldest.done) break;
      const evicted = this.memoryCache.get(oldest.value);
      this.memoryCache.delete(oldest.value);
      if (evicted) this.memoryBytes -= evicted.byteLength;
    }
  }

  private evictFromMemory(file: string): void {
    const cached = this.memoryCache.get(file);
    if (cached) {
      this.memoryCache.delete(file);
      this.memoryBytes -= cached.byteLength;
    }
  }

  private allocateFileName(): string {
    const index = (this.nextFile++).toString(36);
    return this.sessionDir ? `${this.sessionDir}/${index}.b64` : `${FILE_PREFIX}${this.token}-${index}.b64`;
  }

  private async persist(bytes: Uint8Array, isInit = false): Promise<{file: string; bytes: number}> {
    const size = 4 * Math.ceil(bytes.length / 3);
    if (size > this.limits.bytes) throw new RecordingUnavailable('This stream exceeds the temporary live-buffer size limit.');
    await this.trim(size, 0);
    const file = this.allocateFileName();
    this.files.add(file);
    try {await this.store.write(file, encodeBytes(bytes));} catch {
      await this.removeFile(file).catch(() => {});
      throw new RecordingUnavailable('Temporary storage is unavailable for live rewind.');
    }
    if (this.closed) {await this.removeFile(file); throw new Error('Live buffer closed.');}
    this.bytes += size;
    if (isInit) {
      this.initBytes = bytes;
    } else {
      this.cacheSegmentInMemory(file, bytes);
    }
    return {file, bytes: size};
  }

  private async removeFile(file: string): Promise<void> {
    this.evictFromMemory(file);
    await this.store.remove(file);
    this.files.delete(file);
  }

  private async trim(incomingBytes: number, incomingSeconds: number): Promise<void> {
    let seconds = this.segments.reduce((sum, segment) => sum + segment.duration, 0);
    while (this.segments.length && (this.bytes + incomingBytes > this.limits.bytes || seconds + incomingSeconds > this.limits.seconds ||
      (incomingSeconds > 0 && this.segments.length >= 1200))) {
      const first = this.segments[0];
      if (first.file) try {await this.removeFile(first.file);} catch {
        throw new RecordingUnavailable('Temporary storage could not reclaim the live buffer.');
      }
      this.segments.shift(); this.bytes -= first.bytes; seconds -= first.duration;
    }
    if (this.bytes + incomingBytes > this.limits.bytes) throw new RecordingUnavailable('The temporary live buffer reached its storage limit.');
  }

  private buildSegmentEntry(
    sequence: number,
    duration: number,
    discontinuity: number,
    gap: boolean,
    start: number,
    bytes: number,
    file?: string,
  ): StoredSegment {
    const ext = this.initFile ? 'm4s' : 'ts';
    return {
      sequence,
      duration,
      discontinuity,
      gap,
      start,
      bytes,
      file,
      pdtLine: `#EXT-X-PROGRAM-DATE-TIME:${new Date((this.epoch + start) * 1000).toISOString()}`,
      extinfLine: `#EXTINF:${duration},`,
      uriLine: `brutv-timeshift://${this.token}/${file || `gap-${sequence}`}.${ext}`,
    };
  }

  private async ingest(playlist: Playlist): Promise<boolean> {
    if (this.closed) return false;
    const longestSegment = playlist.segments.reduce((longest, segment) => Math.max(longest, Math.ceil(segment.duration)), 0);
    this.target = Math.max(this.target, playlist.target, longestSegment);
    this.pollInterval = Math.min(5000, Math.max(1000, playlist.target * 500));
    this.independent = playlist.independent;
    if (playlist.init !== this.initURL && this.lastSequence !== undefined) throw new RecordingUnavailable('Changing HLS initialization is not supported for live rewind.');
    if (playlist.init && !this.initFile) {
      const init = await this.download(playlist.init, this.limits.segmentBytes);
      const stored = await this.persist(init.bytes, true);
      this.initURL = playlist.init; this.initFile = stored.file;
    }
    const last = playlist.segments[playlist.segments.length - 1];
    if (this.lastSequence !== undefined && last.sequence < this.lastSequence) {
      if (this.lastSequence - last.sequence <= 3) return false;
      throw new RecordingUnavailable('The provider restarted its live timeline. Live rewind is unavailable for this session.');
    }
    let advanced = false;
    for (const segment of playlist.segments) {
      if (this.closed) return advanced;
      if (this.lastSequence !== undefined && segment.sequence <= this.lastSequence) continue;
      if (segment.discontinuity < this.lastDiscontinuity) throw new RecordingUnavailable('The provider reset its HLS discontinuity timeline. Live rewind is unavailable for this session.');
      const missing = this.lastSequence === undefined ? 0 : segment.sequence - this.lastSequence - 1;
      if (missing > 64) throw new RecordingUnavailable('The provider skipped too much live content to maintain a rewind buffer.');
      for (let offset = 0; offset < missing; offset++) {
        await this.trim(0, this.target);
        const gapSeq = this.lastSequence! + 1;
        this.segments.push(this.buildSegmentEntry(gapSeq, this.target, this.lastDiscontinuity, true, this.nextStart, 0));
        this.nextStart += this.target;
        this.lastSequence = gapSeq;
      }
      await this.trim(0, segment.duration);
      const stored = segment.gap ? {bytes: 0, file: undefined} : await this.persist((await this.download(segment.url, this.limits.segmentBytes)).bytes);
      if (this.closed) return advanced;
      this.segments.push(this.buildSegmentEntry(
        segment.sequence,
        segment.duration,
        segment.discontinuity,
        segment.gap,
        this.nextStart,
        stored.bytes,
        stored.file,
      ));
      this.nextStart += segment.duration;
      this.lastSequence = segment.sequence; this.lastDiscontinuity = segment.discontinuity;
      advanced = true;
    }
    if (!this.segments.some(segment => !segment.gap)) throw new RecordingUnavailable('No playable content is available in the live buffer.');
    return advanced;
  }

  private schedule(): void {
    if (this.closed || !this.recording) return;
    const delay = this.failures > 0 ? Math.min(8000, this.pollInterval * (this.failures + 1)) : this.pollInterval;
    this.timer = setTimeout(() => {void this.refresh().finally(() => this.schedule());}, delay);
  }

  async refresh(): Promise<void> {
    if (this.closed || !this.recording) return;
    if (this.active) return this.active;
    this.active = (async () => {
      try {
        const {text, url} = await this.fetchMediaPlaylist();
        const advanced = await this.ingest(parseMediaPlaylist(text, url));
        if (advanced) {
          this.lastAdvanceAt = this.now();
          this.failures = 0;
          this.message = undefined;
        } else {
          const staleLimit = Math.max(20_000, this.target * 3_000);
          if (this.now() - this.lastAdvanceAt >= staleLimit) {
            this.mediaURL = this.originalURL;
            throw new Error('Live playlist stopped advancing.');
          }
        }
      } catch (error) {
        if (this.closed) return;
        this.mediaURL = this.originalURL;
        if (error instanceof RecordingUnavailable || ++this.failures >= 3) {
          this.recording = false;
          this.message = error instanceof RecordingUnavailable ? error.message : 'Live recording stopped after repeated provider errors. Reopen the channel to reconnect.';
        } else this.message = 'Reconnecting the live buffer. Saved content is still available.';
      } finally {if (!this.closed) this.publish();}
    })();
    try {await this.active;} finally {this.active = undefined;}
  }

  get info(): RecordedInfo {
    return {recording: this.recording, seconds: this.segments.reduce((sum, segment) => sum + (segment.gap ? 0 : segment.duration), 0), bytes: this.bytes, message: this.message};
  }
  private publish(): void {this.report(this.info);}
  get timelineOrigin(): number {return this.segments[0]?.start || 0;}

  manifest(): string {
    if (this.closed || !this.segments.length) throw new Error('Live buffer unavailable.');
    const first = this.segments[0];
    const lines = [
      '#EXTM3U',
      '#EXT-X-VERSION:7',
      `#EXT-X-TARGETDURATION:${this.target}`,
      `#EXT-X-MEDIA-SEQUENCE:${first.sequence}`,
      `#EXT-X-DISCONTINUITY-SEQUENCE:${first.discontinuity}`,
    ];
    if (this.independent) lines.push('#EXT-X-INDEPENDENT-SEGMENTS');
    if (this.initFile) lines.push(`#EXT-X-MAP:URI="brutv-timeshift://${this.token}/${this.initFile}.mp4"`);
    let discontinuity = first.discontinuity;
    for (let index = 0; index < this.segments.length; index++) {
      const segment = this.segments[index];
      for (; discontinuity < segment.discontinuity; discontinuity++) lines.push('#EXT-X-DISCONTINUITY');
      if (segment.gap) lines.push('#EXT-X-GAP');
      lines.push(segment.pdtLine, segment.extinfLine, segment.uriLine);
    }
    return lines.join('\n') + '\n';
  }

  async response(uri: string, cancelled: () => boolean = () => false): Promise<{data: Uint8Array; mime: string; origin?: number}> {
    if (this.closed || !uri.startsWith(`brutv-timeshift://${this.token}/`)) throw new Error('Live buffer unavailable.');
    if (uri === this.manifestURL) {
      const manifest = this.manifest();
      return {data: encodeAsciiBytes(manifest), mime: 'application/x-mpegurl', origin: this.timelineOrigin};
    }
    const name = uri.slice(`brutv-timeshift://${this.token}/`.length).replace(/\.(?:ts|m4s|mp4)$/, '');
    if (!this.files.has(name)) throw new Error('This part of the live buffer has expired.');
    if (this.initFile && name === this.initFile && this.initBytes) {
      return {data: this.initBytes, mime: 'video/mp4'};
    }
    const cached = this.memoryCache.get(name);
    if (cached) {
      return {data: cached, mime: this.initFile ? 'video/mp4' : 'video/mp2t'};
    }
    if (this.queuedReads >= 8) throw new Error('Too many pending live-buffer reads.');
    const previous = this.readTail;
    let release!: () => void;
    this.readTail = new Promise(resolve => {release = resolve;});
    this.queuedReads++;
    await previous;
    try {
      if (this.closed || cancelled()) throw new Error('Live-buffer request cancelled.');
      if (!this.files.has(name)) throw new Error('This part of the live buffer has expired.');
      const contents = await this.store.read(name);
      if (this.closed || cancelled()) throw new Error('Live-buffer request cancelled.');
      if (contents.length > 4 * Math.ceil(this.limits.segmentBytes / 3)) throw new Error('Invalid temporary live-buffer file.');
      return {data: decodeBytes(contents), mime: this.initFile ? 'video/mp4' : 'video/mp2t'};
    } finally {this.queuedReads--; release();}
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true; this.recording = false;
    if (this.timer) clearTimeout(this.timer);
    for (const transfer of this.transfers) transfer.abort();
    await this.active?.catch(() => {});
    await this.readTail;
    let failure: unknown;
    this.memoryCache.clear();
    this.memoryBytes = 0;
    this.initBytes = undefined;
    if (this.sessionDir && this.store.removeDir) {
      try {
        await this.store.removeDir(this.sessionDir);
        this.files.clear();
      } catch (error) {
        failure = error;
      }
    } else {
      for (const file of this.files) try {await this.removeFile(file);} catch (error) {failure = error;}
    }
    this.segments = []; this.bytes = 0;
    if (failure) throw failure;
  }
}
