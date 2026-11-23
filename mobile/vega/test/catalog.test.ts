import assert from 'node:assert/strict';
import test from 'node:test';
import {loadCatalog, loadEpisodes} from '../src/domain/catalog';
import {IPTV_USER_AGENT, resilientFetch} from '../src/domain/http';

test('Xtream catalog and episode adapters use provider IDs and explicit container extensions', async () => {
  const previousFetch = global.fetch;
  const actions: string[] = [];
  global.fetch = async input => {
    const action = new URL(String(input)).searchParams.get('action') || 'auth';
    actions.push(action);
    const payload: Record<string, unknown> = {
      auth: {user_info: {auth: '1'}},
      get_live_categories: [{category_id: 7, category_name: 'News'}],
      get_live_streams: [{stream_id: 42, category_id: '7', name: 'Channel'}],
      get_vod_categories: [{category_id: '8', category_name: 'Films'}],
      get_vod_streams: [{stream_id: 43, category_id: 8, name: 'Movie', container_extension: 'mp4'}],
      get_series_categories: [{category_id: 9, category_name: 'Shows'}],
      get_series: [{series_id: 44, category_id: '9', name: 'Series'}],
      get_series_info: {episodes: {'1': [{id: '45', title: 'Episode one', container_extension: 'mp4'}]}},
    };
    return new Response(JSON.stringify(payload[action]), {status: 200});
  };
  try {
    const source = {kind: 'xtream' as const, server: 'https://provider.example/panel', username: 'qa', password: 'qa'};
    const catalog = await loadCatalog(source);
    assert.equal(catalog.items[0].url, 'https://provider.example/panel/live/qa/qa/42.m3u8');
    assert.equal(catalog.items[1].url, 'https://provider.example/panel/movie/qa/qa/43.mp4');
    assert.equal(catalog.items[2].url, undefined);
    assert.equal(catalog.items[2].group, 'Shows');
    const episodes = await loadEpisodes(source, '44');
    assert.equal(episodes[0].url, 'https://provider.example/panel/series/qa/qa/45.mp4');
    assert.equal(episodes[0].group, 'Season 1');
    assert.deepEqual(actions, ['auth', 'get_live_categories', 'get_live_streams', 'get_vod_categories', 'get_vod_streams', 'get_series_categories', 'get_series', 'get_series_info']);
  } finally { global.fetch = previousFetch; }
});

test('playlist loader rejects HLS media manifests instead of listing segments as channels', async () => {
  const previousFetch = global.fetch;
  global.fetch = async () => new Response('#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nhttps://example.test/segment.ts');
  try {
    await assert.rejects(loadCatalog({kind: 'm3u', url: 'https://provider.example/live.m3u8'}), /playback manifest/);
  } finally { global.fetch = previousFetch; }
});

test('provider rejections do not echo account credentials or URLs into errors', async () => {
  const previousFetch = global.fetch;
  global.fetch = async () => new Response('', {status: 403});
  try {
    await assert.rejects(loadCatalog({kind: 'xtream', server: 'https://provider.example', username: 'qa', password: 'qa'}), {message: 'The provider returned HTTP 403.'});
  } finally { global.fetch = previousFetch; }
});

test('Xtream catalog loads Live first and tolerates failing or non-array VOD and Series endpoints', async () => {
  const previousFetch = global.fetch;
  const actions: string[] = [];
  global.fetch = async input => {
    const action = new URL(String(input)).searchParams.get('action') || 'auth';
    actions.push(action);
    if (action === 'auth') return new Response(JSON.stringify({user_info: {auth: '1'}}), {status: 200});
    if (action === 'get_live_categories') return new Response(JSON.stringify({}), {status: 200});
    if (action === 'get_live_streams') return new Response(JSON.stringify([{stream_id: 7, name: 'Live One'}]), {status: 200});
    if (action === 'get_vod_categories') return new Response('', {status: 404});
    if (action === 'get_series_categories') return new Response(JSON.stringify([{category_id: 1, category_name: 'Shows'}]), {status: 200});
    if (action === 'get_series') return new Response(JSON.stringify({error: 'disabled'}), {status: 200});
    return new Response('[]', {status: 200});
  };
  try {
    const source = {kind: 'xtream' as const, server: 'https://provider.example', username: 'qa', password: 'qa'};
    const catalog = await loadCatalog(source);
    assert.equal(catalog.items.length, 1);
    assert.equal(catalog.items[0].kind, 'live');
    assert.equal(catalog.items[0].name, 'Live One');
    assert.equal(catalog.items[0].group, 'Uncategorized');
    assert.equal(actions[0], 'auth');
    assert.equal(actions[1], 'get_live_categories');
    assert.equal(actions[2], 'get_live_streams');
  } finally { global.fetch = previousFetch; }
});

test('resilientFetch sends IPTV User-Agent, follows relative redirects manually, and enforces hop and scheme limits', async () => {
  const seen: {url: string; ua: string | undefined}[] = [];
  const fetcher: typeof fetch = async (input, init) => {
    const url = String(input);
    const headers = init?.headers as Record<string, string> | undefined;
    seen.push({url, ua: headers?.['User-Agent']});
    if (url === 'https://entry.example:8080/live/u/p/42.m3u8?t=1') {
      return new Response('', {status: 302, headers: {Location: '../edge/stream.m3u8?s=2'}});
    }
    if (url === 'https://entry.example:8080/live/u/edge/stream.m3u8?s=2') {
      return new Response('', {status: 307, headers: {Location: 'https://cdn.example/final/42.m3u8'}});
    }
    return new Response('#EXTM3U\n', {status: 200});
  };
  const result = await resilientFetch('https://entry.example:8080/live/u/p/42.m3u8?t=1', {fetcher, baseDelayMs: 1});
  assert.equal(result.response.status, 200);
  assert.equal(result.url, 'https://cdn.example/final/42.m3u8');
  assert.deepEqual(seen.map(s => s.url), [
    'https://entry.example:8080/live/u/p/42.m3u8?t=1',
    'https://entry.example:8080/live/u/edge/stream.m3u8?s=2',
    'https://cdn.example/final/42.m3u8',
  ]);
  assert.ok(seen.every(s => s.ua === IPTV_USER_AGENT));

  await assert.rejects(
    resilientFetch('https://entry.example/loop', {
      fetcher: async () => new Response('', {status: 302, headers: {Location: '/loop'}}),
      maxRedirects: 2,
      baseDelayMs: 1,
    }),
    /Too many redirects/,
  );

  await assert.rejects(
    resilientFetch('https://entry.example/evil', {
      fetcher: async () => new Response('', {status: 302, headers: {Location: 'file:///etc/passwd'}}),
      baseDelayMs: 1,
    }),
    /invalid redirect/,
  );
});

test('resilientFetch retries Cloudflare 522, 429 Retry-After, and transient network errors without retrying 403', async () => {
  let calls = 0;
  const result = await resilientFetch('https://provider.example/api', {
    fetcher: async () => {
      calls++;
      if (calls === 1) return new Response('', {status: 522});
      if (calls === 2) return new Response('', {status: 429, headers: {'Retry-After': '0'}});
      if (calls === 3) throw new TypeError('network reset');
      return new Response('ok', {status: 200});
    },
    maxRetries: 3,
    baseDelayMs: 1,
    maxDelayMs: 5,
    random: () => 0.5,
  });
  assert.equal(calls, 4);
  assert.equal(await result.response.text(), 'ok');

  let forbiddenCalls = 0;
  const forbidden = await resilientFetch('https://provider.example/api', {
    fetcher: async () => { forbiddenCalls++; return new Response('', {status: 403}); },
    maxRetries: 3,
    baseDelayMs: 1,
  });
  assert.equal(forbiddenCalls, 1);
  assert.equal(forbidden.response.status, 403);
});

test('resilientFetch retries HTTP 458, cancels unused bodies, and strips sensitive headers across origins', async () => {
  let calls = 0;
  let cancelled = 0;
  const retryResult = await resilientFetch('https://provider.example/stream', {
    fetcher: async () => {
      calls++;
      if (calls === 1) {
        return {
          ok: false,
          status: 458,
          headers: new Headers(),
          body: {cancel: async () => { cancelled++; }},
        } as unknown as Response;
      }
      return new Response('ready', {status: 200});
    },
    maxRetries: 2,
    baseDelayMs: 1,
    maxDelayMs: 5,
    random: () => 0.5,
  });
  assert.equal(calls, 2);
  assert.equal(cancelled, 1);
  assert.equal(await retryResult.response.text(), 'ready');

  const hopHeaders: {url: string; headers: Record<string, string>}[] = [];
  const redirectResult = await resilientFetch('https://origin-a.example/start', {
    headers: {
      Authorization: 'Bearer secret',
      cookie: 'session=abc',
      'Proxy-Authorization': 'Basic xyz',
      'X-Trace': 'keep-me',
    },
    fetcher: async (input, init) => {
      const url = String(input);
      hopHeaders.push({url, headers: {...(init?.headers as Record<string, string>)}});
      if (url === 'https://origin-a.example/start') {
        return new Response('', {status: 302, headers: {Location: '/same-origin'}});
      }
      if (url === 'https://origin-a.example/same-origin') {
        return new Response('', {status: 302, headers: {Location: 'https://origin-b.example/final'}});
      }
      return new Response('ok', {status: 200});
    },
    baseDelayMs: 1,
  });
  assert.equal(redirectResult.url, 'https://origin-b.example/final');
  assert.equal(hopHeaders.length, 3);
  assert.equal(hopHeaders[0].headers.Authorization, 'Bearer secret');
  assert.equal(hopHeaders[1].headers.Authorization, 'Bearer secret');
  assert.equal(hopHeaders[1].headers.cookie, 'session=abc');
  assert.equal(hopHeaders[2].headers.Authorization, undefined);
  assert.equal(hopHeaders[2].headers.cookie, undefined);
  assert.equal(hopHeaders[2].headers['Proxy-Authorization'], undefined);
  assert.equal(hopHeaders[2].headers['X-Trace'], 'keep-me');
  assert.equal(hopHeaders[2].headers['User-Agent'], IPTV_USER_AGENT);
});

test('Xtream auth accepts boolean true, rejects expired or disabled status, and strips leading dots in extensions', async () => {
  const previousFetch = global.fetch;
  let authPayload: Record<string, unknown> = {user_info: {auth: true, status: 'Active'}};
  global.fetch = async input => {
    const action = new URL(String(input)).searchParams.get('action') || 'auth';
    const payload: Record<string, unknown> = {
      auth: authPayload,
      get_live_categories: [],
      get_live_streams: [{stream_id: 1, name: 'Live'}],
      get_vod_categories: [],
      get_vod_streams: [{stream_id: 2, name: 'Film', container_extension: '.mp4'}],
      get_series_categories: [],
      get_series: [{series_id: 3, name: 'Show'}],
      get_series_info: {episodes: {'1': [{id: '4', title: 'Ep 1', container_extension: '..m4v'}]}},
    };
    return new Response(JSON.stringify(payload[action]), {status: 200});
  };
  try {
    const source = {kind: 'xtream' as const, server: 'https://provider.example', username: 'qa', password: 'qa'};
    const catalog = await loadCatalog(source);
    assert.equal(catalog.items.find(item => item.id === 'movie:2')?.url, 'https://provider.example/movie/qa/qa/2.mp4');
    const episodes = await loadEpisodes(source, '3');
    assert.equal(episodes[0].url, 'https://provider.example/series/qa/qa/4.m4v');

    authPayload = {user_info: {auth: 1, status: 'Expired'}};
    await assert.rejects(loadCatalog(source), /rejected the sign-in details/);

    authPayload = {user_info: {auth: 'true', status: 'disabled'}};
    await assert.rejects(loadCatalog(source), /rejected the sign-in details/);
  } finally { global.fetch = previousFetch; }
});
