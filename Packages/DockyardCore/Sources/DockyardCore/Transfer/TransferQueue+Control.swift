import Foundation
import ConnectionKit
import GRDB

/// Bulk operations. Each one flushes pending writes, changes SQLite and the in-memory counters without
/// suspending in between, then drops the ready windows so they reload from SQLite.
extension TransferQueue {
    private static let subtree = """
        WITH RECURSIVE sub(id) AS (SELECT ? UNION ALL SELECT j.id FROM transferJob j JOIN sub ON j.parentId = sub.id)
        """

    // MARK: Cancel

    public func cancel(_ id: UUID) async {
        guard let row = JobID.row(id) else { return }
        persistActive()
        guard let record = fetch(row), !record.state.isFinished else { return }
        let ids = (readNow { db in
            try Set(Int64.fetchAll(db, sql: Self.subtree + " SELECT id FROM sub", arguments: [row]))
        }) ?? [row]
        var running: [ActiveJob] = []
        for job in active.values where ids.contains(job.record.id) || (record.parentId == nil && job.record.rootId == row) {
            job.cancelRequested = true
            running.append(job)
        }
        let wasRunning = active[row] != nil
        writeNow { db in
            try db.run(Self.subtree + """
                 UPDATE transferJob SET state = 4 WHERE id IN (SELECT id FROM sub)
                 AND (state = 0 OR (state = 1 AND isDirectory = 1 AND expanded = 1))
                """, [row])
        }
        for id in ids { trackers.removeValue(forKey: id) }
        if !wasRunning, let parent = record.parentId { childFinished(parent, state: .cancelled) }
        flushSync()
        reloadStats()
        resetLanes()
        settleWaiters()
        for job in running { job.task?.cancel() }
        pump()
        publishSoon()
    }

    public func cancelAll() async {
        persistActive()
        flushSync()
        let running = Array(active.values)
        for job in running { job.cancelRequested = true }
        writeNow { db in
            try db.run("UPDATE transferJob SET state = 4 WHERE state = 0 OR (state = 1 AND isDirectory = 1 AND expanded = 1)")
        }
        trackers.removeAll()
        reloadStats()
        resetLanes()
        settleWaiters()
        for job in running { job.task?.cancel() }
        pump()
        publishSoon()
    }

    // MARK: Retry

    /// Re-queues a failed or cancelled job. Partial files are resumed where the protocol supports it.
    public func retry(_ id: UUID) {
        guard let row = JobID.row(id) else { return }
        requeueFailed(subtree: row, states: "(3, 4)")
    }

    public func retryFailed() { requeueFailed(subtree: nil, states: "(3)") }

    private func requeueFailed(subtree root: Int64?, states: String) {
        persistActive()
        flushSync()
        let scope = root == nil ? "SELECT id FROM transferJob" : "SELECT id FROM sub"
        let prefix = root == nil ? "" : Self.subtree
        let args: StatementArguments = root.map { [$0] } ?? StatementArguments()
        try? writer.write { db in
            // Files, and folders whose listing never finished, go back to the queue.
            try db.run(prefix + """
                 UPDATE transferJob SET state = 0, error = NULL,
                   resume = CASE WHEN isDirectory = 0 THEN bytesDone > 0 ELSE 1 END
                 WHERE id IN (\(scope)) AND state IN \(states) AND (isDirectory = 0 OR expanded = 0)
                """, args)
            // Listed folders wait for their children again, or only for removing their source.
            for _ in 0..<64 {
                try db.run("""
                    UPDATE transferJob SET state = 1, error = NULL WHERE isDirectory = 1 AND expanded = 1 AND state IN \(states)
                    AND EXISTS (SELECT 1 FROM transferJob c WHERE c.parentId = transferJob.id AND c.state IN (0, 1))
                    """)
                if db.changesCount == 0 { break }
            }
            if let root {
                try db.run("""
                    UPDATE transferJob SET state = 0, error = NULL WHERE id = ? AND isDirectory = 1 AND expanded = 1 AND state IN \(states)
                    """, [root])
            }
            try db.run("""
                UPDATE transferJob SET childrenDone =
                  (SELECT COUNT(*) FROM transferJob c WHERE c.parentId = transferJob.id AND c.state >= 2)
                WHERE isDirectory = 1 AND expanded = 1
                """)
        }
        reloadStats()
        reloadTrackers()
        resetLanes()
        pump()
        publishSoon()
    }

    // MARK: Removal

    /// Forgets completed and skipped top-level jobs together with their children.
    public func removeFinished() {
        persistActive()
        flushSync()
        try? writer.write { db in
            try db.run("""
                DELETE FROM transferJob WHERE rootId IN (SELECT id FROM transferJob WHERE parentId IS NULL AND state IN (2, 5))
                """)
        }
        reloadStats()
        publishSoon()
    }

    // MARK: Pause

    /// Stops starting jobs and interrupts the running ones, which return to the queue and resume where they stopped.
    public func pause() {
        isPaused = true
        interrupt(Array(active.values))
        publishSoon()
    }

    public func resume() {
        isPaused = false
        pump()
        publishSoon()
    }

    public func pauseSite(_ id: UUID) {
        guard let site = sites[id.uuidString] else { return }
        site.isPaused = true
        interrupt(active.values.filter { $0.leases.contains { $0.site === site } })
        publishSoon()
    }

    public func resumeSite(_ id: UUID) {
        sites[id.uuidString]?.isPaused = false
        pump()
        publishSoon()
    }

    private func interrupt(_ jobs: [ActiveJob]) {
        for job in jobs { job.interrupted = true; job.task?.cancel() }
    }

    /// Stops all work without changing job states in SQLite and closes pooled sessions. Call before quitting.
    public func shutdown() async {
        isPaused = true
        let running = Array(active.values)
        interrupt(running)
        for job in running { await job.task?.value }
        wakeTask?.cancel()
        for site in sites.values {
            let idle = site.idle
            site.idle.removeAll()
            for entry in idle { await entry.fs.disconnect() }
        }
        await flushNow()
    }

    // MARK: Waiting

    /// Returns when nothing is queued or running.
    public func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Returns the final state of a job (for folders: once all children are done), or nil for an unknown id.
    public func waitUntilFinished(_ id: UUID) async -> TransferState? {
        guard let row = JobID.row(id), let record = fetch(row) else { return nil }
        if record.state.isFinished { return record.state }
        return await withCheckedContinuation { finishWaiters[row, default: []].append($0) }
    }

    /// Resumes waiters whose job finished through a bulk SQL change.
    func settleWaiters() {
        for id in Array(finishWaiters.keys) {
            guard let record = fetch(id), record.state.isFinished, let waiters = finishWaiters.removeValue(forKey: id) else { continue }
            for w in waiters { w.resume(returning: record.state) }
        }
    }

    var isIdle: Bool { active.isEmpty && stats.queued == 0 && stats.active == 0 }

    func checkIdle() {
        guard isIdle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for w in waiters { w.resume() }
    }
}
