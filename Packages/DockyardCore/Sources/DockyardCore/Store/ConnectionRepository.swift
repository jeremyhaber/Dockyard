import Foundation
import GRDB
import ConnectionKit

/// What the connection manager and sidebar can ask for.
public struct ConnectionFilter: Sendable, Equatable {
    public enum Scope: Sendable, Equatable {
        case all
        case favorites
        /// Most recently connected first.
        case recent(limit: Int)
        /// Most recently created first.
        case recentlyAdded(limit: Int)
        case source(ConnectionSource)
        /// Any WHM server.
        case anyWHM
        case ids([UUID])
    }

    public enum LastUsed: Sendable, Equatable {
        case within(days: Int)
        case never
    }

    /// Last known test result. Connections never tested count as `.untested`.
    public enum Health: Sendable, Equatable {
        /// Any status other than OK.
        case failing
        case ok
        case untested
    }

    public var scope: Scope
    /// Free text; every whitespace separated token must match name, client, host, username or tags.
    public var search: String
    public var protocols: Set<ConnectionProtocol>
    public var whmServer: UUID?
    public var tag: String?
    public var lastUsed: LastUsed?
    public var hideRemovedFromSource: Bool
    public var health: Health?
    /// Soft-deleted connections are hidden unless a caller (such as a sync that must not resurrect them) asks for them.
    public var includeRemoved: Bool

    public init(
        scope: Scope = .all, search: String = "", protocols: Set<ConnectionProtocol> = [],
        whmServer: UUID? = nil, tag: String? = nil, lastUsed: LastUsed? = nil, hideRemovedFromSource: Bool = false,
        health: Health? = nil, includeRemoved: Bool = false
    ) {
        self.scope = scope; self.search = search; self.protocols = protocols
        self.whmServer = whmServer; self.tag = tag; self.lastUsed = lastUsed
        self.hideRemovedFromSource = hideRemovedFromSource
        self.health = health; self.includeRemoved = includeRemoved
    }

    public static let all = ConnectionFilter()
    public static let favorites = ConnectionFilter(scope: .favorites)
    public static func recent(_ limit: Int = 5) -> ConnectionFilter { .init(scope: .recent(limit: limit)) }
    public static func recentlyAdded(_ limit: Int = 20) -> ConnectionFilter { .init(scope: .recentlyAdded(limit: limit)) }
    public static func source(_ s: ConnectionSource) -> ConnectionFilter { .init(scope: .source(s)) }
    public static func search(_ text: String) -> ConnectionFilter { .init(search: text) }
}

/// Which connections currently have a tab open. Held in memory only.
public final class OpenConnections: Sendable {
    private struct State {
        var ids: [UUID] = []
        var continuations: [UUID: AsyncStream<[UUID]>.Continuation] = [:]
    }
    private let state = LockedBox(State())
    public init() {}

    public var ids: [UUID] { state.withLock { $0.ids } }
    public func isOpen(_ id: UUID) -> Bool { state.withLock { $0.ids.contains(id) } }

    public func open(_ id: UUID) {
        publish { s in if !s.ids.contains(id) { s.ids.append(id); return true }; return false }
    }

    public func close(_ id: UUID) {
        publish { s in
            if let i = s.ids.firstIndex(of: id) { s.ids.remove(at: i); return true }
            return false
        }
    }

    private func publish(_ mutate: (inout State) -> Bool) {
        let (targets, ids): ([AsyncStream<[UUID]>.Continuation], [UUID]) = state.withLock { s in
            guard mutate(&s) else { return ([], s.ids) }
            return (Array(s.continuations.values), s.ids)
        }
        for c in targets { c.yield(ids) }
    }

    /// Emits the current set immediately and on every change.
    public func stream() -> AsyncStream<[UUID]> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<[UUID]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { s in
            s.continuations[key] = continuation
            continuation.yield(s.ids)
        }
        continuation.onTermination = { [state] _ in state.withLock { _ = $0.continuations.removeValue(forKey: key) } }
        return stream
    }
}

public final class ConnectionRepository: Sendable {
    let db: DockyardDatabase
    let clock: any DockyardClock
    public let openConnections: OpenConnections

    public init(database: DockyardDatabase, clock: any DockyardClock = SystemClock(), openConnections: OpenConnections = OpenConnections()) {
        self.db = database
        self.clock = clock
        self.openConnections = openConnections
    }

    // MARK: Writes

    /// Inserts or replaces a connection exactly as given (used by importers and sync).
    public func save(_ connection: Connection) async throws {
        try await db.writer.write { try connection.save($0) }
    }

    public func save(_ connections: [Connection]) async throws {
        try await db.writer.write { db in for c in connections { try c.save(db) } }
    }

    /// Saves an edit made by the user and records which tracked fields changed so syncs leave them alone.
    @discardableResult
    public func saveEdited(_ edited: Connection) async throws -> Connection {
        try await db.writer.write { db in
            var updated = edited
            if let old = try Connection.fetchOne(db, key: edited.id.uuidString) {
                updated.userEditedFields = old.userEditedFields
                if old.name != edited.name { updated.userEditedFields.insert(.name) }
                if old.notes != edited.notes { updated.userEditedFields.insert(.notes) }
                if old.host != edited.host { updated.userEditedFields.insert(.host) }
                if old.port != edited.port { updated.userEditedFields.insert(.port) }
                if old.faviconSite != edited.faviconSite { updated.userEditedFields.insert(.faviconSite) }
                if old.webURLs != edited.webURLs { updated.userEditedFields.insert(.webURLs) }
            }
            try updated.save(db)
            return updated
        }
    }

    public func delete(_ id: UUID) async throws {
        openConnections.close(id)
        _ = try await db.writer.write { try Connection.deleteOne($0, key: id.uuidString) }
    }

    public func setFavorite(_ id: UUID, _ favorite: Bool) async throws {
        try await update(id) { $0.favorite = favorite }
    }

    public func clearNew(_ id: UUID) async throws {
        try await update(id) { $0.isNew = false }
    }

    /// Records a successful connection: sets last used, clears the NEW flag.
    public func markConnected(_ id: UUID) async throws {
        let now = clock.now()
        try await update(id) { $0.lastConnectedAt = now; $0.isNew = false }
    }

    public func update(_ id: UUID, _ change: @escaping @Sendable (inout Connection) -> Void) async throws {
        try await db.writer.write { db in
            guard var c = try Connection.fetchOne(db, key: id.uuidString) else { return }
            change(&c)
            try c.update(db)
        }
    }

    // MARK: Reads

    public func connection(id: UUID) async throws -> Connection? {
        try await db.writer.read { try Connection.fetchOne($0, key: id.uuidString) }
    }

    public func connection(protocol p: ConnectionProtocol, host: String, port: Int, username: String) async throws -> Connection? {
        try await db.writer.read { db in
            try Connection.fetchOne(
                db,
                sql: "SELECT * FROM connection WHERE protocol = ? AND host = ? COLLATE NOCASE AND port = ? AND username = ? AND deletedAt IS NULL ORDER BY createdAt LIMIT 1",
                arguments: [p.rawValue, host, port, username])
        }
    }

    /// The connection a previous 1Password import created from this item.
    public func connection(onePasswordItemId itemId: String, source: ConnectionSource = .onePasswordImport) async throws -> Connection? {
        try await db.writer.read { db in
            try Connection.fetchOne(
                db, sql: "SELECT * FROM connection WHERE onePasswordItemId = ? AND source = ? AND deletedAt IS NULL ORDER BY createdAt LIMIT 1",
                arguments: [itemId, source.rawValue])
        }
    }

    public func fetch(_ filter: ConnectionFilter = .all) async throws -> [Connection] {
        let (sql, args) = query(for: filter)
        return try await db.writer.read { try Connection.fetchAll($0, sql: sql, arguments: args) }
    }

    public func count() async throws -> Int {
        try await db.writer.read { try Connection.filter(sql: "deletedAt IS NULL").fetchCount($0) }
    }

    /// Distinct tags in use, sorted.
    public func allTags() async throws -> [String] {
        let all = try await fetch(.all)
        return Array(Set(all.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Connection counts per source (for the manager's Sources list).
    public func sourceCounts() async throws -> [String: Int] {
        try await db.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT source, COUNT(*) AS n FROM connection WHERE deletedAt IS NULL GROUP BY source")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["source"] as String, $0["n"] as Int) })
        }
    }

    // MARK: Observation

    /// Emits the current result and again after every change that affects it.
    public func observe(_ filter: ConnectionFilter = .all) -> AsyncStream<[Connection]> {
        let (sql, args) = query(for: filter)
        let observation = ValueObservation.tracking { db in
            try Connection.fetchAll(db, sql: sql, arguments: args)
        }
        let writer = db.writer
        return Self.stream(observation, in: writer)
    }

    /// Connections that currently have a tab, in the order they were opened.
    public func observeOpenNow() -> AsyncStream<[Connection]> {
        let writer = db.writer
        let tracker = openConnections
        let (out, continuation) = AsyncStream<[Connection]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (trigger, triggerContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let sources = [
            Task { for await _ in tracker.stream() { triggerContinuation.yield() } },
            Task {
                let obs = ValueObservation.tracking { try Connection.fetchCount($0) }
                do { for try await _ in obs.values(in: writer) { triggerContinuation.yield() } } catch {}
            },
        ]
        let loop = Task {
            for await _ in trigger {
                let ids = tracker.ids
                guard let rows = try? await writer.read({ db in
                    try Connection.filter(keys: ids.map(\.uuidString)).filter(sql: "deletedAt IS NULL").fetchAll(db)
                }) else { continue }
                let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
                continuation.yield(ids.compactMap { byId[$0] })
            }
        }
        continuation.onTermination = { _ in
            sources.forEach { $0.cancel() }
            triggerContinuation.finish()
            loop.cancel()
        }
        return out
    }

    static func stream<T: Sendable>(_ observation: ValueObservation<ValueReducers.Fetch<T>>, in writer: any DatabaseWriter) -> AsyncStream<T> {
        let (stream, continuation) = AsyncStream<T>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            do {
                for try await value in observation.values(in: writer) { continuation.yield(value) }
            } catch {}
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: Query building

    func query(for filter: ConnectionFilter) -> (String, StatementArguments) {
        var clauses: [String] = []
        var args = StatementArguments()
        var order = "c.name COLLATE NOCASE, c.createdAt"
        var limit: Int?

        switch filter.scope {
        case .all: break
        case .favorites: clauses.append("c.favorite = 1")
        case .recent(let n):
            clauses.append("c.lastConnectedAt IS NOT NULL")
            order = "c.lastConnectedAt DESC"; limit = n
        case .recentlyAdded(let n):
            order = "c.createdAt DESC"; limit = n
        case .source(let s):
            clauses.append("c.source = ?"); args += [s.rawValue]
        case .anyWHM: clauses.append("c.source LIKE 'whm:%'")
        case .ids(let ids):
            if ids.isEmpty { clauses.append("0") } else {
                clauses.append("c.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))")
                args += StatementArguments(ids.map(\.uuidString))
            }
        }
        if !filter.protocols.isEmpty {
            clauses.append("c.protocol IN (\(filter.protocols.map { _ in "?" }.joined(separator: ",")))")
            args += StatementArguments(filter.protocols.map(\.rawValue).sorted())
        }
        if let w = filter.whmServer { clauses.append("c.source = ?"); args += ["whm:\(w.uuidString)"] }
        if let tag = filter.tag,
           let json = try? JSONEncoder().encode(tag) {
            clauses.append("c.tags LIKE ? ESCAPE '\\'")
            args += ["%" + Self.escapeLike(String(decoding: json, as: UTF8.self)) + "%"]
        }
        switch filter.lastUsed {
        case .within(let days)?:
            clauses.append("c.lastConnectedAt >= ?")
            args += [clock.now().addingTimeInterval(-Double(days) * 86_400)]
        case .never?: clauses.append("c.lastConnectedAt IS NULL")
        case nil: break
        }
        if filter.hideRemovedFromSource { clauses.append("c.removedFromSource = 0") }
        if !filter.includeRemoved { clauses.append("c.deletedAt IS NULL") }
        let latestStatus = "(SELECT status FROM connectionHealth WHERE connectionId = c.id ORDER BY id DESC LIMIT 1)"
        switch filter.health {
        case .failing?: clauses.append("\(latestStatus) <> 'ok'")
        case .ok?: clauses.append("\(latestStatus) = 'ok'")
        case .untested?: clauses.append("\(latestStatus) IS NULL")
        case nil: break
        }
        for token in filter.search.split(whereSeparator: \.isWhitespace) {
            let like = "%" + Self.escapeLike(String(token)) + "%"
            clauses.append("""
                (c.name LIKE ? ESCAPE '\\' OR c.host LIKE ? ESCAPE '\\' OR c.username LIKE ? ESCAPE '\\' \
                OR c.tags LIKE ? ESCAPE '\\' OR f.name LIKE ? ESCAPE '\\')
                """)
            args += [like, like, like, like, like]
        }

        var sql = "SELECT c.* FROM connection c LEFT JOIN clientFolder f ON f.id = c.clientFolderId"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY " + order
        if let limit { sql += " LIMIT \(max(0, limit))" }
        return (sql, args)
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
