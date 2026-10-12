import Foundation

enum SourceEndpointIdentity {
    static func canonicalURL(_ raw: String, isPanel: Bool) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isPanel, !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return text }

        components.scheme = scheme
        components.host = host.lowercased()
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if isPanel {
            var path = components.percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            components.percentEncodedPath = path
            components.query = nil
            components.fragment = nil
        }
        return components.string ?? text
    }
}

struct ChannelLibrary: Codable, Equatable, Sendable {
    var favoriteIDs: Set<Int> = []
    var recentIDs: [Int] = []

    mutating func addRecent(_ channelID: Int) {
        recentIDs.removeAll { $0 == channelID }
        recentIDs.insert(channelID, at: 0)
        recentIDs = Array(recentIDs.prefix(30))
    }
}

struct SourceLibraryState: Codable, Equatable, Sendable {
    private var libraries: [String: ChannelLibrary] = [:]

    func library(for sourceID: UUID?) -> ChannelLibrary {
        guard let sourceID else { return ChannelLibrary() }
        return libraries[sourceID.uuidString] ?? ChannelLibrary()
    }

    mutating func setLibrary(_ library: ChannelLibrary, for sourceID: UUID) {
        libraries[sourceID.uuidString] = library
    }

    /// Old IDs have no source marker. Only the profile persisted before migration may claim them.
    @discardableResult
    mutating func migrateLegacy(favorites: [Int]?, recents: [Int]?, ownerID: UUID?) -> Bool {
        guard let ownerID, favorites != nil || recents != nil else { return false }
        if libraries[ownerID.uuidString] == nil {
            var seen = Set<Int>()
            let recentIDs = (recents ?? []).filter { seen.insert($0).inserted }
            libraries[ownerID.uuidString] = ChannelLibrary(
                favoriteIDs: Set(favorites ?? []),
                recentIDs: Array(recentIDs.prefix(30))
            )
        }
        return true
    }
}
