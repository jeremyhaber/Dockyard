import ConnectionKit
import DockyardCore
import Foundation

extension AppModel {
    /// The hops for `connection`, outermost first. Each hop checks its own host key against `knownHost`
    /// and asks to trust it the first time, like the final host does.
    func jumpHops(for connection: Connection, log: LogBuffer) throws -> [SSHJumpHop] {
        guard connection.protocol == .sftp, connection.jumpHost != nil else { return [] }
        let chain = try JumpChain.resolve(for: connection, lookup: jumpLookup(replacing: connection))
        return chain.map { hop in
            SSHJumpHop(
                config: hop.config, secrets: secrets,
                hostKeyValidator: hostKeyValidator(host: hop.host, port: hop.port, log: log))
        }
    }

    /// Looks hops up among the saved connections; `connection` itself wins over its saved copy so unsaved edits are checked too.
    func jumpLookup(replacing connection: Connection) -> (UUID) -> Connection? {
        let saved = Dictionary(allConnections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return { $0 == connection.id ? connection : saved[$0] }
    }

    /// Names from the outermost hop to the connection `id` called `name`, for the editor's route line.
    /// Nil when the chain is broken.
    func jumpRoute(via hop: UUID, to name: String, id: UUID) -> [String]? {
        let target = Connection(id: id, name: name, host: "", username: "", jumpHost: hop)
        guard let chain = try? JumpChain.resolve(for: target, lookup: jumpLookup(replacing: target)) else { return nil }
        return (chain + [target]).map(\.name)
    }

    /// Hops that log in with a password only need it in the Keychain before the tunnel opens.
    func ensureJumpCredentials(for connection: Connection, log: LogBuffer) async throws {
        guard connection.jumpHost != nil else { return }
        let chain = try JumpChain.resolve(for: connection, lookup: jumpLookup(replacing: connection))
        for hop in chain where hop.authMethods.contains(.password) && !hop.authMethods.contains(.agent) && !hop.authMethods.contains(.key) {
            if let existing = try await storedSecret(hop.id, .password), !existing.isEmpty {
                log.registerSecret(existing)
                continue
            }
            let request = PasswordRequest(
                title: "Password for \(hop.name)",
                message: "Enter the password for \(hop.username)@\(hop.host), the jump host for \(connection.name). Dockyard stores it in your Keychain.",
                fieldLabel: "Password")
            guard let value = await prompts.askPassword(request), !value.isEmpty else { throw AppError.cancelled }
            try await secrets.setSecret(value, for: hop.id, purpose: .password)
            log.registerSecret(value)
        }
    }

    /// Saved SFTP connections that could be this connection's jump host: not itself and not downstream of it.
    func jumpCandidates(for connectionID: UUID) -> [Connection] {
        let byID = Dictionary(allConnections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return allConnections.filter { candidate in
            guard candidate.protocol == .sftp, candidate.id != connectionID else { return false }
            var seen: Set<UUID> = [candidate.id]
            var next = candidate.jumpHost
            while let id = next, seen.insert(id).inserted {
                if id == connectionID { return false }
                next = byID[id]?.jumpHost
            }
            return true
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
