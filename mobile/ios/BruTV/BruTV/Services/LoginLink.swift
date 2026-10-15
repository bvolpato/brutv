import Foundation

/// A shareable sign-in link. QR codes encode `url`; scanning one opens BruTV and signs in.
///
///     brutv://login?server=http://host:port&username=USER&password=PASS
///     brutv://login?m3u=https://host/playlist.m3u
///
/// The link carries credentials in plain text. Share it only with people you trust.
public enum LoginLink: Equatable, Sendable {
    case xtream(server: String, username: String, password: String)
    case m3u(url: String)

    public static let scheme = "brutv"
    public static let defaultWebJoinBaseURL = "https://bvolpato.github.io/brutv/join.html"

    /// Parses a `brutv://login` link or universal HTTPS `https://.../join...` link.
    public init?(url: URL) {
        let scheme = url.scheme?.lowercased()
        let isSchemeMatch = scheme == Self.scheme && url.host?.lowercased() == "login"
        let isWebJoinMatch = (scheme == "http" || scheme == "https") &&
            (url.path.lowercased().contains("join") || url.host?.lowercased() == "join.brutv.app")

        guard isSchemeMatch || isWebJoinMatch,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        func value(_ name: String) -> String? {
            items.first(where: { $0.name.lowercased() == name })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }

        if let playlist = value("m3u") {
            self = .m3u(url: playlist)
        } else if let server = value("server"), let user = value("username"), let pass = value("password") {
            self = .xtream(server: server, username: user, password: pass)
        } else {
            return nil
        }
    }

    /// Parses anything a user may paste: a `brutv://` link or a playlist URL.
    /// Xtream `get.php` playlist URLs become `.xtream` so the app can use the full API.
    public init?(pasted text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }

        if let link = LoginLink(url: url) {
            self = link
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        self = LoginLink.fromPlaylistURL(trimmed)
    }

    /// Xtream panels serve M3U from `/get.php?username=..&password=..`. The API on the same
    /// host is faster and richer than downloading a large playlist, so prefer it.
    public static func fromPlaylistURL(_ playlist: String) -> LoginLink {
        guard let components = URLComponents(string: playlist),
              components.path.lowercased().hasSuffix("get.php"),
              let items = components.queryItems,
              let user = items.first(where: { $0.name == "username" })?.value?.nilIfEmpty,
              let pass = items.first(where: { $0.name == "password" })?.value?.nilIfEmpty,
              let scheme = components.scheme,
              let host = components.host
        else {
            return .m3u(url: playlist)
        }
        let port = components.port.map { ":\($0)" } ?? ""
        var panelPath = components.percentEncodedPath
        panelPath = String(panelPath.dropLast("get.php".count))
        while panelPath.hasSuffix("/") {
            panelPath.removeLast()
        }
        return .xtream(server: "\(scheme)://\(host)\(port)\(panelPath)", username: user, password: pass)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "login"
        switch self {
        case let .xtream(server, username, password):
            components.queryItems = [
                URLQueryItem(name: "server", value: server),
                URLQueryItem(name: "username", value: username),
                URLQueryItem(name: "password", value: password),
            ]
        case let .m3u(playlist):
            components.queryItems = [URLQueryItem(name: "m3u", value: playlist)]
        }
        // URLComponents leaves "&", "=", "+" unescaped inside values; escape them so
        // nested playlist URLs survive the round trip.
        components.percentEncodedQuery = components.queryItems?
            .map { "\($0.name)=\(Self.escape($0.value ?? ""))" }
            .joined(separator: "&")
        return components.url!
    }

    /// An HTTPS Universal Link that opens BruTV directly when installed,
    /// or opens a web fallback landing page offering app download when not installed.
    public var universalURL: URL {
        guard var components = URLComponents(string: Self.defaultWebJoinBaseURL) else {
            return url
        }
        switch self {
        case let .xtream(server, username, password):
            components.queryItems = [
                URLQueryItem(name: "server", value: server),
                URLQueryItem(name: "username", value: username),
                URLQueryItem(name: "password", value: password),
            ]
        case let .m3u(playlist):
            components.queryItems = [URLQueryItem(name: "m3u", value: playlist)]
        }
        components.percentEncodedQuery = components.queryItems?
            .map { "\($0.name)=\(Self.escape($0.value ?? ""))" }
            .joined(separator: "&")
        return components.url ?? url
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
