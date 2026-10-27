import Foundation
import GRDB

public final class ClientFolderRepository: Sendable {
    private let db: DockyardDatabase
    public init(database: DockyardDatabase) { db = database }

    public func all() async throws -> [ClientFolder] {
        try await db.writer.read { try ClientFolder.order(sql: "name COLLATE NOCASE").fetchAll($0) }
    }

    @discardableResult
    public func create(name: String) async throws -> ClientFolder {
        let folder = ClientFolder(name: name)
        try await db.writer.write { try folder.insert($0) }
        return folder
    }

    /// Finds a folder by name (case-insensitive) or creates it.
    public func findOrCreate(name: String) async throws -> ClientFolder {
        try await db.writer.write { db in
            if let f = try ClientFolder.fetchOne(db, sql: "SELECT * FROM clientFolder WHERE name = ? COLLATE NOCASE", arguments: [name]) {
                return f
            }
            let f = ClientFolder(name: name)
            try f.insert(db)
            return f
        }
    }

    public func rename(_ id: UUID, to name: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE clientFolder SET name = ? WHERE id = ?", arguments: [name, id.uuidString])
        }
    }

    /// Connections in the folder become unfiled.
    public func delete(_ id: UUID) async throws {
        _ = try await db.writer.write { try ClientFolder.deleteOne($0, key: id.uuidString) }
    }

    public func observe() -> AsyncStream<[ClientFolder]> {
        let obs = ValueObservation.tracking { try ClientFolder.order(sql: "name COLLATE NOCASE").fetchAll($0) }
        let (stream, c) = AsyncStream<[ClientFolder]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let writer = db.writer
        let task = Task { do { for try await v in obs.values(in: writer) { c.yield(v) } } catch {}; c.finish() }
        c.onTermination = { _ in task.cancel() }
        return stream
    }
}

public final class SessionRepository: Sendable {
    private let db: DockyardDatabase
    public init(database: DockyardDatabase) { db = database }

    public func load(_ connectionId: UUID) async throws -> SessionState? {
        try await db.writer.read { try SessionState.fetchOne($0, key: connectionId.uuidString) }
    }

    /// Silently ignores connections that were deleted in the meantime.
    public func save(_ state: SessionState) async throws {
        try await db.writer.write { db in
            guard try Connection.exists(db, key: state.connectionId.uuidString) else { return }
            try state.save(db)
        }
    }

    public func clear(_ connectionId: UUID) async throws {
        _ = try await db.writer.write { try SessionState.deleteOne($0, key: connectionId.uuidString) }
    }
}

public final class FolderHistoryRepository: Sendable {
    public static let defaultCap = 200
    private let db: DockyardDatabase
    private let cap: Int
    public init(database: DockyardDatabase, cap: Int = FolderHistoryRepository.defaultCap) { db = database; self.cap = max(1, cap) }

    /// Records a visit. A repeat of the most recent path only refreshes its time. Keeps at most `cap` rows per connection.
    public func record(connectionId: UUID, path: String, at date: Date = Date()) async throws {
        let cap = self.cap
        try await db.writer.write { db in
            guard try Connection.exists(db, key: connectionId.uuidString) else { return }
            let last = try FolderHistoryEntry.fetchOne(
                db, sql: "SELECT * FROM folderHistory WHERE connectionId = ? ORDER BY id DESC LIMIT 1",
                arguments: [connectionId.uuidString])
            if var last, last.path == path {
                last.visitedAt = date
                try last.update(db)
                return
            }
            var entry = FolderHistoryEntry(connectionId: connectionId, path: path, visitedAt: date)
            try entry.insert(db)
            try db.execute(sql: """
                DELETE FROM folderHistory WHERE connectionId = ? AND id NOT IN \
                (SELECT id FROM folderHistory WHERE connectionId = ? ORDER BY id DESC LIMIT ?)
                """, arguments: [connectionId.uuidString, connectionId.uuidString, cap])
        }
    }

    /// Most recent first, with repeated paths collapsed to their latest visit.
    public func entries(connectionId: UUID, limit: Int = 200) async throws -> [FolderHistoryEntry] {
        let rows = try await db.writer.read { db in
            try FolderHistoryEntry.fetchAll(
                db, sql: "SELECT * FROM folderHistory WHERE connectionId = ? ORDER BY id DESC",
                arguments: [connectionId.uuidString])
        }
        var seen = Set<String>()
        return Array(rows.filter { seen.insert($0.path).inserted }.prefix(limit))
    }

    /// Recent folders across every connection (for the jump search).
    public func recentAcrossConnections(limit: Int = 100) async throws -> [FolderHistoryEntry] {
        let rows = try await db.writer.read { db in
            try FolderHistoryEntry.fetchAll(db, sql: "SELECT * FROM folderHistory ORDER BY id DESC LIMIT ?", arguments: [limit * 3])
        }
        var seen = Set<String>()
        return Array(rows.filter { seen.insert("\($0.connectionId)|\($0.path)").inserted }.prefix(limit))
    }

    public func clear(connectionId: UUID) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM folderHistory WHERE connectionId = ?", arguments: [connectionId.uuidString])
        }
    }
}

public final class WHMSourceRepository: Sendable {
    private let db: DockyardDatabase
    public init(database: DockyardDatabase) { db = database }

    public func all() async throws -> [WHMSource] {
        try await db.writer.read { try WHMSource.order(sql: "label COLLATE NOCASE").fetchAll($0) }
    }
    public func source(id: UUID) async throws -> WHMSource? {
        try await db.writer.read { try WHMSource.fetchOne($0, key: id.uuidString) }
    }
    public func save(_ s: WHMSource) async throws { try await db.writer.write { try s.save($0) } }
    public func delete(_ id: UUID) async throws { _ = try await db.writer.write { try WHMSource.deleteOne($0, key: id.uuidString) } }
}

public final class SnippetRepository: Sendable {
    private let db: DockyardDatabase
    public init(database: DockyardDatabase) { db = database }

    /// Global snippets plus the ones attached to `connectionId`.
    public func snippets(for connectionId: UUID?) async throws -> [Snippet] {
        try await db.writer.read { db in
            if let connectionId {
                return try Snippet.fetchAll(
                    db, sql: "SELECT * FROM snippet WHERE connectionId IS NULL OR connectionId = ? ORDER BY sortOrder, name COLLATE NOCASE",
                    arguments: [connectionId.uuidString])
            }
            return try Snippet.fetchAll(db, sql: "SELECT * FROM snippet WHERE connectionId IS NULL ORDER BY sortOrder, name COLLATE NOCASE")
        }
    }
    public func save(_ s: Snippet) async throws { try await db.writer.write { try s.save($0) } }
    public func delete(_ id: UUID) async throws { _ = try await db.writer.write { try Snippet.deleteOne($0, key: id.uuidString) } }
}
