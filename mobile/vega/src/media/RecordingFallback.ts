// A recorded rendition may be incompatible even when the original master has playable alternatives.
export class RecordingFallback {
  private direct = false;
  private requested = false;
  get disabled(): boolean {return this.direct;}

  request(): boolean {
    if (this.direct) return false;
    this.requested = true;
    return true;
  }
  disable(): void {this.direct = true; this.requested = false;}

  async load(recorded: () => Promise<void>, release: () => Promise<void>, original: () => Promise<void>): Promise<void> {
    if (this.direct) {await original(); return;}
    if (!this.requested) try {
      await recorded();
      if (!this.requested) return;
    } catch {this.requested = true;}
    this.disable();
    await release();
    await original();
  }
}
