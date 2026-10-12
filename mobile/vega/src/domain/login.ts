export type LoginSource =
  | {kind: 'xtream'; server: string; username: string; password: string}
  | {kind: 'm3u'; url: string};

export function httpURL(value: string): URL {
  const url = new URL(value);
  if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password) {
    throw new Error('Use an HTTP or HTTPS address without embedded user information.');
  }
  return url;
}

// Foundation URLComponents decodes percent escapes, but preserves literal '+' in queries.
function queryValues(url: URL): Map<string, string> {
  const result = new Map<string, string>();
  for (const part of url.search.slice(1).split('&')) {
    const index = part.indexOf('=');
    const name = decodeURIComponent(index < 0 ? part : part.slice(0, index)).toLowerCase();
    if (!result.has(name)) {
      result.set(name, decodeURIComponent(index < 0 ? '' : part.slice(index + 1)).trim());
    }
  }
  return result;
}

export function playlistSource(value: string): LoginSource {
  const url = httpURL(value.trim());
  const values = queryValues(url);
  const username = values.get('username');
  const password = values.get('password');
  if (url.pathname.toLowerCase().endsWith('get.php') && username && password) {
    return {kind: 'xtream', server: url.origin + url.pathname.slice(0, url.pathname.lastIndexOf('/')), username, password};
  }
  return {kind: 'm3u', url: value.trim()};
}

export function parseLogin(value: string): LoginSource {
  const url = new URL(value.trim());
  if (url.protocol.toLowerCase() !== 'brutv:') return playlistSource(value);
  if (url.hostname.toLowerCase() !== 'login') throw new Error('This is not a BruTV sign-in link.');
  const values = queryValues(url);
  const playlist = values.get('m3u');
  if (playlist) {
    httpURL(playlist);
    return {kind: 'm3u', url: playlist};
  }
  const server = values.get('server');
  const username = values.get('username');
  const password = values.get('password');
  if (!server || !username || !password) throw new Error('The sign-in link is missing account details.');
  httpURL(server);
  return {kind: 'xtream', server, username, password};
}

// Match iOS URLComponents.urlQueryAllowed minus & = + ? #, including its literal : / @.
export function escapeLoginValue(value: string): string {
  return encodeURIComponent(value).replace(/%3A|%2F|%40|%24|%3B|%2C/gi, encoded =>
    String.fromCharCode(parseInt(encoded.slice(1), 16)),
  );
}

export function loginLink(source: LoginSource): string {
  const fields = source.kind === 'm3u'
    ? [['m3u', source.url]]
    : [['server', source.server], ['username', source.username], ['password', source.password]];
  return 'brutv://login?' + fields.map(([key, value]) => `${key}=${escapeLoginValue(value)}`).join('&');
}

export function apiURL(source: Extract<LoginSource, {kind: 'xtream'}>, action?: string, id?: string): string {
  const url = httpURL(source.server.replace(/\/+$/, '') + '/player_api.php');
  url.search = `username=${encodeURIComponent(source.username)}&password=${encodeURIComponent(source.password)}`;
  if (action) url.search += `&action=${encodeURIComponent(action)}`;
  if (id) url.search += `&series_id=${encodeURIComponent(id)}`;
  return url.href;
}

export function streamURL(source: Extract<LoginSource, {kind: 'xtream'}>, section: 'live' | 'movie' | 'series', id: string, extension: string): string {
  const base = source.server.replace(/\/+$/, '');
  return `${base}/${section}/${encodeURIComponent(source.username)}/${encodeURIComponent(source.password)}/${encodeURIComponent(id)}.${encodeURIComponent(extension)}`;
}
