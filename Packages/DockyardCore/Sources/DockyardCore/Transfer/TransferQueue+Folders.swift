import Foundation
import ConnectionKit
import GRDB

extension TransferQueue {
    /// Children are inserted this many at a time so workers can start while a big listing is processed.
    static let expansionBatch = 500
    /// Listings above this size keep the server's order instead of being sorted.
    static let sortLimit = 5000

    func runFolder(_ job: ActiveJob, _ route: Route) async throws -> Outcome {
        if job.record.expanded { return try await removeSourceFolder(job, route) }
        let rec = job.record
        if rec.createParents { try await Self.ensureDirectory(route.dst, RemotePath.parent(of: rec.destPath)) }
        try await Self.ensureDirectory(route.dst, rec.destPath)
        guard rec.recursive else { return .completed }

        log.emit(.status, "Listing \(rec.sourcePath) (\(rec.route))")
        var items = try await route.src.list(rec.sourcePath)
        try Task.checkCancellation()
        items.removeAll { $0.isDirectory && $0.isSymlink }  // never follow folder symlinks
        var known = Set<String>()
        if rec.resume {
            known = knownChildren(of: rec.id)
            items.removeAll { known.contains($0.path) }
        }
        if items.count <= Self.sortLimit { items.sort { $0.name < $1.name } }

        trackers[rec.id] = Tracker(record: job.record, pending: 0, listing: true)
        var start = 0
        while start < items.count {
            try Task.checkCancellation()
            guard !job.cancelRequested else { throw CancellationError() }
            let end = min(items.count, start + Self.expansionBatch)
            insertChildren(of: job.record, items[start..<end])
            job.record.childCount += end - start
            start = end
            pump()
            await Task.yield()
        }
        return .waitingForChildren
    }

    private func insertChildren(of parent: JobRecord, _ items: ArraySlice<RemoteItem>) {
        var sizeTotal: Int64 = 0
        var records: [JobRecord] = []
        records.reserveCapacity(items.count)
        for item in items {
            let id = nextId
            nextId += 1
            let child = parent.child(id: id, sourcePath: item.path, destPath: RemotePath.join(parent.destPath, item.name), item: item)
            sizeTotal += Int64(clamping: child.bytesTotal)
            records.append(child)
        }
        for child in records {
            stats.add(child)
            let site = siteState(child.siteKey, label: child.srcLabel)
            if child.isDirectory { site.dirs.add(child) } else { site.files.add(child) }
        }
        let batch = records
        ops.append { db in
            let statement = try db.cachedStatement(sql: JobRecord.insertSQL)
            for r in batch { try statement.execute(arguments: r.arguments) }
        }
        trackers[parent.id]?.pending += records.count
        rollupTotal[parent.rootId, default: 0] += sizeTotal
        scheduleFlush()
    }

    private func knownChildren(of id: Int64) -> Set<String> {
        flushSync()
        let paths = try? writer.read { db in
            try String.fetchAll(db, sql: "SELECT sourcePath FROM transferJob WHERE parentId = ?", arguments: [id])
        }
        return Set(paths ?? [])
    }

    /// Called by `conclude` once the folder's listing is done: it starts waiting for its children.
    func folderListed(_ job: ActiveJob) {
        var rec = job.record
        let wasInterrupted = rec.resume
        stats.add(rec, sign: -1)
        rec.expanded = true
        rec.resume = false
        stats.add(rec)
        job.record = rec
        persist(rec)
        // A re-run listing skipped children that already existed, so count from the database.
        var t = wasInterrupted ? rebuiltTracker(rec) : (trackers[rec.id] ?? Tracker(record: rec, pending: rec.childCount))
        t.record = wasInterrupted ? t.record : rec
        t.listing = false
        if wasInterrupted { persist(t.record) }
        trackers[rec.id] = t
        if t.pending <= 0 { finalizeFolder(rec.id) }
    }

    func childFinished(_ parentId: Int64, state: TransferState) {
        childrenDoneDelta[parentId, default: 0] += 1
        scheduleFlush()
        guard var t = trackers[parentId] else { return }
        t.pending -= 1
        switch state {
        case .failed: t.failed += 1
        case .cancelled: t.cancelled += 1
        case .skipped: t.skipped += 1
        default: break
        }
        trackers[parentId] = t
        if t.pending <= 0 && !t.listing { finalizeFolder(parentId) }
    }

    func finalizeFolder(_ id: Int64) {
        guard let t = trackers[id] else { return }
        var rec = t.record
        rec.childCount = max(rec.childCount, 0)
        if t.failed > 0 {
            finish(&rec, .failed, error: "\(t.failed) item\(t.failed == 1 ? "" : "s") failed")
        } else if t.cancelled > 0 {
            finish(&rec, .cancelled, error: nil)
        } else if rec.deleteSource && t.skipped == 0 {
            // Everything arrived: queue the folder once more to remove its source.
            trackers.removeValue(forKey: id)
            stats.add(rec, sign: -1)
            rec.state = .queued
            stats.add(rec)
            persist(rec)
            siteState(rec.siteKey, label: rec.srcLabel).retry.append((clock.now(), rec))
            pump()
        } else {
            log.emit(.status, "Finished folder \(rec.name) (\(rec.route))")
            finish(&rec, .completed, error: nil)
        }
    }

    private func removeSourceFolder(_ job: ActiveJob, _ route: Route) async throws -> Outcome {
        do { try await route.src.delete(job.record.sourcePath, recursive: true) } catch {
            fail(job, "Copied, but could not remove source: \(Self.describe(error))")
            return .waitingForChildren  // already finished as failed
        }
        log.emit(.status, "Finished folder \(job.record.name) (\(job.record.route))")
        return .completed
    }
}
