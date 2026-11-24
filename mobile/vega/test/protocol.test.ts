import assert from 'node:assert/strict';
import test from 'node:test';
import {
  apiURL,
  httpURL,
  isUnsupportedPlaybackURL,
  loginLink,
  normalizePlaybackURL,
  parseLogin,
  parseURL,
  resolveURL,
  streamURL,
} from '../src/domain/login';
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
  for (const link of [
    'brutv://other?m3u=https://provider.example/list.m3u',
    'brutv://login?server=https://provider.example&username=u',
    'brutv://login?m3u=file:///data/list.m3u',
    'https://',
    'https://user:pass@provider.example/list.m3u',
    'https://user@provider.example/list.m3u',
    'https://@provider.example/list.m3u',
    'brutv://login?server=https://provider.example&username=%GG&password=p',
  ]) {
    assert.throws(() => parseLogin(link));
  }
});

test('API and playback URL paths percent-encode account characters', () => {
  const source = {kind: 'xtream' as const, server: 'https://provider.example/panel/', username: 'qa/one+', password: 'p&?'};
  assert.equal(apiURL(source, 'get_series_info', '9'), 'https://provider.example/panel/player_api.php?username=qa%2Fone%2B&password=p%26%3F&action=get_series_info&series_id=9');
  assert.equal(streamURL(source, 'live', '42', 'm3u8'), 'https://provider.example/panel/live/qa%2Fone%2B/p%26%3F/42.m3u8');
});

test('pure-TS RFC 3986 URL parser handles custom schemes, ports, IPv6, and @ in path or query', () => {
  const deepLink = parseURL('brutv://login?server=https://provider.example:8080&username=user@domain&password=p');
  assert.equal(deepLink.protocol, 'brutv:');
  assert.equal(deepLink.hostname, 'login');
  assert.equal(deepLink.search, '?server=https://provider.example:8080&username=user@domain&password=p');

  const withPortAndAt = httpURL('https://host.example:8080/live/user@domain/pass/42.m3u8?email=a@b.example');
  assert.equal(withPortAndAt.hostname, 'host.example');
  assert.equal(withPortAndAt.port, '8080');
  assert.equal(withPortAndAt.origin, 'https://host.example:8080');
  assert.equal(withPortAndAt.username, '');
  assert.equal(withPortAndAt.password, '');
  assert.equal(withPortAndAt.pathname, '/live/user@domain/pass/42.m3u8');
  assert.equal(withPortAndAt.search, '?email=a@b.example');

  const ipv6 = httpURL('https://[::1]:8443/live/1.m3u8');
  assert.equal(ipv6.hostname, '[::1]');
  assert.equal(ipv6.port, '8443');
  assert.equal(ipv6.origin, 'https://[::1]:8443');

  assert.equal(httpURL('https://host.example:443/a').origin, 'https://host.example');
  assert.equal(httpURL('http://host.example:80/a').origin, 'http://host.example');

  const apiWithPort = apiURL({kind: 'xtream', server: 'http://host.example:8080/panel/', username: 'u@d', password: 'p:1'}, 'get_live_streams');
  assert.equal(apiWithPort, 'http://host.example:8080/panel/player_api.php?username=u%40d&password=p%3A1&action=get_live_streams');
});

test('RFC 3986 relative URI resolution strips manifest filename and query and resolves dot segments', () => {
  const base = 'https://host.example:8080/live/u/p/42.m3u8?token=abc';
  assert.equal(resolveURL('seg1.ts', base), 'https://host.example:8080/live/u/p/seg1.ts');
  assert.equal(resolveURL('./sub/seg1.ts?k=1', base), 'https://host.example:8080/live/u/p/sub/seg1.ts?k=1');
  assert.equal(resolveURL('/abs/seg1.ts', base), 'https://host.example:8080/abs/seg1.ts');
  assert.equal(resolveURL('../seg1.ts', base), 'https://host.example:8080/live/u/seg1.ts');
  assert.equal(resolveURL('../../../../seg1.ts', base), 'https://host.example:8080/seg1.ts');
  assert.equal(resolveURL('//cdn.example/live/seg1.ts?x=2', base), 'https://cdn.example/live/seg1.ts?x=2');
  assert.equal(resolveURL('?token=next', base), 'https://host.example:8080/live/u/p/42.m3u8?token=next');
  assert.equal(resolveURL('https://edge.example:9090/s/seg1.ts', base), 'https://edge.example:9090/s/seg1.ts');

  const atBase = 'https://host.example:8080/live/user@domain/pass/42.m3u8?email=a@b.example';
  assert.equal(resolveURL('seg2.ts', atBase), 'https://host.example:8080/live/user@domain/pass/seg2.ts');
});

test('Xtream live .ts URLs normalize to .m3u8 preserving query while non-Xtream .ts and .mkv stay rejected', () => {
  assert.equal(
    normalizePlaybackURL('https://provider.example:8080/live/user/pass/42.ts'),
    'https://provider.example:8080/live/user/pass/42.m3u8',
  );
  assert.equal(
    normalizePlaybackURL('https://provider.example/panel/live/user/pass/42.TS?token=abc&s=1'),
    'https://provider.example/panel/live/user/pass/42.m3u8?token=abc&s=1',
  );
  assert.equal(
    normalizePlaybackURL('https://provider.example:8080/user/pass/12345.ts?token=xyz'),
    'https://provider.example:8080/user/pass/12345.m3u8?token=xyz',
  );
  assert.equal(isUnsupportedPlaybackURL(normalizePlaybackURL('https://provider.example:8080/user/pass/12345.ts?token=xyz')), false);

  const rawTs = normalizePlaybackURL('https://provider.example/channel.ts');
  assert.equal(rawTs, 'https://provider.example/channel.ts');
  assert.equal(isUnsupportedPlaybackURL(rawTs), true);

  const movieTs = normalizePlaybackURL('https://provider.example/movie/user/pass/42.ts');
  assert.equal(movieTs, 'https://provider.example/movie/user/pass/42.ts');
  assert.equal(isUnsupportedPlaybackURL(movieTs), true);

  for (const root of ['movie', 'series', 'timeshift', 'vod', 'hls', 'streams', 'static', 'assets']) {
    const nonLiveThreeSeg = `https://provider.example/${root}/sub/42.ts`;
    assert.equal(normalizePlaybackURL(nonLiveThreeSeg), nonLiveThreeSeg);
  }

  const mkv = normalizePlaybackURL('https://provider.example/movie/user/pass/42.mkv?sig=1');
  assert.equal(isUnsupportedPlaybackURL(mkv), true);
  assert.equal(isUnsupportedPlaybackURL('https://provider.example/movie/user/pass/42.mp4'), false);
});

test('M3U handles CRLF, quoted commas, case-insensitive attributes, deduplication, and first group', () => {
  const entries = parseM3U('#EXTM3U\r\n#EXTINF:-1 TVG-ID="news" tvg-logo="https://example.test/logo.png" group-title="News;Local" tvg-name="Fallback, Name",Actual, Name\r\nhttps://example.test/live/news.m3u8\r\n#EXTINF:-1 TVG-ID="news",Duplicate Entry\r\nhttps://example.test/live/news.m3u8\r\n#EXTINF:-1 tvg-name=Movie,\n#EXTGRP: ; Films;Drama\nhttps://example.test/movie/qa/qa/12.mp4\n#EXTINF:-1,Missing URL\n');
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
