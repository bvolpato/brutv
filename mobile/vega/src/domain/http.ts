import {httpURL, resolveURL} from './login';

export const IPTV_USER_AGENT = 'Mozilla/5.0 (Linux; VegaOS TV) AppleWebKit/537.36 (KHTML, like Gecko) BruTV/1.0';

export interface ResilientFetchOptions {
  signal?: AbortSignal;
  headers?: Record<string, string>;
  fetcher?: typeof fetch;
  maxRetries?: number;
  maxRedirects?: number;
  baseDelayMs?: number;
  maxDelayMs?: number;
  now?: () => number;
  random?: () => number;
}

export interface ResilientFetchResult {
  response: Response;
  url: string;
}

class RedirectError extends Error {}

const REDIRECT_STATUSES = new Set([301, 302, 307, 308]);
const SENSITIVE_HEADERS = new Set(['authorization', 'cookie', 'proxy-authorization']);

function isRetryableStatus(status: number): boolean {
  return status === 408 || status === 429 || status === 458 || (status >= 500 && status <= 599);
}

function stripSensitiveHeaders(headers: Record<string, string>): Record<string, string> {
  const cleaned: Record<string, string> = {};
  for (const [key, value] of Object.entries(headers)) {
    if (!SENSITIVE_HEADERS.has(key.toLowerCase())) {
      cleaned[key] = value;
    }
  }
  return cleaned;
}

function parseRetryAfterMs(header: string | null | undefined, now: () => number, maxDelayMs: number): number | undefined {
  if (!header) return undefined;
  const trimmed = header.trim();
  if (/^\d+$/.test(trimmed)) {
    return Math.min(maxDelayMs, Math.max(0, Number(trimmed) * 1000));
  }
  const timestamp = Date.parse(trimmed);
  if (Number.isFinite(timestamp)) {
    return Math.min(maxDelayMs, Math.max(0, timestamp - now()));
  }
  return undefined;
}

function sleepWithAbort(delayMs: number, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) {
    return Promise.reject(new Error('The request was aborted.'));
  }
  if (delayMs <= 0) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const onAbort = () => {
      clearTimeout(timer);
      reject(new Error('The request was aborted.'));
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort);
      resolve();
    }, delayMs);
    signal?.addEventListener('abort', onAbort, {once: true});
  });
}

function responseStatus(response: Response): number {
  return typeof response.status === 'number' ? response.status : (response.ok ? 200 : 500);
}

export async function resilientFetch(url: string, options: ResilientFetchOptions = {}): Promise<ResilientFetchResult> {
  const initialParsed = httpURL(url);
  const initialURL = initialParsed.href;
  const initialOrigin = initialParsed.origin;
  const fetcher = options.fetcher ?? fetch;
  const maxRetries = options.maxRetries ?? 3;
  const maxRedirects = options.maxRedirects ?? 10;
  const baseDelayMs = options.baseDelayMs ?? 500;
  const maxDelayMs = options.maxDelayMs ?? 10_000;
  const now = options.now ?? Date.now;
  const random = options.random ?? Math.random;
  const signal = options.signal;
  const baseHeaders: Record<string, string> = {'User-Agent': IPTV_USER_AGENT, ...options.headers};

  for (let attempt = 0; ; attempt++) {
    if (signal?.aborted) throw new Error('The request was aborted.');
    let currentURL = initialURL;
    let requestHeaders: Record<string, string> = {...baseHeaders};
    try {
      let response!: Response;
      let status = 200;
      for (let hop = 0; ; hop++) {
        response = await fetcher(currentURL, {signal, headers: requestHeaders});
        status = responseStatus(response);
        if (!REDIRECT_STATUSES.has(status)) break;
        const location = response.headers?.get?.('location');
        if (!location) break;
        if (hop >= maxRedirects) {
          void response.body?.cancel?.().catch(() => {});
          throw new RedirectError('Too many redirects.');
        }
        let nextParsed: ReturnType<typeof httpURL>;
        try {
          nextParsed = httpURL(resolveURL(location, currentURL));
        } catch {
          void response.body?.cancel?.().catch(() => {});
          throw new RedirectError('The provider returned an invalid redirect address.');
        }
        void response.body?.cancel?.().catch(() => {});
        if (nextParsed.origin !== initialOrigin) {
          requestHeaders = stripSensitiveHeaders(requestHeaders);
        }
        currentURL = nextParsed.href;
      }

      if (isRetryableStatus(status) && attempt < maxRetries && !signal?.aborted) {
        const retryAfter = parseRetryAfterMs(response.headers?.get?.('retry-after'), now, maxDelayMs);
        void response.body?.cancel?.().catch(() => {});
        const jitter = 0.75 + random() * 0.5;
        const delay = retryAfter ?? Math.min(maxDelayMs, Math.round(baseDelayMs * (2 ** attempt) * jitter));
        await sleepWithAbort(delay, signal);
        continue;
      }

      const finalURL = response.url ? httpURL(response.url).href : currentURL;
      return {response, url: finalURL};
    } catch (error) {
      if (signal?.aborted || error instanceof RedirectError || attempt >= maxRetries) {
        throw error;
      }
      const jitter = 0.75 + random() * 0.5;
      const delay = Math.min(maxDelayMs, Math.round(baseDelayMs * (2 ** attempt) * jitter));
      await sleepWithAbort(delay, signal);
    }
  }
}
