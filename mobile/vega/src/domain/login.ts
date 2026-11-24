export type LoginSource =
  | {kind: 'xtream'; server: string; username: string; password: string}
  | {kind: 'm3u'; url: string};

export interface ParsedURL {
  protocol: string;
  username: string;
  password: string;
  hasUserinfo: boolean;
  hostname: string;
  port: string;
  host: string;
  origin: string;
  pathname: string;
  search: string;
  hash: string;
  href: string;
}

const CONTROL_CHARS = /[\u0000-\u001f\u007f]/;
const SCHEME_PREFIX = /^([A-Za-z][A-Za-z0-9+.-]*):/;
const INVALID_HOST_CHARS = /[\s\\/?#@[\]:%]/;

// RFC 3986 §5.2.4 remove_dot_segments.
function removeDotSegments(path: string): string {
  let input = path;
  const output: string[] = [];
  while (input.length > 0) {
    if (input.startsWith('../')) {
      input = input.slice(3);
    } else if (input.startsWith('./')) {
      input = input.slice(2);
    } else if (input.startsWith('/./')) {
      input = '/' + input.slice(3);
    } else if (input === '/.') {
      input = '/';
    } else if (input.startsWith('/../')) {
      input = '/' + input.slice(4);
      output.pop();
    } else if (input === '/..') {
      input = '/';
      output.pop();
    } else if (input === '.' || input === '..') {
      input = '';
    } else {
      const start = input.startsWith('/') ? 1 : 0;
      const nextSlash = input.indexOf('/', start);
      if (nextSlash < 0) {
        output.push(input);
        input = '';
      } else {
        output.push(input.slice(0, nextSlash));
        input = input.slice(nextSlash);
      }
    }
  }
  return output.join('');
}

// Pure-TS RFC 3986 parser avoiding Kepler RN URL.js bugs (getter-only search,
// empty non-http hostname, broken relative resolution, and greedy password regex).
export function parseURL(value: string): ParsedURL {
  const trimmed = value.trim();
  if (!trimmed || CONTROL_CHARS.test(trimmed)) throw new TypeError('Invalid URL');
  const schemeMatch = SCHEME_PREFIX.exec(trimmed);
  if (!schemeMatch) throw new TypeError('Invalid URL');
  const protocol = schemeMatch[1].toLowerCase() + ':';
  const rest = trimmed.slice(schemeMatch[0].length);
  const hashIndex = rest.indexOf('#');
  const hash = hashIndex >= 0 ? rest.slice(hashIndex) : '';
  const beforeHash = hashIndex >= 0 ? rest.slice(0, hashIndex) : rest;
  const queryIndex = beforeHash.indexOf('?');
  const search = queryIndex >= 0 ? beforeHash.slice(queryIndex) : '';
  const beforeQuery = queryIndex >= 0 ? beforeHash.slice(0, queryIndex) : beforeHash;
  const isHttp = protocol === 'http:' || protocol === 'https:';

  if (beforeQuery.startsWith('//')) {
    const afterSlashes = beforeQuery.slice(2);
    const slashIndex = afterSlashes.indexOf('/');
    const authority = slashIndex >= 0 ? afterSlashes.slice(0, slashIndex) : afterSlashes;
    const rawPath = slashIndex >= 0 ? afterSlashes.slice(slashIndex) : '';
    if (/[\s\\]/.test(authority)) throw new TypeError('Invalid URL');

    const atIndex = authority.lastIndexOf('@');
    const hasUserinfo = atIndex >= 0;
    let username = '';
    let password = '';
    const hostport = hasUserinfo ? authority.slice(atIndex + 1) : authority;
    if (hasUserinfo) {
      const userinfo = authority.slice(0, atIndex);
      const colon = userinfo.indexOf(':');
      username = colon >= 0 ? userinfo.slice(0, colon) : userinfo;
      password = colon >= 0 ? userinfo.slice(colon + 1) : '';
    }

    let hostname = '';
    let port = '';
    if (hostport.startsWith('[')) {
      const end = hostport.indexOf(']');
      if (end <= 1) throw new TypeError('Invalid URL');
      hostname = hostport.slice(0, end + 1).toLowerCase();
      if (!/^\[[0-9a-f:.]+\]$/.test(hostname)) throw new TypeError('Invalid URL');
      const tail = hostport.slice(end + 1);
      if (tail.startsWith(':')) port = tail.slice(1);
      else if (tail !== '') throw new TypeError('Invalid URL');
    } else {
      if (hostport.includes('[') || hostport.includes(']')) throw new TypeError('Invalid URL');
      const colon = hostport.indexOf(':');
      if (colon >= 0) {
        hostname = hostport.slice(0, colon).toLowerCase();
        port = hostport.slice(colon + 1);
      } else {
        hostname = hostport.toLowerCase();
      }
      if (hostname && INVALID_HOST_CHARS.test(hostname)) throw new TypeError('Invalid URL');
    }

    if (port !== '') {
      if (!/^\d+$/.test(port) || Number(port) > 65535) throw new TypeError('Invalid URL');
      port = String(Number(port));
      if ((protocol === 'http:' && port === '80') || (protocol === 'https:' && port === '443')) port = '';
    }
    if (isHttp && !hostname) throw new TypeError('Invalid URL');

    const host = port ? `${hostname}:${port}` : hostname;
    const origin = isHttp ? `${protocol}//${host}` : 'null';
    const pathname = rawPath ? removeDotSegments(rawPath) : (isHttp ? '/' : '');
    const userPart = hasUserinfo ? (password ? `${username}:${password}@` : `${username}@`) : '';
    const href = `${protocol}//${userPart}${host}${pathname}${search}${hash}`;
    return {protocol, username, password, hasUserinfo, hostname, port, host, origin, pathname, search, hash, href};
  }

  if (isHttp) throw new TypeError('Invalid URL');
  return {
    protocol,
    username: '',
    password: '',
    hasUserinfo: false,
    hostname: '',
    port: '',
    host: '',
    origin: 'null',
    pathname: beforeQuery,
    search,
    hash,
    href: `${protocol}${beforeQuery}${search}${hash}`,
  };
}

// RFC 3986 §5.2 relative-URI resolution against an absolute base URI.
export function resolveURL(reference: string, base: string): string {
  const baseURL = parseURL(base);
  const ref = reference.trim();
  if (CONTROL_CHARS.test(ref)) throw new TypeError('Invalid URL');
  if (SCHEME_PREFIX.test(ref)) return parseURL(ref).href;

  const hashIndex = ref.indexOf('#');
  const rHash = hashIndex >= 0 ? ref.slice(hashIndex) : '';
  const rBeforeHash = hashIndex >= 0 ? ref.slice(0, hashIndex) : ref;
  const queryIndex = rBeforeHash.indexOf('?');
  const hasQuery = queryIndex >= 0;
  const rSearch = hasQuery ? rBeforeHash.slice(queryIndex) : '';
  const rPath = hasQuery ? rBeforeHash.slice(0, queryIndex) : rBeforeHash;

  if (rPath.startsWith('//')) {
    return parseURL(`${baseURL.protocol}${ref}`).href;
  }

  let targetPath: string;
  let targetSearch: string;
  if (rPath === '') {
    targetPath = baseURL.pathname;
    targetSearch = hasQuery ? rSearch : baseURL.search;
  } else if (rPath.startsWith('/')) {
    targetPath = removeDotSegments(rPath);
    targetSearch = rSearch;
  } else {
    const basePath = baseURL.pathname;
    const merged = basePath === ''
      ? '/' + rPath
      : basePath.slice(0, basePath.lastIndexOf('/') + 1) + rPath;
    targetPath = removeDotSegments(merged);
    targetSearch = rSearch;
  }

  const userPart = baseURL.hasUserinfo
    ? (baseURL.password ? `${baseURL.username}:${baseURL.password}@` : `${baseURL.username}@`)
    : '';
  const authority = baseURL.host || baseURL.hasUserinfo ? `//${userPart}${baseURL.host}` : '';
  return parseURL(`${baseURL.protocol}${authority}${targetPath}${targetSearch}${rHash}`).href;
}

export function httpURL(value: string): ParsedURL {
  let url: ParsedURL;
  try {
    url = parseURL(value);
  } catch {
    throw new Error('Use an HTTP or HTTPS address without embedded user information.');
  }
  if ((url.protocol !== 'http:' && url.protocol !== 'https:') || !url.hostname || url.hasUserinfo || url.username || url.password) {
    throw new Error('Use an HTTP or HTTPS address without embedded user information.');
  }
  return url;
}

const NON_LIVE_ROOT_SEGMENTS = new Set([
  'movie', 'series', 'timeshift', 'vod', 'hls', 'streams', 'static', 'assets',
]);

export function normalizePlaybackURL(value: string): string {
  const parsed = httpURL(value);
  const lowerPath = parsed.pathname.toLowerCase();
  if (lowerPath.endsWith('.ts')) {
    const threeSegmentMatch = /^\/([^/]+)\/[^/]+\/\d+\.ts$/i.exec(parsed.pathname);
    const isThreeSegmentLive = !!threeSegmentMatch && !NON_LIVE_ROOT_SEGMENTS.has(threeSegmentMatch[1].toLowerCase());
    const isXtreamLive = /(?:^|\/)live\/.+\.ts$/i.test(parsed.pathname) || isThreeSegmentLive;
    if (isXtreamLive) {
      const rewrittenPath = parsed.pathname.slice(0, -3) + '.m3u8';
      return `${parsed.origin}${rewrittenPath}${parsed.search}${parsed.hash}`;
    }
  }
  return parsed.href;
}

export function isUnsupportedPlaybackURL(value: string): boolean {
  const lowerPath = httpURL(value).pathname.toLowerCase();
  return lowerPath.endsWith('.ts') || lowerPath.endsWith('.mkv');
}

// Foundation URLComponents decodes percent escapes, but preserves literal '+' in queries.
function queryValues(url: ParsedURL): Map<string, string> {
  const result = new Map<string, string>();
  if (url.search.length <= 1) return result;
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
  if (url.pathname.toLowerCase().endsWith('/get.php') && username && password) {
    return {kind: 'xtream', server: url.origin + url.pathname.slice(0, url.pathname.lastIndexOf('/')), username, password};
  }
  return {kind: 'm3u', url: value.trim()};
}

export function parseLogin(value: string): LoginSource {
  const url = parseURL(value.trim());
  if (url.protocol !== 'brutv:') return playlistSource(value);
  if (url.hostname !== 'login') throw new Error('This is not a BruTV sign-in link.');
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

export function apiURL(
  source: Extract<LoginSource, {kind: 'xtream'}>,
  action?: string,
  id?: string,
  extraParams?: Record<string, string>,
): string {
  const base = httpURL(source.server.replace(/\/+$/, '') + '/player_api.php');
  let query = `username=${encodeURIComponent(source.username)}&password=${encodeURIComponent(source.password)}`;
  if (action) query += `&action=${encodeURIComponent(action)}`;
  if (id) query += `&series_id=${encodeURIComponent(id)}`;
  if (extraParams) {
    for (const [key, value] of Object.entries(extraParams)) {
      query += `&${encodeURIComponent(key)}=${encodeURIComponent(value)}`;
    }
  }
  return `${base.origin}${base.pathname}?${query}`;
}

export function streamURLPrefix(
  source: Extract<LoginSource, {kind: 'xtream'}>,
  section: 'live' | 'movie' | 'series',
): string {
  const base = httpURL(source.server.replace(/\/+$/, ''));
  const basePath = base.pathname === '/' ? '' : base.pathname.replace(/\/+$/, '');
  return `${base.origin}${basePath}/${section}/${encodeURIComponent(source.username)}/${encodeURIComponent(source.password)}/`;
}

const SAFE_SEGMENT = /^[A-Za-z0-9_-]+$/;

export function streamURLFromPrefix(prefix: string, id: string, extension: string): string {
  const encodedID = SAFE_SEGMENT.test(id) ? id : encodeURIComponent(id);
  const encodedExt = SAFE_SEGMENT.test(extension) ? extension : encodeURIComponent(extension);
  return `${prefix}${encodedID}.${encodedExt}`;
}

export function streamURL(source: Extract<LoginSource, {kind: 'xtream'}>, section: 'live' | 'movie' | 'series', id: string, extension: string): string {
  return streamURLFromPrefix(streamURLPrefix(source, section), id, extension);
}
