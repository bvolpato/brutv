import {parseURL} from './login';

export interface PlaylistEntry {
  id: string;
  name: string;
  url: string;
  group: string;
  logo?: string;
  tvgID?: string;
  kind: 'live' | 'movie' | 'series';
}

const ATTRIBUTE_RE = /([\w-]+)=(?:"([^"]*)"|([^\s]+))/g;

function primaryGroup(value?: string): string | undefined {
  if (!value) return undefined;
  const parts = value.split(';');
  for (let index = 0; index < parts.length; index++) {
    const trimmed = parts[index].trim();
    if (trimmed) return trimmed;
  }
  return undefined;
}

export function stableID(value: string): string {
  // Two 32-bit lanes preserve FNV-1a 64-bit identity without Hermes BigInt support.
  let high = 0xcbf29ce4;
  let low = 0x84222325;
  let ascii = true;
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index);
    if (code >= 0x80) {
      ascii = false;
      break;
    }
    low = (low ^ code) >>> 0;
    const product = low * 0x1b3;
    high = (Math.imul(high, 0x1b3) + Math.imul(low, 0x100) + Math.floor(product / 0x100000000)) >>> 0;
    low = product >>> 0;
  }
  if (!ascii) {
    high = 0xcbf29ce4;
    low = 0x84222325;
    const bytes = unescape(encodeURIComponent(value));
    for (let index = 0; index < bytes.length; index++) {
      low = (low ^ bytes.charCodeAt(index)) >>> 0;
      const product = low * 0x1b3;
      high = (Math.imul(high, 0x1b3) + Math.imul(low, 0x100) + Math.floor(product / 0x100000000)) >>> 0;
      low = product >>> 0;
    }
  }
  high &= 0x7fffffff;
  return high.toString(16).padStart(8, '0') + low.toString(16).padStart(8, '0');
}

export function parseM3U(text: string): PlaylistEntry[] {
  const entries: PlaylistEntry[] = [];
  const seen = new Set<string>();
  let attributes: Record<string, string> = {};
  let title: string | undefined;
  let fallbackGroup: string | undefined;
  let offset = 0;
  while (offset < text.length) {
    const end = text.indexOf('\n', offset);
    const line = text.slice(offset, end < 0 ? text.length : end).trim();
    offset = end < 0 ? text.length : end + 1;
    if (!line) continue;
    if (line.startsWith('#EXTINF')) {
      attributes = {};
      fallbackGroup = undefined;
      let quoted = false;
      let comma = -1;
      for (let index = 0; index < line.length; index++) {
        const ch = line.charCodeAt(index);
        if (ch === 34) quoted = !quoted;
        else if (ch === 44 && !quoted) { comma = index; break; }
      }
      title = comma < 0 ? undefined : line.slice(comma + 1).trim() || undefined;
      const metadata = comma < 0 ? line : line.slice(0, comma);
      ATTRIBUTE_RE.lastIndex = 0;
      let match: RegExpExecArray | null;
      while ((match = ATTRIBUTE_RE.exec(metadata))) {
        attributes[match[1].toLowerCase()] = match[2] ?? match[3];
      }
    } else if (line.startsWith('#EXTGRP:')) {
      fallbackGroup = line.slice(8).trim();
    } else if (!line.startsWith('#')) {
      const id = stableID(line);
      if (!seen.has(id)) {
        seen.add(id);
        let name = title || attributes['tvg-name'];
        if (!name) {
          name = line;
          try { name = parseURL(line).pathname.split('/').pop() || line; } catch { /* Retain provider input for catalog inspection. */ }
        }
        entries.push({
          id,
          url: line,
          name,
          group: primaryGroup(attributes['group-title']) || primaryGroup(fallbackGroup) || 'Uncategorized',
          logo: attributes['tvg-logo'] || undefined,
          tvgID: attributes['tvg-id'] || undefined,
          kind: line.includes('/movie/') ? 'movie' : line.includes('/series/') ? 'series' : 'live',
        });
      }
      attributes = {};
      title = undefined;
      fallbackGroup = undefined;
    }
  }
  return entries;
}
