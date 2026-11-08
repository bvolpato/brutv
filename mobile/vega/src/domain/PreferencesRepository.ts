import {emptyPreferences, Preferences, readPreferences} from './preferences';

export interface PreferenceFiles {
  read(name: string): Promise<string | undefined>;
  write(name: string, text: string): Promise<number>;
}

const slots = ['brutv-library-v1-a.json', 'brutv-library-v1-b.json'];

export class PreferencesRepository {
  private activeSlot = 1;
  private generation = 0;
  private writes = Promise.resolve();

  constructor(private files: PreferenceFiles) {}

  async load(): Promise<Preferences> {
    const records = await Promise.all(slots.map(async (name, slot) => {
      const text = await this.files.read(name);
      if (text === undefined) return undefined;
      const value = JSON.parse(text);
      if (!Number.isSafeInteger(value?.generation) || value.generation < 1) throw new Error('Invalid saved-library generation.');
      return {slot, generation: value.generation as number, preferences: readPreferences(JSON.stringify(value.preferences))};
    }).map(promise => promise.then(value => ({value}), () => ({error: true as const}))));
    const valid = records.flatMap(record => 'value' in record && record.value ? [record.value] : []);
    valid.sort((a, b) => b.generation - a.generation);
    if (!valid.length) {
      if (records.some(record => 'error' in record)) throw new Error('Saved-library data could not be restored.');
      return emptyPreferences();
    }
    this.activeSlot = valid[0].slot;
    this.generation = valid[0].generation;
    return valid[0].preferences;
  }

  save(preferences: Preferences): Promise<void> {
    // Whitelist the snapshot before queueing it; sources and catalog URLs are never serialized.
    const snapshot = readPreferences(JSON.stringify(preferences));
    this.writes = this.writes.catch(() => {}).then(async () => {
      const slot = 1 - this.activeSlot;
      const generation = this.generation + 1;
      if (!Number.isSafeInteger(generation)) throw new Error('Saved-library generation exceeds its limit.');
      const text = JSON.stringify({generation, preferences: snapshot});
      const written = await this.files.write(slots[slot], text);
      if (written !== text.length) throw new Error('Incomplete saved-library write.');
      this.activeSlot = slot;
      this.generation = generation;
    });
    return this.writes;
  }
}
