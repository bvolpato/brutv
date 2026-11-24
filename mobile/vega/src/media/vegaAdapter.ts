import {VideoPlayer} from '@amazon-devices/react-native-w3cmedia';
import Document from '../../vendor/amazon/polyfills/DocumentPolyfill';
import Element from '../../vendor/amazon/polyfills/ElementPolyfill';
import TextDecoderPolyfill from '../../vendor/amazon/polyfills/TextDecoderPolyfill';
import DOMParserPolyfill from '../../vendor/amazon/polyfills/DOMParserPolyfill';
import MiscPolyfill from '../../vendor/amazon/polyfills/MiscPolyfill';
import W3CMediaPolyfill from '../../vendor/amazon/polyfills/W3CMediaPolyfill';
import {IPTV_USER_AGENT} from '../domain/http';
import {httpURL, isUnsupportedPlaybackURL, normalizePlaybackURL} from '../domain/login';
import {MediaAdapter, MediaTrackInfo, TrackSnapshot} from './PlaybackSession';
import {cleanStaleRecordings, HlsRecorder, RecordedInfo, RecordingUnavailable} from './HlsRecorder';
import {keplerTempStore} from './KeplerTempStore';
import {RecordingFallback} from './RecordingFallback';

let shakaRuntime: typeof shaka | undefined;
const recordings = new Map<string, {recorder: HlsRecorder; manifestLoaded: (origin: number) => void}>();
const TERMINAL_HTTP_STATUSES = new Set([401, 403, 404, 410]);
let cleanup: Promise<void> | undefined;
let runtimeInitialized = false;

function getShaka(): typeof shaka {
  if (!shakaRuntime) {
    // Lazy-require Shaka on first playback so cold launch does not parse the 600KB runtime.
    shakaRuntime = require('./shaka/shaka-player.compiled') as typeof shaka;
  }
  return shakaRuntime;
}

function installRuntime(): typeof shaka {
  const shakaLib = getShaka();
  if (runtimeInitialized) return shakaLib;
  Document.install();
  Element.install();
  TextDecoderPolyfill.install();
  W3CMediaPolyfill.install();
  MiscPolyfill.install();
  DOMParserPolyfill.install();
  shakaLib.polyfill.installAll();
  shakaLib.net.NetworkingEngine.registerScheme('brutv-timeshift', uri => {
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
        throw new shakaLib.util.Error(
          shakaLib.util.Error.Severity.RECOVERABLE,
          shakaLib.util.Error.Category.NETWORK,
          shakaLib.util.Error.Code.OPERATION_ABORTED,
          uri,
        );
      }
      const message = error instanceof Error ? error.message : '';
      const busy = message.includes('Too many pending');
      const expired = message.includes('expired');
      throw new shakaLib.util.Error(
        busy ? shakaLib.util.Error.Severity.RECOVERABLE : shakaLib.util.Error.Severity.CRITICAL,
        shakaLib.util.Error.Category.NETWORK,
        shakaLib.util.Error.Code.BAD_HTTP_STATUS,
        uri,
        busy ? 503 : (expired ? 410 : 404),
      );
    });
    return new shakaLib.util.AbortableOperation(promise, async () => {aborted = true;});
  }, shakaLib.net.NetworkingEngine.PluginPriority.APPLICATION);
  // Amazon's patched fetch plugin buffers whole responses without ReadableStream progress;
  // pass progressSupport = false so Shaka does not trigger premature connection/stall aborts.
  for (const scheme of ['http', 'https']) {
    shakaLib.net.NetworkingEngine.registerScheme(
      scheme,
      shakaLib.net.HttpFetchPlugin.parse,
      shakaLib.net.NetworkingEngine.PluginPriority.APPLICATION,
      false,
    );
  }
  runtimeInitialized = true;
  return shakaLib;
}

function mimeTypeHint(url: string, live: boolean): string | undefined {
  const path = httpURL(url).pathname.toLowerCase();
  if (path.endsWith('.m3u8')) return 'application/x-mpegurl';
  if (path.endsWith('.mpd')) return 'application/dash+xml';
  if (path.endsWith('.mp4') || path.endsWith('.m4v')) return 'video/mp4';
  if (live && /(?:^|\/)live\/[^/]+\/[^/]+\/[^/]+$/.test(path)) return 'application/x-mpegurl';
  return undefined;
}

function trackDisplayLabel(track: shaka.extern.Track, index: number): string {
  if (track.label && track.label.trim()) return track.label.trim();
  const lang = (track.language || 'und').trim();
  const role = track.roles?.length ? ` (${track.roles[0]})` : '';
  return lang === 'und' ? `Track ${index + 1}${role}` : `${lang.toUpperCase()}${role}`;
}

export function buildAudioTrackList(variants: readonly shaka.extern.Track[]): MediaTrackInfo[] {
  const byKey = new Map<string, {info: MediaTrackInfo; bandwidth: number}>();
  for (let i = 0; i < variants.length; i++) {
    const v = variants[i];
    const role = v.audioRoles?.[0] || v.roles?.[0] || undefined;
    const key = v.audioId !== null && v.audioId !== undefined
      ? `aid:${v.audioId}`
      : `${v.language || 'und'}|${role || ''}|${v.label || ''}`;
    const existing = byKey.get(key);
    const active = !!v.active;
    if (!existing || active || v.bandwidth > existing.bandwidth) {
      byKey.set(key, {
        bandwidth: v.bandwidth,
        info: {
          id: key,
          language: v.language || 'und',
          label: trackDisplayLabel(v, byKey.size),
          active: existing ? (existing.info.active || active) : active,
          role,
        },
      });
    }
  }
  return [...byKey.values()].map(entry => entry.info);
}

export function buildTextTrackList(tracks: readonly shaka.extern.Track[], visible: boolean): MediaTrackInfo[] {
  const result: MediaTrackInfo[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < tracks.length; i++) {
    const t = tracks[i];
    const id = `txt:${t.id}`;
    if (seen.has(id)) continue;
    seen.add(id);
    result.push({
      id,
      language: t.language || 'und',
      label: trackDisplayLabel(t, result.length),
      active: visible && !!t.active,
      role: t.roles?.[0] || undefined,
    });
  }
  return result;
}

export function vegaAdapter(video: VideoPlayer, onError: () => void, initialLive = false): MediaAdapter {
  const shakaLib = installRuntime();
  global.gmedia = video;
  // Shaka's browser declarations expect DOM types; Vega implements the runtime W3C surface.
  const player = new shakaLib.Player(video as unknown as HTMLMediaElement);
  let isLive = initialLive;
  let fallback = new RecordingFallback();
  let activeLoads = 0;
  let activeUnloads = 0;
  let loadGen = 0;
  let prepareGen = 0;
  let recorder: HlsRecorder | undefined;
  let preparingRecorder: HlsRecorder | undefined;
  let info: RecordedInfo | undefined;
  let unavailable: string | undefined;
  let loadedURL: string | undefined;
  let usingRecorded = false;
  let destroyed = false;
  let recordingPreparation: Promise<void> | undefined;
  let recordingOrigin: number | undefined;
  let needsRecordingOrigin = false;
  let streamingFailures = 0;
  let lastHealthyMediaTime = -1;
  let healthySinceAt = 0;
  let healthyAdvanceMs = 0;
  const trackListeners = new Set<(tracks: TrackSnapshot) => void>();
  const backgroundCleanups = new Set<Promise<void>>();

  const trackBackgroundCleanup = (promise: Promise<void>) => {
    backgroundCleanups.add(promise);
    void promise.finally(() => backgroundCleanups.delete(promise));
  };

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
    if (!recorder || !usingRecorded) return false;
    if (detail.code === shakaLib.util.Error.Code.OPERATION_ABORTED) return false;
    const isBadStatus = detail.code === shakaLib.util.Error.Code.BAD_HTTP_STATUS;
    const httpStatus = isBadStatus && Array.isArray(detail.data) ? Number(detail.data[1]) : NaN;
    if (isBadStatus && httpStatus === 503) return false;
    if (detail.category === shakaLib.util.Error.Category.MEDIA
      || detail.category === shakaLib.util.Error.Category.MANIFEST) {
      return true;
    }
    if (isBadStatus && (httpStatus === 404 || httpStatus === 410) && !recorder.info.recording) {
      return true;
    }
    return false;
  };

  const handleError = (event: Event) => {
    const detail = (event as Event & {detail?: {severity: number; category: number; code: number; data?: unknown[]}}).detail;
    if (!detail || detail.severity !== shakaLib.util.Error.Severity.CRITICAL) return;
    if (detail.code === shakaLib.util.Error.Code.OPERATION_ABORTED) return;
    if (shouldDisableRecording(detail)) fallback.request();
    escalate();
  };

  const readTrackSnapshot = (): TrackSnapshot => {
    try {
      const audio = buildAudioTrackList(player.getVariantTracks());
      const textVisible = player.isTextTrackVisible();
      const text = buildTextTrackList(player.getTextTracks(), textVisible);
      return {audio, text, textVisible};
    } catch {
      return {audio: [], text: [], textVisible: false};
    }
  };

  const notifyTracks = () => {
    if (destroyed || trackListeners.size === 0) return;
    const snapshot = readTrackSnapshot();
    for (const listener of trackListeners) listener(snapshot);
  };

  player.addEventListener('error', handleError);
  player.addEventListener('trackschanged', notifyTracks);
  player.addEventListener('adaptation', notifyTracks);
  player.addEventListener('variantchanged', notifyTracks);
  player.addEventListener('textchanged', notifyTracks);

  const networkingEngine = player.getNetworkingEngine();
  const requestFilter: shaka.extern.RequestFilter = (type, request) => {
    if (request.uris.some(uri => uri.startsWith('brutv-timeshift://'))) return;
    request.headers['User-Agent'] = IPTV_USER_AGENT;
    if (type === shakaLib.net.NetworkingEngine.RequestType.MANIFEST) {
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

  const configureStreaming = (liveMode: boolean, lowMemory = false) => {
    player.configure({
      abr: {enabled: true},
      streaming: {
        bufferingGoal: lowMemory ? 6 : (liveMode ? 14 : 30),
        rebufferingGoal: liveMode ? 2.5 : 4,
        bufferBehind: lowMemory ? 5 : 30,
        liveSync: false,
        inaccurateManifestTolerance: 4,
        ignoreTextStreamFailures: true,
        retryParameters,
        failureCallback: (error: shaka.util.Error) => {
          if (destroyed || error.code === shakaLib.util.Error.Code.OPERATION_ABORTED) return;
          resetHealthyProgress();

          const isBadStatus = error.code === shakaLib.util.Error.Code.BAD_HTTP_STATUS;
          const httpStatus = isBadStatus && Array.isArray(error.data) ? Number(error.data[1]) : NaN;
          const isTerminalHttp = Number.isFinite(httpStatus) && TERMINAL_HTTP_STATUSES.has(httpStatus);
          const isTransientNetwork =
            isBadStatus ||
            error.code === shakaLib.util.Error.Code.HTTP_ERROR ||
            error.code === shakaLib.util.Error.Code.TIMEOUT;

          if (!isTerminalHttp && isTransientNetwork && player.isLive() && ++streamingFailures <= 2) {
            error.severity = shakaLib.util.Error.Severity.RECOVERABLE;
            player.retryStreaming(error.code === shakaLib.util.Error.Code.TIMEOUT ? 0.5 : 1);
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
  };

  configureStreaming(isLive);

  function detachRecorder(target: HlsRecorder | undefined): Promise<void> {
    if (!target) return Promise.resolve();
    recordings.delete(target.token);
    if (recorder === target) {
      recorder = undefined;
      info = undefined;
      usingRecorded = false;
      recordingOrigin = undefined;
      needsRecordingOrigin = false;
    }
    if (preparingRecorder === target) {
      preparingRecorder = undefined;
    }
    const closing = target.close().catch(() => { cleanup = undefined; });
    trackBackgroundCleanup(closing);
    return closing;
  }

  async function useOriginalSource(message: string): Promise<void> {
    fallback.disable();
    unavailable = message + ' Playing the provider directly without local rewind.';
    usingRecorded = false;
    activeUnloads++;
    try {await player.unload().catch(() => {});} finally {activeUnloads--;}
    void detachRecorder(recorder);
  }

  async function prepareRecording(url: string): Promise<void> {
    const gen = ++prepareGen;
    void detachRecorder(preparingRecorder);
    void detachRecorder(recorder);
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
        if (recorder === candidate && usingRecorded && loadedURL && !update.recording) escalate();
      });
      preparingRecorder = candidate;
      await candidate.start();
      if (destroyed || gen !== prepareGen) {
        void detachRecorder(candidate);
        return;
      }
      preparingRecorder = undefined;
      recorder = candidate;
      info = candidate.info;
      recordings.set(token, {recorder: candidate, manifestLoaded(origin) {
        if (recorder === candidate && needsRecordingOrigin) {recordingOrigin = origin; needsRecordingOrigin = false;}
      }});
    } catch (error) {
      void detachRecorder(candidate);
      if (!destroyed && gen === prepareGen) {
        unavailable = error instanceof RecordingUnavailable ? error.message : 'Local live rewind is unavailable. Playing the provider directly.';
      }
    }
  }

  return {
    setLive(nextLive: boolean) {
      isLive = nextLive;
      fallback = new RecordingFallback();
      unavailable = undefined;
      loadedURL = undefined;
      usingRecorded = false;
      configureStreaming(isLive);
    },
    startTimeshift() {
      if (destroyed || !isLive || !loadedURL || fallback.disabled || recorder || preparingRecorder) return;
      unavailable = undefined;
      const targetURL = loadedURL;
      const prep = prepareRecording(targetURL);
      recordingPreparation = prep;
      void prep.finally(() => {
        if (recordingPreparation === prep) recordingPreparation = undefined;
      });
    },
    hasActiveRecording() {
      return !!(recorder && recorder.info.recording && !usingRecorded && !fallback.disabled);
    },
    async switchToRecorded() {
      if (destroyed || !recorder || !recorder.info.recording || usingRecorded || fallback.disabled || !loadedURL) {
        return false;
      }
      const gen = ++loadGen;
      const targetURL = loadedURL;
      const localURL = recorder.manifestURL;
      const mime = mimeTypeHint(targetURL, isLive);
      recordingOrigin = recorder.timelineOrigin;
      needsRecordingOrigin = true;
      usingRecorded = true;
      activeLoads++;
      try {
        await fallback.load(
          () => player.load(localURL, undefined, 'application/x-mpegurl'),
          () => useOriginalSource('The temporary live buffer could not be played on this device.'),
          async () => {
            usingRecorded = false;
            if (!destroyed && gen === loadGen) await player.load(targetURL, undefined, mime);
          },
        );
        if (!destroyed && gen === loadGen) {
          notifyTracks();
          return usingRecorded;
        }
        return false;
      } finally {
        activeLoads--;
      }
    },
    async load(url) {
      const targetURL = normalizePlaybackURL(url);
      if (isUnsupportedPlaybackURL(targetURL)) {
        throw new Error('Use an HLS, DASH, or MP4 source on Vega.');
      }
      const gen = ++loadGen;
      if (loadedURL !== targetURL) {
        // Switching to a new channel: detach any previous recorder non-blockingly.
        prepareGen++;
        void detachRecorder(preparingRecorder);
        void detachRecorder(recorder);
        fallback = new RecordingFallback();
        unavailable = undefined;
        usingRecorded = false;
      } else if (recorder && !recorder.info.recording) {
        await useOriginalSource(info?.message || 'Local live recording stopped.');
      }
      if (destroyed || gen !== loadGen) return;

      loadedURL = targetURL;
      streamingFailures = 0;
      resetHealthyProgress();
      const mime = mimeTypeHint(targetURL, isLive);
      activeLoads++;
      try {
        // Direct-first for instant live zapping + full ABR; only load recorded URL if already in recorded timeshift mode.
        if (usingRecorded && recorder && !fallback.disabled) {
          recordingOrigin = recorder.timelineOrigin;
          needsRecordingOrigin = true;
          const localURL = recorder.manifestURL;
          await fallback.load(
            () => player.load(localURL, undefined, 'application/x-mpegurl'),
            () => useOriginalSource('The temporary live buffer could not be played on this device.'),
            async () => {
              usingRecorded = false;
              if (!destroyed && gen === loadGen) await player.load(targetURL, undefined, mime);
            },
          );
        } else {
          usingRecorded = false;
          recordingOrigin = undefined;
          needsRecordingOrigin = false;
          await player.load(targetURL, undefined, mime);
        }
        if (!destroyed && gen === loadGen) {
          streamingFailures = 0;
          resetHealthyProgress();
          notifyTracks();
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
        // Non-blocking cleanup of pending or failed recorder so next channel loads immediately.
        if (pending) void detachRecorder(pending);
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
    async handleMemoryWarning() {
      if (destroyed) return;
      prepareGen++;
      void detachRecorder(preparingRecorder);
      if (recorder) {
        const wasRecorded = usingRecorded;
        void detachRecorder(recorder);
        fallback.disable();
        unavailable = 'Live rewind buffer cleared to free memory.';
        if (wasRecorded && loadedURL) {
          const targetURL = loadedURL;
          activeLoads++;
          try {
            await player.load(targetURL, undefined, mimeTypeHint(targetURL, isLive)).catch(() => {});
          } finally {
            activeLoads--;
          }
        }
      }
      configureStreaming(isLive, true);
    },
    timeline() {
      const range = player.seekRange();
      const liveNow = player.isLive();
      if (!Number.isFinite(range.start) || !Number.isFinite(range.end) || range.end <= range.start) return undefined;
      // Shaka's seekRange end already subtracts its normal presentation delay.
      return {
        start: range.start,
        end: range.end,
        live: liveNow,
        liveTarget: liveNow ? range.end : undefined,
        recording: !!recorder && !!info?.recording,
        message: info?.message || unavailable,
        recordedBytes: info?.bytes,
        recordedSeconds: info?.seconds,
        recordingOrigin,
      };
    },
    recordingMessage() {
      return info?.message || unavailable;
    },
    getTracks() {
      return readTrackSnapshot();
    },
    selectAudioTrack(id: string) {
      if (destroyed) return;
      try {
        const variants = player.getVariantTracks();
        if (id.startsWith('aid:')) {
          const audioId = Number(id.slice(4));
          const match = variants.find(v => v.audioId === audioId);
          if (match) {
            player.selectAudioLanguage(match.language, match.audioRoles?.[0] || match.roles?.[0]);
            notifyTracks();
            return;
          }
        }
        const [language, role] = id.split('|');
        if (language) {
          player.selectAudioLanguage(language, role || undefined);
          notifyTracks();
        }
      } catch { /* Ignore unsupported track switches. */ }
    },
    selectTextTrack(id: string | null) {
      if (destroyed) return;
      try {
        if (id === null) {
          player.setTextTrackVisibility(false);
          notifyTracks();
          return;
        }
        const numericId = id.startsWith('txt:') ? Number(id.slice(4)) : Number(id);
        const match = player.getTextTracks().find(t => t.id === numericId);
        if (match) {
          player.selectTextTrack(match);
          player.setTextTrackVisibility(true);
          notifyTracks();
        }
      } catch { /* Ignore unsupported text track switches. */ }
    },
    onTracksChanged(listener) {
      trackListeners.add(listener);
      return () => { trackListeners.delete(listener); };
    },
    async destroy() {
      destroyed = true;
      prepareGen++;
      loadGen++;
      trackListeners.clear();
      player.removeEventListener('error', handleError);
      player.removeEventListener('trackschanged', notifyTracks);
      player.removeEventListener('adaptation', notifyTracks);
      player.removeEventListener('variantchanged', notifyTracks);
      player.removeEventListener('textchanged', notifyTracks);
      video.removeEventListener('timeupdate', handleTimeUpdate);
      networkingEngine?.unregisterRequestFilter(requestFilter);
      void detachRecorder(recorder);
      void detachRecorder(preparingRecorder);
      const pending = [recordingPreparation, ...backgroundCleanups];
      try {await player.destroy();} finally {
        await Promise.allSettled(pending);
        if (global.gmedia === video) global.gmedia = null;
      }
    },
  };
}
