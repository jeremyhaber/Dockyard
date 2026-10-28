import ConnectionKit
import Foundation

/// How the connections a WHM server creates log in. Set once per server instead of editing every account.
public enum WHMAccountLogin: Sendable, Hashable, RawRepresentable {
    /// Each account's cPanel password, asked on first connect.
    case password
    /// One private key for every account. Its passphrase, if any, is stored once under the WHM source's id.
    case key(path: String)
    case agent(AgentSocket)
    /// SSH logs in as root, then each account's files, commands and shell run as that account. Nothing is set
    /// up per account and accounts need no shell access.
    case throughRoot(RootAuth)

    /// How root logs in for `throughRoot`.
    public enum RootAuth: Sendable, Hashable {
        case key(path: String)
        case agent(AgentSocket)
    }

    public static let rootUser = "root"

    public var rawValue: String {
        switch self {
        case .password: "password"
        case .key(let path): "key:\(path)"
        case .agent(let socket): "agent:\(socket.rawValue)"
        case .throughRoot(.key(let path)): "root:key:\(path)"
        case .throughRoot(.agent(let socket)): "root:agent:\(socket.rawValue)"
        }
    }

    public init?(rawValue: String) {
        if rawValue.hasPrefix("root:") {
            switch WHMAccountLogin(rawValue: String(rawValue.dropFirst(5))) {
            case .key(let path): self = .throughRoot(.key(path: path))
            case .agent(let socket): self = .throughRoot(.agent(socket))
            default: return nil
            }
        } else if rawValue == "password" {
            self = .password
        } else if rawValue.hasPrefix("key:"), rawValue.count > 4 {
            self = .key(path: String(rawValue.dropFirst(4)))
        } else if rawValue.hasPrefix("agent:"), let socket = AgentSocket(rawValue: String(rawValue.dropFirst(6))) {
            self = .agent(socket)
        } else {
            return nil
        }
    }

    /// The private key every account uses, for sharing its passphrase.
    public var keyPath: String? {
        switch self {
        case .key(let path), .throughRoot(.key(let path)): path
        case .password, .agent, .throughRoot(.agent): nil
        }
    }

    /// Sets the authentication fields of `connection` to this login.
    public func apply(to connection: inout Connection) {
        connection.loginUser = nil
        switch self {
        case .password:
            connection.authMethods = .password
            connection.keyPath = nil
            connection.agentSocket = .system
        case .key(let path):
            connection.authMethods = .key
            connection.keyPath = path
            connection.agentSocket = .system
        case .agent(let socket):
            connection.authMethods = .agent
            connection.keyPath = nil
            connection.agentSocket = socket
        case .throughRoot(let root):
            switch root {
            case .key(let path): WHMAccountLogin.key(path: path).apply(to: &connection)
            case .agent(let socket): WHMAccountLogin.agent(socket).apply(to: &connection)
            }
            connection.loginUser = Self.rootUser
        }
    }

    /// Whether `connection` logs in exactly this way, i.e. it was never given its own login by hand.
    public func matches(_ connection: Connection) -> Bool {
        var copy = connection
        apply(to: &copy)
        return copy.authMethods == connection.authMethods && copy.keyPath == connection.keyPath
            && copy.agentSocket == connection.agentSocket && copy.loginUser == connection.loginUser
    }

    /// The source's accounts that need saving to move from `old` to `new`. Accounts whose login no longer
    /// matches `old` were set by hand and are left alone.
    public static func relogin(_ existing: [Connection], source: WHMSource, from old: WHMAccountLogin, to new: WHMAccountLogin) -> [Connection] {
        guard old != new else { return [] }
        return existing.compactMap { c in
            guard c.source == .whm(source.id), old.matches(c) else { return nil }
            var changed = c
            new.apply(to: &changed)
            return changed
        }
    }
}

/// Reads a WHM account's key passphrase from its WHM server when the account has none of its own and still uses
/// the server's key. Everything else passes straight through to `base`.
public struct WHMPassphraseStore: SecretStore {
    private let base: any SecretStore
    private let connections: ConnectionRepository
    private let sources: WHMSourceRepository

    public init(base: any SecretStore, connections: ConnectionRepository, sources: WHMSourceRepository) {
        self.base = base
        self.connections = connections
        self.sources = sources
    }

    public func secret(for connection: UUID, purpose: SecretPurpose) async throws -> String? {
        if let own = try await base.secret(for: connection, purpose: purpose) { return own }
        guard purpose == .keyPassphrase,
              let c = try? await connections.connection(id: connection), let sourceID = c.source.whmServerId,
              let source = try? await sources.source(id: sourceID), source.accountLogin.keyPath != nil, source.accountLogin.matches(c)
        else { return nil }
        return try await base.secret(for: sourceID, purpose: .keyPassphrase)
    }

    public func setSecret(_ secret: String, for connection: UUID, purpose: SecretPurpose) async throws {
        try await base.setSecret(secret, for: connection, purpose: purpose)
    }

    public func removeSecret(for connection: UUID, purpose: SecretPurpose) async throws {
        try await base.removeSecret(for: connection, purpose: purpose)
    }
}
