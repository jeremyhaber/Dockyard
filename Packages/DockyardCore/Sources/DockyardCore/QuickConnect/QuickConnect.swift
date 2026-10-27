import Foundation
import ConnectionKit

/// What the Quick Connect bar holds.
public struct QuickConnectInput: Sendable, Equatable {
    public var protocolChoice: ConnectionProtocol
    /// Host, or a pasted URL such as `sftp://user@host:22/path`, or `host:port`.
    public var host: String
    public var port: Int?
    public var username: String
    public var password: String?
    public var keyPath: String?

    public init(protocolChoice: ConnectionProtocol = .sftp, host: String, port: Int? = nil,
                username: String = "", password: String? = nil, keyPath: String? = nil) {
        self.protocolChoice = protocolChoice
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.keyPath = keyPath
    }
}

public enum QuickConnectError: Error, Equatable {
    case missingHost
    case invalidPort(String)
    case badURL(ConnectionURLError)
}

public struct QuickConnectResult: Sendable {
    public var connection: Connection
    /// True when a new Connection row was created (it gets the NEW tag).
    public var created: Bool
    /// Folder to open first, from a pasted URL path.
    public var initialPath: String?
}

/// A normalised, validated form of the bar's contents.
public struct ResolvedQuickConnect: Sendable, Equatable {
    public var `protocol`: ConnectionProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var keyPath: String?
    public var path: String?
}

public struct QuickConnectService: Sendable {
    private let repository: ConnectionRepository
    private let secrets: any SecretStore
    private let clock: any DockyardClock

    public init(repository: ConnectionRepository, secrets: any SecretStore, clock: any DockyardClock = SystemClock()) {
        self.repository = repository
        self.secrets = secrets
        self.clock = clock
    }

    /// Parses the bar contents. A pasted URL wins over the individual fields it specifies.
    public static func resolve(_ input: QuickConnectInput) throws -> ResolvedQuickConnect {
        let raw = input.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw QuickConnectError.missingHost }
        var proto = input.protocolChoice
        var host = raw
        var port = input.port
        var user = input.username.trimmingCharacters(in: .whitespaces)
        var password = input.password.flatMap { $0.isEmpty ? nil : $0 }
        var path: String?

        if raw.contains("://") {
            let parsed: ParsedConnectionURL
            do { parsed = try ConnectionConfig.parse(url: raw) } catch let e as ConnectionURLError { throw QuickConnectError.badURL(e) }
            proto = parsed.config.protocol
            host = parsed.config.host
            // The URL always yields a port (default for its scheme); only treat it as explicit when written.
            port = Self.urlHasExplicitPort(raw) ? parsed.config.port : input.port
            if !parsed.config.username.isEmpty { user = parsed.config.username }
            if let p = parsed.password, !p.isEmpty { password = p }
            path = parsed.path
        } else if let colon = raw.lastIndex(of: ":"), !raw.hasPrefix("["), raw.filter({ $0 == ":" }).count == 1 {
            let portText = String(raw[raw.index(after: colon)...])
            guard let p = Int(portText), (1...65535).contains(p) else { throw QuickConnectError.invalidPort(portText) }
            host = String(raw[..<colon])
            port = p
        }
        // user@host typed in the host field.
        if !raw.contains("://"), let at = host.lastIndex(of: "@") {
            if user.isEmpty { user = String(host[..<at]) }
            host = String(host[host.index(after: at)...])
        }
        host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw QuickConnectError.missingHost }
        if let p = port, !(1...65535).contains(p) { throw QuickConnectError.invalidPort(String(p)) }
        let finalPort = port ?? proto.defaultPort
        if user.isEmpty && proto != .sftp { user = "anonymous" }
        return ResolvedQuickConnect(protocol: proto, host: host, port: finalPort, username: user,
                                    password: password, keyPath: input.keyPath, path: path)
    }

    private static func urlHasExplicitPort(_ url: String) -> Bool {
        guard let r = url.range(of: "://") else { return false }
        var rest = url[r.upperBound...]
        if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        if rest.hasPrefix("[") { return rest.contains("]:") }
        return rest.contains(":")
    }

    /// Finds the matching saved connection or creates one with source `quickConnect`. The password
    /// goes to the secret store, never to the database.
    public func connect(_ input: QuickConnectInput) async throws -> QuickConnectResult {
        let r = try Self.resolve(input)
        var created = false
        var connection: Connection
        if var existing = try await repository.connection(protocol: r.protocol, host: r.host, port: r.port, username: r.username) {
            // Using a quick connect a second time retires its NEW tag.
            existing.isNew = false
            if let key = r.keyPath, !key.isEmpty {
                existing.keyPath = key
                existing.authMethods.insert(.key)
            }
            existing.lastConnectedAt = clock.now()
            connection = existing
        } else {
            created = true
            var auth: AuthMethods = .password
            if let key = r.keyPath, !key.isEmpty { auth = r.password == nil ? .key : .both }
            connection = Connection(
                name: r.host, protocol: r.protocol, host: r.host, port: r.port, username: r.username,
                authMethods: auth, keyPath: r.keyPath.flatMap { $0.isEmpty ? nil : $0 }, source: .quickConnect,
                lastConnectedAt: clock.now(), createdAt: clock.now(), isNew: true, initialRemotePath: r.path)
        }
        try await repository.save(connection)
        if let pw = r.password {
            try await secrets.setSecret(pw, for: connection.id, purpose: .password)
        }
        return QuickConnectResult(connection: connection, created: created, initialPath: r.path ?? connection.initialRemotePath)
    }

    /// Entries for the history dropdown: quick connects, most recently used first.
    public func history(limit: Int = 20) async throws -> [QuickConnectHistoryEntry] {
        let all = try await repository.fetch(.source(.quickConnect))
        return all
            .sorted { ($0.lastConnectedAt ?? $0.createdAt) > ($1.lastConnectedAt ?? $1.createdAt) }
            .prefix(limit)
            .map { QuickConnectHistoryEntry(connectionId: $0.id, protocol: $0.protocol, host: $0.host, port: $0.port, username: $0.username) }
    }
}

public struct QuickConnectHistoryEntry: Sendable, Hashable, Identifiable {
    public var connectionId: UUID
    public var `protocol`: ConnectionProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var id: UUID { connectionId }

    /// e.g. `sftp://bob@box.example.com:2222`
    public var display: String {
        let user = username.isEmpty ? "" : "\(username)@"
        let port = self.port == `protocol`.defaultPort ? "" : ":\(self.port)"
        return "\(`protocol`.rawValue)://\(user)\(host)\(port)"
    }

    /// The bar contents this entry restores.
    public var input: QuickConnectInput {
        QuickConnectInput(protocolChoice: `protocol`, host: host, port: port, username: username)
    }
}
