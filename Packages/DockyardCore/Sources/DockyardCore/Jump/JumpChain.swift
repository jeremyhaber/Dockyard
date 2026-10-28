import Foundation
import ConnectionKit

public enum JumpChainError: Error, Equatable, CustomStringConvertible {
    case cycle([String])
    case missing(UUID)
    case tooLong
    case notSSH(String)

    public var description: String {
        switch self {
        case .cycle(let names): "Jump hosts form a loop: \(names.joined(separator: " -> "))"
        case .missing: "A jump host was deleted"
        case .tooLong: "Too many jump hosts in a chain"
        case .notSSH(let name): "\"\(name)\" is not an SFTP connection and cannot be used as a jump host"
        }
    }
}

/// Resolves `Connection.jumpHost` references into the hop list that `SFTPFileSystem.Options.jumpHosts` takes.
public enum JumpChain {
    public static let maxHops = 8

    /// The hops outermost first, following each hop's own `jumpHost`.
    public static func resolve(for connection: Connection, lookup: (UUID) -> Connection?) throws -> [Connection] {
        var chain: [Connection] = []
        var visited: Set<UUID> = [connection.id]
        var next = connection.jumpHost
        while let id = next {
            guard let hop = lookup(id) else { throw JumpChainError.missing(id) }
            guard visited.insert(hop.id).inserted else {
                throw JumpChainError.cycle(([connection] + chain + [hop]).map(\.name))
            }
            guard hop.protocol == .sftp else { throw JumpChainError.notSSH(hop.name) }
            guard chain.count < maxHops else { throw JumpChainError.tooLong }
            chain.insert(hop, at: 0)
            next = hop.jumpHost
        }
        return chain
    }

    public static func hops(for connection: Connection, lookup: (UUID) -> Connection?, secrets: any SecretStore) throws -> [SSHJumpHop] {
        try resolve(for: connection, lookup: lookup).map { SSHJumpHop(config: $0.config, secrets: secrets) }
    }
}
