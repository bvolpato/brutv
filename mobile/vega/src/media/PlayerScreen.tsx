import React, {useEffect, useRef, useState} from 'react';
import {AppState, BackHandler, StyleSheet, Text, View} from 'react-native';
import {useTVEventHandler} from '@amazon-devices/react-native-kepler';
import {KeplerVideoSurfaceView, VideoPlayer} from '@amazon-devices/react-native-w3cmedia';
import {ContentItem} from '../domain/catalog';
import {PlaybackPosition, PlaybackSession, PlaybackStatus} from './PlaybackSession';
import {vegaAdapter} from './vegaAdapter';
import {TVButton} from '../TVButton';

export function PlayerScreen({item, onClose}: {item: ContentItem; onClose: () => void}) {
  const [status, setStatus] = useState<PlaybackStatus>('loading');
  const [attempt, setAttempt] = useState(0);
  const [position, setPosition] = useState<PlaybackPosition>();
  const [recordingMessage, setRecordingMessage] = useState<string>();
  const session = useRef<PlaybackSession>();
  const surface = useRef<string>();
  const released = useRef<Promise<void>>(Promise.resolve());
  useTVEventHandler(({eventType, eventKeyAction}) => {
    if (eventType === 'playpause' && eventKeyAction === 1) {
      void session.current?.toggle().catch(() => setStatus('error'));
    }
  });
  useEffect(() => {
    const video = new VideoPlayer();
    setPosition(undefined); setRecordingMessage(undefined);
    const current = new PlaybackSession(video, onError => vegaAdapter(video, onError, item.kind === 'live'), setStatus,
      (update, message) => {setPosition(update); setRecordingMessage(message);});
    session.current = current;
    if (surface.current) current.surfaceCreated(surface.current);
    void released.current.then(() => current.start(item.url!));
    const back = BackHandler.addEventListener('hardwareBackPress', () => { onClose(); return true; });
    const appState = AppState.addEventListener('change', state => { if (state !== 'active') onClose(); });
    return () => {
      back.remove(); appState.remove(); session.current = undefined;
      released.current = current.close().catch(() => { /* The screen has exited; no stale UI updates. */ });
    };
  }, [item.url, item.kind, attempt, onClose]);
  const behind = position?.live ? Math.max(0, (position.liveTarget ?? position.end) - position.position) : 0;
  const canRewind = !!position && position.end - position.start > 1;
  return <View style={styles.screen}>
    <KeplerVideoSurfaceView style={styles.surface}
      onSurfaceViewCreated={handle => { surface.current = handle; session.current?.surfaceCreated(handle); }}
      onSurfaceViewDestroyed={handle => { surface.current = undefined; session.current?.surfaceDestroyed(handle); }}/>
    <View style={styles.overlay}>
      <Text style={styles.title}>{item.name}</Text>
      <Text style={styles.status}>{status === 'error' ? 'Playback failed. Check the provider and source format, then retry.' : status}</Text>
      {item.kind === 'live' && <Text style={styles.status}>
        {position?.expired ? 'Your pause exceeded the saved window. Playback moved to the earliest saved point. ' : ''}
        {position?.message || recordingMessage || (position?.recording
          ? `Saving live TV in temporary storage · ${Math.round(position.recordedSeconds || 0)} seconds saved · ${Math.round((position.recordedBytes || 0) / 1024 / 1024)} MB`
          : 'Checking live rewind support…')}
        {behind > 3 ? ` · ${Math.round(behind)} seconds behind live` : ''}
      </Text>}
      <View style={styles.row}>
        <TVButton label="Back to library" preferred onPress={onClose}/>
        {status === 'error' ? <TVButton label="Retry" onPress={() => setAttempt(value => value + 1)}/> : <>
          <TVButton label={status === 'paused' ? 'Play' : 'Pause'} onPress={() => { void session.current?.toggle().catch(() => setStatus('error')); }}/>
          {(item.kind !== 'live' || canRewind) && <>
            <TVButton label="Back 10 seconds" onPress={() => session.current?.seek(-10)}/>
            <TVButton label="Forward 10 seconds" onPress={() => session.current?.seek(10)}/>
          </>}
          {item.kind === 'live' && behind > 3 && <TVButton label="Go live" onPress={() => {void session.current?.goLive().catch(() => setStatus('error'));}}/>}
        </>}
      </View>
    </View>
  </View>;
}

const styles = StyleSheet.create({
  screen: {flex: 1, backgroundColor: '#000'}, surface: {flex: 1},
  overlay: {position: 'absolute', left: 32, right: 32, bottom: 20, padding: 16, backgroundColor: '#101b2de8', borderRadius: 16},
  row: {flexDirection: 'row', flexWrap: 'wrap'}, title: {color: '#fff', fontSize: 28}, status: {color: '#b9c9d9', fontSize: 20, marginVertical: 10},
});
