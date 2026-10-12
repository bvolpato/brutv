import Foundation

public enum M3UPlaylistError: LocalizedError, Sendable {
    case hlsMediaManifest

    public var errorDescription: String? {
        switch self {
        case .hlsMediaManifest:
            return "This is an HLS media manifest, not an IPTV channel playlist. Use the provider's playlist URL instead."
        }
    }
}

/// One channel entry from an M3U / M3U8 playlist.
public struct M3UEntry: Equatable, Sendable {
    public let name: String
    public let url: String
    public let logo: String?
    public let group: String
    public let tvgID: String?

    /// Xtream-style playlists mix live channels with `/movie/` and `/series/` items.
    public var isVOD: Bool {
        url.contains("/movie/") || url.contains("/series/")
    }
}

/// Parses extended M3U playlists (`#EXTM3U` / `#EXTINF`).
///
/// Supports the attributes used by IPTV providers: `tvg-id`, `tvg-name`,
/// `tvg-logo`, and `group-title`. `#EXTGRP` is used as a fallback group.
/// Other `#` lines are ignored. Entries without a URL are dropped.
///
/// The parser scans raw UTF-8 bytes. Provider playlists can exceed 250k entries
/// and 70 MB, where per-character `String` work takes many seconds.
public enum M3UPlaylistParser {
    public static let ungroupedTitle = "Uncategorized"

    public static func parse(_ text: String) -> [M3UEntry] {
        parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) -> [M3UEntry] {
        parseResult(data).entries
    }

    /// Parses an IPTV channel playlist and rejects HLS media manifests, whose segment URLs are
    /// not channels and should not appear as browseable content.
    public static func parseValidated(_ data: Data) throws -> [M3UEntry] {
        let result = parseResult(data)
        guard !result.containsHLSMediaTags else { throw M3UPlaylistError.hlsMediaManifest }
        return result.entries
    }

    private static func parseResult(_ data: Data) -> ParseResult {
        data.withUnsafeBytes { raw -> ParseResult in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return ParseResult(entries: [], containsHLSMediaTags: false) }
            return parse(UnsafeBufferPointer(start: base, count: raw.count))
        }
    }

    private struct ParseResult {
        let entries: [M3UEntry]
        let containsHLSMediaTags: Bool
    }

    private static func parse(_ buf: UnsafeBufferPointer<UInt8>) -> ParseResult {
        var entries: [M3UEntry] = []
        var pendingInfo: Range<Int>?
        var pendingGroup: String?
        var containsHLSMediaTags = false

        let count = buf.count
        var lineStart = 0
        while lineStart < count {
            var lineEnd = lineStart
            while lineEnd < count && buf[lineEnd] != Byte.newline { lineEnd += 1 }
            let next = lineEnd + 1

            // Trim spaces, tabs, and CR (some providers emit \r\r\n).
            var s = lineStart
            var e = lineEnd
            while s < e && isSpace(buf[s]) { s += 1 }
            while e > s && isSpace(buf[e - 1]) { e -= 1 }

            if s < e {
                if matchesPrefix(buf, s, e, Prefix.extX) {
                    containsHLSMediaTags = true
                } else if hasPrefix(buf, s, e, Prefix.extinf) {
                    pendingInfo = s..<e
                    pendingGroup = nil
                } else if hasPrefix(buf, s, e, Prefix.extgrp) {
                    pendingGroup = string(buf, s + Prefix.extgrp.count, e).trimmingCharacters(in: .whitespaces)
                } else if buf[s] != Byte.hash {
                    let url = string(buf, s, e)
                    let info = pendingInfo.map { parseInfo(buf, $0) } ?? InfoFields()
                    let group = primaryGroup(info.group) ?? primaryGroup(pendingGroup) ?? ungroupedTitle
                    let name = info.title ?? info.tvgName ?? URL(string: url)?.lastPathComponent ?? url
                    entries.append(M3UEntry(name: name, url: url, logo: info.logo, group: group, tvgID: info.tvgID))
                    pendingInfo = nil
                    pendingGroup = nil
                }
            }
            lineStart = next
        }
        return ParseResult(entries: entries, containsHLSMediaTags: containsHLSMediaTags)
    }

    private struct InfoFields {
        var title: String?
        var tvgName: String?
        var tvgID: String?
        var logo: String?
        var group: String?
    }

    /// Parses `#EXTINF:-1 key="value" key2=value2,Display Name`.
    private static func parseInfo(_ buf: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> InfoFields {
        var fields = InfoFields()

        // The title follows the first comma outside quotes.
        var inQuotes = false
        var split = range.upperBound
        var i = range.lowerBound
        while i < range.upperBound {
            let b = buf[i]
            if b == Byte.quote {
                inQuotes.toggle()
            } else if b == Byte.comma && !inQuotes {
                split = i
                break
            }
            i += 1
        }
        if split < range.upperBound {
            var ts = split + 1
            var te = range.upperBound
            while ts < te && isSpace(buf[ts]) { ts += 1 }
            while te > ts && isSpace(buf[te - 1]) { te -= 1 }
            if ts < te { fields.title = string(buf, ts, te) }
        }

        // key=value pairs before the title.
        i = range.lowerBound
        while i < split {
            guard buf[i] == Byte.equals else { i += 1; continue }

            var ks = i
            while ks > range.lowerBound && !isSpace(buf[ks - 1]) && buf[ks - 1] != Byte.colon { ks -= 1 }
            let keyStart = ks
            let keyEnd = i

            var vs = i + 1
            var ve: Int
            if vs < split && buf[vs] == Byte.quote {
                vs += 1
                ve = vs
                while ve < split && buf[ve] != Byte.quote { ve += 1 }
                i = ve + 1
            } else {
                ve = vs
                while ve < split && !isSpace(buf[ve]) { ve += 1 }
                i = ve
            }
            guard vs < ve else { continue }

            if matches(buf, keyStart, keyEnd, Key.tvgLogo) {
                fields.logo = string(buf, vs, ve)
            } else if matches(buf, keyStart, keyEnd, Key.groupTitle) {
                fields.group = string(buf, vs, ve)
            } else if matches(buf, keyStart, keyEnd, Key.tvgID) {
                fields.tvgID = string(buf, vs, ve)
            } else if matches(buf, keyStart, keyEnd, Key.tvgName) {
                fields.tvgName = string(buf, vs, ve)
            }
        }
        return fields
    }

    /// Deterministic positive ID from a URL (FNV-1a). Swift's `hashValue` changes per launch,
    /// which would break favorites and recents.
    public static func stableID(for url: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash & 0x7FFF_FFFF_FFFF_FFFF)
    }

    // MARK: - Byte helpers

    private enum Byte {
        static let newline = UInt8(ascii: "\n")
        static let hash = UInt8(ascii: "#")
        static let quote = UInt8(ascii: "\"")
        static let comma = UInt8(ascii: ",")
        static let equals = UInt8(ascii: "=")
        static let colon = UInt8(ascii: ":")
    }

    private enum Prefix {
        static let extinf = Array("#EXTINF".utf8)
        static let extgrp = Array("#EXTGRP:".utf8)
        static let extX = Array("#ext-x-".utf8)
    }

    private enum Key {
        static let tvgLogo = Array("tvg-logo".utf8)
        static let groupTitle = Array("group-title".utf8)
        static let tvgID = Array("tvg-id".utf8)
        static let tvgName = Array("tvg-name".utf8)
    }

    @inline(__always)
    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0D
    }

    @inline(__always)
    private static func hasPrefix(_ buf: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int, _ prefix: [UInt8]) -> Bool {
        guard e - s >= prefix.count else { return false }
        for k in 0..<prefix.count where buf[s + k] != prefix[k] { return false }
        return true
    }

    @inline(__always)
    private static func matchesPrefix(_ buf: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int, _ prefix: [UInt8]) -> Bool {
        guard e - s >= prefix.count else { return false }
        for k in 0..<prefix.count {
            var byte = buf[s + k]
            if byte >= 0x41 && byte <= 0x5A { byte += 0x20 }
            if byte != prefix[k] { return false }
        }
        return true
    }

    /// Case-insensitive ASCII key comparison.
    @inline(__always)
    private static func matches(_ buf: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int, _ key: [UInt8]) -> Bool {
        guard e - s == key.count else { return false }
        for k in 0..<key.count {
            var b = buf[s + k]
            if b >= 0x41 && b <= 0x5A { b += 0x20 }
            if b != key[k] { return false }
        }
        return true
    }

    @inline(__always)
    private static func string(_ buf: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: buf[s..<e]), as: UTF8.self)
    }

    /// The first non-empty group in a `;`-separated list, for example "Animation;Comedy" gives "Animation".
    static func primaryGroup(_ value: String?) -> String? {
        guard let value else { return nil }
        return value
            .split(separator: ";")
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}
