import Foundation

public struct ShortEPGResponse: Codable, Sendable {
    public let epgListings: [EPGListing]

    enum CodingKeys: String, CodingKey {
        case epgListings = "epg_listings"
    }

    public init(epgListings: [EPGListing] = []) {
        self.epgListings = epgListings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.epgListings = (try? container.decodeIfPresent([EPGListing].self, forKey: .epgListings)) ?? []
    }
}

public struct EPGListing: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let description: String?
    public let startTimestamp: Double
    public let stopTimestamp: Double
    public let channelId: String?

    private static let timeFormatterLock = NSLock()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case startTimestamp = "start_timestamp"
        case stopTimestamp = "stop_timestamp"
        case channelId = "channel_id"
    }

    public init(
        id: String = UUID().uuidString,
        title: String,
        description: String? = nil,
        startTimestamp: Double,
        stopTimestamp: Double,
        channelId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.startTimestamp = startTimestamp
        self.stopTimestamp = stopTimestamp
        self.channelId = channelId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.id), (try? container.decodeNil(forKey: .id)) != true {
            if let str = try? container.decode(String.self, forKey: .id), !str.isEmpty {
                self.id = str
            } else if let intVal = try? container.decode(Int.self, forKey: .id) {
                self.id = String(intVal)
            } else {
                self.id = UUID().uuidString
            }
        } else {
            self.id = UUID().uuidString
        }

        let rawTitle = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        self.title = Self.decodePossibleBase64(rawTitle)

        if let rawDescription = try? container.decodeIfPresent(String.self, forKey: .description), !rawDescription.isEmpty {
            let decoded = Self.decodePossibleBase64(rawDescription).trimmingCharacters(in: .whitespacesAndNewlines)
            self.description = decoded.isEmpty ? nil : decoded
        } else {
            self.description = nil
        }

        self.startTimestamp = Self.decodeFlexibleTimestamp(from: container, forKey: .startTimestamp)
        self.stopTimestamp = Self.decodeFlexibleTimestamp(from: container, forKey: .stopTimestamp)
        self.channelId = try? container.decodeIfPresent(String.self, forKey: .channelId)
    }

    private static func decodeFlexibleTimestamp(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double {
        guard container.contains(key), (try? container.decodeNil(forKey: key)) != true else {
            return 0
        }
        if let str = try? container.decode(String.self, forKey: key), let val = Double(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return val
        }
        if let doubleVal = try? container.decode(Double.self, forKey: key) {
            return doubleVal
        }
        if let intVal = try? container.decode(Int.self, forKey: key) {
            return Double(intVal)
        }
        return 0
    }

    /// Xtream `get_short_epg` base64-encodes `title` and `description`.
    /// Decode cleanly when the input looks like base64 UTF-8; otherwise keep raw text.
    static func decodePossibleBase64(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count >= 4, trimmed.count % 4 == 0 else {
            return value
        }
        guard trimmed.utf8.allSatisfy({ b in
            (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 43 || b == 47 || b == 61
        }) else {
            return value
        }
        guard let data = Data(base64Encoded: trimmed),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty,
              decoded.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\n" || $0 == "\r" || $0 == "\t" }) else {
            return value
        }
        return decoded
    }

    public var isNow: Bool {
        let now = Date().timeIntervalSince1970
        return now >= startTimestamp && now <= stopTimestamp
    }

    public var progress: Double {
        let now = Date().timeIntervalSince1970
        guard now >= startTimestamp else { return 0.0 }
        guard now <= stopTimestamp else { return 1.0 }
        let total = stopTimestamp - startTimestamp
        guard total > 0 else { return 0.0 }
        return (now - startTimestamp) / total
    }

    public var timeRangeString: String {
        let startDate = Date(timeIntervalSince1970: startTimestamp)
        let endDate = Date(timeIntervalSince1970: stopTimestamp)
        Self.timeFormatterLock.lock()
        defer { Self.timeFormatterLock.unlock() }
        return "\(Self.timeFormatter.string(from: startDate)) - \(Self.timeFormatter.string(from: endDate))"
    }
}
