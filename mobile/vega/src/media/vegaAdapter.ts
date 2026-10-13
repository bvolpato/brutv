import {VideoPlayer} from '@amazon-devices/react-native-w3cmedia';
import Document from '../../vendor/amazon/polyfills/DocumentPolyfill';
import Element from '../../vendor/amazon/polyfills/ElementPolyfill';
import TextDecoderPolyfill from '../../vendor/amazon/polyfills/TextDecoderPolyfill';
import DOMParserPolyfill from '../../vendor/amazon/polyfills/DOMParserPolyfill';
import MiscPolyfill from '../../vendor/amazon/polyfills/MiscPolyfill';
import W3CMediaPolyfill from '../../vendor/amazon/polyfills/W3CMediaPolyfill';
import {httpURL} from '../domain/login';
import {MediaAdapter} from './PlaybackSession';
import {cleanStaleRecordings, HlsRecorder, RecordedInfo, RecordingUnavailable} from './HlsRecorder';
import {keplerTempStore} from './KeplerTempStore';
import {RecordingFallback} from './RecordingFallback';

const shakaRuntime: typeof shaka = require('./shaka/shaka-player.compiled');
const recordings = new Map<string, {recorder: HlsRecorder; manifestLoaded: (origin: number) => void}>();
let cleanup: Promise<void> | undefined;
let registered = false;

function installRecordingScheme(): void {
  if (registered) return;
  shakaRuntime.net.NetworkingEngine.registerScheme('brutv-timeshift', uri => {
    let aborted = false;
    const promise = (async () => {
      const token = /^brutv-timeshift:\/\/([a-z0-9]+)\//.exec(uri)?.[1];
      const entry = token && recordings.get(token);
      if (!entry) throw new Error('Live buffer unavailable.');
      const response = await entry.recorder.response(uri, () => aborted);
      if (aborted) throw new Error('Live-buffer request cancelled.');
      if (response.origin !== undefined) entry.manifestLoaded(response.origin);
      return {uri, originalUri: uri, data: response.data, headers: {'content-type': response.mime}, fromCache: true, status: 200};
    })().catch(() => {
      throw new shakaRuntime.util.Error(shakaRuntime.util.Error.Severity.CRITICAL, shakaRuntime.util.Error.Category.NETWORK,
        aborted ? shakaRuntime.util.Error.Code.OPERATION_ABORTED : shakaRuntime.util.Error.Code.BAD_HTTP_STATUS,
        uri, 404);
    });
    return new shakaRuntime.util.AbortableOperation(promise, async () => {aborted = true;});
  }, shakaRuntime.net.NetworkingEngine.PluginPriority.APPLICATION);
  registered = true;
}

export function vegaAdapter(video: VideoPlayer, onError: () => void, live = false): MediaAdapter {
  Document.install();
  Element.install();
  TextDecoderPolyfill.install();
  W3CMediaPolyfill.install();
  MiscPolyfill.install();
  DOMParserPolyfill.install();
  global.gmedia = video;
  shakaRuntime.polyfill.installAll();
  installRecordingScheme();
  // Amazon's patched fetch plugin avoids browser ReadableStream requirements.
  for (const scheme of ['http', 'https']) {
    shakaRuntime.net.NetworkingEngine.registerScheme(scheme, shakaRuntime.net.HttpFetchPlugin.parse,
      shakaRuntime.net.NetworkingEngine.PluginPriority.APPLICATION, true);
  }
  // Shaka's browser declarations expect DOM types; Vega implements the runtime W3C surface.
  const player = new shakaRuntime.Player(video as unknown as HTMLMediaElement);
  const fallback = new RecordingFallback();
  let loading = false;
  const handleError = (event: Event) => {
    const detail = (event as Event & {detail?: {severity: number; category: number; code: number}}).detail;
    if (!detail || detail.severity !== shakaRuntime.util.Error.Severity.CRITICAL) return;
    if (detail.code === shakaRuntime.util.Error.Code.OPERATION_ABORTED) return;
    if (recorder && [shakaRuntime.util.Error.Category.MEDIA, shakaRuntime.util.Error.Category.MANIFEST,
      shakaRuntime.util.Error.Category.NETWORK].includes(detail.category)) {
      fallback.request();
      if (!loading) onError();
    } else onError();
  };
  player.addEventListener('error', handleError);
  player.configure({
    abr: {enabled: true},
    streaming: {
      bufferingGoal: live ? 6 : 20, rebufferingGoal: live ? 1 : 3,
      bufferBehind: 30, liveSync: live,
      retryParameters: {maxAttempts: 3, baseDelay: 1000, backoffFactor: 2, fuzzFactor: 0.5, timeout: 15000},
    },
    manifest: {retryParameters: {maxAttempts: 3, timeout: 15000}},
  });
  let recorder: HlsRecorder | undefined;
  let info: RecordedInfo | undefined;
  let unavailable: string | undefined;
  let loadedURL: string | undefined;
  let destroyed = false;
  let recordingPreparation: Promise<void> | undefined;
  let recordingOrigin: number | undefined;
  let needsRecordingOrigin = false;

  async function useOriginalSource(message: string): Promise<void> {
    fallback.disable();
    unavailable = message + ' Playing the provider directly without local rewind.';
    await player.unload().catch(() => {});
    const stopped = recorder;
    if (stopped) recordings.delete(stopped.token);
    recorder = undefined; info = undefined; recordingOrigin = undefined; needsRecordingOrigin = false;
    try {await stopped?.close();} catch {cleanup = undefined;}
  }

  async function prepareRecording(url: string): Promise<void> {
    try {
      cleanup ??= cleanStaleRecordings(keplerTempStore);
      await cleanup;
      if (destroyed) return;
      const token = Date.now().toString(36) + Math.random().toString(36).slice(2, 14);
      recorder = new HlsRecorder(keplerTempStore, url, token, fetch, undefined, update => {
        info = update;
        if (loadedURL && !update.recording) onError();
      });
      await recorder.start();
      if (!destroyed) recordings.set(token, {recorder, manifestLoaded(origin) {
        if (needsRecordingOrigin) {recordingOrigin = origin; needsRecordingOrigin = false;}
      }});
    } catch (error) {
      try {await recorder?.close();} catch {cleanup = undefined;}
      recorder = undefined; info = undefined;
      unavailable = error instanceof RecordingUnavailable ? error.message : 'Local live rewind is unavailable. Playing the provider directly.';
    }
  }
  return {
    async load(url) {
      httpURL(url);
      let targetURL = url;
      const path = new URL(url).pathname.toLowerCase();
      if (path.endsWith('.ts')) {
        if (url.includes('/live/')) {
          targetURL = url.replace(/\.ts$/i, '.m3u8');
        } else {
          throw new Error('Use HLS, DASH or an MP4 source on this Vega starter.');
        }
      } else if (path.endsWith('.mkv')) {
        throw new Error('Use HLS, DASH or an MP4 source on this Vega starter.');
      }
      if (recorder && !recorder.info.recording) {
        await useOriginalSource(info?.message || 'Local live recording stopped.');
      }
      if (live && loadedURL !== targetURL && !fallback.disabled) {
        unavailable = undefined;
        recordingPreparation = prepareRecording(targetURL);
        await recordingPreparation;
        recordingPreparation = undefined;
      }
      if (destroyed) return;
      loadedURL = targetURL;
      recordingOrigin = recorder?.timelineOrigin;
      needsRecordingOrigin = !!recorder;
      loading = true;
      try {
        if (recorder) {
          const localURL = recorder.manifestURL;
          await fallback.load(() => player.load(localURL, undefined, 'application/x-mpegurl'),
            () => useOriginalSource('The temporary live buffer could not be played on this device.'),
            async () => {if (!destroyed) await player.load(targetURL);});
        } else await player.load(targetURL);
      } finally {loading = false;}
    },
    timeline() {
      const range = player.seekRange();
      const isLive = player.isLive();
      if (!Number.isFinite(range.start) || !Number.isFinite(range.end) || range.end <= range.start) return undefined;
      // Shaka's seekRange end already subtracts its normal presentation delay.
      return {start: range.start, end: range.end, live: isLive, liveTarget: isLive ? range.end : undefined,
        recording: !!recorder && !!info?.recording, message: info?.message || unavailable,
        recordedBytes: info?.bytes, recordedSeconds: info?.seconds, recordingOrigin};
    },
    recordingMessage() {
      return info?.message || unavailable;
    },
    async destroy() {
      destroyed = true;
      player.removeEventListener('error', handleError);
      if (recorder) recordings.delete(recorder.token);
      // Abort recorder preparation immediately instead of waiting for all initial downloads.
      const released = Promise.allSettled([recorder?.close(), recordingPreparation]);
      try {await player.destroy();} finally {
        const results = await released;
        if (global.gmedia === video) global.gmedia = null;
        const failure = results.find(result => result.status === 'rejected');
        if (failure?.status === 'rejected') {cleanup = undefined; throw failure.reason;}
      }
    },
  };
}
