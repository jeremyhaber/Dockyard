import Foundation

/// A connection's own icon, shown in the sidebar and tabs instead of the website icon or initials.
public enum ConnectionIcon: Sendable, Hashable, Codable {
    /// An SF Symbol name and a colour as `#RRGGBB` (nil: accent colour).
    case symbol(name: String, color: String?)
    /// A small PNG chosen by the user.
    case image(Data)

    /// Images larger than this are refused; the app scales chosen files down to 64 px first.
    public static let maxImageBytes = 64 * 1024
}

/// A colour label for a connection, shown on its tab and its panel header.
public enum ConnectionColor: String, Sendable, Hashable, Codable, CaseIterable {
    case red, orange, yellow, green, teal, blue, indigo, purple, pink, brown, gray

    public var title: String { rawValue == "gray" ? "Grey" : rawValue.capitalized }
}

/// Where to look for a connection's website icon, in order.
public enum FaviconCandidates {
    /// The chosen icon website, then the host itself, each parent domain down to the registrable one
    /// (`test.acme.co.uk`, `acme.co.uk`), then the origins of the web URLs.
    /// Cloud connections, IP addresses and single-label hosts skip the host step, and so do WHM accounts, whose
    /// host is the shared server rather than the account's site.
    public static func origins(for connection: Connection) -> [String] {
        var out: [String] = []
        if let site = connection.faviconSite.flatMap(WebURLResolver.normalizeBase), let origin = origin(of: site) {
            out.append(origin)
        }
        let sharedServer = connection.source.whmServerId != nil && !connection.userEditedFields.contains(.host)
        if connection.protocol != .rclone, !sharedServer { out += hostOrigins(connection.host) }
        for mapping in connection.webURLs {
            guard let base = WebURLResolver.normalizeBase(mapping.baseURL), let origin = origin(of: base) else { continue }
            out.append(origin)
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    static func hostOrigins(_ host: String) -> [String] {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count >= 2, !h.contains(":"), !labels.allSatisfy({ Int($0) != nil }),
              labels.allSatisfy({ !$0.isEmpty }) else { return [] }
        var out: [String] = []
        for start in 0...(labels.count - 2) {
            let suffix = Array(labels[start...])
            if suffix.count == 2, isPublicSecondLevel(suffix) { break }
            out.append("https://" + suffix.joined(separator: "."))
        }
        return out
    }

    /// `co.uk`, `com.au` and the like: a short generic label under a two-letter country code.
    private static func isPublicSecondLevel(_ labels: [String]) -> Bool {
        labels.count == 2 && labels[1].count == 2
            && ["co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go", "gob", "nic"].contains(labels[0])
    }

    static func origin(of base: String) -> String? {
        guard let c = URLComponents(string: base), let scheme = c.scheme, let host = c.host else { return nil }
        return "\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "")
    }
}

/// Where the server pane's folder tree starts.
public enum FolderTreeRoot: String, Sendable, Hashable, Codable, CaseIterable {
    /// The login folder (e.g. `/home/user` on cPanel); `..` climbs above it.
    case home
    /// The server's `/`.
    case serverRoot

    public var title: String { self == .home ? "Home folder" : "Server root (/)" }

    /// The tree's starting folder for a server whose login folder is `home`.
    public func path(home: String) -> String { self == .home ? PathTools.normalize(home) : "/" }
}

/// Where the local pane starts when a connection opens.
public enum LocalStart: String, Sendable, Hashable, Codable, CaseIterable {
    /// The default folder from Settings, else the home folder.
    case defaultFolder = "default"
    /// The connection's own `localFolder`.
    case folder
    /// The Scratch folder, whose downloads expire.
    case scratch
}
