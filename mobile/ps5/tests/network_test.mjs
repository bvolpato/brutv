import {createServer} from 'node:http';
import {createReadStream} from 'node:fs';
import {readFile, stat} from 'node:fs/promises';
import {resolve, sep} from 'node:path';
import {spawn} from 'node:child_process';

const [binary, fixtureRoot] = process.argv.slice(2);
if (!binary || !fixtureRoot) throw new Error('Expected the player test and fixture directory');
const root = resolve(fixtureRoot);
const requested = new Set();
const seenUserAgents = new Set();
let sawCookieHeader = false;
let sawOriginHeader = false;
let sawLiveNoCache = false;
let flakyHits = 0;

function streamLiveTs(filename, info, res) {
  res.writeHead(200, {'Content-Type': 'video/mp2t'});
  const source = createReadStream(filename, {highWaterMark: Math.ceil(info.size / 100 / 188) * 188});
  source.pause();
  const timer = setInterval(() => {
    const chunk = source.read();
    if (chunk) res.write(chunk);
  }, 100);
  source.once('end', () => { clearInterval(timer); res.end(); });
  source.once('error', () => { clearInterval(timer); res.destroy(); });
  res.once('close', () => { clearInterval(timer); source.destroy(); });
}

const server = createServer(async (req, res) => {
  try {
    if (req.headers['user-agent']) seenUserAgents.add(req.headers['user-agent']);
    if (req.headers.cookie === 'session=brutv-test') sawCookieHeader = true;
    if (req.headers.origin === 'https://brutv.example') sawOriginHeader = true;
    const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    requested.add(pathname);
    if (pathname === '/live.ts' && String(req.headers['cache-control'] || '').toLowerCase().includes('no-cache')) {
      sawLiveNoCache = true;
    }

    // Xtream .m3u8 -> .ts fallback test: .m3u8 fails with 404, .ts streams live.ts.
    if (pathname === '/live/u/p/100.m3u8' || pathname === '/u/p/300.m3u8') {
      res.writeHead(404).end();
      return;
    }
    if (pathname === '/live/u/p/100.ts' || pathname === '/u/p/300.ts') {
      const liveFile = resolve(root, 'live.ts');
      streamLiveTs(liveFile, await stat(liveFile), res);
      return;
    }

    // Xtream .ts -> .m3u8 fallback + extensionless HLS segment (allowed_extensions=ALL).
    if (pathname === '/live/u/p/200.ts') {
      res.writeHead(404).end();
      return;
    }
    if (pathname === '/live/u/p/200.m3u8') {
      const manifest = await readFile(resolve(root, 'hls/index.m3u8'), 'utf8');
      const rewritten = manifest.replace(/part-(\d+)\.ts/g, '/seg/part$1');
      res.writeHead(200, {'Content-Type': 'application/vnd.apple.mpegurl'});
      res.end(rewritten);
      return;
    }
    const segMatch = pathname.match(/^\/seg\/part(\d+)$/);
    if (segMatch) {
      const segFile = resolve(root, `hls/part-${segMatch[1]}.ts`);
      const info = await stat(segFile);
      res.writeHead(200, {'Content-Type': 'video/mp2t', 'Content-Length': info.size});
      createReadStream(segFile).on('error', () => res.destroy()).pipe(res);
      return;
    }

    // Flaky VOD stream: first request serves header + partial video then drops socket.
    if (pathname === '/flaky.mp4') {
      const videoFile = resolve(root, 'video.mp4');
      const info = await stat(videoFile);
      ++flakyHits;
      const range = req.headers.range?.match(/^bytes=(\d+)-(\d*)$/);
      const start = range ? Number(range[1]) : 0;
      const end = range?.[2] ? Math.min(Number(range[2]), info.size - 1) : info.size - 1;
      const headers = {'Content-Length': end - start + 1, 'Accept-Ranges': 'bytes', 'Content-Type': 'video/mp4'};
      if (range) headers['Content-Range'] = `bytes ${start}-${end}/${info.size}`;
      res.writeHead(range ? 206 : 200, headers);
      if (flakyHits === 1 && start === 0) {
        const cutoff = Math.min(info.size - 1, Math.floor(info.size / 3));
        const partial = createReadStream(videoFile, {start: 0, end: cutoff});
        partial.on('data', chunk => res.write(chunk));
        partial.once('end', () => res.destroy());
        return;
      }
      createReadStream(videoFile, {start, end}).on('error', () => res.destroy()).pipe(res);
      return;
    }

    const filename = resolve(root, '.' + pathname);
    if (!filename.startsWith(root + sep)) { res.writeHead(403).end(); return; }
    const info = await stat(filename);
    if (!info.isFile()) { res.writeHead(404).end(); return; }
    if (pathname === '/live.ts') {
      streamLiveTs(filename, info, res);
      return;
    }
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
function runPlayer(args, timeoutMs = 30000, env = process.env) {
  return new Promise((done, reject) => {
    const child = spawn(binary, args, {stdio: 'inherit', env});
    const deadline = setTimeout(() => { child.kill('SIGKILL'); reject(new Error(`Player test timed out: ${args.join(' ')}`)); }, timeoutMs);
    child.once('error', error => { clearTimeout(deadline); reject(error); });
    child.once('exit', code => { clearTimeout(deadline); code === 0 ? done() : reject(new Error(`Player test exited ${code}: ${args.join(' ')}`)); });
  });
}
try {
  const base = `http://127.0.0.1:${server.address().port}`;
  for (const stream of ['/video.mp4', '/hls/index.m3u8']) {
    await runPlayer([base + stream], 60000);
  }
  for (const mode of ['--live', '--live-direct']) {
    const env = mode === '--live-direct' ? {...process.env, TMPDIR: resolve(root, 'missing-temp-directory')} : process.env;
    await runPlayer([mode, base + '/live.ts'], 30000, env);
  }
  await runPlayer(['--vod-headers', base + '/video.mp4'], 30000);
  await runPlayer(['--live-fallback', base + '/live/u/p/100.m3u8?token=test'], 30000);
  await runPlayer(['--live-fallback', base + '/live/u/p/200.ts?token=test'], 30000);
  await runPlayer(['--live-fallback', base + '/u/p/300.m3u8?token=test'], 30000);
  await runPlayer(['--vod-reconnect', base + '/flaky.mp4'], 30000);
  if (!requested.has('/video.mp4') || !requested.has('/hls/index.m3u8') ||
      ![...requested].some(path => path.endsWith('.ts'))) {
    throw new Error('The player did not fetch both the MP4 and HLS segments');
  }
  if (!requested.has('/live/u/p/100.m3u8') || !requested.has('/live/u/p/100.ts')) {
    throw new Error('Xtream .m3u8 -> .ts fallback did not fetch alternate URL');
  }
  if (!requested.has('/u/p/300.m3u8') || !requested.has('/u/p/300.ts')) {
    throw new Error('3-segment Xtream .m3u8 -> .ts fallback did not fetch alternate URL');
  }
  if (!requested.has('/live/u/p/200.ts') || !requested.has('/live/u/p/200.m3u8') || !requested.has('/seg/part000')) {
    throw new Error('Xtream .ts -> .m3u8 fallback or extensionless HLS segment was not fetched');
  }
  if (!sawLiveNoCache) {
    throw new Error('Live stream requests did not include Cache-Control: no-cache');
  }
  if (!seenUserAgents.has('BruTV/1.0') || [...seenUserAgents].some(ua => ua.startsWith('Lavf/'))) {
    throw new Error(`Expected default BruTV/1.0 User-Agent and no Lavf/* UA; saw: ${[...seenUserAgents].join(', ')}`);
  }
  if (!sawCookieHeader || !sawOriginHeader) {
    throw new Error('Custom Cookie / Origin M3U headers were not forwarded over HTTP');
  }
  if (flakyHits < 2) {
    throw new Error('VOD reconnect did not retry after mid-stream socket drop');
  }
  console.log('HTTP range, HLS, headers, Xtream bidirectional fallback, extensionless segments, and VOD reconnect verified');
} finally {
  server.closeAllConnections();
  await new Promise(done => server.close(done));
}
