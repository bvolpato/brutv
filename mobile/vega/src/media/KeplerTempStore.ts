import {KeplerFileSystem} from '@amazon-devices/kepler-file-system';
import {TempStore} from './HlsRecorder';

const FLAT_FILE_RE = /^brutv-timeshift-[a-z0-9]+-[a-z0-9]+\.b64$/;
const SESSION_FILE_RE = /^brutv-ts-[a-z0-9]+\/[a-z0-9]+\.b64$/;
const SESSION_DIR_RE = /^brutv-ts-[a-z0-9]+$/;

function filePath(name: string): string {
  if (!SESSION_FILE_RE.test(name) && !FLAT_FILE_RE.test(name)) {
    throw new Error('Invalid live-buffer file name.');
  }
  return `/tmp/${name}`;
}

function dirPath(name: string): string {
  if (!SESSION_DIR_RE.test(name)) {
    throw new Error('Invalid live-buffer directory name.');
  }
  return `/tmp/${name}`;
}

// SDK 0.23 documents UTF-8 string IO. Encoded segment bytes count toward the disk cap.
export const keplerTempStore: TempStore = {
  async entries() {
    return (await KeplerFileSystem.getEntries('/tmp')).map(entry => entry.startsWith('/tmp/') ? entry.slice(5) : entry);
  },
  async write(name, value) {
    const written = await KeplerFileSystem.writeStringToFile(filePath(name), value, 'UTF-8');
    if (written !== value.length) throw new Error('Incomplete temporary live-buffer write.');
  },
  read: name => KeplerFileSystem.readFileAsString(filePath(name), 'UTF-8'),
  remove: name => KeplerFileSystem.removeFile(filePath(name)),
  async removeDir(name) {
    const target = dirPath(name);
    if (await KeplerFileSystem.exists(target)) {
      await KeplerFileSystem.removeDirAll(target);
    }
  },
};
