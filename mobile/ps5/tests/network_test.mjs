import {createServer} from 'node:http';
import {createReadStream} from 'node:fs';
import {stat} from 'node:fs/promises';
import {resolve, sep} from 'node:path';
import {spawn} from 'node:child_process';

const [binary, fixtureRoot] = process.argv.slice(2);
if (!binary || !fixtureRoot) throw new Error('Expected the player test and fixture directory');
const root = resolve(fixtureRoot);
const requested = new Set();
const server = createServer(async (req, res) => {
  try {
    const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    const filename = resolve(root, '.' + pathname);
    if (!filename.startsWith(root + sep)) { res.writeHead(403).end(); return; }
    const info = await stat(filename);
    if (!info.isFile()) { res.writeHead(404).end(); return; }
    requested.add(pathname);
    const range = req.headers.range?.match(/^bytes=(\d+)-(\d*)$/);
    const start = range ? Number(range[1]) : 0;
    const end = range?.[2] ? Math.min(Number(range[2]), info.size - 1) : info.size - 1;
    if (start > end || start >= info.size) { res.writeHead(416).end(); return; }
    const headers = {'Content-Length': end - start + 1, 'Accept-Ranges': 'bytes'};
    if (range) headers['Content-Range'] = `bytes ${start}-${end}/${info.size}`;
    headers['Content-Type'] = filename.endsWith('.m3u8') ? 'application/vnd.apple.mpegurl' :
      filename.endsWith('.ts') ? 'video/mp2t' : 'video/mp4';
    res.writeHead(range ? 206 : 200, headers);
    createReadStream(filename, {start, end}).on('error', () => res.destroy()).pipe(res);
  } catch { res.writeHead(404).end(); }
});
await new Promise((ready, reject) => {
  server.once('error', reject);
  server.listen(0, '127.0.0.1', ready);
});
try {
  const base = `http://127.0.0.1:${server.address().port}`;
  for (const stream of ['/video.mp4', '/hls/index.m3u8']) {
    await new Promise((done, reject) => {
      const child = spawn(binary, [base + stream], {stdio: 'inherit'});
      const deadline = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('Player network test timed out')); }, 60000);
      child.once('error', error => { clearTimeout(deadline); reject(error); });
      child.once('exit', code => { clearTimeout(deadline); code === 0 ? done() : reject(new Error(`Player test exited ${code}`)); });
    });
  }
  if (!requested.has('/video.mp4') || !requested.has('/hls/index.m3u8') ||
      ![...requested].some(path => path.endsWith('.ts'))) {
    throw new Error('The player did not fetch both the MP4 and HLS segments');
  }
  console.log('HTTP range and HLS segment playback verified');
} finally {
  server.closeAllConnections();
  await new Promise(done => server.close(done));
}
