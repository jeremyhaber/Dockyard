import Foundation
import GRDB
import ConnectionKit

/// Removing a connection hides it for 30 days. Its secrets, session state and history stay until it is purged.
extension ConnectionRepository {
    public static let removedRetention: TimeInterval = 30 * 86_400

    /// Hides the connections and closes their tabs. Returns how many were removed.
    @discardableResult
    public func softDelete(ids: [UUID]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let now = clock.now()
        let strings = ids.map(\.uuidString)
        let count = try await db.writer.write { db in
            try Connection.filter(keys: strings).filter(sql: "deletedAt IS NULL").updateAll(db, Column("deletedAt").set(to: now))
        }
        for id in ids { openConnections.close(id) }
        return count
    }

    /// Brings removed connections back exactly as they were.
    @discardableResult
    public func restore(ids: [UUID]) async throws -> [Connection] {
        guard !ids.isEmpty else { return [] }
        let strings = ids.map(\.uuidString)
        return try await db.writer.write { db in
            try Connection.filter(keys: strings).filter(sql: "deletedAt IS NOT NULL").updateAll(db, Column("deletedAt").set(to: nil))
            return try Connection.filter(keys: strings).order(sql: "name COLLATE NOCASE, createdAt").fetchAll(db)
        }
    }

    /// Removed connections, most recently removed first.
    public func recentlyRemoved() async throws -> [Connection] {
        try await db.writer.read(Self.fetchRemoved)
    }

    public func observeRecentlyRemoved() -> AsyncStream<[Connection]> {
        let observation = ValueObservation.tracking(Self.fetchRemoved)
        return Self.stream(observation, in: db.writer)
    }

    /// Permanently deletes connections removed more than `age` ago, with their Keychain secrets (every purpose).
    /// Session state, folder history and health results go with the row. Returns how many were purged.
    @discardableResult
    public func purgeRemoved(olderThan age: TimeInterval = ConnectionRepository.removedRetention, secrets: any SecretStore) async throws -> Int {
        let cutoff = clock.now().addingTimeInterval(-age)
        let ids = try await db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM connection WHERE deletedAt IS NOT NULL AND deletedAt <= ?", arguments: [cutoff])
        }
        return try await purge(ids: ids.compactMap(UUID.init(uuidString:)), secrets: secrets)
    }

    /// Empties the Recently removed list now: purges the given removed connections (or all of them).
    @discardableResult
    public func emptyRecentlyRemoved(ids: [UUID]? = nil, secrets: any SecretStore) async throws -> Int {
        let removed = try await recentlyRemoved().map(\.id)
        return try await purge(ids: ids.map { wanted in removed.filter(wanted.contains) } ?? removed, secrets: secrets)
    }

    /// Secrets go first so a failure leaves the row, and the purge is retried later, instead of orphaning Keychain items.
    private func purge(ids: [UUID], secrets: any SecretStore) async throws -> Int {
        var purged = 0
        for id in ids {
            for purpose in SecretPurpose.allCases { try await secrets.removeSecret(for: id, purpose: purpose) }
            let removed = try await db.writer.write { db in
                try Connection.filter(key: id.uuidString).filter(sql: "deletedAt IS NOT NULL").deleteAll(db)
            }
            purged += removed
        }
        return purged
    }

    private static func fetchRemoved(_ db: Database) throws -> [Connection] {
        try Connection.filter(sql: "deletedAt IS NOT NULL").order(sql: "deletedAt DESC, name COLLATE NOCASE").fetchAll(db)
    }
}
