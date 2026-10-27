import Foundation
import GRDB

public enum HealthStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case ok
    case authFailed
    case hostNotFound
    case timedOut
    case refused
    case hostKeyChanged
    case needsSecret
    case removedFromSource
    case otherError

    public var isFailing: Bool { self != .ok }
}

/// The outcome of one connection test.
public struct ConnectionHealth: Sendable, Hashable {
    public var connectionId: UUID
    public var status: HealthStatus
    /// Time to connect, log in and list the folder. Only set when the test reached the server successfully.
    public var latencyMs: Int?
    /// A short explanation with secrets removed.
    public var message: String?
    public var testedAt: Date

    public init(connectionId: UUID, status: HealthStatus, latencyMs: Int? = nil, message: String? = nil, testedAt: Date = Date()) {
        self.connectionId = connectionId
        self.status = status
        self.latencyMs = latencyMs
        self.message = message
        self.testedAt = testedAt
    }
}

extension ConnectionHealth: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "connectionHealth"

    public init(row: Row) throws {
        let id: String = row["connectionId"]
        guard let connectionId = UUID(uuidString: id) else { throw DatabaseError(message: "Invalid UUID in connectionId") }
        let status: String = row["status"]
        self.init(
            connectionId: connectionId, status: HealthStatus(rawValue: status) ?? .otherError,
            latencyMs: row["latencyMs"], message: row["message"], testedAt: row["testedAt"])
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["connectionId"] = connectionId.uuidString
        container["status"] = status.rawValue
        container["latencyMs"] = latencyMs
        container["message"] = message
        container["testedAt"] = testedAt
    }
}

/// Stores test results. Each connection keeps its latest few; the newest one is what the manager shows.
public final class ConnectionHealthRepository: Sendable {
    public static let historyLimit = 10
    private let db: DockyardDatabase

    public init(database: DockyardDatabase) { db = database }

    public func record(_ results: [ConnectionHealth]) async throws {
        guard !results.isEmpty else { return }
        let limit = Self.historyLimit
        try await db.writer.write { db in
            for result in results {
                try result.insert(db)
                try db.execute(
                    sql: """
                        DELETE FROM connectionHealth WHERE connectionId = ?1
                        AND id NOT IN (SELECT id FROM connectionHealth WHERE connectionId = ?1 ORDER BY id DESC LIMIT ?2)
                        """,
                    arguments: [result.connectionId.uuidString, limit])
            }
        }
    }

    public func record(_ result: ConnectionHealth) async throws { try await record([result]) }

    /// The newest result per connection.
    public func latest() async throws -> [UUID: ConnectionHealth] {
        try await db.writer.read(Self.fetchLatest)
    }

    public func latest(for connectionId: UUID) async throws -> ConnectionHealth? {
        try await history(for: connectionId, limit: 1).first
    }

    /// Newest first.
    public func history(for connectionId: UUID, limit: Int = ConnectionHealthRepository.historyLimit) async throws -> [ConnectionHealth] {
        try await db.writer.read { db in
            try ConnectionHealth.fetchAll(
                db, sql: "SELECT * FROM connectionHealth WHERE connectionId = ? ORDER BY id DESC LIMIT ?",
                arguments: [connectionId.uuidString, max(0, limit)])
        }
    }

    /// Forgets a connection's results, e.g. after it was edited and the old verdict no longer applies.
    public func clear(connectionIds: [UUID]) async throws {
        guard !connectionIds.isEmpty else { return }
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM connectionHealth WHERE connectionId IN (\(connectionIds.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments(connectionIds.map(\.uuidString)))
        }
    }

    /// Emits the newest result per connection now and after every change.
    public func observeLatest() -> AsyncStream<[UUID: ConnectionHealth]> {
        ConnectionRepository.stream(ValueObservation.tracking(Self.fetchLatest), in: db.writer)
    }

    private static func fetchLatest(_ db: Database) throws -> [UUID: ConnectionHealth] {
        let rows = try ConnectionHealth.fetchAll(
            db, sql: """
                SELECT h.* FROM connectionHealth h
                WHERE h.id = (SELECT MAX(id) FROM connectionHealth WHERE connectionId = h.connectionId)
                """)
        return Dictionary(rows.map { ($0.connectionId, $0) }, uniquingKeysWith: { _, new in new })
    }
}
