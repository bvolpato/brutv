import Foundation

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
        if let stringId = try? container.decode(String.self, forKey: .id) {
            self.id = stringId
        } else if let intId = try? container.decode(Int.self, forKey: .id) {
            self.id = String(intId)
        } else {
            self.id = UUID().uuidString
        }

        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"

        if let intParent = try? container.decode(Int.self, forKey: .parentId) {
            self.parentId = intParent
        } else if let stringParent = try? container.decode(String.self, forKey: .parentId), let intVal = Int(stringParent) {
            self.parentId = intVal
        } else {
            self.parentId = 0
        }
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
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let intId = try? container.decode(Int.self, forKey: .id) {
            self.id = intId
        } else if let stringId = try? container.decode(String.self, forKey: .id), let intVal = Int(stringId) {
            self.id = intVal
        } else {
            self.id = 0
        }

        if let intNum = try? container.decode(Int.self, forKey: .num) {
            self.num = intNum
        } else if let stringNum = try? container.decode(String.self, forKey: .num), let intVal = Int(stringNum) {
            self.num = intVal
        } else {
            self.num = 0
        }

        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Channel \(self.id)"
        self.streamType = try container.decodeIfPresent(String.self, forKey: .streamType) ?? "live"
        self.iconURLString = try? container.decodeIfPresent(String.self, forKey: .iconURLString)
        self.epgChannelId = try? container.decodeIfPresent(String.self, forKey: .epgChannelId)

        if let stringCat = try? container.decode(String.self, forKey: .categoryId) {
            self.categoryId = stringCat
        } else if let intCat = try? container.decode(Int.self, forKey: .categoryId) {
            self.categoryId = String(intCat)
        } else {
            self.categoryId = ""
        }

        if let intArchive = try? container.decode(Int.self, forKey: .tvArchive) {
            self.tvArchive = intArchive
        } else if let stringArchive = try? container.decode(String.self, forKey: .tvArchive), let intVal = Int(stringArchive) {
            self.tvArchive = intVal
        } else {
            self.tvArchive = 0
        }

        self.directURLString = try? container.decodeIfPresent(String.self, forKey: .directURLString)
    }

    public var quality: StreamQuality {
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

    public var iconURL: URL? {
        guard let iconURLString, !iconURLString.isEmpty else { return nil }
        // URL with unencoded characters
        if let direct = URL(string: iconURLString) {
            return direct
        }
        if let encoded = iconURLString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: encoded)
        }
        return nil
    }

    public var cleanName: String {
        var result = name
        // Strip common suffixes for cleaner display when quality badge is shown
        let redundantTags = [" FHD", " HD", " 4K", " SD", " [FHD]", " [HD]", " [4K]", " [SD]"]
        for tag in redundantTags {
            if result.hasSuffix(tag) {
                result = String(result.dropLast(tag.count))
                break
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
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
        if let stringId = try? container.decode(String.self, forKey: .id) {
            self.id = stringId
        } else if let intId = try? container.decode(Int.self, forKey: .id) {
            self.id = String(intId)
        } else {
            self.id = UUID().uuidString
        }

        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Movies"

        if let intParent = try? container.decode(Int.self, forKey: .parentId) {
            self.parentId = intParent
        } else if let stringParent = try? container.decode(String.self, forKey: .parentId), let intVal = Int(stringParent) {
            self.parentId = intVal
        } else {
            self.parentId = 0
        }
    }
}

public struct VODStream: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let iconURLString: String?
    public let rating: String?
    public let categoryId: String
    public let containerExtension: String

    enum CodingKeys: String, CodingKey {
        case id = "stream_id"
        case name
        case iconURLString = "stream_icon"
        case rating
        case categoryId = "category_id"
        case containerExtension = "container_extension"
    }

    public init(
        id: Int,
        name: String,
        iconURLString: String? = nil,
        rating: String? = nil,
        categoryId: String = "",
        containerExtension: String = "mp4"
    ) {
        self.id = id
        self.name = name
        self.iconURLString = iconURLString
        self.rating = rating
        self.categoryId = categoryId
        self.containerExtension = containerExtension
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let intId = try? container.decode(Int.self, forKey: .id) {
            self.id = intId
        } else if let stringId = try? container.decode(String.self, forKey: .id), let intVal = Int(stringId) {
            self.id = intVal
        } else {
            self.id = 0
        }

        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Movie \(self.id)"
        self.iconURLString = try? container.decodeIfPresent(String.self, forKey: .iconURLString)

        if let stringRating = try? container.decode(String.self, forKey: .rating) {
            self.rating = stringRating
        } else if let doubleRating = try? container.decode(Double.self, forKey: .rating) {
            self.rating = String(format: "%.1f", doubleRating)
        } else {
            self.rating = nil
        }

        if let stringCat = try? container.decode(String.self, forKey: .categoryId) {
            self.categoryId = stringCat
        } else if let intCat = try? container.decode(Int.self, forKey: .categoryId) {
            self.categoryId = String(intCat)
        } else {
            self.categoryId = ""
        }

        self.containerExtension = try container.decodeIfPresent(String.self, forKey: .containerExtension) ?? "mp4"
    }

    public var iconURL: URL? {
        guard let iconURLString, !iconURLString.isEmpty else { return nil }
        return URL(string: iconURLString)
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
        if let stringId = try? container.decode(String.self, forKey: .id) {
            self.id = stringId
        } else if let intId = try? container.decode(Int.self, forKey: .id) {
            self.id = String(intId)
        } else {
            self.id = UUID().uuidString
        }

        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Series"

        if let intParent = try? container.decode(Int.self, forKey: .parentId) {
            self.parentId = intParent
        } else if let stringParent = try? container.decode(String.self, forKey: .parentId), let intVal = Int(stringParent) {
            self.parentId = intVal
        } else {
            self.parentId = 0
        }
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
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let intId = try? container.decode(Int.self, forKey: .id) {
            self.id = intId
        } else if let stringId = try? container.decode(String.self, forKey: .id), let intVal = Int(stringId) {
            self.id = intVal
        } else {
            self.id = 0
        }

        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Series \(self.id)"
        self.coverURLString = try? container.decodeIfPresent(String.self, forKey: .coverURLString)
        self.plot = try? container.decodeIfPresent(String.self, forKey: .plot)
        self.cast = try? container.decodeIfPresent(String.self, forKey: .cast)
        self.director = try? container.decodeIfPresent(String.self, forKey: .director)
        self.genre = try? container.decodeIfPresent(String.self, forKey: .genre)

        if let stringRating = try? container.decode(String.self, forKey: .rating) {
            self.rating = stringRating
        } else if let doubleRating = try? container.decode(Double.self, forKey: .rating) {
            self.rating = String(format: "%.1f", doubleRating)
        } else {
            self.rating = nil
        }

        if let stringCat = try? container.decode(String.self, forKey: .categoryId) {
            self.categoryId = stringCat
        } else if let intCat = try? container.decode(Int.self, forKey: .categoryId) {
            self.categoryId = String(intCat)
        } else {
            self.categoryId = ""
        }
    }

    public var coverURL: URL? {
        guard let coverURLString, !coverURLString.isEmpty else { return nil }
        return URL(string: coverURLString)
    }
}
