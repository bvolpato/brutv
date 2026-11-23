import {VideoPlayer} from '@amazon-devices/react-native-w3cmedia';
import Document from '../../vendor/amazon/polyfills/DocumentPolyfill';
import Element from '../../vendor/amazon/polyfills/ElementPolyfill';
import TextDecoderPolyfill from '../../vendor/amazon/polyfills/TextDecoderPolyfill';
import DOMParserPolyfill from '../../vendor/amazon/polyfills/DOMParserPolyfill';
import MiscPolyfill from '../../vendor/amazon/polyfills/MiscPolyfill';
import W3CMediaPolyfill from '../../vendor/amazon/polyfills/W3CMediaPolyfill';
import {IPTV_USER_AGENT} from '../domain/http';
import {httpURL, isUnsupportedPlaybackURL, normalizePlaybackURL} from '../domain/login';
import {MediaAdapter} from './PlaybackSession';
import {cleanStaleRecordings, HlsRecorder, RecordedInfo, RecordingUnavailable} from './HlsRecorder';
import {keplerTempStore} from './KeplerTempStore';
import {RecordingFallback} from './RecordingFallback';

const shakaRuntime: typeof shaka = require('./shaka/shaka-player.compiled');
const recordings = new Map<string, {recorder: HlsRecorder; manifestLoaded: (origin: number) => void}>();
const TERMINAL_HTTP_STATUSES = new Set([401, 403, 404, 410]);
let cleanup: Promise<void> | undefined;
let runtimeInitialized = false;

function installRuntime(): void {
  if (runtimeInitialized) return;
  Document.install();
  Element.install();
  TextDecoderPolyfill.install();
  W3CMediaPolyfill.install();
  MiscPolyfill.install();
  DOMParserPolyfill.install();
  shakaRuntime.polyfill.installAll();
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
    })().catch((error: unknown) => {
      if (aborted) {
        throw new shakaRuntime.util.Error(
          shakaRuntime.util.Error.Severity.RECOVERABLE,
          shakaRuntime.util.Error.Category.NETWORK,
          shakaRuntime.util.Error.Code.OPERATION_ABORTED,
          uri,
        );
      }
      const message = error instanceof Error ? error.message : '';
      const busy = message.includes('Too many pending');
      const expired = message.includes('expired');
      throw new shakaRuntime.util.Error(
        busy ? shakaRuntime.util.Error.Severity.RECOVERABLE : shakaRuntime.util.Error.Severity.CRITICAL,
        shakaRuntime.util.Error.Category.NETWORK,
        shakaRuntime.util.Error.Code.BAD_HTTP_STATUS,
        uri,
        busy ? 503 : (expired ? 410 : 404),
      );
    });
    return new shakaRuntime.util.AbortableOperation(promise, async () => {aborted = true;});
  }, shakaRuntime.net.NetworkingEngine.PluginPriority.APPLICATION);
  // Amazon's patched fetch plugin buffers whole responses without ReadableStream progress;
  // pass progressSupport = false so Shaka does not trigger premature connection/stall aborts.
  for (const scheme of ['http', 'https']) {
    shakaRuntime.net.NetworkingEngine.registerScheme(
      scheme,
      shakaRuntime.net.HttpFetchPlugin.parse,
      shakaRuntime.net.NetworkingEngine.PluginPriority.APPLICATION,
      false,
    );
  }
  runtimeInitialized = true;
}

function mimeTypeHint(url: string, live: boolean): string | undefined {
  const path = httpURL(url).pathname.toLowerCase();
  if (path.endsWith('.m3u8')) return 'application/x-mpegurl';
  if (path.endsWith('.mpd')) return 'application/dash+xml';
  if (path.endsWith('.mp4') || path.endsWith('.m4v')) return 'video/mp4';
  if (live && /(?:^|\/)live\/[^/]+\/[^/]+\/[^/]+$/.test(path)) return 'application/x-mpegurl';
  return undefined;
}

export function vegaAdapter(video: VideoPlayer, onError: () => void, live = false): MediaAdapter {
  installRuntime();
  global.gmedia = video;
  // Shaka's browser declarations expect DOM types; Vega implements the runtime W3C surface.
  const player = new shakaRuntime.Player(video as unknown as HTMLMediaElement);
  const fallback = new RecordingFallback();
  let activeLoads = 0;
  let activeUnloads = 0;
  let loadGen = 0;
  let prepareGen = 0;
  let recorder: HlsRecorder | undefined;
  let preparingRecorder: HlsRecorder | undefined;
  let info: RecordedInfo | undefined;
  let unavailable: string | undefined;
  let loadedURL: string | undefined;
  let destroyed = false;
  let recordingPreparation: Promise<void> | undefined;
  let recordingOrigin: number | undefined;
  let needsRecordingOrigin = false;
  let streamingFailures = 0;
  let lastHealthyMediaTime = -1;
  let healthySinceAt = 0;
  let healthyAdvanceMs = 0;

  const resetHealthyProgress = () => {
    lastHealthyMediaTime = Number.isFinite(video.currentTime) ? video.currentTime : -1;
    healthySinceAt = 0;
    healthyAdvanceMs = 0;
  };

  const handleTimeUpdate = () => {
    if (destroyed || activeLoads > 0 || activeUnloads > 0 || video.paused) return;
    const current = video.currentTime;
    if (!Number.isFinite(current)) return;
    const now = Date.now();
    if (lastHealthyMediaTime < 0 || current < lastHealthyMediaTime - 0.01) {
      lastHealthyMediaTime = current;
      healthySinceAt = now;
      return;
    }
    if (current > lastHealthyMediaTime + 0.01) {
      const mediaDeltaMs = (current - lastHealthyMediaTime) * 1000;
      const wallDeltaMs = healthySinceAt > 0 ? Math.max(0, now - healthySinceAt) : 0;
      lastHealthyMediaTime = current;
      healthySinceAt = now;
      if (streamingFailures > 0) {
        healthyAdvanceMs += Math.min(wallDeltaMs, mediaDeltaMs * 1.1);
        if (healthyAdvanceMs >= 15_000) {
          streamingFailures = 0;
          healthyAdvanceMs = 0;
        }
      }
    }
  };
  video.addEventListener('timeupdate', handleTimeUpdate);

  const escalate = () => {
    if (destroyed || activeLoads > 0 || activeUnloads > 0) return;
    onError();
  };

  const shouldDisableRecording = (detail: {category: number; code: number; data?: unknown[]}): boolean => {
    if (!recorder) return false;
    if (detail.code === shakaRuntime.util.Error.Code.OPERATION_ABORTED) return false;
    const isBadStatus = detail.code === shakaRuntime.util.Error.Code.BAD_HTTP_STATUS;
    const httpStatus = isBadStatus && Array.isArray(detail.data) ? Number(detail.data[1]) : NaN;
    if (isBadStatus && httpStatus === 503) return false;
    if (detail.category === shakaRuntime.util.Error.Category.MEDIA
      || detail.category === shakaRuntime.util.Error.Category.MANIFEST) {
      return true;
    }
    if (isBadStatus && (httpStatus === 404 || httpStatus === 410) && !recorder.info.recording) {
      return true;
    }
    return false;
  };

  const handleError = (event: Event) => {
    const detail = (event as Event & {detail?: {severity: number; category: number; code: number; data?: unknown[]}}).detail;
    if (!detail || detail.severity !== shakaRuntime.util.Error.Severity.CRITICAL) return;
    if (detail.code === shakaRuntime.util.Error.Code.OPERATION_ABORTED) return;
    if (shouldDisableRecording(detail)) fallback.request();
    escalate();
  };

  player.addEventListener('error', handleError);

  const networkingEngine = player.getNetworkingEngine();
  const requestFilter: shaka.extern.RequestFilter = (type, request) => {
    if (request.uris.some(uri => uri.startsWith('brutv-timeshift://'))) return;
    request.headers['User-Agent'] = IPTV_USER_AGENT;
    if (type === shakaRuntime.net.NetworkingEngine.RequestType.MANIFEST) {
      request.headers['Cache-Control'] = 'no-cache';
    }
  };
  networkingEngine?.registerRequestFilter(requestFilter);

  const retryParameters = {
    maxAttempts: 2,
    baseDelay: 750,
    backoffFactor: 2,
    fuzzFactor: 0.3,
    timeout: 12000,
    connectionTimeout: 10000,
    stallTimeout: 12000,
  };

  player.configure({
    abr: {enabled: true},
    streaming: {
      bufferingGoal: live ? 18 : 30,
      rebufferingGoal: live ? 4 : 5,
      bufferBehind: 30,
      liveSync: false,
      inaccurateManifestTolerance: 4,
      ignoreTextStreamFailures: true,
      retryParameters,
      failureCallback: (error: shaka.util.Error) => {
        if (destroyed || error.code === shakaRuntime.util.Error.Code.OPERATION_ABORTED) return;
        resetHealthyProgress();

        const isBadStatus = error.code === shakaRuntime.util.Error.Code.BAD_HTTP_STATUS;
        const httpStatus = isBadStatus && Array.isArray(error.data) ? Number(error.data[1]) : NaN;
        const isTerminalHttp = Number.isFinite(httpStatus) && TERMINAL_HTTP_STATUSES.has(httpStatus);
        const isTransientNetwork =
          isBadStatus ||
          error.code === shakaRuntime.util.Error.Code.HTTP_ERROR ||
          error.code === shakaRuntime.util.Error.Code.TIMEOUT;

        if (!isTerminalHttp && isTransientNetwork && player.isLive() && ++streamingFailures <= 2) {
          error.severity = shakaRuntime.util.Error.Severity.RECOVERABLE;
          player.retryStreaming(error.code === shakaRuntime.util.Error.Code.TIMEOUT ? 0.5 : 1);
          return;
        }
        if (shouldDisableRecording(error)) fallback.request();
        escalate();
      },
    },
    manifest: {
      retryParameters,
      hls: {ignoreTextStreamFailures: true},
    },
  });

  async function closeRecorder(target: HlsRecorder | undefined): Promise<void> {
    if (!target) return;
    recordings.delete(target.token);
    if (recorder === target) {
      recorder = undefined;
      info = undefined;
      recordingOrigin = undefined;
      needsRecordingOrigin = false;
    }
    if (preparingRecorder === target) {
      preparingRecorder = undefined;
    }
    try {await target.close();} catch {cleanup = undefined;}
  }

  async function useOriginalSource(message: string): Promise<void> {
    fallback.disable();
    unavailable = message + ' Playing the provider directly without local rewind.';
    activeUnloads++;
    try {await player.unload().catch(() => {});} finally {activeUnloads--;}
    await closeRecorder(recorder);
  }

  async function prepareRecording(url: string): Promise<void> {
    const gen = ++prepareGen;
    await closeRecorder(preparingRecorder);
    await closeRecorder(recorder);
    if (destroyed || gen !== prepareGen) return;
    let candidate: HlsRecorder | undefined;
    try {
      cleanup ??= cleanStaleRecordings(keplerTempStore).catch(error => {
        cleanup = undefined;
        throw error;
      });
      await cleanup;
      if (destroyed || gen !== prepareGen) return;
      const token = Date.now().toString(36) + Math.random().toString(36).slice(2, 14);
      candidate = new HlsRecorder(keplerTempStore, url, token, fetch, undefined, update => {
        if ((recorder !== candidate && preparingRecorder !== candidate) || destroyed) return;
        info = update;
        if (recorder === candidate && loadedURL && !update.recording) escalate();
      });
      preparingRecorder = candidate;
      await candidate.start();
      if (destroyed || gen !== prepareGen) {
        await closeRecorder(candidate);
        return;
      }
      preparingRecorder = undefined;
      recorder = candidate;
      info = candidate.info;
      recordings.set(token, {recorder: candidate, manifestLoaded(origin) {
        if (recorder === candidate && needsRecordingOrigin) {recordingOrigin = origin; needsRecordingOrigin = false;}
      }});
    } catch (error) {
      await closeRecorder(candidate);
      if (!destroyed && gen === prepareGen) {
        unavailable = error instanceof RecordingUnavailable ? error.message : 'Local live rewind is unavailable. Playing the provider directly.';
      }
    }
  }
  return {
    async load(url) {
      const targetURL = normalizePlaybackURL(url);
      if (isUnsupportedPlaybackURL(targetURL)) {
        throw new Error('Use HLS, DASH or an MP4 source on this Vega starter.');
      }
      const gen = ++loadGen;
      if (recorder && !recorder.info.recording) {
        await useOriginalSource(info?.message || 'Local live recording stopped.');
      }
      if (destroyed || gen !== loadGen) return;
      if (live && loadedURL !== targetURL && !fallback.disabled) {
        unavailable = undefined;
        const prep = prepareRecording(targetURL);
        recordingPreparation = prep;
        await prep;
        if (recordingPreparation === prep) recordingPreparation = undefined;
      }
      if (destroyed || gen !== loadGen) return;
      loadedURL = targetURL;
      recordingOrigin = recorder?.timelineOrigin;
      needsRecordingOrigin = !!recorder;
      streamingFailures = 0;
      resetHealthyProgress();
      const mime = mimeTypeHint(targetURL, live);
      activeLoads++;
      try {
        if (recorder) {
          const localURL = recorder.manifestURL;
          await fallback.load(
            () => player.load(localURL, undefined, 'application/x-mpegurl'),
            () => useOriginalSource('The temporary live buffer could not be played on this device.'),
            async () => {if (!destroyed && gen === loadGen) await player.load(targetURL, undefined, mime);},
          );
        } else {
          await player.load(targetURL, undefined, mime);
        }
        if (!destroyed && gen === loadGen) {
          streamingFailures = 0;
          resetHealthyProgress();
        }
      } finally {activeLoads--;}
    },
    async unload() {
      if (destroyed) return;
      activeUnloads++;
      prepareGen++;
      loadGen++;
      resetHealthyProgress();
      const pending = preparingRecorder;
      preparingRecorder = undefined;
      try {
        await player.unload().catch(() => {});
        if (pending) await closeRecorder(pending);
        if (recorder && (fallback.pending || !recorder.info.recording)) {
          await useOriginalSource(
            fallback.pending
              ? 'The temporary live buffer could not be played on this device.'
              : (info?.message || 'Local live recording stopped.'),
          );
        }
      } finally {
        activeUnloads--;
      }
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
      prepareGen++;
      loadGen++;
      player.removeEventListener('error', handleError);
      video.removeEventListener('timeupdate', handleTimeUpdate);
      networkingEngine?.unregisterRequestFilter(requestFilter);
      if (recorder) recordings.delete(recorder.token);
      if (preparingRecorder) recordings.delete(preparingRecorder.token);
      // Abort recorder preparation immediately instead of waiting for all initial downloads.
      const released = Promise.allSettled([recorder?.close(), preparingRecorder?.close(), recordingPreparation]);
      try {await player.destroy();} finally {
        const results = await released;
        if (global.gmedia === video) global.gmedia = null;
        const failure = results.find(result => result.status === 'rejected');
        if (failure?.status === 'rejected') {cleanup = undefined; throw failure.reason;}
      }
    },
  };
}
