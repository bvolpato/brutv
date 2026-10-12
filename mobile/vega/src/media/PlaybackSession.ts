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
  load(url: string): Promise<void>; destroy(): Promise<void>;
  timeline?(): PlaybackTimeline | undefined;
  recordingMessage?(): string | undefined;
}
export type PlaybackStatus = 'loading' | 'buffering' | 'playing' | 'paused' | 'ended' | 'error';

export class PlaybackSession {
  private closed = false;
  private initialized = false;
  private ready = false;
  private surface?: string;
  private retryTimer?: ReturnType<typeof setTimeout>;
  private retries = 0;
  private listeners: [string, () => void][] = [];
  private adapter?: MediaAdapter;
  private wantsPlayback = true;
  private positionTimer?: ReturnType<typeof setInterval>;
  private heldPosition?: number;
  private expired = false;

  constructor(private media: MediaElement, private createAdapter: (onError: () => void) => MediaAdapter,
    private report: (status: PlaybackStatus) => void,
    private reportPosition: (position: PlaybackPosition | undefined, message?: string) => void = () => {}) {}

  async start(url: string): Promise<void> {
    if (this.closed) return;
    this.report('loading');
    try {
      await this.media.initialize();
      this.initialized = true;
      if (this.closed) { await this.media.deinitialize(); return; }
      this.bind('waiting', () => this.report(this.wantsPlayback ? 'buffering' : 'paused'));
      this.bind('playing', () => {
        if (!this.wantsPlayback) {this.media.pause(); this.report('paused'); return;}
        this.retries = 0; this.report('playing');
      });
      this.bind('pause', () => this.report('paused'));
      this.bind('ended', () => this.report('ended'));
      this.bind('error', () => this.retry(url));
      this.bind('timeupdate', () => this.updatePosition());
      this.adapter = this.createAdapter(() => this.retry(url));
      await this.adapter.load(url);
      if (this.closed) return;
      this.ready = true;
      this.positionTimer = setInterval(() => this.updatePosition(), 1000);
      this.updatePosition();
      if (this.surface) {
        this.media.setSurfaceHandle(this.surface);
        if (this.wantsPlayback) await this.media.play(); else {this.media.pause(); this.report('paused');}
      }
    } catch { if (!this.closed) this.report('error'); }
  }

  private bind(event: string, listener: () => void): void {
    const guarded = () => { if (!this.closed) listener(); };
    this.listeners.push([event, guarded]);
    this.media.addEventListener(event, guarded);
  }

  private retry(url: string): void {
    if (this.retryTimer || this.closed) return;
    if (this.retries >= 2) { this.report('error'); return; }
    this.report('buffering');
    const delay = 1000 * 2 ** this.retries++;
    this.retryTimer = setTimeout(async () => {
      this.retryTimer = undefined;
      if (this.closed) return;
      const position = this.heldPosition ?? this.media.currentTime;
      const oldOrigin = this.adapter?.timeline?.()?.recordingOrigin;
      const anchor = oldOrigin === undefined ? undefined : oldOrigin + position;
      try {
        await this.adapter?.load(url);
        if (this.closed) return;
        const range = this.adapter?.timeline?.();
        if (range && Number.isFinite(position)) {
          const remapped = anchor === undefined || range.recordingOrigin === undefined ? position : anchor - range.recordingOrigin;
          this.expired ||= remapped < range.start;
          this.media.currentTime = Math.max(range.start, Math.min(range.end, remapped));
        } else if (Number.isFinite(this.media.duration) && position > 0) this.media.currentTime = Math.min(this.media.duration, position);
        if (this.wantsPlayback) await this.media.play(); else {
          this.media.pause(); this.heldPosition = this.media.currentTime; this.report('paused');
        }
        this.updatePosition();
      } catch { if (!this.closed) this.retry(url); }
    }, delay);
  }

  surfaceCreated(handle: string): void {
    this.surface = handle;
    if (this.closed || !this.ready) return;
    this.media.setSurfaceHandle(handle);
    if (this.wantsPlayback) void this.media.play().catch(() => { if (!this.closed) this.report('error'); });
    else this.media.pause();
  }

  surfaceDestroyed(handle: string): void {
    if (!this.closed && this.initialized) { this.media.pause(); this.media.clearSurfaceHandle(handle); }
    if (this.surface === handle) this.surface = undefined;
  }

  async toggle(): Promise<void> {
    if (this.closed || !this.initialized) return;
    this.wantsPlayback = !this.wantsPlayback;
    if (this.wantsPlayback) {
      if (this.heldPosition !== undefined) {
        const range = this.adapter?.timeline?.();
        if (range) {
          this.expired ||= this.heldPosition < range.start;
          this.media.currentTime = Math.max(range.start, Math.min(range.end, this.heldPosition));
        }
      }
      this.heldPosition = undefined;
      if (this.ready) await this.media.play();
    } else {
      if (this.retryTimer) { clearTimeout(this.retryTimer); this.retryTimer = undefined; }
      this.media.pause(); this.heldPosition = this.media.currentTime;
    }
    this.updatePosition();
  }

  seek(delta: number): void {
    if (this.closed || !Number.isFinite(delta)) return;
    const range = this.adapter?.timeline?.();
    if (range) this.media.currentTime = Math.max(range.start, Math.min(range.end, this.media.currentTime + delta));
    else if (Number.isFinite(this.media.duration)) this.media.currentTime = Math.max(0, Math.min(this.media.duration, this.media.currentTime + delta));
    else return;
    if (!this.wantsPlayback) this.heldPosition = this.media.currentTime;
    this.expired = false; this.updatePosition();
  }

  async goLive(): Promise<void> {
    const range = this.adapter?.timeline?.();
    if (this.closed || !range?.live || range.liveTarget === undefined) return;
    this.media.currentTime = Math.max(range.start, Math.min(range.end, range.liveTarget));
    this.wantsPlayback = true; this.heldPosition = undefined; this.expired = false;
    await this.media.play(); this.updatePosition();
  }

  private updatePosition(): void {
    if (this.closed || !this.ready) return;
    const range = this.adapter?.timeline?.();
    if (!range) {this.reportPosition(undefined, this.adapter?.recordingMessage?.()); return;}
    if (!this.wantsPlayback && this.heldPosition !== undefined && this.heldPosition < range.start) {
      this.expired = true;
      this.media.currentTime = range.start;
      this.heldPosition = range.start;
    }
    this.reportPosition({...range, position: this.media.currentTime, paused: !this.wantsPlayback, expired: this.expired}, this.adapter?.recordingMessage?.());
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    if (this.positionTimer) clearInterval(this.positionTimer);
    for (const [event, listener] of this.listeners) this.media.removeEventListener(event, listener);
    if (this.initialized) {
      this.media.pause();
      if (this.surface) this.media.clearSurfaceHandle(this.surface);
      try {await this.adapter?.destroy();} finally {await this.media.deinitialize();}
    }
  }
}
