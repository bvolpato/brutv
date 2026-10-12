import Foundation

public struct UserInfo: Codable, Equatable, Sendable {
    public let username: String
    public let password: String?
    public let message: String?
    public let auth: Int
    public let status: String
    public let expDate: String?
    public let isTrial: String?
    public let activeCons: String?
    public let maxConnections: String?
    public let allowedOutputFormats: [String]?

    enum CodingKeys: String, CodingKey {
        case username
        case password
        case message
        case auth
        case status
        case expDate = "exp_date"
        case isTrial = "is_trial"
        case activeCons = "active_cons"
        case maxConnections = "max_connections"
        case allowedOutputFormats = "allowed_output_formats"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.password = try container.decodeIfPresent(String.self, forKey: .password)
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
        
        // Handle auth as Int or String or Bool
        if let intAuth = try? container.decode(Int.self, forKey: .auth) {
            self.auth = intAuth
        } else if let stringAuth = try? container.decode(String.self, forKey: .auth), let intVal = Int(stringAuth) {
            self.auth = intVal
        } else {
            self.auth = 0
        }
        
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? "Active"
        
        if let stringExp = try? container.decode(String.self, forKey: .expDate) {
            self.expDate = stringExp
        } else if let intExp = try? container.decode(Int.self, forKey: .expDate) {
            self.expDate = String(intExp)
        } else {
            self.expDate = nil
        }
        
        self.isTrial = try? container.decodeIfPresent(String.self, forKey: .isTrial)
        self.activeCons = try? container.decodeIfPresent(String.self, forKey: .activeCons)
        self.maxConnections = try? container.decodeIfPresent(String.self, forKey: .maxConnections)
        self.allowedOutputFormats = try? container.decodeIfPresent([String].self, forKey: .allowedOutputFormats)
    }

    public init(
        username: String,
        password: String? = nil,
        message: String? = nil,
        auth: Int = 1,
        status: String = "Active",
        expDate: String? = nil,
        isTrial: String? = "0",
        activeCons: String? = "0",
        maxConnections: String? = "1",
        allowedOutputFormats: [String]? = ["m3u8", "ts"]
    ) {
        self.username = username
        self.password = password
        self.message = message
        self.auth = auth
        self.status = status
        self.expDate = expDate
        self.isTrial = isTrial
        self.activeCons = activeCons
        self.maxConnections = maxConnections
        self.allowedOutputFormats = allowedOutputFormats
    }

    public var expirationFormatted: String {
        guard let expDate, let timestamp = Double(expDate), timestamp > 0 else {
            return "Unlimited / No Expiry"
        }
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    public var isExpired: Bool {
        guard let expDate, let timestamp = Double(expDate), timestamp > 0 else {
            return false
        }
        return Date().timeIntervalSince1970 > timestamp
    }
}

public struct ServerInfo: Codable, Equatable, Sendable {
    public let url: String?
    public let port: String?
    public let httpsPort: String?
    public let serverProtocol: String?
    public let rtmpPort: String?
    public let timezone: String?
    public let timestampNow: Int?
    public let timeNow: String?

    enum CodingKeys: String, CodingKey {
        case url
        case port
        case httpsPort = "https_port"
        case serverProtocol = "server_protocol"
        case rtmpPort = "rtmp_port"
        case timezone
        case timestampNow = "timestamp_now"
        case timeNow = "time_now"
    }

    public init(
        url: String? = nil,
        port: String? = nil,
        httpsPort: String? = nil,
        serverProtocol: String? = "http",
        rtmpPort: String? = nil,
        timezone: String? = nil,
        timestampNow: Int? = nil,
        timeNow: String? = nil
    ) {
        self.url = url
        self.port = port
        self.httpsPort = httpsPort
        self.serverProtocol = serverProtocol
        self.rtmpPort = rtmpPort
        self.timezone = timezone
        self.timestampNow = timestampNow
        self.timeNow = timeNow
    }
}

public struct AuthResponse: Codable, Equatable, Sendable {
    public let userInfo: UserInfo
    public let serverInfo: ServerInfo

    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
        case serverInfo = "server_info"
    }

    public init(userInfo: UserInfo, serverInfo: ServerInfo) {
        self.userInfo = userInfo
        self.serverInfo = serverInfo
    }
}

public enum SourceKind: String, Codable, Sendable {
    case xtream
    case m3u
}

public struct ServerProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var serverURL: String
    public var username: String
    public var password: String
    public var lastConnected: Date?
    public var isActive: Bool
    public var kind: SourceKind
    public var playlistURL: String?

    public init(
        id: UUID = UUID(),
        name: String = "My IPTV",
        serverURL: String,
        username: String,
        password: String,
        lastConnected: Date? = nil,
        isActive: Bool = true,
        kind: SourceKind = .xtream,
        playlistURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.lastConnected = lastConnected
        self.isActive = isActive
        self.kind = kind
        self.playlistURL = playlistURL
    }

    public static func playlist(url: String, lastConnected: Date? = Date()) -> ServerProfile {
        let host = URL(string: url)?.host ?? "M3U Playlist"
        return ServerProfile(
            name: host,
            serverURL: url,
            username: "",
            password: "",
            lastConnected: lastConnected,
            kind: .m3u,
            playlistURL: url
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, serverURL, username, password, lastConnected, isActive, kind, playlistURL
    }

    // Profiles saved before M3U support have no `kind`; treat them as Xtream.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "My IPTV"
        self.serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
        self.username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        self.lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
        self.isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        self.kind = try c.decodeIfPresent(SourceKind.self, forKey: .kind) ?? .xtream
        self.playlistURL = try c.decodeIfPresent(String.self, forKey: .playlistURL)
    }

    /// The sign-in link for this profile, used for QR codes.
    public var loginLink: LoginLink {
        switch kind {
        case .xtream:
            return .xtream(server: serverURL, username: username, password: password)
        case .m3u:
            return .m3u(url: playlistURL ?? serverURL)
        }
    }

    /// Two profiles point at the same source.
    public func sameSource(as other: ServerProfile) -> Bool {
        loginLink == other.loginLink
    }

    #if DEBUG
    /// Test account for Debug builds and UI tests only. Release builds hold no credentials.
    public static let demo = ServerProfile(
        name: "Demo Account",
        serverURL: "http://example.invalid",
        username: "REDACTED_USERNAMEp2",
        password: "REDACTED_PASSWORD",
        lastConnected: Date(),
        isActive: true
    )
    #endif
}
