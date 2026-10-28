import Foundation

public enum ConnectionProtocol: String, Sendable, Hashable, Codable, CaseIterable {
    case sftp, ftp, ftps, rclone

    public var defaultPort: Int {
        switch self {
        case .sftp: 22
        case .ftp, .ftps: 21
        case .rclone: 0
        }
    }
}

public struct AuthMethods: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let key = AuthMethods(rawValue: 1)
    public static let password = AuthMethods(rawValue: 2)
    public static let agent = AuthMethods(rawValue: 4)
    /// Answers keyboard-interactive prompts with the stored password. `.password` also falls back to it.
    public static let keyboardInteractive = AuthMethods(rawValue: 8)
    public static let both: AuthMethods = [.key, .password]
}

public enum Elevation: String, Sendable, Hashable, Codable, CaseIterable {
    case none, su, sudo
}

public struct ConnectionConfig: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var `protocol`: ConnectionProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var authMethods: AuthMethods
    public var keyPath: String?
    public var elevation: Elevation
    /// The agent used by `.agent` authentication.
    public var agentSocket: AgentSocket
    /// SFTP only: after logging in as `username` (root), files, commands and shells run as this user instead.
    public var runAs: String?

    public init(
        id: UUID = UUID(),
        protocol: ConnectionProtocol,
        host: String,
        port: Int? = nil,
        username: String,
        authMethods: AuthMethods = .password,
        keyPath: String? = nil,
        elevation: Elevation = .none,
        agentSocket: AgentSocket = .system,
        runAs: String? = nil
    ) {
        self.id = id
        self.protocol = `protocol`
        self.host = host
        self.port = port ?? `protocol`.defaultPort
        self.username = username
        self.authMethods = authMethods
        self.keyPath = keyPath
        self.elevation = elevation
        self.agentSocket = agentSocket
        self.runAs = runAs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            protocol: try c.decode(ConnectionProtocol.self, forKey: .protocol),
            host: try c.decode(String.self, forKey: .host),
            port: try c.decode(Int.self, forKey: .port),
            username: try c.decode(String.self, forKey: .username),
            authMethods: try c.decode(AuthMethods.self, forKey: .authMethods),
            keyPath: try c.decodeIfPresent(String.self, forKey: .keyPath),
            elevation: try c.decode(Elevation.self, forKey: .elevation),
            agentSocket: try c.decodeIfPresent(AgentSocket.self, forKey: .agentSocket) ?? .system,
            runAs: try c.decodeIfPresent(String.self, forKey: .runAs)
        )
    }
}

/// Result of parsing a pasted URL such as `sftp://user@host:22/path`.
public struct ParsedConnectionURL: Sendable, Equatable {
    public var config: ConnectionConfig
    /// Initial remote path, if the URL has one.
    public var path: String?
    /// A password embedded in the URL. Callers should move it into a `SecretStore`.
    public var password: String?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        var a = lhs.config, b = rhs.config
        a.id = b.id
        return a == b && lhs.path == rhs.path && lhs.password == rhs.password
    }
}

public enum ConnectionURLError: Error, Equatable {
    case missingScheme
    case unsupportedScheme(String)
    case missingHost
    case invalidPort(String)
}

extension ConnectionConfig {
    public static func parse(url string: String) throws -> ParsedConnectionURL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://") else { throw ConnectionURLError.missingScheme }
        let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
        let proto: ConnectionProtocol
        switch scheme {
        case "sftp", "ssh": proto = .sftp
        case "ftp": proto = .ftp
        case "ftps", "ftpes": proto = .ftps
        default: throw ConnectionURLError.unsupportedScheme(scheme)
        }

        var rest = trimmed[schemeEnd.upperBound...]
        var path: String?
        if let slash = rest.firstIndex(of: "/") {
            let raw = String(rest[slash...])
            let decoded = raw.removingPercentEncoding ?? raw
            path = decoded == "/" ? nil : decoded
            rest = rest[..<slash]
        }

        var username = ""
        var password: String?
        if let at = rest.lastIndex(of: "@") {
            let userInfo = rest[..<at]
            rest = rest[rest.index(after: at)...]
            if let colon = userInfo.firstIndex(of: ":") {
                username = decode(userInfo[..<colon])
                password = decode(userInfo[userInfo.index(after: colon)...])
            } else {
                username = decode(userInfo)
            }
        }

        var host = String(rest)
        var port: Int?
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { throw ConnectionURLError.missingHost }
            let after = host[host.index(after: close)...]
            if after.hasPrefix(":") { port = try parsePort(after.dropFirst()) }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if let colon = host.lastIndex(of: ":") {
            port = try parsePort(host[host.index(after: colon)...])
            host = String(host[..<colon])
        }
        guard !host.isEmpty else { throw ConnectionURLError.missingHost }

        let config = ConnectionConfig(
            protocol: proto,
            host: host,
            port: port,
            username: username,
            authMethods: .password
        )
        return ParsedConnectionURL(config: config, path: path, password: password)
    }

    private static func decode(_ s: Substring) -> String {
        String(s).removingPercentEncoding ?? String(s)
    }

    private static func parsePort(_ s: Substring) throws -> Int {
        guard let port = Int(s), (1...65535).contains(port) else {
            throw ConnectionURLError.invalidPort(String(s))
        }
        return port
    }
}
