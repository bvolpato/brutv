export interface MediaElement {
  initialize(): Promise<void>;
  deinitialize(): Promise<void>;
  play(): Promise<void>;
  pause(): void;
  currentTime: number;
  duration: number;
  paused: boolean;
  setSurfaceHandle(handle: string): void;
  clearSurfaceHandle(handle: string): void;
  addEventListener(event: string, listener: () => void): void;
  removeEventListener(event: string, listener: () => void): void;
}
export interface PlaybackTimeline {
  start: number; end: number; live: boolean; liveTarget?: number;
  recording?: boolean; message?: string; recordedBytes?: number; recordedSeconds?: number;
  recordingOrigin?: number;
}
export interface PlaybackPosition extends PlaybackTimeline {position: number; paused: boolean; expired: boolean}
export interface MediaAdapter {
  load(url: string): Promise<void>;
  unload?(): Promise<void>;
  destroy(): Promise<void>;
  timeline?(): PlaybackTimeline | undefined;
  recordingMessage?(): string | undefined;
}
export type PlaybackStatus = 'loading' | 'buffering' | 'playing' | 'paused' | 'ended' | 'error';

interface ReloadSnapshot {
  wasReady: boolean;
  position: number;
  anchor?: number;
}

export interface PlaybackSessionOptions {
  live?: boolean;
  bufferingTimeoutMs?: number;
  liveStallTimeoutMs?: number;
  vodStallTimeoutMs?: number;
  healthyPlaybackMs?: number;
  retryDelaysMs?: readonly number[];
  watchdogIntervalMs?: number;
  now?: () => number;
}

const DEFAULT_RETRY_DELAYS_MS = [1000, 2000, 4000, 8000, 15000] as const;
const DEFAULT_BUFFERING_TIMEOUT_MS = 24_000;
const DEFAULT_LIVE_STALL_TIMEOUT_MS = 10_000;
const DEFAULT_VOD_STALL_TIMEOUT_MS = 15_000;
const DEFAULT_HEALTHY_PLAYBACK_MS = 30_000;
const DEFAULT_WATCHDOG_INTERVAL_MS = 1000;

export class PlaybackSession {
  private closed = false;
  private closePromise?: Promise<void>;
  private initializing = false;
  private initialized = false;
  private deinitialized = false;
  private ready = false;
  private needsReload = false;
  private reloading = false;
  private activeReloadGen?: number;
  private pendingReload?: ReloadSnapshot;
  private surface?: string;
  private surfaceAttached?: string;
  private retryTimer?: ReturnType<typeof setTimeout>;
  private retries = 0;
  private listeners: [string, () => void][] = [];
  private adapter?: MediaAdapter;
  private wantsPlayback = true;
  private positionTimer?: ReturnType<typeof setInterval>;
  private heldPosition?: number;
  private expired = false;
  private status: PlaybackStatus = 'loading';
  private url?: string;
  private loadGen = 0;
  private bufferingSince?: number;
  private cumulativeHealthyMs = 0;
  private lastHealthySampleAt?: number;
  private lastObservedTime?: number;
  private lastTimeAdvanceAt?: number;

  private readonly liveHint: boolean;
  private readonly bufferingTimeoutMs: number;
  private readonly liveStallTimeoutMs: number;
  private readonly vodStallTimeoutMs: number;
  private readonly healthyPlaybackMs: number;
  private readonly retryDelaysMs: readonly number[];
  private readonly watchdogIntervalMs: number;
  private readonly now: () => number;

  constructor(private media: MediaElement, private createAdapter: (onError: () => void) => MediaAdapter,
    private report: (status: PlaybackStatus) => void,
    private reportPosition: (position: PlaybackPosition | undefined, message?: string) => void = () => {},
    options: PlaybackSessionOptions = {}) {
    this.liveHint = options.live ?? false;
    this.bufferingTimeoutMs = options.bufferingTimeoutMs ?? DEFAULT_BUFFERING_TIMEOUT_MS;
    this.liveStallTimeoutMs = options.liveStallTimeoutMs ?? DEFAULT_LIVE_STALL_TIMEOUT_MS;
    this.vodStallTimeoutMs = options.vodStallTimeoutMs ?? DEFAULT_VOD_STALL_TIMEOUT_MS;
    this.healthyPlaybackMs = options.healthyPlaybackMs ?? DEFAULT_HEALTHY_PLAYBACK_MS;
    this.retryDelaysMs = options.retryDelaysMs ?? DEFAULT_RETRY_DELAYS_MS;
    this.watchdogIntervalMs = options.watchdogIntervalMs ?? DEFAULT_WATCHDOG_INTERVAL_MS;
    this.now = options.now ?? Date.now;
  }

  private setStatus(next: PlaybackStatus): void {
    const prev = this.status;
    this.status = next;
    if (next === 'loading' || next === 'buffering') {
      if (prev !== 'loading' && prev !== 'buffering') {
        this.bufferingSince = this.now();
      } else if (this.bufferingSince === undefined) {
        this.bufferingSince = this.now();
      }
      this.lastHealthySampleAt = undefined;
      this.lastTimeAdvanceAt = undefined;
    } else if (next === 'playing') {
      const now = this.now();
      this.bufferingSince = undefined;
      this.lastObservedTime = this.media.currentTime;
      this.lastTimeAdvanceAt = now;
      this.lastHealthySampleAt = now;
    } else {
      this.bufferingSince = undefined;
      this.lastHealthySampleAt = undefined;
      this.lastTimeAdvanceAt = undefined;
    }
    this.report(next);
  }

  private isLive(): boolean {
    const timeline = this.adapter?.timeline?.();
    if (timeline !== undefined) return timeline.live;
    return this.liveHint || this.media.duration === Infinity;
  }

  private ensurePositionTimer(): void {
    if (this.positionTimer || this.closed) return;
    this.positionTimer = setInterval(() => {
      this.tickWatchdog();
      this.updatePosition();
    }, this.watchdogIntervalMs);
  }

  private attachSurface(): void {
    if (this.surface && this.surfaceAttached !== this.surface) {
      this.media.setSurfaceHandle(this.surface);
      this.surfaceAttached = this.surface;
    }
  }

  private async deinitializeOnce(): Promise<void> {
    if (this.deinitialized) return;
    this.deinitialized = true;
    await this.media.deinitialize();
  }

  async start(url: string): Promise<void> {
    if (this.closed) return;
    this.url = url;
    this.setStatus('loading');
    this.initializing = true;
    try {
      await this.media.initialize();
    } catch {
      this.initializing = false;
      if (this.closed) {
        await this.deinitializeOnce().catch(() => {});
        return;
      }
      this.setStatus('error');
      return;
    }
    this.initializing = false;
    this.initialized = true;
    if (this.closed) {
      await this.deinitializeOnce();
      return;
    }

    this.bind('waiting', () => {
      if (this.status === 'error') return;
      this.setStatus(this.wantsPlayback ? 'buffering' : 'paused');
    });
    this.bind('stalled', () => {
      if (this.status === 'error') return;
      this.setStatus(this.wantsPlayback ? 'buffering' : 'paused');
    });
    this.bind('playing', () => {
      if (this.status === 'error' || this.retryTimer || this.needsReload) return;
      if (!this.wantsPlayback) { this.media.pause(); this.setStatus('paused'); return; }
      this.setStatus('playing');
    });
    this.bind('pause', () => {
      if (this.status === 'error' || this.retryTimer || (this.needsReload && this.wantsPlayback)) return;
      this.setStatus('paused');
    });
    this.bind('ended', () => {
      if (this.isLive() && this.wantsPlayback) {
        this.retry(url);
      } else {
        this.setStatus('ended');
      }
    });
    this.bind('error', () => this.retry(url));
    this.bind('timeupdate', () => {
      this.checkPlayheadAdvance();
      this.updatePosition();
    });

    this.adapter = this.createAdapter(() => this.retry(url));
    this.ensurePositionTimer();

    const gen = ++this.loadGen;
    try {
      await this.adapter.load(url);
      if (this.closed || gen !== this.loadGen) return;
      this.ready = true;
      this.updatePosition();
      if (this.surface) {
        this.attachSurface();
        if (this.wantsPlayback) await this.media.play();
        else { this.media.pause(); this.setStatus('paused'); }
      }
    } catch {
      if (!this.closed && gen === this.loadGen) this.retry(url);
    }
  }

  private bind(event: string, listener: () => void): void {
    const guarded = () => { if (!this.closed) listener(); };
    this.listeners.push([event, guarded]);
    this.media.addEventListener(event, guarded);
  }

  private checkPlayheadAdvance(): void {
    if (this.closed || !this.wantsPlayback || this.media.paused || this.status !== 'playing') return;
    const current = this.media.currentTime;
    const now = this.now();
    if (!Number.isFinite(current)) return;
    if (this.lastObservedTime === undefined) {
      this.lastObservedTime = current;
      this.lastTimeAdvanceAt = now;
      this.lastHealthySampleAt = now;
      return;
    }
    if (current > this.lastObservedTime + 0.01) {
      const mediaDeltaMs = (current - this.lastObservedTime) * 1000;
      const wallElapsedMs = this.lastHealthySampleAt === undefined ? 0 : Math.max(0, now - this.lastHealthySampleAt);
      this.lastObservedTime = current;
      this.lastTimeAdvanceAt = now;
      this.lastHealthySampleAt = now;
      if (this.retries > 0) {
        this.cumulativeHealthyMs += Math.min(wallElapsedMs, mediaDeltaMs * 1.1);
        if (this.cumulativeHealthyMs >= this.healthyPlaybackMs) {
          this.retries = 0;
          this.cumulativeHealthyMs = 0;
        }
      }
    } else if (current < this.lastObservedTime - 0.01) {
      // Backward timeline jump (e.g. HLS live discontinuity or native seek): rebase without crediting healthy time.
      this.lastObservedTime = current;
      this.lastTimeAdvanceAt = now;
      this.lastHealthySampleAt = now;
    }
  }

  private tickWatchdog(): void {
    if (this.closed || this.retryTimer || !this.url) return;
    if (!this.wantsPlayback) return;
    const now = this.now();

    if (this.status === 'loading' || this.status === 'buffering') {
      if (this.bufferingSince !== undefined && now - this.bufferingSince >= this.bufferingTimeoutMs) {
        this.retry(this.url);
      }
      return;
    }

    if (this.status === 'playing' && !this.media.paused) {
      this.checkPlayheadAdvance();
      if (this.lastTimeAdvanceAt !== undefined) {
        const stallLimit = this.isLive() ? this.liveStallTimeoutMs : this.vodStallTimeoutMs;
        if (now - this.lastTimeAdvanceAt >= stallLimit) {
          this.retry(this.url);
        }
      }
    }
  }

  private retry(url: string): void {
    if (this.retryTimer || this.closed || this.status === 'error') return;
    ++this.loadGen;
    this.reloading = false;
    this.activeReloadGen = undefined;
    this.cumulativeHealthyMs = 0;
    this.lastHealthySampleAt = undefined;
    const wasReady = this.ready;
    const position = this.heldPosition ?? this.media.currentTime;
    const oldOrigin = this.adapter?.timeline?.()?.recordingOrigin;
    const anchor = oldOrigin === undefined ? undefined : oldOrigin + position;
    const snapshot: ReloadSnapshot = {wasReady, position, anchor};
    this.pendingReload = snapshot;
    this.needsReload = true;
    this.ready = false;
    this.media.pause();
    void this.adapter?.unload?.().catch(() => {});
    if (this.retries >= this.retryDelaysMs.length) {
      this.setStatus('error');
      return;
    }
    this.setStatus('buffering');
    const delay = this.retryDelaysMs[this.retries++];
    this.retryTimer = setTimeout(() => {
      this.retryTimer = undefined;
      void this.reload(url, snapshot);
    }, delay);
  }

  private async reload(url: string, snapshot: ReloadSnapshot): Promise<void> {
    if (this.closed) return;
    const gen = ++this.loadGen;
    this.reloading = true;
    this.activeReloadGen = gen;
    if (this.status !== 'buffering') this.setStatus('buffering');
    this.bufferingSince = this.now();
    try {
      await this.adapter?.load(url);
      if (this.closed || gen !== this.loadGen) return;
      this.needsReload = false;
      this.pendingReload = undefined;
      this.ready = true;
      this.ensurePositionTimer();
      this.attachSurface();
      const range = this.adapter?.timeline?.();
      if (snapshot.wasReady) {
        if (range && Number.isFinite(snapshot.position)) {
          if (this.wantsPlayback && range.live && !range.recording && range.liveTarget !== undefined) {
            this.media.currentTime = Math.max(range.start, Math.min(range.end, range.liveTarget));
          } else {
            const remapped = snapshot.anchor === undefined || range.recordingOrigin === undefined
              ? snapshot.position
              : snapshot.anchor - range.recordingOrigin;
            this.expired ||= remapped < range.start;
            this.media.currentTime = Math.max(range.start, Math.min(range.end, remapped));
          }
        } else if (Number.isFinite(this.media.duration) && snapshot.position > 0) {
          this.media.currentTime = Math.min(this.media.duration, snapshot.position);
        }
      }
      if (this.wantsPlayback) {
        if (this.surface) await this.media.play();
      } else {
        this.media.pause();
        this.heldPosition = this.media.currentTime;
        this.setStatus('paused');
      }
      this.updatePosition();
    } catch {
      if (this.activeReloadGen === gen) {
        this.reloading = false;
        this.activeReloadGen = undefined;
      }
      if (!this.closed && gen === this.loadGen) this.retry(url);
    } finally {
      if (this.activeReloadGen === gen) {
        this.reloading = false;
        this.activeReloadGen = undefined;
      }
    }
  }

  surfaceCreated(handle: string): void {
    this.surface = handle;
    if (this.closed || !this.ready) return;
    this.attachSurface();
    if (this.wantsPlayback) {
      void this.media.play().catch(() => {
        if (this.closed) return;
        if (this.url) this.retry(this.url);
        else this.setStatus('error');
      });
    } else {
      this.media.pause();
    }
  }

  surfaceDestroyed(handle: string): void {
    if (!this.closed && this.initialized) { this.media.pause(); this.media.clearSurfaceHandle(handle); }
    if (this.surface === handle) this.surface = undefined;
    if (this.surfaceAttached === handle) this.surfaceAttached = undefined;
  }

  async toggle(): Promise<void> {
    await this.setPlaying(!this.wantsPlayback);
  }

  async play(): Promise<void> { await this.setPlaying(true); }

  async pause(): Promise<void> { await this.setPlaying(false); }

  private async setPlaying(playing: boolean): Promise<void> {
    if (this.closed) return;
    const canResumeReload = this.needsReload && !this.retryTimer && !this.reloading && !!this.url;
    if (this.wantsPlayback === playing) {
      if (playing ? ((!this.ready && !canResumeReload) || !this.media.paused) : (!this.initialized || this.media.paused)) return;
    }
    this.wantsPlayback = playing;
    if (this.wantsPlayback) {
      if (canResumeReload && this.url) {
        const position = this.heldPosition ?? this.pendingReload?.position ?? this.media.currentTime;
        const snapshot: ReloadSnapshot = this.pendingReload
          ? {
              wasReady: this.pendingReload.wasReady,
              position,
              anchor: this.heldPosition !== undefined && this.heldPosition !== this.pendingReload.position
                ? undefined
                : this.pendingReload.anchor,
            }
          : {wasReady: false, position};
        this.heldPosition = undefined;
        if (this.status === 'error') this.retries = 0;
        await this.reload(this.url, snapshot);
        return;
      }
      if (this.heldPosition !== undefined) {
        const range = this.adapter?.timeline?.();
        if (range) {
          this.expired ||= this.heldPosition < range.start;
          this.media.currentTime = Math.max(range.start, Math.min(range.end, this.heldPosition));
        }
      }
      this.heldPosition = undefined;
      if (this.ready) {
        const now = this.now();
        this.lastObservedTime = this.media.currentTime;
        this.lastTimeAdvanceAt = now;
        this.lastHealthySampleAt = now;
        await this.media.play();
      }
    } else {
      if (this.retryTimer) { clearTimeout(this.retryTimer); this.retryTimer = undefined; }
      if (this.initialized) {
        this.media.pause();
        if (this.ready) this.heldPosition = this.media.currentTime;
        else if (this.heldPosition === undefined && this.pendingReload) this.heldPosition = this.pendingReload.position;
      }
      this.setStatus('paused');
    }
    this.updatePosition();
  }

  seek(delta: number): void {
    if (this.closed || !Number.isFinite(delta)) return;
    this.seekTo(this.media.currentTime + delta);
  }

  seekTo(position: number): void {
    if (this.closed || !Number.isFinite(position)) return;
    const range = this.adapter?.timeline?.();
    if (range) this.media.currentTime = Math.max(range.start, Math.min(range.end, position));
    else if (Number.isFinite(this.media.duration)) this.media.currentTime = Math.max(0, Math.min(this.media.duration, position));
    else return;
    const now = this.now();
    this.lastObservedTime = this.media.currentTime;
    this.lastTimeAdvanceAt = now;
    this.lastHealthySampleAt = now;
    if (!this.wantsPlayback) this.heldPosition = this.media.currentTime;
    this.expired = false; this.updatePosition();
  }

  async goLive(): Promise<void> {
    if (this.closed) return;
    if (this.needsReload && !this.retryTimer && !this.reloading && this.url) {
      await this.setPlaying(true);
      return;
    }
    const range = this.adapter?.timeline?.();
    if (!range?.live || range.liveTarget === undefined) return;
    this.media.currentTime = Math.max(range.start, Math.min(range.end, range.liveTarget));
    this.wantsPlayback = true; this.heldPosition = undefined; this.expired = false;
    const now = this.now();
    this.lastObservedTime = this.media.currentTime;
    this.lastTimeAdvanceAt = now;
    this.lastHealthySampleAt = now;
    await this.media.play(); this.updatePosition();
  }

  private updatePosition(): void {
    if (this.closed || !this.ready) return;
    const range = this.adapter?.timeline?.();
    if (!range) { this.reportPosition(undefined, this.adapter?.recordingMessage?.()); return; }
    if (!this.wantsPlayback && this.heldPosition !== undefined && this.heldPosition < range.start) {
      this.expired = true;
      this.media.currentTime = range.start;
      this.heldPosition = range.start;
    }
    this.reportPosition({...range, position: this.media.currentTime, paused: !this.wantsPlayback, expired: this.expired}, this.adapter?.recordingMessage?.());
  }

  async close(): Promise<void> {
    if (this.closePromise) return this.closePromise;
    this.closed = true;
    this.loadGen++;
    if (this.retryTimer) { clearTimeout(this.retryTimer); this.retryTimer = undefined; }
    if (this.positionTimer) { clearInterval(this.positionTimer); this.positionTimer = undefined; }
    for (const [event, listener] of this.listeners) this.media.removeEventListener(event, listener);
    this.listeners = [];
    this.closePromise = (async () => {
      if (this.initialized) {
        this.media.pause();
        if (this.surfaceAttached) {
          this.media.clearSurfaceHandle(this.surfaceAttached);
          this.surfaceAttached = undefined;
        } else if (this.surface) {
          this.media.clearSurfaceHandle(this.surface);
        }
        try { await this.adapter?.destroy(); } finally { await this.deinitializeOnce(); }
      } else if (this.initializing) {
        await this.deinitializeOnce();
      }
    })();
    return this.closePromise;
  }
}
