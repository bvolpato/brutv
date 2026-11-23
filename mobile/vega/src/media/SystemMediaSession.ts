import type {Action, IMediaControlHandlerAsync, IMediaControlServerAsync, IMediaSessionId, ITimeValue, MediaSessionState} from '@amazon-devices/kepler-media-controls';
import {ContentItem} from '../domain/catalog';
import {PlaybackPosition, PlaybackSession, PlaybackStatus} from './PlaybackSession';

function reject(name: string, message: string): never {
  const error = new Error(message);
  error.name = name;
  throw error;
}

function seconds(value: ITimeValue): number {
  if (!Number.isSafeInteger(value.seconds) || value.seconds < 0 || !Number.isInteger(value.nanoseconds)
    || value.nanoseconds < 0 || value.nanoseconds > 999999999) reject('InvalidArgumentError', 'Invalid playback time.');
  return value.seconds + value.nanoseconds / 1e9;
}

function time(value: number): ITimeValue {
  const valid = Math.max(0, Number.isFinite(value) ? value : 0);
  return {seconds: Math.floor(valid), nanoseconds: Math.floor((valid % 1) * 1e9)};
}

interface PublishedSnapshot {
  status: PlaybackStatus;
  canSeek: boolean;
  live?: boolean;
  start?: number;
  end?: number;
  position?: number;
  publishedAtMs: number;
}

const MATERIAL_CHANGE_SECONDS = 2;

export class SystemMediaSession {
  private active = true;
  private status: PlaybackStatus = 'loading';
  private position?: PlaybackPosition;
  private publishing = true;
  private lastPublished?: PublishedSnapshot;
  readonly handler: IMediaControlHandlerAsync;

  constructor(private session: PlaybackSession, private item: ContentItem, private onClose: () => void,
    private server: Pick<IMediaControlServerAsync, 'updateMediaSessionStates'>,
    private now: () => number = Date.now) {
    const check = (id?: IMediaSessionId) => {
      if (!this.active || (id && id.id !== 0)) reject('InvalidStateError', 'The playback session is no longer available.');
    };
    const seek = (value: number, id?: IMediaSessionId) => {
      check(id);
      if (!this.position || this.position.end <= this.position.start) reject('NotAllowedError', 'This stream cannot seek.');
      if (value < this.position.start || value > this.position.end) reject('SeekOutOfRangeError', 'The requested position is outside the available window.');
      this.session.seekTo(value);
    };
    const skip = (value: ITimeValue, direction: number, id?: IMediaSessionId) => {
      check(id);
      if (!this.position) reject('NotAllowedError', 'This stream cannot seek.');
      seek(Math.max(this.position.start, Math.min(this.position.end, this.position.position + seconds(value) * direction)), id);
    };
    const unsupported = async () => reject('NotAllowedError', 'This media action is not supported.');
    this.handler = {
      handlePlay: async id => {check(id); await session.play();},
      handlePause: async id => {check(id); await session.pause();},
      handleTogglePlayPause: async id => {check(id); await session.toggle();},
      handleStop: async id => {
        check(id);
        try {await session.close();} finally {this.close(); onClose();}
      },
      handleSeek: async (value, id) => seek(seconds(value), id),
      handleSkipForward: async (value, id) => skip(value, 1, id),
      handleSkipBackward: async (value, id) => skip(value, -1, id),
      handleGetSessionState: async id => {
        if (!this.active) return [];
        check(id); return [this.state()];
      },
      handleGetMetadataInfo: async id => {
        check();
        if (id.contentId !== item.id || id.catalogName !== 'brutv') reject('NotAvailableError', 'This media item is not active.');
        return {mediaId: id, title: item.name, artwork: []};
      },
      handleStartOver: unsupported, handleFastForward: unsupported, handleRewind: unsupported,
      handleSetPlaybackSpeed: unsupported, handleSetAudioVolume: unsupported, handleSetAudioTrack: unsupported,
      handleEnableTextTrack: unsupported, handleDisableTextTrack: unsupported, handleNext: unsupported,
      handlePrevious: unsupported, handleEnableShuffle: unsupported, handleSetRepeatMode: unsupported,
      handleSetRating: unsupported, handleCustomAction: unsupported,
    };
  }

  private shouldPublish(status: PlaybackStatus, position: PlaybackPosition | undefined, nowMs: number): boolean {
    const prev = this.lastPublished;
    const canSeek = !!(position && position.end > position.start);
    if (!prev) return true;
    if (prev.status !== status || prev.canSeek !== canSeek || prev.live !== position?.live) return true;
    if ((position === undefined) !== (prev.start === undefined)) return true;
    if (position !== undefined && prev.start !== undefined && prev.end !== undefined) {
      if (Math.abs(position.start - prev.start) >= MATERIAL_CHANGE_SECONDS
        || Math.abs(position.end - prev.end) >= MATERIAL_CHANGE_SECONDS) {
        return true;
      }
      if (prev.position !== undefined) {
        const elapsed = Math.max(0, (nowMs - prev.publishedAtMs) / 1000);
        const expected = prev.status === 'playing' ? prev.position + elapsed : prev.position;
        if (Math.abs(position.position - expected) >= MATERIAL_CHANGE_SECONDS) return true;
      }
    }
    return false;
  }

  update(status: PlaybackStatus, position?: PlaybackPosition): void {
    if (!this.active) return;
    this.status = status;
    this.position = position;
    const nowMs = this.now();
    if (!this.shouldPublish(status, position, nowMs)) return;
    this.lastPublished = {
      status,
      canSeek: !!(position && position.end > position.start),
      live: position?.live,
      start: position?.start,
      end: position?.end,
      position: position?.position,
      publishedAtMs: nowMs,
    };
    this.publish([this.state()]);
  }

  close(): void {
    if (!this.active) return;
    this.active = false;
    this.lastPublished = undefined;
    this.publish([]);
  }

  private publish(states: MediaSessionState[]): void {
    if (!this.publishing) return;
    try {this.server.updateMediaSessionStates(states);}
    catch {
      this.publishing = false;
      console.warn('System media state updates are unavailable; on-screen playback controls remain active.');
    }
  }

  private state(): MediaSessionState {
    const position = this.position;
    const names: Record<PlaybackStatus, string> = {
      playing: 'PLAYING', paused: 'PAUSED', loading: 'BUFFERING', buffering: 'BUFFERING', ended: 'NOT_PLAYING', error: 'NOT_PLAYING',
    };
    const actions: Action[] = ['PLAY', 'PAUSE', 'TOGGLE_PLAY_PAUSE', 'STOP'].map(name => ({name}));
    if (position && position.end > position.start) actions.push(...['SEEK', 'SKIP_FORWARD', 'SKIP_BACKWARD'].map(name => ({name})));
    return {
      id: {id: 0},
      playbackState: {
        playbackStatus: names[this.status] as MediaSessionState['playbackState']['playbackStatus'],
        playbackSpeed: this.status === 'playing' ? 1 : 0,
        ...(position ? {position: {position: time(position.position), updatedAtTime: time(this.now() / 1000)}} : {}),
      },
      mediaInfo: {
        id: {contentId: this.item.id, catalogName: 'brutv'}, hasVideo: true,
        availableAudioTracks: [], availableTextTracks: [],
        ...(position ? {seekRangeStart: time(position.start), seekRangeEnd: time(position.end),
          ...(!position.live ? {duration: time(position.end)} : {})} : {}),
      },
      capabilities: {actions, speeds: [1], ratings: [], forwardSkipSteps: position ? [time(10)] : [], backwardSkipSteps: position ? [time(10)] : []},
      controls: [],
    };
  }
}
