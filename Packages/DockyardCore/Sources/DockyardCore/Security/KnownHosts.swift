import Foundation
import GRDB

public enum HostKeyVerdict: Sendable, Equatable {
    case trusted
    /// First time this host (and key type) is seen.
    case unknown
    /// A different key than the one trusted before. `previous` is the stored fingerprint.
    case changed(previous: String)
}

/// Trust-on-first-use host key fingerprints. Public key fingerprints are not secrets, so they live in SQLite.
public final class KnownHostRepository: Sendable {
    private let db: DockyardDatabase
    public init(database: DockyardDatabase) { db = database }

    static func key(_ host: String) -> String { host.lowercased() }

    public func verdict(host: String, port: Int, keyType: String, fingerprint: String) async throws -> HostKeyVerdict {
        let host = Self.key(host)
        let stored: String? = try await db.writer.read { db in
            try String.fetchOne(
                db, sql: "SELECT fingerprint FROM knownHost WHERE host = ? AND port = ? AND keyType = ?",
                arguments: [host, port, keyType])
        }
        guard let stored else { return .unknown }
        return stored == fingerprint ? .trusted : .changed(previous: stored)
    }

    /// Trusts (or replaces) the key for this host, port and key type.
    public func trust(host: String, port: Int, keyType: String, fingerprint: String, at date: Date = Date()) async throws {
        let host = Self.key(host)
        try await db.writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO knownHost (host, port, keyType, fingerprint, firstSeenAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [host, port, keyType, fingerprint, date])
        }
    }

    public func forget(host: String, port: Int) async throws {
        let host = Self.key(host)
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM knownHost WHERE host = ? AND port = ?", arguments: [host, port])
        }
    }

    public func count() async throws -> Int {
        try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM knownHost") ?? 0 }
    }
}
