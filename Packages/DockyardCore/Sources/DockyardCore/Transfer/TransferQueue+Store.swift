import Foundation
import ConnectionKit
import GRDB

extension Database {
    /// Runs a statement through GRDB's statement cache (the queue issues the same few thousands of times).
    func run(_ sql: String, _ arguments: StatementArguments = StatementArguments()) throws {
        try cachedStatement(sql: sql).execute(arguments: arguments)
    }
}

struct Recovered {
    var maxId: Int64 = 0
    var stats = TransferStats()
    var unfinished = 0
    var trackers: [Int64: TransferQueue.Tracker] = [:]
    var siteKeys: [(key: String, label: String)] = []
}

extension TransferQueue {
    // MARK: Writing

    /// Blocking database access for bulk operations. These are not `async` so Swift picks GRDB's synchronous overloads.
    func readNow<T>(_ body: (Database) throws -> T) -> T? { try? writer.read(body) }

    func writeNow(_ body: (Database) throws -> Void) {
        do { try writer.write(body) } catch { log.emit(.error, "Could not update the transfer queue: \(error)") }
    }

    func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { await self.runFlush() }
    }

    private func runFlush() async {
        while true {
            drainRollups()
            guard !ops.isEmpty else { break }
            let batch = ops
            ops = []
            do {
                try await writer.write { db in for op in batch { try op(db) } }
            } catch {
                log.emit(.error, "Could not save the transfer queue: \(error)")
            }
        }
        flushTask = nil
    }

    /// Waits until everything recorded so far is in SQLite.
    public func flush() async { await flushNow() }

    func flushNow() async {
        scheduleFlush()
        while let task = flushTask { await task.value }
    }

    /// Writes pending changes on the calling thread. Bulk operations use it so that SQL and in-memory
    /// state change in one actor turn.
    func flushSync() {
        drainRollups()
        guard !ops.isEmpty else { return }
        let batch = ops
        ops = []
        do {
            try writer.write { db in for op in batch { try op(db) } }
        } catch {
            log.emit(.error, "Could not save the transfer queue: \(error)")
        }
    }

    private func drainRollups() {
        for (root, total) in rollupTotal {
            let done = rollupDone.removeValue(forKey: root) ?? 0
            ops.append { db in try db.run("UPDATE transferJob SET bytesTotal = MAX(0, bytesTotal + ?), bytesDone = MAX(0, bytesDone + ?) WHERE id = ?", [total, done, root]) }
        }
        for (root, done) in rollupDone {
            ops.append { db in try db.run("UPDATE transferJob SET bytesDone = MAX(0, bytesDone + ?) WHERE id = ?", [done, root]) }
        }
        for (parent, n) in childrenDoneDelta {
            ops.append { db in try db.run("UPDATE transferJob SET childrenDone = childrenDone + ? WHERE id = ?", [n, parent]) }
        }
        rollupTotal.removeAll()
        rollupDone.removeAll()
        childrenDoneDelta.removeAll()
    }

    /// Writes the running jobs' latest progress so that a SQL pass sees it.
    func persistActive() {
        for job in active.values { persist(job.record) }
    }

    // MARK: Lanes

    static let refillSize = 256

    func startRefills(_ site: SiteState) {
        for directories in [false, true] {
            let path: ReferenceWritableKeyPath<SiteState, Lane> = directories ? \.dirs : \.files
            let lane = site[keyPath: path]
            guard !lane.refilling, !lane.tailKnownEmpty, lane.window.count < Self.refillSize / 2 else { continue }
            site[keyPath: path].refilling = true
            site[keyPath: path].skippedAdds = false
            let key = site.key, generation = lane.generation, cursor = lane.cursor
            Task { await self.refill(key, directories: directories, generation: generation, cursor: cursor) }
        }
    }

    private func refill(_ key: String, directories: Bool, generation: Int, cursor: Int64) async {
        await flushNow()
        let limit = Self.refillSize
        let rows: [JobRecord] = (try? await writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT \(JobRecord.columns) FROM transferJob WHERE siteKey = ? AND isDirectory = ? AND state = 0 AND id > ? ORDER BY id LIMIT ?",
                arguments: [key, directories, cursor, limit]).map(JobRecord.init(row:))
        }) ?? []
        guard let site = sites[key] else { return }
        let path: ReferenceWritableKeyPath<SiteState, Lane> = directories ? \.dirs : \.files
        site[keyPath: path].refilling = false
        if site[keyPath: path].generation == generation {
            for row in rows { site[keyPath: path].window.append(row) }
            if let last = rows.last { site[keyPath: path].cursor = last.id }
            site[keyPath: path].tailKnownEmpty = rows.count < limit && !site[keyPath: path].skippedAdds
        }
        pump()
    }

    func resetLanes() {
        for site in sites.values {
            site.files.reset()
            site.dirs.reset()
            site.retry.removeAll()
        }
    }

    // MARK: Recovery

    static func recover(_ writer: any DatabaseWriter) throws -> Recovered {
        try writer.write { db in
            var out = Recovered()
            try db.run("""
                UPDATE transferJob SET state = 0, resume = CASE WHEN isDirectory = 0 THEN bytesDone > 0 ELSE 1 END
                WHERE state = 1 AND (isDirectory = 0 OR expanded = 0)
                """)
            out.maxId = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM transferJob") ?? 0
            out.stats = try aggregateStats(db)
            out.unfinished = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transferJob WHERE state IN (0, 1)") ?? 0
            out.trackers = try buildTrackers(db)
            let keys = try Row.fetchAll(db, sql: """
                SELECT DISTINCT siteKey, CASE WHEN srcSite IS NULL THEN dstLabel ELSE srcLabel END AS label
                FROM transferJob WHERE state = 0 AND siteKey != ?
                """, arguments: [JobRecord.localKey])
            var seen = Set<String>()
            for row in keys {
                let key: String = row["siteKey"]
                if seen.insert(key).inserted { out.siteKeys.append((key, row["label"])) }
            }
            return out
        }
    }

    static func aggregateStats(_ db: Database) throws -> TransferStats {
        var stats = TransferStats()
        let rows = try Row.fetchAll(db, sql: """
            SELECT state, isDirectory, expanded, COUNT(*) AS n, SUM(bytesTotal) AS total, SUM(bytesDone) AS done
            FROM transferJob GROUP BY state, isDirectory, expanded
            """)
        for row in rows {
            stats.add(
                state: TransferState(dbValue: row["state"]), isDirectory: row["isDirectory"], expanded: row["expanded"],
                count: row["n"], total: UInt64(max(0, row["total"] as Int64? ?? 0)), done: UInt64(max(0, row["done"] as Int64? ?? 0)))
        }
        return stats
    }

    /// One tracker per folder that has listed its contents and waits for its children.
    static func buildTrackers(_ db: Database) throws -> [Int64: Tracker] {
        var out: [Int64: Tracker] = [:]
        let dirs = try Row.fetchAll(db, sql: "SELECT \(JobRecord.columns) FROM transferJob WHERE isDirectory = 1 AND expanded = 1 AND state = 1")
        for row in dirs {
            let record = JobRecord(row: row)
            out[record.id] = Tracker(record: record, pending: 0)
        }
        guard !out.isEmpty else { return out }
        let counts = try Row.fetchAll(db, sql: """
            SELECT parentId, state, COUNT(*) AS n FROM transferJob
            WHERE parentId IN (SELECT id FROM transferJob WHERE isDirectory = 1 AND expanded = 1 AND state = 1)
            GROUP BY parentId, state
            """)
        for row in counts {
            guard let parent: Int64 = row["parentId"], var t = out[parent] else { continue }
            let n: Int = row["n"]
            switch TransferState(dbValue: row["state"]) {
            case .queued, .running: t.pending += n
            case .failed: t.failed += n
            case .cancelled: t.cancelled += n
            case .skipped: t.skipped += n
            case .completed: break
            }
            out[parent] = t
        }
        return out
    }

    func reloadStats() {
        if let fresh = try? writer.read({ try Self.aggregateStats($0) }) { stats = fresh }
    }

    func reloadTrackers() {
        if let fresh = try? writer.read({ try Self.buildTrackers($0) }) { trackers = fresh }
        for (id, t) in trackers where t.pending == 0 { finalizeFolder(id) }
    }

    /// Finishes folders that were waiting only for children that had already finished before a restart.
    func settleRecoveredFolders() {
        for (id, t) in trackers where t.pending == 0 { finalizeFolder(id) }
        pump()
    }

    func rebuiltTracker(_ record: JobRecord) -> Tracker {
        flushSync()
        let single = try? writer.read { db -> Tracker? in
            try Self.buildTrackers(db)[record.id]
        }
        var t = single ?? Tracker(record: record, pending: 0)
        t.record = record
        t.record.childCount = (try? writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transferJob WHERE parentId = ?", arguments: [record.id])
        }) ?? record.childCount
        return t
    }

    // MARK: Reading

    func fetch(_ id: Int64) -> JobRecord? {
        flushSync()
        return try? writer.read { db in
            try Row.fetchOne(db, sql: "SELECT \(JobRecord.columns) FROM transferJob WHERE id = ?", arguments: [id]).map(JobRecord.init(row:))
        }
    }

    func info(_ stored: JobRecord) -> TransferJobInfo {
        var r = stored
        var done = r.bytesDone, total = r.bytesTotal
        if let live = active[r.id] {
            r = live.record
            done = r.bytesDone; total = r.bytesTotal
        }
        if r.isDirectory {
            for job in active.values where job.record.rootId == r.id && !job.record.isDirectory { done += job.progressDone }
            total = max(total, done)
        }
        return TransferJobInfo(
            id: JobID.uuid(r.id), parentId: r.parentId.map(JobID.uuid), name: r.name, sourcePath: r.sourcePath,
            destinationPath: r.destPath, route: r.route, isRelay: r.isRelay, isDirectory: r.isDirectory, state: r.state,
            bytesDone: done, bytesTotal: total, error: r.error, childCount: r.childCount, finishedChildCount: r.childrenDone,
            willResume: r.resume && !r.isDirectory)
    }

    public func job(_ id: UUID) async -> TransferJobInfo? {
        guard let row = JobID.row(id) else { return nil }
        await flushNow()
        let record = try? await writer.read { db in
            try Row.fetchOne(db, sql: "SELECT \(JobRecord.columns) FROM transferJob WHERE id = ?", arguments: [row]).map(JobRecord.init(row:))
        }
        return record.flatMap { $0 }.map(info)
    }

    /// All direct children. For large folders use `page(offset:limit:filter:)` with `.children(of:)`.
    public func children(of id: UUID) async -> [TransferJobInfo] {
        await page(offset: 0, limit: Int.max, filter: TransferJobFilter(scope: .children(of: id)))
    }

    /// One page of rows in the order they were added, straight from SQLite.
    public func page(offset: Int, limit: Int, filter: TransferJobFilter = TransferJobFilter()) async -> [TransferJobInfo] {
        await flushNow()
        return await fetchPage(offset: offset, limit: limit, filter: filter)
    }

    func fetchPage(offset: Int, limit: Int, filter: TransferJobFilter) async -> [TransferJobInfo] {
        let (clause, arguments) = Self.whereClause(filter)
        let sql = "SELECT \(JobRecord.columns) FROM transferJob WHERE \(clause) ORDER BY id LIMIT ? OFFSET ?"
        let args = arguments + [min(limit, Int(Int32.max)), max(0, offset)]
        let records: [JobRecord] = (try? await writer.read { db in
            try Row.fetchAll(db, sql: sql, arguments: args).map(JobRecord.init(row:))
        }) ?? []
        return records.map(info)
    }

    /// Number of rows `page` would return in total.
    public func count(_ filter: TransferJobFilter = TransferJobFilter()) async -> Int {
        await flushNow()
        let (clause, arguments) = Self.whereClause(filter)
        return (try? await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transferJob WHERE \(clause)", arguments: arguments)
        }).flatMap { $0 } ?? 0
    }

    private static func whereClause(_ filter: TransferJobFilter) -> (String, StatementArguments) {
        var parts: [String] = []
        var arguments = StatementArguments()
        switch filter.scope {
        case .files: parts.append("isDirectory = 0")
        case .topLevel: parts.append("parentId IS NULL")
        case .children(let parent):
            parts.append("parentId = ?")
            arguments += [JobID.row(parent) ?? -1]
        case .all: break
        }
        if let states = filter.states {
            parts.append("state IN (\(states.map { String($0.dbValue) }.sorted().joined(separator: ",")))")
        }
        return (parts.isEmpty ? "1" : parts.joined(separator: " AND "), arguments)
    }
}
