import Foundation
import GRDB
import ConnectionKit

/// Public job ids are UUIDs (source compatible with the old queue). They embed the SQLite row id, so
/// mapping costs nothing and ids stay valid across restarts.
enum JobID {
    private static let magic: UInt64 = 0x444B_5944_4A4F_4221  // "DKYDJOB!"

    static func uuid(_ row: Int64) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8(truncatingIfNeeded: magic >> UInt64(56 - 8 * i))
            bytes[8 + i] = UInt8(truncatingIfNeeded: UInt64(bitPattern: row) >> UInt64(56 - 8 * i))
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func row(_ id: UUID) -> Int64? {
        let u = id.uuid
        let all = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        var head: UInt64 = 0, tail: UInt64 = 0
        for i in 0..<8 { head = head << 8 | UInt64(all[i]); tail = tail << 8 | UInt64(all[8 + i]) }
        return head == magic ? Int64(bitPattern: tail) : nil
    }
}

extension TransferState {
    var dbValue: Int {
        switch self {
        case .queued: 0
        case .running: 1
        case .completed: 2
        case .failed: 3
        case .cancelled: 4
        case .skipped: 5
        }
    }

    init(dbValue: Int) {
        self = [.queued, .running, .completed, .failed, .cancelled, .skipped][min(max(dbValue, 0), 5)]
    }
}

extension ConflictPolicy {
    var dbValue: Int {
        switch self {
        case .ask: 0
        case .overwrite: 1
        case .overwriteIfNewer: 2
        case .skip: 3
        case .rename: 4
        case .overwriteIfDifferent: 5
        case .overwriteIfSizeDiffers: 6
        case .resume: 7
        }
    }

    init?(dbValue: Int?) {
        guard let dbValue else { return nil }
        self = [.ask, .overwrite, .overwriteIfNewer, .skip, .rename, .overwriteIfDifferent, .overwriteIfSizeDiffers, .resume][min(max(dbValue, 0), 7)]
    }
}

/// One row of `transferJob`. Folder rows also carry the roll-up of their subtree: `bytesTotal` and
/// `bytesDone` count every file below a top-level folder.
struct JobRecord: Sendable {
    static let localKey = "local"

    var id: Int64
    var parentId: Int64?
    var rootId: Int64
    /// Queue the job is scheduled on: the remote side of the transfer (the source for server to server).
    var siteKey: String
    /// Site ids of both sides; nil is this Mac.
    var srcSite: String?
    var dstSite: String?
    var srcLabel: String
    var dstLabel: String
    var sourcePath: String
    var destPath: String
    var isDirectory: Bool
    var size: UInt64?
    var modified: Date?
    var createParents: Bool
    var recursive: Bool
    var deleteSource: Bool
    var conflict: ConflictPolicy?
    var state: TransferState = .queued
    var bytesDone: UInt64 = 0
    var bytesTotal: UInt64 = 0
    var error: String?
    /// Folders: the listing is complete (a queued, expanded folder is waiting to delete its source).
    var expanded = false
    var childCount = 0
    var childrenDone = 0
    /// Files: resume a partial file. Folders: re-run an interrupted listing, skipping known children.
    var resume = false
    var attempts = 0
    /// Starts at once, ignoring pause and the connection limit, and cannot be retried (edit in place).
    var immediate = false

    var name: String { RemotePath.lastComponent(of: destPath) }
    var route: String { "\(srcLabel) → \(dstLabel)" }
    var isRelay: Bool { srcSite != nil && dstSite != nil }
    var direction: ConflictDirection { isRelay ? .relay : (srcSite == nil ? .upload : .download) }

    static let columns = """
        id, parentId, rootId, siteKey, srcSite, dstSite, srcLabel, dstLabel, sourcePath, destPath, isDirectory, size, \
        modified, createParents, recursive, deleteSource, conflict, state, bytesDone, bytesTotal, error, expanded, \
        childCount, childrenDone, resume, attempts, immediate
        """

    static let insertSQL = "INSERT OR REPLACE INTO transferJob (\(columns)) VALUES (\(Array(repeating: "?", count: 27).joined(separator: ",")))"

    var arguments: StatementArguments {
        [
            id, parentId, rootId, siteKey, srcSite, dstSite, srcLabel, dstLabel, sourcePath, destPath, isDirectory,
            size.map { Int64(clamping: $0) }, modified?.timeIntervalSince1970, createParents, recursive, deleteSource,
            conflict?.dbValue, state.dbValue, Int64(clamping: bytesDone), Int64(clamping: bytesTotal), error, expanded,
            childCount, childrenDone, resume, attempts, immediate,
        ]
    }

    init(
        id: Int64, parentId: Int64?, rootId: Int64, siteKey: String, srcSite: String?, dstSite: String?,
        srcLabel: String, dstLabel: String, sourcePath: String, destPath: String, isDirectory: Bool,
        size: UInt64?, modified: Date?, createParents: Bool, recursive: Bool, deleteSource: Bool, conflict: ConflictPolicy?
    ) {
        self.id = id; self.parentId = parentId; self.rootId = rootId; self.siteKey = siteKey
        self.srcSite = srcSite; self.dstSite = dstSite; self.srcLabel = srcLabel; self.dstLabel = dstLabel
        self.sourcePath = sourcePath; self.destPath = destPath; self.isDirectory = isDirectory
        self.size = size; self.modified = modified; self.createParents = createParents
        self.recursive = recursive; self.deleteSource = deleteSource; self.conflict = conflict
        self.bytesTotal = size ?? 0
    }

    init(row: Row) {
        id = row["id"]; parentId = row["parentId"]; rootId = row["rootId"]; siteKey = row["siteKey"]
        srcSite = row["srcSite"]; dstSite = row["dstSite"]; srcLabel = row["srcLabel"]; dstLabel = row["dstLabel"]
        sourcePath = row["sourcePath"]; destPath = row["destPath"]; isDirectory = row["isDirectory"]
        size = (row["size"] as Int64?).map { UInt64(max(0, $0)) }
        modified = (row["modified"] as Double?).map { Date(timeIntervalSince1970: $0) }
        createParents = row["createParents"]; recursive = row["recursive"]; deleteSource = row["deleteSource"]
        conflict = ConflictPolicy(dbValue: row["conflict"])
        state = TransferState(dbValue: row["state"])
        bytesDone = UInt64(max(0, row["bytesDone"] as Int64)); bytesTotal = UInt64(max(0, row["bytesTotal"] as Int64))
        error = row["error"]; expanded = row["expanded"]
        childCount = row["childCount"]; childrenDone = row["childrenDone"]
        resume = row["resume"]; attempts = row["attempts"]; immediate = row["immediate"]
    }

    /// A child that inherits routing from this folder.
    func child(id: Int64, sourcePath: String, destPath: String, item: RemoteItem) -> JobRecord {
        var c = JobRecord(
            id: id, parentId: self.id, rootId: rootId, siteKey: siteKey, srcSite: srcSite, dstSite: dstSite,
            srcLabel: srcLabel, dstLabel: dstLabel, sourcePath: sourcePath, destPath: destPath,
            isDirectory: item.isDirectory, size: item.isDirectory ? nil : item.size, modified: item.modified,
            createParents: false, recursive: recursive, deleteSource: deleteSource, conflict: conflict)
        c.resume = false
        return c
    }
}

/// Running totals kept in memory so the UI never has to count rows.
struct TransferStats: Sendable, Equatable {
    var queued = 0, active = 0, completed = 0, failed = 0, skipped = 0, cancelled = 0
    /// Sum of sizes of files that are not cancelled or skipped.
    var bytesTotal: UInt64 = 0
    /// Bytes of completed files (plus partial bytes of failed ones).
    var bytesFinished: UInt64 = 0

    mutating func add(_ r: JobRecord, sign: Int = 1) { add(state: r.state, isDirectory: r.isDirectory, expanded: r.expanded, count: sign, total: r.bytesTotal, done: r.bytesDone) }

    mutating func add(state: TransferState, isDirectory: Bool, expanded: Bool, count: Int, total: UInt64, done: UInt64) {
        func bump(_ keyPath: WritableKeyPath<TransferStats, Int>) { self[keyPath: keyPath] += count }
        if isDirectory {
            switch state {
            case .queued: bump(\.queued)
            case .running where !expanded: bump(\.active)
            default: break
            }
            return
        }
        let amount = total
        let apply: (inout UInt64, UInt64) -> Void = { value, delta in
            value = count >= 0 ? value &+ delta : value &- min(value, delta)
        }
        switch state {
        case .queued: bump(\.queued)
        case .running: bump(\.active)
        case .completed: bump(\.completed); apply(&bytesFinished, max(total, done))
        case .failed: bump(\.failed); apply(&bytesFinished, done)
        case .skipped: bump(\.skipped)
        case .cancelled: bump(\.cancelled)
        }
        if state != .cancelled && state != .skipped { apply(&bytesTotal, max(amount, done)) }
    }
}
