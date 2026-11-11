import {KeplerFileSystem} from '@amazon-devices/kepler-file-system';
import {Preferences} from './domain/preferences';
import {PreferencesRepository} from './domain/PreferencesRepository';

const repository = new PreferencesRepository({
  async read(name) {
    const path = `/data/${name}`;
    const entries = await KeplerFileSystem.getEntries('/data');
    if (!entries.some(entry => entry === name || entry === path)) return undefined;
    const metadata = await KeplerFileSystem.getMetadata(path, false);
    if (metadata.size > 512 * 1024) throw new Error('Saved-library data exceeds its size limit.');
    return KeplerFileSystem.readFileAsString(path, 'UTF-8');
  },
  write: (name, text) => KeplerFileSystem.writeStringToFile(`/data/${name}`, text, 'UTF-8'),
});

export const loadPreferences = (): Promise<Preferences> => repository.load();
export const savePreferences = (preferences: Preferences): Promise<void> => repository.save(preferences);
