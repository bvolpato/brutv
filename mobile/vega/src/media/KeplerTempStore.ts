import {KeplerFileSystem} from '@amazon-devices/kepler-file-system';
import {TempStore} from './HlsRecorder';

function path(name: string): string {
  if (!/^brutv-timeshift-[a-z0-9]+-[a-z0-9]+\.b64$/.test(name)) throw new Error('Invalid live-buffer file name.');
  return `/tmp/${name}`;
}

// SDK 0.23 documents UTF-8 string IO. Encoded segment bytes count toward the disk cap.
export const keplerTempStore: TempStore = {
  async entries() {return (await KeplerFileSystem.getEntries('/tmp')).map(entry => entry.startsWith('/tmp/') ? entry.slice(5) : entry);},
  async write(name, value) {
    const written = await KeplerFileSystem.writeStringToFile(path(name), value, 'UTF-8');
    if (written !== value.length) throw new Error('Incomplete temporary live-buffer write.');
  },
  read: name => KeplerFileSystem.readFileAsString(path(name), 'UTF-8'),
  remove: name => KeplerFileSystem.removeFile(path(name)),
};
