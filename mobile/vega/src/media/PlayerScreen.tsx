import React, {useCallback, useEffect, useRef, useState} from 'react';
import {AppState, BackHandler, StyleSheet, Text, View} from 'react-native';
import {HWEvent, TVFocusGuideView, useKeplerAppStateManager, useTVEventHandler} from '@amazon-devices/react-native-kepler';
import {MediaControlServerComponentAsync} from '@amazon-devices/kepler-media-controls';
import {KeplerVideoSurfaceView, VideoPlayer} from '@amazon-devices/react-native-w3cmedia';
import {ContentItem} from '../domain/catalog';
import {PlaybackPosition, PlaybackSession, PlaybackStatus} from './PlaybackSession';
import {vegaAdapter} from './vegaAdapter';
import {TVButton} from '../TVButton';
import {localizePlayerMessage, PlayerLanguage, playerText} from './playerCopy';
import {SystemMediaSession} from './SystemMediaSession';

// Module-scoped teardown chain guarantees full decoder, Shaka, and recorder cleanup
// of the previous channel before opening the next stream (critical for single-connection providers).
let previousSessionRelease: Promise<void> = Promise.resolve();

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

export function PlayerScreen({item, language, onClose}: {item: ContentItem; language: PlayerLanguage; onClose: () => void}) {
  const [status, setStatus] = useState<PlaybackStatus>('loading');
  const [attempt, setAttempt] = useState(0);
  const [position, setPosition] = useState<PlaybackPosition>();
  const [recordingMessage, setRecordingMessage] = useState<string>();
  const session = useRef<PlaybackSession>();
  const surface = useRef<string>();
  const canSeekRef = useRef(item.kind !== 'live');
  const controlsFocusedRef = useRef(0);
  const appStateManager = useKeplerAppStateManager();

  const onControlFocus = useCallback(() => { controlsFocusedRef.current += 1; }, []);
  const onControlBlur = useCallback(() => { controlsFocusedRef.current = Math.max(0, controlsFocusedRef.current - 1); }, []);

  const handleTVEvent = useCallback((event: HWEvent) => {
    if (event.eventKeyAction !== 1 && event.eventKeyAction !== undefined) return;
    const type = event.eventType;
    if (type === 'playpause') {
      void session.current?.toggle().catch(() => setStatus('error'));
    } else if (type === 'play') {
      void session.current?.play().catch(() => setStatus('error'));
    } else if (type === 'pause') {
      void session.current?.pause().catch(() => setStatus('error'));
    } else if (type === 'stop') {
      onClose();
    } else if (type === 'rewind' || type === 'skip_backward') {
      if (canSeekRef.current) session.current?.seek(-10);
    } else if (type === 'fastforward' || type === 'fastForward' || type === 'forward' || type === 'skip_forward') {
      if (canSeekRef.current) session.current?.seek(10);
    } else if (type === 'left') {
      if (controlsFocusedRef.current === 0 && canSeekRef.current) session.current?.seek(-10);
    } else if (type === 'right') {
      if (controlsFocusedRef.current === 0 && canSeekRef.current) session.current?.seek(10);
    }
  }, [onClose]);

  useTVEventHandler(handleTVEvent);

  useEffect(() => {
    let cancelled = false;
    const video = new VideoPlayer();
    canSeekRef.current = item.kind !== 'live';
    setPosition(undefined); setRecordingMessage(undefined);
    let system: SystemMediaSession | undefined;
    let playbackStatus: PlaybackStatus = 'loading';
    let playbackPosition: PlaybackPosition | undefined;
    let lastStructuralKey = '';
    let lastDisplayKey = '';
    let lastUiUpdateAt = 0;

    const current = new PlaybackSession(
      video,
      onError => vegaAdapter(video, onError, item.kind === 'live'),
      value => {
        playbackStatus = value;
        setStatus(prev => (prev === value ? prev : value));
        system?.update(value, playbackPosition);
      },
      (update, message) => {
        playbackPosition = update;
        canSeekRef.current = item.kind !== 'live' || !!(update && update.end - update.start > 1);
        system?.update(playbackStatus, update);

        const now = Date.now();
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
      {live: item.kind === 'live'},
    );

    try {
      const server = MediaControlServerComponentAsync.getOrMakeServer();
      system = new SystemMediaSession(current, item, onClose, server);
      server.setHandlerForComponent(system.handler, appStateManager.getComponentInstance());
    } catch {
      system?.close(); system = undefined;
      console.warn('System media controls are unavailable; use the on-screen playback controls.');
    }
    session.current = current;
    if (surface.current) current.surfaceCreated(surface.current);

    const waitForPrevious = previousSessionRelease;
    void waitForPrevious.then(() => {
      if (!cancelled) return current.start(item.url!);
    });

    const back = BackHandler.addEventListener('hardwareBackPress', () => { onClose(); return true; });
    const keplerSubs: {remove: () => void}[] = [];
    try {
      if (typeof appStateManager?.addAppStateListener === 'function') {
        keplerSubs.push(appStateManager.addAppStateListener('change', state => {
          if (state !== 'active') onClose();
        }));
        keplerSubs.push(appStateManager.addAppStateListener('displayChange', state => {
          if (state === 'displayDisconnected') onClose();
        }));
        keplerSubs.push(appStateManager.addAppStateListener('memoryWarning', () => {
          onClose();
        }));
      }
    } catch { /* Fallback to AppState below. */ }
    const appState = AppState.addEventListener('change', state => { if (state !== 'active') onClose(); });

    return () => {
      cancelled = true;
      back.remove();
      appState.remove();
      for (const sub of keplerSubs) sub.remove();
      session.current = undefined;
      system?.close();
      previousSessionRelease = waitForPrevious
        .catch(() => {})
        .then(() => current.close())
        .catch(() => { /* The screen has exited; no stale UI updates. */ });
    };
  }, [item.url, item.kind, attempt, onClose, appStateManager]);

  const behind = position?.live ? Math.max(0, (position.liveTarget ?? position.end) - position.position) : 0;
  const canRewind = !!position && position.end - position.start > 1;
  const text = playerText(language);
  const message = localizePlayerMessage(position?.message || recordingMessage, language);
  return <View style={styles.screen}>
    <KeplerVideoSurfaceView style={styles.surface}
      onSurfaceViewCreated={handle => { surface.current = handle; session.current?.surfaceCreated(handle); }}
      onSurfaceViewDestroyed={handle => { surface.current = undefined; session.current?.surfaceDestroyed(handle); }}/>
    <View style={styles.overlay}>
      <Text style={styles.title}>{item.name}</Text>
      <Text style={styles.status}>{text.status[status]}</Text>
      {item.kind === 'live' && <Text style={styles.status}>
        {position?.expired ? `${text.expired} ` : ''}
        {message || (position?.recording
          ? text.recording(Math.round(position.recordedSeconds || 0), Math.round((position.recordedBytes || 0) / 1024 / 1024))
          : text.checking)}
        {behind > 3 ? ` ${text.behind(Math.round(behind))}` : ''}
      </Text>}
      <TVFocusGuideView autoFocus style={styles.row}>
        <TVButton label={text.back} preferred onFocus={onControlFocus} onBlur={onControlBlur} onPress={onClose}/>
        {status === 'error' ? <TVButton label={text.retry} onFocus={onControlFocus} onBlur={onControlBlur} onPress={() => setAttempt(value => value + 1)}/> : <>
          <TVButton label={status === 'paused' ? text.play : text.pause} onFocus={onControlFocus} onBlur={onControlBlur} onPress={() => { void session.current?.toggle().catch(() => setStatus('error')); }}/>
          {(item.kind !== 'live' || canRewind) && <>
            <TVButton label={text.back10} onFocus={onControlFocus} onBlur={onControlBlur} onPress={() => session.current?.seek(-10)}/>
            <TVButton label={text.forward10} onFocus={onControlFocus} onBlur={onControlBlur} onPress={() => session.current?.seek(10)}/>
          </>}
          {item.kind === 'live' && behind > 3 && <TVButton label={text.goLive} onFocus={onControlFocus} onBlur={onControlBlur} onPress={() => {void session.current?.goLive().catch(() => setStatus('error'));}}/>}
        </>}
      </TVFocusGuideView>
    </View>
  </View>;
}

const styles = StyleSheet.create({
  screen: {flex: 1, backgroundColor: '#000'}, surface: {flex: 1},
  overlay: {position: 'absolute', left: 32, right: 32, bottom: 20, padding: 16, backgroundColor: '#101b2de8', borderRadius: 16},
  row: {flexDirection: 'row', flexWrap: 'wrap'}, title: {color: '#fff', fontSize: 28}, status: {color: '#b9c9d9', fontSize: 20, marginVertical: 10},
});
