import assert from 'node:assert/strict';
import test from 'node:test';
import {loadCatalog, loadEpisodes} from '../src/domain/catalog';

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
