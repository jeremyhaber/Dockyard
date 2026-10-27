import Foundation
import ConnectionKit

public struct SSHConfigImportSummary: Sendable, Equatable {
    public var created = 0
    public var updated = 0
    /// An entry for the same host, port and user already exists and was not created by an ssh config import.
    public var skippedExisting = 0
    public var warnings: [String] = []
}

/// Turns the entries of `~/.ssh/config` into SFTP connections (source `sshConfigImport`).
///
/// Re-importing updates the connections a previous import created (matched by alias = connection name) and
/// leaves fields the user edited alone. `ProxyJump` becomes `jumpHost`: for `ProxyJump a,b` the target uses `b`
/// and `b` uses `a`; hops that are not aliases in the file get connections of their own.
public struct SSHConfigImporter: Sendable {
    private let repository: ConnectionRepository
    private let defaultUser: String
    private let clock: any DockyardClock

    public init(repository: ConnectionRepository, defaultUser: String = NSUserName(), clock: any DockyardClock = SystemClock()) {
        self.repository = repository
        self.defaultUser = defaultUser
        self.clock = clock
    }

    public func apply(_ parsed: SSHConfigResult) async throws -> SSHConfigImportSummary {
        var summary = SSHConfigImportSummary(warnings: parsed.warnings)
        var idByAlias: [String: UUID] = [:]

        for entry in parsed.entries {
            if entry.hasProxyCommand {
                summary.warnings.append("\(entry.alias): ProxyCommand is not supported; imported without it")
            }
            let user = entry.user ?? defaultUser
            let port = entry.port ?? 22
            let existingImport = try await repository.fetch(.source(.sshConfigImport)).first { $0.name == entry.alias }
            if var current = existingImport {
                apply(entry, user: user, port: port, to: &current)
                try await repository.save(current)
                idByAlias[entry.alias] = current.id
                summary.updated += 1
                continue
            }
            if try await repository.connection(protocol: .sftp, host: entry.hostName, port: port, username: user) != nil {
                summary.skippedExisting += 1
                continue
            }
            var connection = Connection(name: entry.alias, protocol: .sftp, host: entry.hostName, port: port, username: user,
                                        source: .sshConfigImport, createdAt: clock.now())
            apply(entry, user: user, port: port, to: &connection)
            try await repository.save(connection)
            idByAlias[entry.alias] = connection.id
            summary.created += 1
        }

        // Second pass: jump hosts, now that every alias has an id.
        for entry in parsed.entries where !entry.proxyJump.isEmpty {
            guard let targetId = idByAlias[entry.alias] else { continue }
            var previous: UUID?
            for spec in entry.proxyJump {
                let hopId: UUID
                if let alias = idByAlias[spec.host] {
                    hopId = alias
                } else {
                    let (id, created) = try await hopConnection(for: spec, entry: entry)
                    hopId = id
                    if created { summary.created += 1 }
                }
                if let previous, previous != hopId { try await setJumpHost(of: hopId, to: previous, onlyIfUnset: true) }
                previous = hopId
            }
            if let last = previous, last != targetId { try await setJumpHost(of: targetId, to: last, onlyIfUnset: false) }
        }
        return summary
    }

    private func apply(_ entry: SSHConfigEntry, user: String, port: Int, to connection: inout Connection) {
        if !connection.userEditedFields.contains(.host) { connection.host = entry.hostName }
        if !connection.userEditedFields.contains(.port) { connection.port = port }
        connection.username = user
        if let key = entry.identityFiles.first {
            connection.keyPath = key
            connection.authMethods = [.key, .agent]
        } else {
            connection.keyPath = nil
            connection.authMethods = [.agent, .password]
        }
    }

    private func hopConnection(for spec: SSHJumpSpec, entry: SSHConfigEntry) async throws -> (UUID, created: Bool) {
        let user = spec.user ?? entry.user ?? defaultUser
        let port = spec.port ?? 22
        if let existing = try await repository.connection(protocol: .sftp, host: spec.host, port: port, username: user) {
            return (existing.id, false)
        }
        let hop = Connection(name: spec.host, protocol: .sftp, host: spec.host, port: port, username: user,
                             authMethods: [.agent, .password], source: .sshConfigImport, createdAt: clock.now())
        try await repository.save(hop)
        return (hop.id, true)
    }

    private func setJumpHost(of id: UUID, to jump: UUID, onlyIfUnset: Bool) async throws {
        try await repository.update(id) { connection in
            if onlyIfUnset && connection.jumpHost != nil { return }
            connection.jumpHost = jump
        }
    }
}
