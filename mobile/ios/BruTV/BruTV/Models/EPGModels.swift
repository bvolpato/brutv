import Foundation

public struct EPGListing: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let description: String?
    public let startTimestamp: Double
    public let stopTimestamp: Double
    public let channelId: String?

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
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: startDate)) - \(formatter.string(from: endDate))"
    }
}
