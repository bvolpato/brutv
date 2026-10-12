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
export interface MediaAdapter {load(url: string): Promise<void>; destroy(): Promise<void>}
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

  constructor(private media: MediaElement, private createAdapter: (onError: () => void) => MediaAdapter, private report: (status: PlaybackStatus) => void) {}

  async start(url: string): Promise<void> {
    if (this.closed) return;
    this.report('loading');
    try {
      await this.media.initialize();
      this.initialized = true;
      if (this.closed) { await this.media.deinitialize(); return; }
      this.bind('waiting', () => this.report('buffering'));
      this.bind('playing', () => { this.retries = 0; this.report('playing'); });
      this.bind('pause', () => this.report('paused'));
      this.bind('ended', () => this.report('ended'));
      this.bind('error', () => this.retry(url));
      this.adapter = this.createAdapter(() => this.retry(url));
      await this.adapter.load(url);
      if (this.closed) return;
      this.ready = true;
      if (this.surface) { this.media.setSurfaceHandle(this.surface); await this.media.play(); }
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
      const position = this.media.currentTime;
      try {
        await this.adapter?.load(url);
        if (this.closed) return;
        if (Number.isFinite(this.media.duration) && position > 0) this.media.currentTime = position;
        await this.media.play();
      } catch { if (!this.closed) this.retry(url); }
    }, delay);
  }

  surfaceCreated(handle: string): void {
    this.surface = handle;
    if (this.closed || !this.ready) return;
    this.media.setSurfaceHandle(handle);
    void this.media.play().catch(() => { if (!this.closed) this.report('error'); });
  }

  surfaceDestroyed(handle: string): void {
    if (!this.closed && this.initialized) { this.media.pause(); this.media.clearSurfaceHandle(handle); }
    if (this.surface === handle) this.surface = undefined;
  }

  async toggle(): Promise<void> {
    if (this.closed || !this.initialized) return;
    if (this.media.paused) await this.media.play(); else {
      if (this.retryTimer) { clearTimeout(this.retryTimer); this.retryTimer = undefined; }
      this.media.pause();
    }
  }

  seek(delta: number): void {
    if (this.closed || !Number.isFinite(this.media.duration)) return;
    this.media.currentTime = Math.max(0, Math.min(this.media.duration, this.media.currentTime + delta));
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    for (const [event, listener] of this.listeners) this.media.removeEventListener(event, listener);
    if (this.initialized) {
      this.media.pause();
      if (this.surface) this.media.clearSurfaceHandle(this.surface);
      await this.adapter?.destroy();
      await this.media.deinitialize();
    }
  }
}
