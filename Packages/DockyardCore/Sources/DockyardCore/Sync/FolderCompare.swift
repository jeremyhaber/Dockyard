import Foundation
import ConnectionKit

public enum DiffStatus: String, Sendable, Equatable {
    case onlyLeft, onlyRight, newerLeft, newerRight, same
    /// Same modification time but different size, or a file on one side and a folder on the other.
    case differs
}

public struct DiffEntry: Sendable, Equatable, Identifiable {
    /// Path relative to the compared roots, without a leading slash.
    public var relativePath: String
    public var isDirectory: Bool
    public var status: DiffStatus
    public var left: RemoteItem?
    public var right: RemoteItem?
    public var id: String { relativePath }
    public var name: String { RemotePath.lastComponent(of: relativePath) }
}

public struct FolderComparator: Sendable {
    /// Times closer than this are equal. FTP servers report minute resolution, so callers may raise it.
    public var timeTolerance: TimeInterval
    /// Entries matching these rules appear on neither side, so sync never touches them.
    public var filter: TransferFilter

    public init(timeTolerance: TimeInterval = 2, filter: TransferFilter = .none) {
        self.timeTolerance = timeTolerance
        self.filter = filter
    }

    /// Compares two folders by size and modification time. Folders are only descended into when `recursive`.
    public func compare(
        left: TransferEndpoint, leftPath: String, right: TransferEndpoint, rightPath: String, recursive: Bool = false
    ) async throws -> [DiffEntry] {
        var out: [DiffEntry] = []
        try await walk(left, leftPath, right, rightPath, prefix: "", recursive: recursive, into: &out)
        return out.sorted { Self.order($0.relativePath, $1.relativePath) }
    }

    /// Pure classification of two files.
    public func classify(left: RemoteItem, right: RemoteItem) -> DiffStatus {
        if left.isDirectory != right.isDirectory { return .differs }
        if left.isDirectory { return .same }
        if let lm = left.modified, let rm = right.modified {
            let delta = lm.timeIntervalSince(rm)
            if abs(delta) <= timeTolerance { return left.size == right.size ? .same : .differs }
            return delta > 0 ? .newerLeft : .newerRight
        }
        // Without times only the size can tell.
        return left.size == right.size ? .same : .differs
    }

    private func walk(
        _ l: TransferEndpoint, _ lp: String, _ r: TransferEndpoint, _ rp: String,
        prefix: String, recursive: Bool, into out: inout [DiffEntry]
    ) async throws {
        async let lItems = l.fs.list(lp)
        async let rItems = r.fs.list(rp)
        let (litems, ritems) = try await (lItems, rItems)
        let lmap = Dictionary(litems.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let rmap = Dictionary(ritems.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for name in Set(lmap.keys).union(rmap.keys) {
            let rel = prefix.isEmpty ? name : prefix + "/" + name
            let li = lmap[name], ri = rmap[name]
            if filter.matches(path: rel, isDirectory: (li ?? ri)?.isDirectory ?? false) { continue }
            switch (li, ri) {
            case let (li?, ri?):
                let status = classify(left: li, right: ri)
                out.append(DiffEntry(relativePath: rel, isDirectory: li.isDirectory && ri.isDirectory, status: status, left: li, right: ri))
                if recursive, li.isDirectory, ri.isDirectory, !li.isSymlink, !ri.isSymlink {
                    try await walk(l, li.path, r, ri.path, prefix: rel, recursive: true, into: &out)
                }
            case let (li?, nil):
                out.append(DiffEntry(relativePath: rel, isDirectory: li.isDirectory, status: .onlyLeft, left: li, right: nil))
                if recursive, li.isDirectory, !li.isSymlink { try await collect(l, li, rel, onLeft: true, into: &out) }
            case let (nil, ri?):
                out.append(DiffEntry(relativePath: rel, isDirectory: ri.isDirectory, status: .onlyRight, left: nil, right: ri))
                if recursive, ri.isDirectory, !ri.isSymlink { try await collect(r, ri, rel, onLeft: false, into: &out) }
            case (nil, nil): break
            }
        }
    }

    /// Everything under a folder that exists on one side only.
    private func collect(_ ep: TransferEndpoint, _ dir: RemoteItem, _ rel: String, onLeft: Bool, into out: inout [DiffEntry]) async throws {
        for item in try await ep.fs.list(dir.path) {
            let r = rel + "/" + item.name
            if filter.matches(path: r, isDirectory: item.isDirectory) { continue }
            out.append(DiffEntry(relativePath: r, isDirectory: item.isDirectory, status: onLeft ? .onlyLeft : .onlyRight,
                                 left: onLeft ? item : nil, right: onLeft ? nil : item))
            if item.isDirectory, !item.isSymlink { try await collect(ep, item, r, onLeft: onLeft, into: &out) }
        }
    }

    /// Folder contents sort by path components; plain string order would put `a-b` between `a` and `a/c`.
    static func order(_ a: String, _ b: String) -> Bool {
        let ac = a.split(separator: "/"), bc = b.split(separator: "/")
        for (x, y) in zip(ac, bc) where x != y {
            let r = x.compare(y, options: [.caseInsensitive, .numeric])
            return r == .orderedSame ? x < y : r == .orderedAscending
        }
        return ac.count < bc.count
    }
}

public enum SyncDirection: Sendable, Equatable {
    /// Left to right (local to server in the usual layout).
    case push
    /// Right to left.
    case pull
}

public struct SyncPlan: Sendable {
    public var requests: [TransferRequest]
    /// Selected entries that cannot go in this direction (e.g. only on the target side) or are already equal.
    public var skipped: [DiffEntry]

    /// Builds the transfers for the selected entries. Existing destination files are overwritten on purpose.
    public static func make(
        selection: [DiffEntry], direction: SyncDirection,
        left: TransferEndpoint, leftRoot: String, right: TransferEndpoint, rightRoot: String
    ) -> SyncPlan {
        var requests: [TransferRequest] = []
        var skipped: [DiffEntry] = []
        let (src, srcRoot, dst, dstRoot) = direction == .push ? (left, leftRoot, right, rightRoot) : (right, rightRoot, left, leftRoot)
        for entry in selection {
            let item = direction == .push ? entry.left : entry.right
            guard let item, entry.status != .same else { skipped.append(entry); continue }
            // A folder on one side and a file on the other cannot be reconciled automatically.
            if entry.status == .differs, entry.left?.isDirectory != entry.right?.isDirectory { skipped.append(entry); continue }
            let dstPath = RemotePath.join(dstRoot, entry.relativePath)
            if item.isDirectory {
                // The compare already lists folder contents as separate entries, so only create the folder.
                requests.append(TransferRequest(
                    source: src, sourcePath: item.path, destination: dst, destinationPath: dstPath, isDirectory: true,
                    createParents: true, recursive: false, conflictOverride: .overwrite))
            } else {
                requests.append(TransferRequest(
                    source: src, sourcePath: RemotePath.join(srcRoot, entry.relativePath), destination: dst, destinationPath: dstPath,
                    isDirectory: false, size: item.size, modified: item.modified, createParents: true, conflictOverride: .overwrite))
            }
        }
        // Folders first so parents exist before their files.
        requests.sort { ($0.isDirectory ? 0 : 1, $0.destinationPath.count) < ($1.isDirectory ? 0 : 1, $1.destinationPath.count) }
        return SyncPlan(requests: requests, skipped: skipped)
    }

    /// Enqueues every transfer; returns their ids.
    @discardableResult
    public func execute(on queue: TransferQueue) async -> [UUID] {
        await queue.enqueue(requests)
    }
}

extension Array where Element == DiffEntry {
    /// "3 only here, 2 newer here..." style counts for the compare header.
    public func count(of status: DiffStatus) -> Int { filter { $0.status == status && !$0.isDirectory }.count }
}
