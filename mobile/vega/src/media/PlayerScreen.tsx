import React, {useCallback, useEffect, useRef, useState} from 'react';
import {AppState, BackHandler, StyleSheet, Text, View} from 'react-native';
import {HWEvent, TVFocusGuideView, useKeplerAppStateManager, useTVEventHandler} from '@amazon-devices/react-native-kepler';
import {MediaControlServerComponentAsync} from '@amazon-devices/kepler-media-controls';
import {KeplerCaptionsView, KeplerVideoSurfaceView, VideoPlayer} from '@amazon-devices/react-native-w3cmedia';
import {ContentItem, ShortEPG} from '../domain/catalog';
import {PlaybackPosition, PlaybackSession, PlaybackStatus, TrackSnapshot} from './PlaybackSession';
import {vegaAdapter} from './vegaAdapter';
import {TVButton} from '../TVButton';
import {formatPlaybackTime, localizePlayerMessage, PlayerLanguage, playerText} from './playerCopy';
import {SystemMediaSession} from './SystemMediaSession';

// Module-scoped teardown chain guarantees full decoder, Shaka, and recorder cleanup
// of the previous session before opening a brand-new player instance.
let previousSessionRelease: Promise<void> = Promise.resolve();

const CONTROLS_AUTO_HIDE_MS = 4500;
const PROGRESS_SAVE_INTERVAL_MS = 10_000;
const EMPTY_TRACKS: TrackSnapshot = {audio: [], text: [], textVisible: false};

export interface PlayerScreenProps {
  item: ContentItem;
  language: PlayerLanguage;
  onClose: () => void;
  startPosition?: number;
  epg?: ShortEPG;
  isFavorite?: boolean;
  onToggleFavorite?: (item: ContentItem) => void;
  canSwitchChannel?: boolean;
  onSwitchChannel?: (delta: 1 | -1) => void;
  onProgress?: (item: ContentItem, position: number, duration: number) => void;
  onEnded?: (item: ContentItem) => void;
  onMemoryWarning?: () => void;
}

function positionStructuralKey(update: PlaybackPosition | undefined, message: string | undefined): string {
  if (!update) return `none|${message ?? ''}`;
  const canRewind = update.end - update.start > 1 ? 1 : 0;
  return `${update.live ? 1 : 0}|${update.paused ? 1 : 0}|${update.expired ? 1 : 0}|${update.recording ? 1 : 0}|${canRewind}|${update.message ?? ''}|${message ?? ''}`;
}

function positionDisplayKey(update: PlaybackPosition | undefined): string {
  if (!update) return 'none';
  const wholeSecond = Math.floor(update.position);
  const behind = update.live ? Math.round(Math.max(0, (update.liveTarget ?? update.end) - update.position)) : 0;
  const recSec = Math.round(update.recordedSeconds || 0);
  const recMB = Math.round((update.recordedBytes || 0) / 1024 / 1024);
  return `${wholeSecond}|${behind}|${recSec}|${recMB}`;
}

export function PlayerScreen({
  item,
  language,
  onClose,
  startPosition,
  epg,
  isFavorite = false,
  onToggleFavorite,
  canSwitchChannel = false,
  onSwitchChannel,
  onProgress,
  onEnded,
  onMemoryWarning,
}: PlayerScreenProps) {
  const [status, setStatus] = useState<PlaybackStatus>('loading');
  const [attempt, setAttempt] = useState(0);
  const [position, setPosition] = useState<PlaybackPosition>();
  const [recordingMessage, setRecordingMessage] = useState<string>();
  const [tracks, setTracks] = useState<TrackSnapshot>(EMPTY_TRACKS);
  const [controlsVisible, setControlsVisible] = useState(true);
  const [trackMenu, setTrackMenu] = useState<'none' | 'audio' | 'text'>('none');

  const session = useRef<PlaybackSession>();
  const systemRef = useRef<SystemMediaSession>();
  const surface = useRef<string>();
  const captionView = useRef<string>();
  const canSeekRef = useRef(item.kind !== 'live');
  const controlsFocusedRef = useRef(0);
  const controlsVisibleRef = useRef(true);
  const statusRef = useRef<PlaybackStatus>('loading');
  const trackMenuRef = useRef<'none' | 'audio' | 'text'>('none');
  const hideTimerRef = useRef<ReturnType<typeof setTimeout>>();
  const itemRef = useRef(item);
  const positionRef = useRef<PlaybackPosition>();
  const lastProgressSavedAtRef = useRef(0);
  const memoryShedRef = useRef(false);
  const mountedUrlRef = useRef<string | undefined>(undefined);
  const onCloseRef = useRef(onClose);
  const onSwitchChannelRef = useRef(onSwitchChannel);
  const onProgressRef = useRef(onProgress);
  const onEndedRef = useRef(onEnded);
  const onMemoryWarningRef = useRef(onMemoryWarning);
  const appStateManager = useKeplerAppStateManager();

  itemRef.current = item;
  onCloseRef.current = onClose;
  onSwitchChannelRef.current = onSwitchChannel;
  onProgressRef.current = onProgress;
  onEndedRef.current = onEnded;
  onMemoryWarningRef.current = onMemoryWarning;
  controlsVisibleRef.current = controlsVisible;
  statusRef.current = status;
  trackMenuRef.current = trackMenu;

  const clearHideTimer = useCallback(() => {
    if (hideTimerRef.current) {
      clearTimeout(hideTimerRef.current);
      hideTimerRef.current = undefined;
    }
  }, []);

  const scheduleHideControls = useCallback(() => {
    clearHideTimer();
    if (statusRef.current !== 'playing' || trackMenuRef.current !== 'none') return;
    hideTimerRef.current = setTimeout(() => {
      hideTimerRef.current = undefined;
      if (statusRef.current === 'playing' && trackMenuRef.current === 'none') {
        setControlsVisible(false);
      }
    }, CONTROLS_AUTO_HIDE_MS);
  }, [clearHideTimer]);

  const wakeControls = useCallback(() => {
    setControlsVisible(true);
    scheduleHideControls();
  }, [scheduleHideControls]);

  useEffect(() => {
    if (status === 'playing' && controlsVisible && trackMenu === 'none') {
      scheduleHideControls();
    } else {
      clearHideTimer();
      if (status !== 'playing') {
        setControlsVisible(true);
      }
    }
    return clearHideTimer;
  }, [status, controlsVisible, trackMenu, scheduleHideControls, clearHideTimer]);

  const flushVodProgress = useCallback(() => {
    const currentItem = itemRef.current;
    const pos = positionRef.current;
    if (currentItem.kind === 'live' || !pos || pos.live || !Number.isFinite(pos.end) || pos.end <= 0) return;
    onProgressRef.current?.(currentItem, pos.position, pos.end);
    lastProgressSavedAtRef.current = Date.now();
  }, []);

  const onControlFocus = useCallback(() => {
    controlsFocusedRef.current += 1;
    scheduleHideControls();
  }, [scheduleHideControls]);

  const onControlBlur = useCallback(() => {
    controlsFocusedRef.current = Math.max(0, controlsFocusedRef.current - 1);
  }, []);

  const handleTVEvent = useCallback((event: HWEvent) => {
    if (event.eventKeyAction !== 1 && event.eventKeyAction !== undefined) return;
    const type = event.eventType;
    wakeControls();
    if (type === 'playpause') {
      void session.current?.toggle().catch(() => setStatus('error'));
    } else if (type === 'play') {
      void session.current?.play().catch(() => setStatus('error'));
    } else if (type === 'pause') {
      flushVodProgress();
      void session.current?.pause().catch(() => setStatus('error'));
    } else if (type === 'stop') {
      flushVodProgress();
      onCloseRef.current();
    } else if (type === 'rewind' || type === 'skip_backward') {
      if (canSeekRef.current) session.current?.seek(-10);
    } else if (type === 'fastforward' || type === 'fastForward' || type === 'forward' || type === 'skip_forward') {
      if (canSeekRef.current) session.current?.seek(10);
    } else if (type === 'channel_up' || type === 'page_up') {
      if (canSwitchChannel) onSwitchChannelRef.current?.(1);
    } else if (type === 'channel_down' || type === 'page_down') {
      if (canSwitchChannel) onSwitchChannelRef.current?.(-1);
    } else if (type === 'up') {
      if (!controlsVisibleRef.current && canSwitchChannel) onSwitchChannelRef.current?.(1);
    } else if (type === 'down') {
      if (!controlsVisibleRef.current && canSwitchChannel) onSwitchChannelRef.current?.(-1);
    } else if (type === 'left') {
      if (controlsFocusedRef.current === 0 && canSeekRef.current) session.current?.seek(-10);
    } else if (type === 'right') {
      if (controlsFocusedRef.current === 0 && canSeekRef.current) session.current?.seek(10);
    }
  }, [canSwitchChannel, flushVodProgress, wakeControls]);

  useTVEventHandler(handleTVEvent);

  // Mount a single VideoPlayer + PlaybackSession + SystemMediaSession and reuse across channel zaps.
  useEffect(() => {
    let cancelled = false;
    const initialItem = itemRef.current;
    const video = new VideoPlayer();
    canSeekRef.current = initialItem.kind !== 'live';
    memoryShedRef.current = false;
    setPosition(undefined);
    setRecordingMessage(undefined);
    setTracks(EMPTY_TRACKS);

    let system: SystemMediaSession | undefined;
    let playbackStatus: PlaybackStatus = 'loading';
    let playbackPosition: PlaybackPosition | undefined;
    let lastStructuralKey = '';
    let lastDisplayKey = '';
    let lastUiUpdateAt = 0;

    const current = new PlaybackSession(
      video,
      onError => vegaAdapter(video, onError, itemRef.current.kind === 'live'),
      value => {
        playbackStatus = value;
        setStatus(prev => (prev === value ? prev : value));
        system?.update(value, playbackPosition);
        if (value === 'paused') {
          flushVodProgress();
        } else if (value === 'ended' && itemRef.current.kind !== 'live') {
          onEndedRef.current?.(itemRef.current);
        }
      },
      (update, message) => {
        playbackPosition = update;
        positionRef.current = update;
        canSeekRef.current = itemRef.current.kind !== 'live' || !!(update && update.end - update.start > 1);
        system?.update(playbackStatus, update);

        const now = Date.now();
        if (
          itemRef.current.kind !== 'live'
          && update
          && !update.live
          && Number.isFinite(update.end)
          && update.end > 0
          && now - lastProgressSavedAtRef.current >= PROGRESS_SAVE_INTERVAL_MS
        ) {
          lastProgressSavedAtRef.current = now;
          onProgressRef.current?.(itemRef.current, update.position, update.end);
        }

        const structuralKey = positionStructuralKey(update, message);
        const displayKey = positionDisplayKey(update);
        const structuralChanged = structuralKey !== lastStructuralKey;
        const displayChanged = displayKey !== lastDisplayKey && now - lastUiUpdateAt >= 1000;
        if (structuralChanged || displayChanged) {
          lastStructuralKey = structuralKey;
          lastDisplayKey = displayKey;
          lastUiUpdateAt = now;
          setPosition(update);
          setRecordingMessage(prev => (prev === message ? prev : message));
        }
      },
      {
        live: initialItem.kind === 'live',
        startPosition,
        onTracksChanged: snapshot => {
          setTracks(snapshot);
          system?.updateTracks(snapshot);
        },
      },
    );

    try {
      const server = MediaControlServerComponentAsync.getOrMakeServer();
      system = new SystemMediaSession(
        current,
        initialItem,
        () => {
          flushVodProgress();
          onCloseRef.current();
        },
        server,
        Date.now,
        {
          onNext: () => { if (onSwitchChannelRef.current) onSwitchChannelRef.current(1); },
          onPrevious: () => { if (onSwitchChannelRef.current) onSwitchChannelRef.current(-1); },
        },
      );
      server.setHandlerForComponent(system.handler, appStateManager.getComponentInstance());
    } catch {
      system?.close();
      system = undefined;
      console.warn('System media controls are unavailable; use the on-screen playback controls.');
    }
    session.current = current;
    systemRef.current = system;
    mountedUrlRef.current = initialItem.url;
    if (surface.current) current.surfaceCreated(surface.current);
    if (captionView.current) current.captionViewCreated(captionView.current);

    const waitForPrevious = previousSessionRelease;
    void waitForPrevious.then(() => {
      if (!cancelled && initialItem.url) return current.start(initialItem.url);
    });

    const back = BackHandler.addEventListener('hardwareBackPress', () => {
      if (trackMenuRef.current !== 'none') {
        setTrackMenu('none');
        return true;
      }
      if (controlsVisibleRef.current && statusRef.current === 'playing') {
        setControlsVisible(false);
        return true;
      }
      flushVodProgress();
      onCloseRef.current();
      return true;
    });

    // Deduplicate app lifecycle subscriptions: prefer Kepler appStateManager and only fall back to RN AppState.
    const lifecycleSubs: {remove: () => void}[] = [];
    let registeredKeplerState = false;
    try {
      if (typeof appStateManager?.addAppStateListener === 'function') {
        registeredKeplerState = true;
        lifecycleSubs.push(appStateManager.addAppStateListener('change', state => {
          if (state !== 'active') {
            flushVodProgress();
            void current.pause().catch(() => {});
          }
        }));
        lifecycleSubs.push(appStateManager.addAppStateListener('displayChange', state => {
          if (state === 'displayDisconnected') {
            flushVodProgress();
            onCloseRef.current();
          }
        }));
        lifecycleSubs.push(appStateManager.addAppStateListener('memoryWarning', () => {
          if (!memoryShedRef.current) {
            memoryShedRef.current = true;
            onMemoryWarningRef.current?.();
            void current.handleMemoryWarning().catch(() => {});
          } else {
            flushVodProgress();
            onCloseRef.current();
          }
        }));
      }
    } catch {
      registeredKeplerState = false;
    }
    if (!registeredKeplerState) {
      lifecycleSubs.push(AppState.addEventListener('change', state => {
        if (state !== 'active') {
          flushVodProgress();
          void current.pause().catch(() => {});
        }
      }));
    }

    return () => {
      cancelled = true;
      flushVodProgress();
      clearHideTimer();
      back.remove();
      for (const sub of lifecycleSubs) sub.remove();
      session.current = undefined;
      systemRef.current = undefined;
      mountedUrlRef.current = undefined;
      system?.close();
      previousSessionRelease = waitForPrevious
        .catch(() => {})
        .then(() => current.close())
        .catch(() => { /* The screen has exited; no stale UI updates. */ });
    };
  }, [appStateManager, clearHideTimer, flushVodProgress]);

  // Reuse the mounted VideoPlayer + Shaka Player on channel zap or manual retry.
  useEffect(() => {
    if (!session.current || !item.url) return;
    if (mountedUrlRef.current === item.url && attempt === 0) return;
    mountedUrlRef.current = item.url;
    canSeekRef.current = item.kind !== 'live';
    positionRef.current = undefined;
    setPosition(undefined);
    setRecordingMessage(undefined);
    setTracks(EMPTY_TRACKS);
    setTrackMenu('none');
    wakeControls();
    systemRef.current?.setItem(item);
    void session.current.switchSource(item.url, {live: item.kind === 'live', startPosition});
  }, [item, attempt, startPosition, wakeControls]);

  const behind = position?.live ? Math.max(0, (position.liveTarget ?? position.end) - position.position) : 0;
  const canRewind = !!position && position.end - position.start > 1;
  const text = playerText(language);
  const message = localizePlayerMessage(position?.message || recordingMessage, language);

  const isVod = item.kind !== 'live' && !!position && !position.live && Number.isFinite(position.end) && position.end > 0;
  const vodProgressPct = isVod ? Math.max(0, Math.min(100, (position.position / position.end) * 100)) : 0;
  const liveWindowLen = position?.live ? Math.max(0, position.end - position.start) : 0;
  const liveDvrPct = position?.live && liveWindowLen > 1
    ? Math.max(0, Math.min(100, ((position.position - position.start) / liveWindowLen) * 100))
    : 100;

  const activeAudio = tracks.audio.find(t => t.active);
  const activeText = tracks.textVisible ? tracks.text.find(t => t.active) : undefined;
  const showOverlay = controlsVisible || status !== 'playing';

  return <View style={styles.screen}>
    <KeplerVideoSurfaceView
      style={styles.surface}
      onSurfaceViewCreated={handle => { surface.current = handle; session.current?.surfaceCreated(handle); }}
      onSurfaceViewDestroyed={handle => { surface.current = undefined; session.current?.surfaceDestroyed(handle); }}
    />
    <KeplerCaptionsView
      style={styles.captions}
      show={tracks.textVisible}
      onCaptionViewCreated={handle => { captionView.current = handle; session.current?.captionViewCreated(handle); }}
      onCaptionViewDestroyed={handle => { captionView.current = undefined; session.current?.captionViewDestroyed(handle); }}
    />
    {showOverlay && (
      <View style={styles.overlay}>
        <View style={styles.headerRow}>
          <Text numberOfLines={1} style={styles.title}>{item.name}</Text>
          {item.kind === 'live' && (
            <View style={[styles.liveBadge, behind > 3 && styles.liveBadgeBehind]}>
              <Text style={styles.liveBadgeText}>
                {behind > 3 ? `-${Math.round(behind)}s` : text.liveBadge}
              </Text>
            </View>
          )}
        </View>

        {item.kind === 'live' && (epg?.now || epg?.next) && (
          <View style={styles.epgBox}>
            {epg.now && (
              <Text numberOfLines={1} style={styles.epgNow}>
                {text.nowPlaying}: {epg.now.title}
              </Text>
            )}
            {epg.next && (
              <Text numberOfLines={1} style={styles.epgNext}>
                {text.upNext}: {epg.next.title}
              </Text>
            )}
          </View>
        )}

        <Text style={styles.status}>
          {text.status[status]}
          {item.kind === 'live' && (
            <>
              {' · '}
              {position?.expired ? `${text.expired} ` : ''}
              {message || (position?.recording
                ? text.recording(Math.round(position.recordedSeconds || 0), Math.round((position.recordedBytes || 0) / 1024 / 1024))
                : text.directLive)}
              {behind > 3 ? ` ${text.behind(Math.round(behind))}` : ''}
            </>
          )}
        </Text>

        {isVod && position && (
          <View style={styles.progressSection}>
            <View style={styles.progressTrack}>
              <View style={[styles.progressFill, {width: `${vodProgressPct}%`}]} />
            </View>
            <View style={styles.progressLabels}>
              <Text style={styles.progressTime}>{formatPlaybackTime(position.position)}</Text>
              <Text style={styles.progressTime}>{formatPlaybackTime(position.end)}</Text>
            </View>
          </View>
        )}

        {item.kind === 'live' && liveWindowLen > 1 && (
          <View style={styles.progressSection}>
            <View style={styles.progressTrack}>
              <View style={[styles.progressFill, behind > 3 && styles.progressFillBehind, {width: `${liveDvrPct}%`}]} />
            </View>
            <View style={styles.progressLabels}>
              <Text style={styles.progressTime}>-{formatPlaybackTime(liveWindowLen)}</Text>
              <Text style={styles.progressTime}>{behind > 3 ? `-${formatPlaybackTime(behind)}` : text.liveBadge}</Text>
            </View>
          </View>
        )}

        {trackMenu === 'audio' && (
          <TVFocusGuideView autoFocus style={styles.trackRow}>
            {tracks.audio.map(track => (
              <TVButton
                key={track.id}
                label={track.label}
                selected={track.active}
                preferred={track.active}
                onFocus={onControlFocus}
                onBlur={onControlBlur}
                onPress={() => {
                  session.current?.selectAudioTrack(track.id);
                  setTrackMenu('none');
                  wakeControls();
                }}
              />
            ))}
          </TVFocusGuideView>
        )}

        {trackMenu === 'text' && (
          <TVFocusGuideView autoFocus style={styles.trackRow}>
            <TVButton
              label={text.off}
              selected={!tracks.textVisible}
              preferred={!tracks.textVisible}
              onFocus={onControlFocus}
              onBlur={onControlBlur}
              onPress={() => {
                session.current?.selectTextTrack(null);
                setTrackMenu('none');
                wakeControls();
              }}
            />
            {tracks.text.map(track => (
              <TVButton
                key={track.id}
                label={track.label}
                selected={track.active}
                preferred={track.active}
                onFocus={onControlFocus}
                onBlur={onControlBlur}
                onPress={() => {
                  session.current?.selectTextTrack(track.id);
                  setTrackMenu('none');
                  wakeControls();
                }}
              />
            ))}
          </TVFocusGuideView>
        )}

        <TVFocusGuideView autoFocus={trackMenu === 'none'} style={styles.row}>
          <TVButton label={text.back} preferred={trackMenu === 'none'} onFocus={onControlFocus} onBlur={onControlBlur} onPress={() => { flushVodProgress(); onClose(); }}/>
          {status === 'error' ? (
            <TVButton label={text.retry} onFocus={onControlFocus} onBlur={onControlBlur} onPress={() => setAttempt(value => value + 1)}/>
          ) : (
            <>
              <TVButton
                label={status === 'paused' ? text.play : text.pause}
                onFocus={onControlFocus}
                onBlur={onControlBlur}
                onPress={() => { wakeControls(); void session.current?.toggle().catch(() => setStatus('error')); }}
              />
              {(item.kind !== 'live' || canRewind) && (
                <>
                  <TVButton label={text.back10} onFocus={onControlFocus} onBlur={onControlBlur} onPress={() => { wakeControls(); session.current?.seek(-10); }}/>
                  <TVButton label={text.forward10} onFocus={onControlFocus} onBlur={onControlBlur} onPress={() => { wakeControls(); session.current?.seek(10); }}/>
                </>
              )}
              {item.kind === 'live' && behind > 3 && (
                <TVButton label={text.goLive} onFocus={onControlFocus} onBlur={onControlBlur} onPress={() => { wakeControls(); void session.current?.goLive().catch(() => setStatus('error')); }}/>
              )}
              {canSwitchChannel && onSwitchChannel && (
                <>
                  <TVButton label={text.prevChannel} onFocus={onControlFocus} onBlur={onControlBlur} onPress={() => { wakeControls(); onSwitchChannel(-1); }}/>
                  <TVButton label={text.nextChannel} onFocus={onControlFocus} onBlur={onControlBlur} onPress={() => { wakeControls(); onSwitchChannel(1); }}/>
                </>
              )}
              {onToggleFavorite && (
                <TVButton
                  label={isFavorite ? text.removeFavorite : text.addFavorite}
                  selected={isFavorite}
                  onFocus={onControlFocus}
                  onBlur={onControlBlur}
                  onPress={() => { wakeControls(); onToggleFavorite(item); }}
                />
              )}
              {tracks.audio.length > 1 && (
                <TVButton
                  label={activeAudio ? `${text.audio}: ${activeAudio.label}` : text.audio}
                  selected={trackMenu === 'audio'}
                  onFocus={onControlFocus}
                  onBlur={onControlBlur}
                  onPress={() => { setTrackMenu(prev => prev === 'audio' ? 'none' : 'audio'); wakeControls(); }}
                />
              )}
              {tracks.text.length > 0 && (
                <TVButton
                  label={`${text.subtitles}: ${activeText ? activeText.label : text.off}`}
                  selected={trackMenu === 'text' || tracks.textVisible}
                  onFocus={onControlFocus}
                  onBlur={onControlBlur}
                  onPress={() => { setTrackMenu(prev => prev === 'text' ? 'none' : 'text'); wakeControls(); }}
                />
              )}
            </>
          )}
        </TVFocusGuideView>
      </View>
    )}
  </View>;
}

const styles = StyleSheet.create({
  screen: {flex: 1, backgroundColor: '#000'},
  surface: {flex: 1},
  captions: {...StyleSheet.absoluteFillObject},
  overlay: {position: 'absolute', left: 32, right: 32, bottom: 20, padding: 18, backgroundColor: '#101b2de8', borderRadius: 16},
  headerRow: {flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between'},
  title: {flex: 1, color: '#fff', fontSize: 28, fontWeight: '700', marginRight: 12},
  liveBadge: {backgroundColor: '#14b8a6', paddingHorizontal: 12, paddingVertical: 4, borderRadius: 8},
  liveBadgeBehind: {backgroundColor: '#d97706'},
  liveBadgeText: {color: '#06201f', fontSize: 15, fontWeight: '800', letterSpacing: 0.6},
  epgBox: {marginTop: 6},
  epgNow: {color: '#e2e8f0', fontSize: 18, fontWeight: '600'},
  epgNext: {color: '#94a3b8', fontSize: 16, marginTop: 2},
  status: {color: '#b9c9d9', fontSize: 18, marginVertical: 8},
  progressSection: {marginBottom: 10},
  progressTrack: {height: 6, backgroundColor: '#263b55', borderRadius: 3, overflow: 'hidden'},
  progressFill: {height: 6, backgroundColor: '#5eead4'},
  progressFillBehind: {backgroundColor: '#f59e0b'},
  progressLabels: {flexDirection: 'row', justifyContent: 'space-between', marginTop: 4},
  progressTime: {color: '#94a3b8', fontSize: 14, fontWeight: '600'},
  trackRow: {flexDirection: 'row', flexWrap: 'wrap', marginBottom: 8, paddingBottom: 8, borderBottomWidth: 1, borderBottomColor: '#263b55'},
  row: {flexDirection: 'row', flexWrap: 'wrap'},
});
