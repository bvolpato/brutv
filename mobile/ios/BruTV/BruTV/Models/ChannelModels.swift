import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

public enum MediaURL {
    public static func parse(_ raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if let direct = URL(string: trimmed) {
            return direct
        }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: encoded)
        }
        return nil
    }
}

public enum ChannelTextHelper {
    /// Fast normalized search string (case- and diacritic-insensitive) with an ASCII fast path.
    public static func normalizedSearchText(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let isASCII = raw.utf8.allSatisfy { $0 < 0x80 }
        if isASCII {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(raw.utf8.count)
            for b in raw.utf8 {
                bytes.append((b >= 0x41 && b <= 0x5A) ? (b + 0x20) : b)
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        return raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Parses ratings such as "8.4", "8.4/10", or " 7.5 " into a comparable Double.
    public static func parseRating(_ raw: String?) -> Double {
        guard let raw else { return 0 }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let prefix: Substring
        if let slash = trimmed.firstIndex(of: "/") {
            prefix = trimmed[..<slash]
        } else {
            prefix = trimmed[...]
        }
        let cleaned = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(cleaned), value.isFinite, value > 0 else { return 0 }
        return value
    }

    /// Detects stream quality by scanning UTF-8 bytes case-insensitively without allocating an uppercased copy.
    public static func detectQuality(from name: String) -> StreamQuality {
        var sawFHD = false
        var sawHD = false
        return name.utf8.withContiguousStorageIfAvailable { buf -> StreamQuality in
            let n = buf.count
            var i = 0
            while i < n {
                let c0 = asciiUpper(buf[i])
                if c0 == 0x34, i + 1 < n, asciiUpper(buf[i + 1]) == 0x4B { // 4K
                    return .uhd4k
                }
                if c0 == 0x55, i + 2 < n, asciiUpper(buf[i + 1]) == 0x48, asciiUpper(buf[i + 2]) == 0x44 { // UHD
                    return .uhd4k
                }
                if !sawFHD {
                    if c0 == 0x46, i + 2 < n, asciiUpper(buf[i + 1]) == 0x48, asciiUpper(buf[i + 2]) == 0x44 { // FHD
                        sawFHD = true
                    } else if c0 == 0x31, i + 4 < n,
                              buf[i + 1] == 0x30, buf[i + 2] == 0x38, buf[i + 3] == 0x30,
                              asciiUpper(buf[i + 4]) == 0x50 { // 1080P
                        sawFHD = true
                    }
                }
                if !sawHD {
                    if c0 == 0x48, i + 1 < n, asciiUpper(buf[i + 1]) == 0x44 { // HD
                        sawHD = true
                    } else if c0 == 0x37, i + 3 < n,
                              buf[i + 1] == 0x32, buf[i + 2] == 0x30,
                              asciiUpper(buf[i + 3]) == 0x50 { // 720P
                        sawHD = true
                    }
                }
                i += 1
            }
            if sawFHD { return .fhd }
            if sawHD { return .hd }
            return .sd
        } ?? fallbackDetectQuality(from: name)
    }

    private static func fallbackDetectQuality(from name: String) -> StreamQuality {
        let upper = name.uppercased()
        if upper.contains("4K") || upper.contains("UHD") {
            return .uhd4k
        } else if upper.contains("FHD") || upper.contains("1080P") {
            return .fhd
        } else if upper.contains("HD") || upper.contains("720P") {
            return .hd
        } else {
            return .sd
        }
    }

    @inline(__always)
    private static func asciiUpper(_ byte: UInt8) -> UInt8 {
        (byte >= 0x61 && byte <= 0x7A) ? (byte - 0x20) : byte
    }

    private static let redundantQualitySuffixes = [" FHD", " HD", " 4K", " SD", " [FHD]", " [HD]", " [4K]", " [SD]"]

    public static func cleanName(from name: String) -> String {
        var result = name
        for tag in redundantQualitySuffixes {
            if result.hasSuffix(tag) {
                result = String(result.dropLast(tag.count))
                break
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

enum FlexibleJSON {
    @inline(__always)
    static func isPresent<K: CodingKey>(_ container: KeyedDecodingContainer<K>, forKey key: K) -> Bool {
        guard container.contains(key) else { return false }
        return (try? container.decodeNil(forKey: key)) != true
    }

    static func decodeInt<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        preferString: Bool = false,
        default defaultValue: Int = 0
    ) -> Int {
        decodeOptionalInt(from: container, forKey: key, preferString: preferString) ?? defaultValue
    }

    static func decodeOptionalInt<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        preferString: Bool = false
    ) -> Int? {
        guard isPresent(container, forKey: key) else { return nil }
        if preferString {
            if let str = try? container.decode(String.self, forKey: key) {
                return Int(str.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let intVal = try? container.decode(Int.self, forKey: key) {
                return intVal
            }
        } else {
            if let intVal = try? container.decode(Int.self, forKey: key) {
                return intVal
            }
            if let str = try? container.decode(String.self, forKey: key) {
                return Int(str.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return nil
    }

    static func decodeString<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        default defaultValue: String = ""
    ) -> String {
        guard isPresent(container, forKey: key) else { return defaultValue }
        if let str = try? container.decode(String.self, forKey: key) {
            return str
        }
        if let intVal = try? container.decode(Int.self, forKey: key) {
            return String(intVal)
        }
        return defaultValue
    }

    static func decodeOptionalString<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> String? {
        guard isPresent(container, forKey: key) else { return nil }
        return try? container.decode(String.self, forKey: key)
    }

    static func decodeRating<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> String? {
        guard isPresent(container, forKey: key) else { return nil }
        if let str = try? container.decode(String.self, forKey: key) {
            return str
        }
        if let dbl = try? container.decode(Double.self, forKey: key) {
            return String(format: "%.1f", dbl)
        }
        return nil
    }

    // MARK: - Zero-throw dictionary extraction (for JSONSerialization fast catalog decoding)

    @inline(__always)
    static func intValue(_ raw: Any?) -> Int? {
        guard let raw else { return nil }
        if let s = raw as? String {
            return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if raw is Bool { return nil }
        #if canImport(CoreFoundation)
        if let num = raw as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
            return num.intValue
        }
        #endif
        if let i = raw as? Int { return i }
        if let d = raw as? Double, d.isFinite { return Int(d) }
        return nil
    }

    @inline(__always)
    static func stringValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let s = raw as? String { return s }
        if raw is NSNull || raw is Bool { return nil }
        #if canImport(CoreFoundation)
        if let num = raw as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
            return num.stringValue
        }
        #endif
        if let i = raw as? Int { return String(i) }
        return nil
    }

    @inline(__always)
    static func ratingString(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let s = raw as? String { return s }
        if raw is NSNull || raw is Bool { return nil }
        #if canImport(CoreFoundation)
        if let num = raw as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
            return String(format: "%.1f", num.doubleValue)
        }
        #endif
        if let d = raw as? Double { return String(format: "%.1f", d) }
        if let i = raw as? Int { return String(format: "%.1f", Double(i)) }
        return nil
    }
}

public enum StreamQuality: String, Codable, CaseIterable, Sendable {
    case all = "ALL"
    case uhd4k = "4K"
    case fhd = "FHD"
    case hd = "HD"
    case sd = "SD"

    public var badgeColorHex: String {
        switch self {
        case .all: return "#718096"
        case .uhd4k: return "#805AD5"
        case .fhd: return "#3182CE"
        case .hd: return "#38A169"
        case .sd: return "#DD6B20"
        }
    }
}

public struct LiveCategory: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let parentId: Int

    enum CodingKeys: String, CodingKey {
        case id = "category_id"
        case name = "category_name"
        case parentId = "parent_id"
    }

    public init(id: String, name: String, parentId: Int = 0) {
        self.id = id
        self.name = name
        self.parentId = parentId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = FlexibleJSON.decodeString(from: container, forKey: .id)
        self.id = decodedID.isEmpty ? UUID().uuidString : decodedID
        self.name = FlexibleJSON.decodeOptionalString(from: container, forKey: .name) ?? "Unknown"
        self.parentId = FlexibleJSON.decodeInt(from: container, forKey: .parentId)
    }

    static func decodeArray(from data: Data) throws -> [LiveCategory] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return try JSONDecoder().decode([LiveCategory].self, from: data)
        }
        var result: [LiveCategory] = []
        result.reserveCapacity(array.count)
        for dict in array {
            let id = FlexibleJSON.stringValue(dict["category_id"]) ?? UUID().uuidString
            let name = (dict["category_name"] as? String) ?? "Unknown"
            let parentId = FlexibleJSON.intValue(dict["parent_id"]) ?? 0
            result.append(LiveCategory(id: id, name: name, parentId: parentId))
        }
        return result
    }
}

public struct LiveStream: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let num: Int
    public let name: String
    public let streamType: String
    public let iconURLString: String?
    public let epgChannelId: String?
    public let categoryId: String
    public let tvArchive: Int
    /// Set for M3U playlist channels. Xtream channels build their URL from credentials.
    public let directURLString: String?
    public let quality: StreamQuality
    public let cleanName: String
    public let normalizedSearchText: String

    enum CodingKeys: String, CodingKey {
        case id = "stream_id"
        case num
        case name
        case streamType = "stream_type"
        case iconURLString = "stream_icon"
        case epgChannelId = "epg_channel_id"
        case categoryId = "category_id"
        case tvArchive = "tv_archive"
        // Not Xtream's "direct_source": providers often fill that with unusable values.
        case directURLString = "brutv_direct_url"
    }

    public init(
        id: Int,
        num: Int = 0,
        name: String,
        streamType: String = "live",
        iconURLString: String? = nil,
        epgChannelId: String? = nil,
        categoryId: String = "",
        tvArchive: Int = 0,
        directURLString: String? = nil
    ) {
        self.id = id
        self.num = num
        self.name = name
        self.streamType = streamType
        self.iconURLString = iconURLString
        self.epgChannelId = epgChannelId
        self.categoryId = categoryId
        self.tvArchive = tvArchive
        self.directURLString = directURLString
        self.quality = ChannelTextHelper.detectQuality(from: name)
        self.cleanName = ChannelTextHelper.cleanName(from: name)
        self.normalizedSearchText = ChannelTextHelper.normalizedSearchText(name)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = FlexibleJSON.decodeInt(from: container, forKey: .id)
        let num = FlexibleJSON.decodeInt(from: container, forKey: .num)
        let name = FlexibleJSON.decodeOptionalString(from: container, forKey: .name) ?? "Channel \(id)"
        let streamType = FlexibleJSON.decodeOptionalString(from: container, forKey: .streamType) ?? "live"
        let iconURLString = FlexibleJSON.decodeOptionalString(from: container, forKey: .iconURLString)
        let epgChannelId = FlexibleJSON.decodeOptionalString(from: container, forKey: .epgChannelId)
        let categoryId = FlexibleJSON.decodeString(from: container, forKey: .categoryId)
        let tvArchive = FlexibleJSON.decodeInt(from: container, forKey: .tvArchive)
        let directURLString = FlexibleJSON.decodeOptionalString(from: container, forKey: .directURLString)
        self.init(
            id: id,
            num: num,
            name: name,
            streamType: streamType,
            iconURLString: iconURLString,
            epgChannelId: epgChannelId,
            categoryId: categoryId,
            tvArchive: tvArchive,
            directURLString: directURLString
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(num, forKey: .num)
        try container.encode(name, forKey: .name)
        try container.encode(streamType, forKey: .streamType)
        try container.encodeIfPresent(iconURLString, forKey: .iconURLString)
        try container.encodeIfPresent(epgChannelId, forKey: .epgChannelId)
        try container.encode(categoryId, forKey: .categoryId)
        try container.encode(tvArchive, forKey: .tvArchive)
        try container.encodeIfPresent(directURLString, forKey: .directURLString)
    }

    static func decodeArray(from data: Data) throws -> [LiveStream] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return try JSONDecoder().decode([LiveStream].self, from: data)
        }
        var result: [LiveStream] = []
        result.reserveCapacity(array.count)
        for dict in array {
            let id = FlexibleJSON.intValue(dict["stream_id"]) ?? 0
            let num = FlexibleJSON.intValue(dict["num"]) ?? 0
            let name = (dict["name"] as? String) ?? "Channel \(id)"
            let streamType = (dict["stream_type"] as? String) ?? "live"
            let icon = dict["stream_icon"] as? String
            let epg = dict["epg_channel_id"] as? String
            let categoryId = FlexibleJSON.stringValue(dict["category_id"]) ?? ""
            let tvArchive = FlexibleJSON.intValue(dict["tv_archive"]) ?? 0
            let directURL = dict["brutv_direct_url"] as? String
            result.append(LiveStream(
                id: id,
                num: num,
                name: name,
                streamType: streamType,
                iconURLString: icon,
                epgChannelId: epg,
                categoryId: categoryId,
                tvArchive: tvArchive,
                directURLString: directURL
            ))
        }
        return result
    }

    public var iconURL: URL? {
        MediaURL.parse(iconURLString)
    }
}

public struct VODCategory: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let parentId: Int

    enum CodingKeys: String, CodingKey {
        case id = "category_id"
        case name = "category_name"
        case parentId = "parent_id"
    }

    public init(id: String, name: String, parentId: Int = 0) {
        self.id = id
        self.name = name
        self.parentId = parentId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = FlexibleJSON.decodeString(from: container, forKey: .id)
        self.id = decodedID.isEmpty ? UUID().uuidString : decodedID
        self.name = FlexibleJSON.decodeOptionalString(from: container, forKey: .name) ?? "Movies"
        self.parentId = FlexibleJSON.decodeInt(from: container, forKey: .parentId)
    }

    static func decodeArray(from data: Data) throws -> [VODCategory] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return try JSONDecoder().decode([VODCategory].self, from: data)
        }
        var result: [VODCategory] = []
        result.reserveCapacity(array.count)
        for dict in array {
            let id = FlexibleJSON.stringValue(dict["category_id"]) ?? UUID().uuidString
            let name = (dict["category_name"] as? String) ?? "Movies"
            let parentId = FlexibleJSON.intValue(dict["parent_id"]) ?? 0
            result.append(VODCategory(id: id, name: name, parentId: parentId))
        }
        return result
    }
}

public struct VODStream: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let iconURLString: String?
    public let rating: String?
    public let plot: String?
    public let categoryId: String
    public let containerExtension: String
    public let streamType: String
    public let ratingValue: Double
    public let normalizedSearchText: String

    enum CodingKeys: String, CodingKey {
        case id = "stream_id"
        case name
        case iconURLString = "stream_icon"
        case rating
        case plot
        case categoryId = "category_id"
        case containerExtension = "container_extension"
        case streamType = "stream_type"
    }

    private enum AltCodingKeys: String, CodingKey {
        case description
    }

    public init(
        id: Int,
        name: String,
        iconURLString: String? = nil,
        rating: String? = nil,
        plot: String? = nil,
        categoryId: String = "",
        containerExtension: String = "mp4",
        streamType: String = "movie"
    ) {
        self.id = id
        self.name = name
        self.iconURLString = iconURLString
        self.rating = rating
        self.plot = plot
        self.categoryId = categoryId
        self.containerExtension = containerExtension
        self.streamType = streamType
        self.ratingValue = ChannelTextHelper.parseRating(rating)
        self.normalizedSearchText = ChannelTextHelper.normalizedSearchText(name)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = FlexibleJSON.decodeInt(from: container, forKey: .id)
        let name = FlexibleJSON.decodeOptionalString(from: container, forKey: .name) ?? "Movie \(id)"
        let iconURLString = FlexibleJSON.decodeOptionalString(from: container, forKey: .iconURLString)
        let rating = FlexibleJSON.decodeRating(from: container, forKey: .rating)
        var plot = FlexibleJSON.decodeOptionalString(from: container, forKey: .plot)
        if plot == nil, let altContainer = try? decoder.container(keyedBy: AltCodingKeys.self) {
            plot = FlexibleJSON.decodeOptionalString(from: altContainer, forKey: .description)
        }
        let categoryId = FlexibleJSON.decodeString(from: container, forKey: .categoryId)
        let containerExtension = FlexibleJSON.decodeOptionalString(from: container, forKey: .containerExtension) ?? "mp4"
        let streamType = FlexibleJSON.decodeOptionalString(from: container, forKey: .streamType) ?? "movie"
        self.init(
            id: id,
            name: name,
            iconURLString: iconURLString,
            rating: rating,
            plot: plot,
            categoryId: categoryId,
            containerExtension: containerExtension,
            streamType: streamType
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(iconURLString, forKey: .iconURLString)
        try container.encodeIfPresent(rating, forKey: .rating)
        try container.encodeIfPresent(plot, forKey: .plot)
        try container.encode(categoryId, forKey: .categoryId)
        try container.encode(containerExtension, forKey: .containerExtension)
        try container.encode(streamType, forKey: .streamType)
    }

    static func decodeArray(from data: Data) throws -> [VODStream] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return try JSONDecoder().decode([VODStream].self, from: data)
        }
        var result: [VODStream] = []
        result.reserveCapacity(array.count)
        for dict in array {
            let id = FlexibleJSON.intValue(dict["stream_id"]) ?? 0
            let name = (dict["name"] as? String) ?? "Movie \(id)"
            let icon = dict["stream_icon"] as? String
            let rating = FlexibleJSON.ratingString(dict["rating"])
            let plot = (dict["plot"] as? String) ?? (dict["description"] as? String)
            let categoryId = FlexibleJSON.stringValue(dict["category_id"]) ?? ""
            let ext = (dict["container_extension"] as? String) ?? "mp4"
            let streamType = (dict["stream_type"] as? String) ?? "movie"
            result.append(VODStream(
                id: id,
                name: name,
                iconURLString: icon,
                rating: rating,
                plot: plot,
                categoryId: categoryId,
                containerExtension: ext,
                streamType: streamType
            ))
        }
        return result
    }

    public var iconURL: URL? {
        MediaURL.parse(iconURLString)
    }
}

public struct VODInfo: Codable, Sendable {
    public let name: String?
    public let plot: String?
    public let cast: String?
    public let director: String?
    public let genre: String?
    public let rating: String?
    public let duration: String?
    public let backdropPath: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case plot
        case cast
        case director
        case genre
        case rating
        case duration
        case backdropPath = "backdrop_path"
    }

    public init(
        name: String? = nil,
        plot: String? = nil,
        cast: String? = nil,
        director: String? = nil,
        genre: String? = nil,
        rating: String? = nil,
        duration: String? = nil,
        backdropPath: [String]? = nil
    ) {
        self.name = name
        self.plot = plot
        self.cast = cast
        self.director = director
        self.genre = genre
        self.rating = rating
        self.duration = duration
        self.backdropPath = backdropPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = FlexibleJSON.decodeOptionalString(from: container, forKey: .name)
        self.plot = FlexibleJSON.decodeOptionalString(from: container, forKey: .plot)
        self.cast = FlexibleJSON.decodeOptionalString(from: container, forKey: .cast)
        self.director = FlexibleJSON.decodeOptionalString(from: container, forKey: .director)
        self.genre = FlexibleJSON.decodeOptionalString(from: container, forKey: .genre)
        self.duration = FlexibleJSON.decodeOptionalString(from: container, forKey: .duration)
        self.rating = FlexibleJSON.decodeRating(from: container, forKey: .rating)
        if FlexibleJSON.isPresent(container, forKey: .backdropPath) {
            if let paths = try? container.decode([String].self, forKey: .backdropPath) {
                self.backdropPath = paths
            } else if let single = try? container.decode(String.self, forKey: .backdropPath) {
                self.backdropPath = [single]
            } else {
                self.backdropPath = nil
            }
        } else {
            self.backdropPath = nil
        }
    }
}

public struct VODDetails: Codable, Sendable {
    public let info: VODInfo?

    public init(info: VODInfo? = nil) {
        self.info = info
    }
}

public struct SeriesCategory: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let parentId: Int

    enum CodingKeys: String, CodingKey {
        case id = "category_id"
        case name = "category_name"
        case parentId = "parent_id"
    }

    public init(id: String, name: String, parentId: Int = 0) {
        self.id = id
        self.name = name
        self.parentId = parentId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = FlexibleJSON.decodeString(from: container, forKey: .id)
        self.id = decodedID.isEmpty ? UUID().uuidString : decodedID
        self.name = FlexibleJSON.decodeOptionalString(from: container, forKey: .name) ?? "Series"
        self.parentId = FlexibleJSON.decodeInt(from: container, forKey: .parentId)
    }

    static func decodeArray(from data: Data) throws -> [SeriesCategory] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return try JSONDecoder().decode([SeriesCategory].self, from: data)
        }
        var result: [SeriesCategory] = []
        result.reserveCapacity(array.count)
        for dict in array {
            let id = FlexibleJSON.stringValue(dict["category_id"]) ?? UUID().uuidString
            let name = (dict["category_name"] as? String) ?? "Series"
            let parentId = FlexibleJSON.intValue(dict["parent_id"]) ?? 0
            result.append(SeriesCategory(id: id, name: name, parentId: parentId))
        }
        return result
    }
}

public struct SeriesItem: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let coverURLString: String?
    public let plot: String?
    public let cast: String?
    public let director: String?
    public let genre: String?
    public let rating: String?
    public let categoryId: String
    public let ratingValue: Double
    public let normalizedSearchText: String

    enum CodingKeys: String, CodingKey {
        case id = "series_id"
        case name
        case coverURLString = "cover"
        case plot
        case cast
        case director
        case genre
        case rating
        case categoryId = "category_id"
    }

    public init(
        id: Int,
        name: String,
        coverURLString: String? = nil,
        plot: String? = nil,
        cast: String? = nil,
        director: String? = nil,
        genre: String? = nil,
        rating: String? = nil,
        categoryId: String = ""
    ) {
        self.id = id
        self.name = name
        self.coverURLString = coverURLString
        self.plot = plot
        self.cast = cast
        self.director = director
        self.genre = genre
        self.rating = rating
        self.categoryId = categoryId
        self.ratingValue = ChannelTextHelper.parseRating(rating)
        self.normalizedSearchText = ChannelTextHelper.normalizedSearchText(name)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = FlexibleJSON.decodeInt(from: container, forKey: .id)
        let name = FlexibleJSON.decodeOptionalString(from: container, forKey: .name) ?? "Series \(id)"
        let coverURLString = FlexibleJSON.decodeOptionalString(from: container, forKey: .coverURLString)
        let plot = FlexibleJSON.decodeOptionalString(from: container, forKey: .plot)
        let cast = FlexibleJSON.decodeOptionalString(from: container, forKey: .cast)
        let director = FlexibleJSON.decodeOptionalString(from: container, forKey: .director)
        let genre = FlexibleJSON.decodeOptionalString(from: container, forKey: .genre)
        let rating = FlexibleJSON.decodeRating(from: container, forKey: .rating)
        let categoryId = FlexibleJSON.decodeString(from: container, forKey: .categoryId)
        self.init(
            id: id,
            name: name,
            coverURLString: coverURLString,
            plot: plot,
            cast: cast,
            director: director,
            genre: genre,
            rating: rating,
            categoryId: categoryId
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(coverURLString, forKey: .coverURLString)
        try container.encodeIfPresent(plot, forKey: .plot)
        try container.encodeIfPresent(cast, forKey: .cast)
        try container.encodeIfPresent(director, forKey: .director)
        try container.encodeIfPresent(genre, forKey: .genre)
        try container.encodeIfPresent(rating, forKey: .rating)
        try container.encode(categoryId, forKey: .categoryId)
    }

    static func decodeArray(from data: Data) throws -> [SeriesItem] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return try JSONDecoder().decode([SeriesItem].self, from: data)
        }
        var result: [SeriesItem] = []
        result.reserveCapacity(array.count)
        for dict in array {
            let id = FlexibleJSON.intValue(dict["series_id"]) ?? 0
            let name = (dict["name"] as? String) ?? "Series \(id)"
            let cover = dict["cover"] as? String
            let plot = dict["plot"] as? String
            let cast = dict["cast"] as? String
            let director = dict["director"] as? String
            let genre = dict["genre"] as? String
            let rating = FlexibleJSON.ratingString(dict["rating"])
            let categoryId = FlexibleJSON.stringValue(dict["category_id"]) ?? ""
            result.append(SeriesItem(
                id: id,
                name: name,
                coverURLString: cover,
                plot: plot,
                cast: cast,
                director: director,
                genre: genre,
                rating: rating,
                categoryId: categoryId
            ))
        }
        return result
    }

    public var coverURL: URL? {
        MediaURL.parse(coverURLString)
    }
}

public struct SeriesDetails: Codable, Sendable {
    public let info: SeriesInfo?
    public let episodes: [String: [SeriesEpisode]]

    enum CodingKeys: String, CodingKey {
        case info
        case episodes
    }

    public init(info: SeriesInfo? = nil, episodes: [String: [SeriesEpisode]] = [:]) {
        self.info = info
        self.episodes = episodes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.info = try? container.decodeIfPresent(SeriesInfo.self, forKey: .info)
        if FlexibleJSON.isPresent(container, forKey: .episodes),
           let dict = try? container.decode([String: [SeriesEpisode]].self, forKey: .episodes) {
            self.episodes = dict
        } else {
            self.episodes = [:]
        }
    }
}

public struct SeriesInfo: Codable, Sendable {
    public let name: String?
    public let cover: String?
    public let plot: String?
    public let cast: String?
    public let director: String?
    public let genre: String?
    public let rating: String?
    public let backdropPath: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case cover
        case plot
        case cast
        case director
        case genre
        case rating
        case backdropPath = "backdrop_path"
    }

    public init(
        name: String? = nil,
        cover: String? = nil,
        plot: String? = nil,
        cast: String? = nil,
        director: String? = nil,
        genre: String? = nil,
        rating: String? = nil,
        backdropPath: [String]? = nil
    ) {
        self.name = name
        self.cover = cover
        self.plot = plot
        self.cast = cast
        self.director = director
        self.genre = genre
        self.rating = rating
        self.backdropPath = backdropPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = FlexibleJSON.decodeOptionalString(from: container, forKey: .name)
        self.cover = FlexibleJSON.decodeOptionalString(from: container, forKey: .cover)
        self.plot = FlexibleJSON.decodeOptionalString(from: container, forKey: .plot)
        self.cast = FlexibleJSON.decodeOptionalString(from: container, forKey: .cast)
        self.director = FlexibleJSON.decodeOptionalString(from: container, forKey: .director)
        self.genre = FlexibleJSON.decodeOptionalString(from: container, forKey: .genre)
        self.rating = FlexibleJSON.decodeRating(from: container, forKey: .rating)
        if FlexibleJSON.isPresent(container, forKey: .backdropPath) {
            if let paths = try? container.decode([String].self, forKey: .backdropPath) {
                self.backdropPath = paths
            } else if let single = try? container.decode(String.self, forKey: .backdropPath) {
                self.backdropPath = [single]
            } else {
                self.backdropPath = nil
            }
        } else {
            self.backdropPath = nil
        }
    }
}

public struct SeriesEpisode: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let episodeNum: Int
    public let title: String
    public let containerExtension: String
    public let season: Int
    public let info: SeriesEpisodeInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case episodeNum = "episode_num"
        case title
        case containerExtension = "container_extension"
        case season
        case info
    }

    public init(
        id: Int,
        episodeNum: Int,
        title: String,
        containerExtension: String = "mp4",
        season: Int = 1,
        info: SeriesEpisodeInfo? = nil
    ) {
        self.id = id
        self.episodeNum = episodeNum
        self.title = title
        self.containerExtension = containerExtension
        self.season = season
        self.info = info
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Xtream get_series_info normally encodes id, episode_num, and season as JSON strings.
        self.id = FlexibleJSON.decodeInt(from: container, forKey: .id, preferString: true)
        self.episodeNum = FlexibleJSON.decodeInt(from: container, forKey: .episodeNum, preferString: true, default: 1)
        self.title = FlexibleJSON.decodeOptionalString(from: container, forKey: .title) ?? "Episode \(self.episodeNum)"
        self.containerExtension = FlexibleJSON.decodeOptionalString(from: container, forKey: .containerExtension) ?? "mp4"
        self.season = FlexibleJSON.decodeInt(from: container, forKey: .season, preferString: true, default: 1)
        self.info = try? container.decodeIfPresent(SeriesEpisodeInfo.self, forKey: .info)
    }
}

public struct SeriesEpisodeInfo: Codable, Hashable, Sendable {
    public let duration: String?
    public let durationSecs: Int?
    public let movieImage: String?
    public let plot: String?
    public let rating: String?

    enum CodingKeys: String, CodingKey {
        case duration
        case durationSecs = "duration_secs"
        case movieImage = "movie_image"
        case plot
        case rating
    }

    public init(
        duration: String? = nil,
        durationSecs: Int? = nil,
        movieImage: String? = nil,
        plot: String? = nil,
        rating: String? = nil
    ) {
        self.duration = duration
        self.durationSecs = durationSecs
        self.movieImage = movieImage
        self.plot = plot
        self.rating = rating
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.duration = FlexibleJSON.decodeOptionalString(from: container, forKey: .duration)
        self.durationSecs = FlexibleJSON.decodeOptionalInt(from: container, forKey: .durationSecs, preferString: true)
        self.movieImage = FlexibleJSON.decodeOptionalString(from: container, forKey: .movieImage)
        self.plot = FlexibleJSON.decodeOptionalString(from: container, forKey: .plot)
        self.rating = FlexibleJSON.decodeRating(from: container, forKey: .rating)
    }
}
