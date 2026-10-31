import assert from 'node:assert/strict';
import test from 'node:test';
import {apiURL, loginLink, parseLogin, streamURL} from '../src/domain/login';
import {parseM3U, stableID} from '../src/domain/m3u';
import {browse} from '../src/domain/catalog';

test('accepts iOS sign-in wire format, UTF-8 and literal plus without double decoding', () => {
  const source = {kind: 'xtream' as const, server: 'https://provider.example:8443/panel', username: 'família+&=', password: 'secret /?#%'};
  const golden = 'brutv://login?server=https://provider.example:8443/panel&username=fam%C3%ADlia%2B%26%3D&password=secret%20/%3F%23%25';
  assert.equal(loginLink(source), golden);
  assert.deepEqual(parseLogin(golden), source);
  assert.equal((parseLogin('brutv://login?server=https://provider.example&username=one+two&password=x%252B') as typeof source).username, 'one+two');
  assert.equal((parseLogin('brutv://login?server=https://provider.example&username=one+two&password=x%252B') as typeof source).password, 'x%2B');
});

test('nested M3U query values survive exactly one decoding pass', () => {
  const source = {kind: 'm3u' as const, url: 'https://provider.example/list.m3u?token=a%2Bb%26c&x=1#entry'};
  const golden = 'brutv://login?m3u=https://provider.example/list.m3u%3Ftoken%3Da%252Bb%2526c%26x%3D1%23entry';
  assert.equal(loginLink(source), golden);
  assert.deepEqual(parseLogin(golden), source);
});

test('get.php recognizes only the exact case-insensitive final path component', () => {
  assert.deepEqual(parseLogin('https://provider.example/panel/get.php?username=one%2Btwo&password=secret%26value&type=m3u_plus'), {
    kind: 'xtream', server: 'https://provider.example/panel', username: 'one+two', password: 'secret&value',
  });
  assert.deepEqual(parseLogin('https://provider.example/get.php?username=qa&password=qa'), {
    kind: 'xtream', server: 'https://provider.example', username: 'qa', password: 'qa',
  });
  assert.deepEqual(parseLogin('https://provider.example/panel/GET.PHP?username=qa&password=qa'), {
    kind: 'xtream', server: 'https://provider.example/panel', username: 'qa', password: 'qa',
  });
  assert.deepEqual(parseLogin('https://provider.example/target.php?username=family&password=secret'), {
    kind: 'm3u', url: 'https://provider.example/target.php?username=family&password=secret',
  });
});

test('rejects malformed links and device-local or unsupported URLs', () => {
  for (const link of ['brutv://other?m3u=https://provider.example/list.m3u', 'brutv://login?server=https://provider.example&username=u', 'brutv://login?m3u=file:///data/list.m3u', 'https://', 'https://user:pass@provider.example/list.m3u', 'brutv://login?server=https://provider.example&username=%GG&password=p']) {
    assert.throws(() => parseLogin(link));
  }
});

test('API and playback URL paths percent-encode account characters', () => {
  const source = {kind: 'xtream' as const, server: 'https://provider.example/panel/', username: 'qa/one+', password: 'p&?'};
  assert.equal(apiURL(source, 'get_series_info', '9'), 'https://provider.example/panel/player_api.php?username=qa%2Fone%2B&password=p%26%3F&action=get_series_info&series_id=9');
  assert.equal(streamURL(source, 'live', '42', 'm3u8'), 'https://provider.example/panel/live/qa%2Fone%2B/p%26%3F/42.m3u8');
});

test('M3U handles CRLF, quoted commas, case-insensitive attributes and first group', () => {
  const entries = parseM3U('#EXTM3U\r\n#EXTINF:-1 TVG-ID="news" tvg-logo="https://example.test/logo.png" group-title="News;Local" tvg-name="Fallback, Name",Actual, Name\r\nhttps://example.test/live/news.m3u8\r\n#EXTINF:-1 tvg-name=Movie,\n#EXTGRP: ; Films;Drama\nhttps://example.test/movie/qa/qa/12.mp4\n#EXTINF:-1,Missing URL\n');
  assert.equal(entries.length, 2);
  assert.equal(entries[0].name, 'Actual, Name');
  assert.equal(entries[0].group, 'News');
  assert.equal(entries[0].tvgID, 'news');
  assert.equal(entries[1].name, 'Movie');
  assert.equal(entries[1].group, 'Films');
  assert.equal(entries[1].kind, 'movie');
});

test('M3U stable IDs match masked 64-bit FNV-1a used in iOS', () => {
  for (const value of ['https://example.test/ação.m3u8', 'https://example.test/live/qa/qa/42.m3u8']) {
    let expected = 0xcbf29ce484222325n;
    for (const byte of Buffer.from(value)) expected = BigInt.asUintN(64, (expected ^ BigInt(byte)) * 0x100000001b3n);
    assert.equal(stableID(value), (expected & 0x7fffffffffffffffn).toString(16).padStart(16, '0'));
  }
});

test('section, category and Unicode search select real content', () => {
  const items = parseM3U('#EXTINF:-1 group-title="Local",Ação News\nhttps://example.test/live/1.m3u8\n#EXTINF:-1 group-title="Films",Film\nhttps://example.test/movie/1.mp4');
  assert.equal(browse(items, 'live', 'AÇÃO', 'Local').length, 1);
  assert.equal(browse(items, 'live', 'AÇÃO', 'Films').length, 0);
  assert.equal(browse(items, 'movie', '').length, 1);
});
