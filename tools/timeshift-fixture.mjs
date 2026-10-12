#!/usr/bin/env node
import http from 'node:http';
import {spawn} from 'node:child_process';
import {mkdtemp, readFile, rm, stat} from 'node:fs/promises';
import {createReadStream} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

// A live source with a six-second provider window, so longer pauses require local storage.
const port = Number(process.argv[2] ?? 8765);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Use a port from 1024 to 65535.');
const directory = await mkdtemp(path.join(tmpdir(), 'brutv-timeshift-fixture-'));
const playlist = path.join(directory, 'live.m3u8');
const ffmpeg = spawn('ffmpeg', [
  '-hide_banner', '-loglevel', 'error', '-re', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=15',
  '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
  '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'libx264', '-preset', 'ultrafast',
  '-b:v', '800k', '-maxrate', '800k', '-bufsize', '1600k', '-g', '30', '-keyint_min', '30',
  '-sc_threshold', '0', '-c:a', 'aac', '-b:a', '64k', '-f', 'hls', '-hls_time', '2',
  '-hls_list_size', '3', '-hls_delete_threshold', '1',
  '-hls_flags', 'delete_segments+independent_segments+omit_endlist+program_date_time',
  '-hls_segment_filename', path.join(directory, 'segment-%06d.ts'), playlist,
], {stdio: ['ignore', 'ignore', 'inherit']});
let stopped = false;
let manifestRequests = 0;
let segmentRequests = 0;
let segmentBytes = 0;
let missingSegments = 0;
const requested = new Set();
const server = http.createServer(async (request, response) => {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    response.writeHead(405).end(); return;
  }
  const pathname = new URL(request.url, `http://127.0.0.1:${port}`).pathname;
  const send = (type, body) => {
    response.writeHead(200, {'Content-Type': type, 'Cache-Control': 'no-store', 'Content-Length': Buffer.byteLength(body)});
    response.end(request.method === 'HEAD' ? undefined : body);
  };
  if (pathname === '/playlist.m3u') {
    send('audio/x-mpegurl', `#EXTM3U\n#EXTINF:-1 group-title="Test",Timeshift fixture\nhttp://${request.headers.host}/live.m3u8\n`);
    return;
  }
  if (pathname === '/stats') {
    send('application/json', JSON.stringify({manifestRequests, segmentRequests, segmentBytes, missingSegments, uniqueSegments: requested.size}));
    return;
  }
  const name = pathname.slice(1);
  if (name !== 'live.m3u8' && !/^segment-\d{6}\.ts$/.test(name)) {
    response.writeHead(404).end(); return;
  }
  try {
    if (name === 'live.m3u8') {
      manifestRequests++;
      send('application/vnd.apple.mpegurl', await readFile(playlist));
      return;
    }
    const file = path.join(directory, name);
    const info = await stat(file);
    let start = 0;
    let end = info.size - 1;
    const range = request.headers.range;
    if (range) {
      const match = /^bytes=(\d+)-(\d*)$/.exec(range);
      if (!match) { response.writeHead(416).end(); return; }
      start = Number(match[1]);
      end = match[2] ? Math.min(Number(match[2]), end) : end;
      if (start > end) { response.writeHead(416, {'Content-Range': `bytes */${info.size}`}).end(); return; }
    }
    if (request.method === 'GET') {
      segmentRequests++; requested.add(name); segmentBytes += end - start + 1;
    }
    response.writeHead(range ? 206 : 200, {
      'Content-Type': 'video/mp2t', 'Content-Length': end - start + 1, 'Accept-Ranges': 'bytes',
      ...(range ? {'Content-Range': `bytes ${start}-${end}/${info.size}`} : {}),
    });
    if (request.method === 'HEAD') response.end();
    else {
      const stream = createReadStream(file, {start, end});
      response.on('close', () => stream.destroy());
      stream.on('error', () => response.destroy());
      stream.pipe(response);
    }
  } catch {
    if (name !== 'live.m3u8') missingSegments++;
    if (!response.headersSent) response.writeHead(404).end();
    else response.destroy();
  }
});

async function close() {
  if (stopped) return;
  stopped = true;
  ffmpeg.kill('SIGTERM');
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
  if (ffmpeg.exitCode === null && ffmpeg.signalCode === null) {
    await new Promise(resolve => ffmpeg.once('exit', resolve));
  }
  await rm(directory, {recursive: true, force: true});
}
process.once('SIGINT', () => { void close(); });
process.once('SIGTERM', () => { void close(); });
ffmpeg.once('error', error => { console.error(error.message); void close(); process.exitCode = 1; });
ffmpeg.once('exit', () => { if (!stopped) { console.error('ffmpeg exited'); void close(); process.exitCode = 1; } });
server.once('error', error => { console.error(error.message); void close(); process.exitCode = 1; });
server.listen(port, '127.0.0.1', () => {
  console.log(`Source: http://127.0.0.1:${port}/playlist.m3u`);
  console.log(`Android emulator: http://10.0.2.2:${port}/playlist.m3u`);
  console.log(`Counters: http://127.0.0.1:${port}/stats`);
});
