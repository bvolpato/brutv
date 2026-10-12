import {httpURL} from '../domain/login';

export const DVR_LIMITS = {seconds: 600, bytes: 256 * 1024 * 1024, segmentBytes: 8 * 1024 * 1024, manifestBytes: 1024 * 1024};
const FILE_PREFIX = 'brutv-timeshift-';

export interface TempStore {
  entries(): Promise<string[]>;
  write(name: string, value: string): Promise<void>;
  read(name: string): Promise<string>;
  remove(name: string): Promise<void>;
}
export class RecordingUnavailable extends Error {}
export interface RecordedInfo {recording: boolean; seconds: number; bytes: number; message?: string}
type Segment = {sequence: number; duration: number; url: string; discontinuity: number; gap: boolean};
type Playlist = {target: number; segments: Segment[]; init?: string; independent: boolean};
type StoredSegment = Omit<Segment, 'url'> & {file?: string; bytes: number; start: number};
type Limits = typeof DVR_LIMITS;

function attributes(value: string): Map<string, string> {
  const result = new Map<string, string>();
  const pattern = /([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))(?:,|$)/g;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(value))) result.set(match[1], match[2] ?? match[3]);
  return result;
}
function sourceURL(value: string, base: string): string {return httpURL(new URL(value, base).href).href;}
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
  const target = number(lines.find(line => line.startsWith('#EXT-X-TARGETDURATION:'))?.split(':')[1], 0);
  if (target < 1 || target > 60) throw new RecordingUnavailable('This HLS segment duration is not supported for live rewind.');
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
      duration = Number(line.slice(8).split(',')[0]);
      if (!Number.isFinite(duration) || duration < 0.25 || duration > 60) throw new RecordingUnavailable('This HLS segment duration is not supported for live rewind.');
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
  const lines = text.trim().split(/\r?\n/).map(line => line.trim());
  if (lines.some(line => line.startsWith('#EXT-X-SESSION-KEY:'))) throw new RecordingUnavailable('Encrypted streams play directly without local live rewind.');
  if (lines.some(line => line.startsWith('#EXT-X-MEDIA:') && attributes(line.slice(13)).has('URI'))) {
    throw new RecordingUnavailable('Separate HLS audio or subtitle renditions play directly without local live rewind.');
  }
  const variants: {url: string; bandwidth: number}[] = [];
  for (let index = 0; index < lines.length; index++) if (lines[index].startsWith('#EXT-X-STREAM-INF:')) {
    const attrs = attributes(lines[index].slice(18));
    if (attrs.has('AUDIO') || attrs.has('SUBTITLES') || attrs.has('VIDEO')) throw new RecordingUnavailable('Separate HLS renditions play directly without local live rewind.');
    const uri = lines[index + 1];
    const bandwidth = Number(attrs.get('BANDWIDTH'));
    if (!uri || uri.startsWith('#') || !Number.isFinite(bandwidth) || bandwidth <= 0) throw new RecordingUnavailable('This HLS master playlist is not supported for live rewind.');
    variants.push({url: sourceURL(uri, base), bandwidth});
  }
  if (!variants.length) return undefined;
  variants.sort((left, right) => left.bandwidth - right.bandwidth);
  return (variants.filter(variant => variant.bandwidth <= 8_000_000).pop() || variants[0]).url;
}

const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
export function encodeBytes(bytes: Uint8Array): string {
  const chunks: string[] = [];
  let chunk = '';
  for (let index = 0; index < bytes.length; index += 3) {
    const value = (bytes[index] << 16) | ((bytes[index + 1] || 0) << 8) | (bytes[index + 2] || 0);
    chunk += alphabet[(value >>> 18) & 63] + alphabet[(value >>> 12) & 63] +
      (index + 1 < bytes.length ? alphabet[(value >>> 6) & 63] : '=') + (index + 2 < bytes.length ? alphabet[value & 63] : '=');
    if (chunk.length >= 8192) {chunks.push(chunk); chunk = '';}
  }
  if (chunk) chunks.push(chunk);
  return chunks.join('');
}
export function decodeBytes(value: string): Uint8Array {
  if (value.length % 4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) throw new RecordingUnavailable('The temporary live buffer could not be read.');
  const padding = value.endsWith('==') ? 2 : value.endsWith('=') ? 1 : 0;
  const bytes = new Uint8Array(value.length / 4 * 3 - padding);
  let output = 0;
  for (let index = 0; index < value.length; index += 4) {
    const bits = (alphabet.indexOf(value[index]) << 18) | (alphabet.indexOf(value[index + 1]) << 12) |
      ((value[index + 2] === '=' ? 0 : alphabet.indexOf(value[index + 2])) << 6) | (value[index + 3] === '=' ? 0 : alphabet.indexOf(value[index + 3]));
    if (output < bytes.length) bytes[output++] = bits >>> 16;
    if (output < bytes.length) bytes[output++] = bits >>> 8;
    if (output < bytes.length) bytes[output++] = bits;
  }
  return bytes;
}

export async function cleanStaleRecordings(store: TempStore): Promise<void> {
  for (const name of await store.entries()) if (/^brutv-timeshift-[a-z0-9]+-[a-z0-9]+\.b64$/.test(name)) await store.remove(name);
}

export class HlsRecorder {
  readonly manifestURL: string;
  private segments: StoredSegment[] = [];
  private target = 0;
  private pollInterval = 1000;
  private independent = false;
  private initURL?: string;
  private initFile?: string;
  private files = new Set<string>();
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
  private failures = 0;
  private recording = false;
  private message?: string;
  private readTail = Promise.resolve();
  private queuedReads = 0;
  private nextStart = 0;
  private epoch = Date.now() / 1000;

  constructor(private store: TempStore, url: string, readonly token: string,
    private fetcher: typeof fetch = fetch, private limits: Limits = DVR_LIMITS,
    private report: (info: RecordedInfo) => void = () => {}) {
    if (!/^[a-z0-9]+$/.test(token)) throw new Error('Invalid live-buffer session token.');
    this.mediaURL = httpURL(url).href;
    this.manifestURL = `brutv-timeshift://${token}/live.m3u8`;
  }

  async start(): Promise<void> {
    if (this.closed) return;
    if (this.started) {await this.active; return;}
    this.started = true;
    this.active = this.startRecording();
    try {await this.active;} finally {this.active = undefined;}
  }
  private async startRecording(): Promise<void> {
    let text = '';
    for (let depth = 0; depth < 3; depth++) {
      const response = await this.download(this.mediaURL, this.limits.manifestBytes);
      this.mediaURL = response.url;
      text = new TextDecoder().decode(response.bytes);
      const variant = masterVariant(text, this.mediaURL);
      if (!variant) break;
      if (depth === 2) throw new RecordingUnavailable('Nested HLS masters are not supported for live rewind.');
      this.mediaURL = variant;
    }
    const playlist = parseMediaPlaylist(text, this.mediaURL);
    playlist.segments = playlist.segments.slice(-6);
    this.epoch -= playlist.segments.reduce((sum, segment) => sum + segment.duration, 0);
    await this.ingest(playlist);
    if (this.closed) return;
    this.recording = true; this.publish(); this.schedule();
  }

  private async download(url: string, cap: number): Promise<{bytes: Uint8Array; url: string}> {
    const controller = new AbortController();
    this.transfers.add(controller);
    const timeout = setTimeout(() => controller.abort(), 15_000);
    try {
      const response = await this.fetcher(url, {signal: controller.signal, headers: {'Accept-Encoding': 'identity'}});
      if (this.closed) throw new Error('Live buffer closed.');
      if (!response.ok) {controller.abort(); throw new Error('Live buffer provider request failed.');}
      // Vega's fetch returns a whole ArrayBuffer. Refuse unknown sizes before allocating it.
      const header = response.headers.get('content-length');
      const encoding = response.headers.get('content-encoding');
      const length = header && /^\d+$/.test(header) ? Number(header) : NaN;
      if (!Number.isSafeInteger(length) || length <= 0 || length > cap || (encoding && encoding !== 'identity')) {
        controller.abort(); throw new RecordingUnavailable('This provider does not supply bounded downloads for live rewind.');
      }
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (this.closed) throw new Error('Live buffer closed.');
      if (bytes.length !== length || bytes.length > cap) throw new RecordingUnavailable('This provider exceeded the live-buffer download limit.');
      return {bytes, url: httpURL(response.url || url).href};
    } finally {clearTimeout(timeout); this.transfers.delete(controller);}
  }

  private async persist(bytes: Uint8Array): Promise<{file: string; bytes: number}> {
    const size = 4 * Math.ceil(bytes.length / 3);
    if (size > this.limits.bytes) throw new RecordingUnavailable('This stream exceeds the temporary live-buffer size limit.');
    await this.trim(size, 0);
    const file = `${FILE_PREFIX}${this.token}-${(this.nextFile++).toString(36)}.b64`;
    this.files.add(file);
    try {await this.store.write(file, encodeBytes(bytes));} catch {
      await this.removeFile(file).catch(() => {});
      throw new RecordingUnavailable('Temporary storage is unavailable for live rewind.');
    }
    if (this.closed) {await this.removeFile(file); throw new Error('Live buffer closed.');}
    this.bytes += size;
    return {file, bytes: size};
  }
  private async removeFile(file: string): Promise<void> {await this.store.remove(file); this.files.delete(file);}
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

  private async ingest(playlist: Playlist): Promise<void> {
    if (this.closed) return;
    const longestSegment = playlist.segments.reduce((longest, segment) => Math.max(longest, Math.ceil(segment.duration)), 0);
    this.target = Math.max(this.target, playlist.target, longestSegment);
    this.pollInterval = Math.min(5000, Math.max(1000, playlist.target * 500));
    this.independent = playlist.independent;
    if (playlist.init !== this.initURL && this.lastSequence !== undefined) throw new RecordingUnavailable('Changing HLS initialization is not supported for live rewind.');
    if (playlist.init && !this.initFile) {
      const init = await this.download(playlist.init, this.limits.segmentBytes);
      const stored = await this.persist(init.bytes);
      this.initURL = playlist.init; this.initFile = stored.file;
    }
    const last = playlist.segments[playlist.segments.length - 1];
    if (this.lastSequence !== undefined && last.sequence < this.lastSequence) throw new RecordingUnavailable('The provider restarted its live timeline. Live rewind is unavailable for this session.');
    for (const segment of playlist.segments) {
      if (this.closed) return;
      if (this.lastSequence !== undefined && segment.sequence <= this.lastSequence) continue;
      if (segment.discontinuity < this.lastDiscontinuity) throw new RecordingUnavailable('The provider reset its HLS discontinuity timeline. Live rewind is unavailable for this session.');
      const missing = this.lastSequence === undefined ? 0 : segment.sequence - this.lastSequence - 1;
      if (missing > 64) throw new RecordingUnavailable('The provider skipped too much live content to maintain a rewind buffer.');
      for (let offset = 0; offset < missing; offset++) {
        await this.trim(0, this.target);
        this.segments.push({sequence: this.lastSequence! + 1, duration: this.target, discontinuity: this.lastDiscontinuity, gap: true, bytes: 0, start: this.nextStart});
        this.nextStart += this.target;
        this.lastSequence = this.lastSequence! + 1;
      }
      await this.trim(0, segment.duration);
      const stored = segment.gap ? {bytes: 0} : await this.persist((await this.download(segment.url, this.limits.segmentBytes)).bytes);
      if (this.closed) return;
      this.segments.push({sequence: segment.sequence, duration: segment.duration, discontinuity: segment.discontinuity, gap: segment.gap, start: this.nextStart, ...stored});
      this.nextStart += segment.duration;
      this.lastSequence = segment.sequence; this.lastDiscontinuity = segment.discontinuity;
    }
    if (!this.segments.some(segment => !segment.gap)) throw new RecordingUnavailable('No playable content is available in the live buffer.');
  }

  private schedule(): void {
    if (this.closed || !this.recording) return;
    this.timer = setTimeout(() => {void this.refresh().finally(() => this.schedule());}, this.pollInterval);
  }
  async refresh(): Promise<void> {
    if (this.closed || !this.recording) return;
    if (this.active) return this.active;
    this.active = (async () => {
      try {
        const response = await this.download(this.mediaURL, this.limits.manifestBytes);
        await this.ingest(parseMediaPlaylist(new TextDecoder().decode(response.bytes), response.url));
        this.failures = 0; this.message = undefined;
      } catch (error) {
        if (this.closed) return;
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
    const lines = ['#EXTM3U', '#EXT-X-VERSION:7', `#EXT-X-TARGETDURATION:${this.target}`, `#EXT-X-MEDIA-SEQUENCE:${first.sequence}`,
      `#EXT-X-DISCONTINUITY-SEQUENCE:${first.discontinuity}`];
    if (this.independent) lines.push('#EXT-X-INDEPENDENT-SEGMENTS');
    if (this.initFile) lines.push(`#EXT-X-MAP:URI="brutv-timeshift://${this.token}/${this.initFile}.mp4"`);
    let discontinuity = first.discontinuity;
    for (const segment of this.segments) {
      for (; discontinuity < segment.discontinuity; discontinuity++) lines.push('#EXT-X-DISCONTINUITY');
      if (segment.gap) lines.push('#EXT-X-GAP');
      lines.push(`#EXT-X-PROGRAM-DATE-TIME:${new Date((this.epoch + segment.start) * 1000).toISOString()}`);
      lines.push(`#EXTINF:${segment.duration},`, `brutv-timeshift://${this.token}/${segment.file || `gap-${segment.sequence}`}.${this.initFile ? 'm4s' : 'ts'}`);
    }
    return lines.join('\n') + '\n';
  }
  async response(uri: string, cancelled: () => boolean = () => false): Promise<{data: Uint8Array; mime: string; origin?: number}> {
    if (this.closed || !uri.startsWith(`brutv-timeshift://${this.token}/`)) throw new Error('Live buffer unavailable.');
    if (uri === this.manifestURL) {
      const manifest = this.manifest();
      return {data: Uint8Array.from(manifest, character => character.charCodeAt(0)), mime: 'application/x-mpegurl', origin: this.timelineOrigin};
    }
    const name = uri.slice(`brutv-timeshift://${this.token}/`.length).replace(/\.(?:ts|m4s|mp4)$/, '');
    if (!this.files.has(name)) throw new Error('This part of the live buffer has expired.');
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
    for (const file of this.files) try {await this.removeFile(file);} catch (error) {failure = error;}
    this.segments = []; this.bytes = 0;
    if (failure) throw failure;
  }
}
