import Foundation
import ConnectionKit

/// A local folder linked to a server folder on one connection.
public struct WatchLink: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var connectionId: UUID
    public var localRoot: String
    public var remoteRoot: String
    /// Deletions and renames are mirrored on the server. Off by default: nothing is ever deleted remotely.
    public var mirrorDeletes: Bool
    public var paused: Bool
    /// The connection's own skip patterns, on top of the global defaults and the editor-junk patterns.
    public var filterPatterns: [String]

    public init(id: UUID = UUID(), connectionId: UUID, localRoot: String, remoteRoot: String,
                mirrorDeletes: Bool = false, paused: Bool = false, filterPatterns: [String] = []) {
        self.id = id; self.connectionId = connectionId; self.localRoot = localRoot; self.remoteRoot = remoteRoot
        self.mirrorDeletes = mirrorDeletes; self.paused = paused; self.filterPatterns = filterPatterns
    }

    /// Temporary files editors create while saving; uploading them would only produce noise.
    public static let editorJunk = ["*.swp", "*.swx", "*~", ".#*", "4913"]

    public var filter: TransferFilter {
        TransferFilter(patterns: TransferFilter.globalDefaults + Self.editorJunk + filterPatterns)
    }
}

/// A change reported by the file system watcher (FSEvents in the app).
public struct WatchEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case created, modified, deleted
        /// `path` is the new location.
        case renamed(from: String)
    }

    public var path: String
    public var kind: Kind
    public var isDirectory: Bool

    public init(path: String, kind: Kind, isDirectory: Bool = false) {
        self.path = path; self.kind = kind; self.isDirectory = isDirectory
    }
}

public enum WatchWorkItem: Sendable, Equatable {
    case makeDirectory(remote: String)
    case upload(local: String, remote: String)
    /// Only produced when the link mirrors deletes.
    case rename(fromRemote: String, toRemote: String)
    /// Only produced when the link mirrors deletes.
    case delete(remote: String, isDirectory: Bool)
}

/// What one debounced batch of events turns into. Order: folders first, then uploads, renames, deletes.
public struct WatchPlan: Sendable, Equatable {
    public var items: [WatchWorkItem] = []
    /// Events dropped by the filters (counted so the queue can show "N skipped").
    public var skippedByFilter = 0
    /// Events outside the linked folder.
    public var outsideRoot = 0
    /// Deletions that were not mirrored because the link does not mirror deletes.
    public var unmirroredDeletes = 0

    public var isEmpty: Bool { items.isEmpty && skippedByFilter == 0 && unmirroredDeletes == 0 }
}

/// Turns a batch of events into work items. Pure.
///
/// Queue hook: run each `.upload` through `TransferFilter` (already applied here), `SafetyNet.prepareOverwrite`
/// when the site keeps versions, and `Guardrails` for read-only sites before executing the item.
public enum WatchPlanner {
    public static func plan(_ events: [WatchEvent], for link: WatchLink) -> WatchPlan {
        var plan = WatchPlan()
        let filter = link.filter
        let root = normalized(link.localRoot)

        struct Entry { var isDirectory: Bool; var createdInBatch: Bool }
        var uploads: [String: Entry] = [:]       // relative path -> needs upload / mkdir
        var deletes: [String: Bool] = [:]        // relative path -> isDirectory
        var renames: [String: String] = [:]      // relative to -> relative from
        var touched: [String: Int] = [:]

        func relative(_ path: String) -> String? {
            let p = normalized(path)
            guard p.hasPrefix(root + "/") else { return nil }
            return String(p.dropFirst(root.count + 1))
        }
        func isSkipped(_ rel: String, _ isDirectory: Bool) -> Bool {
            if filter.matches(path: rel, isDirectory: isDirectory) { plan.skippedByFilter += 1; return true }
            return false
        }

        for event in events {
            guard let rel = relative(event.path) else { plan.outsideRoot += 1; continue }
            touched[rel, default: 0] += 1
            switch event.kind {
            case .created, .modified:
                // Folder "modified" events only mean that a child changed.
                if event.isDirectory, event.kind == .modified { continue }
                if isSkipped(rel, event.isDirectory) { continue }
                let wasCreated = uploads[rel]?.createdInBatch ?? (event.kind == .created)
                uploads[rel] = Entry(isDirectory: event.isDirectory, createdInBatch: wasCreated)
                deletes.removeValue(forKey: rel)
            case .deleted:
                if isSkipped(rel, event.isDirectory) { continue }
                if let entry = uploads.removeValue(forKey: rel), entry.createdInBatch { continue }  // came and went
                deletes[rel] = event.isDirectory
            case .renamed(let from):
                guard let fromRel = relative(from) else {
                    // Moved in from outside: it is new here.
                    if !isSkipped(rel, event.isDirectory) { uploads[rel] = Entry(isDirectory: event.isDirectory, createdInBatch: true); deletes.removeValue(forKey: rel) }
                    continue
                }
                touched[fromRel, default: 0] += 1
                let skippedTo = filter.matches(path: rel, isDirectory: event.isDirectory)
                let skippedFrom = filter.matches(path: fromRel, isDirectory: event.isDirectory)
                if skippedFrom && skippedTo { plan.skippedByFilter += 1; continue }
                if skippedTo {  // renamed to something ignored: the old name goes away
                    plan.skippedByFilter += 1
                    if let entry = uploads.removeValue(forKey: fromRel), entry.createdInBatch { continue }
                    deletes[fromRel] = event.isDirectory
                    continue
                }
                if skippedFrom {  // renamed from an ignored name: it is new
                    uploads[rel] = Entry(isDirectory: event.isDirectory, createdInBatch: true)
                    deletes.removeValue(forKey: rel)
                    continue
                }
                if let entry = uploads.removeValue(forKey: fromRel), entry.createdInBatch {
                    uploads[rel] = entry  // created and renamed inside one batch: just the new name
                    deletes.removeValue(forKey: rel)
                } else if link.mirrorDeletes, touched[fromRel] == 1, touched[rel] == 1 {
                    renames[rel] = fromRel
                } else {
                    deletes[fromRel] = event.isDirectory
                    uploads[rel] = Entry(isDirectory: event.isDirectory, createdInBatch: false)
                    deletes.removeValue(forKey: rel)
                }
            }
        }

        func remote(_ rel: String) -> String { RemotePath.join(link.remoteRoot, rel) }
        func depth(_ rel: String) -> Int { rel.split(separator: "/").count }

        let folders = uploads.filter(\.value.isDirectory).keys.sorted { (depth($0), $0) < (depth($1), $1) }
        for rel in folders { plan.items.append(.makeDirectory(remote: remote(rel))) }
        for rel in uploads.filter({ !$0.value.isDirectory }).keys.sorted() {
            plan.items.append(.upload(local: root + "/" + rel, remote: remote(rel)))
        }
        for (to, from) in renames.sorted(by: { $0.key < $1.key }) {
            plan.items.append(.rename(fromRemote: remote(from), toRemote: remote(to)))
        }
        // Children before parents, and a folder delete swallows deletes below it.
        let deleteOrder = deletes.keys.sorted { (depth($0), $0) > (depth($1), $1) }
        if link.mirrorDeletes {
            let deletedFolders = deletes.filter(\.value).keys
            for rel in deleteOrder {
                if deletedFolders.contains(where: { rel.hasPrefix($0 + "/") }) { continue }
                plan.items.append(.delete(remote: remote(rel), isDirectory: deletes[rel] ?? false))
            }
        } else {
            plan.unmirroredDeletes += deletes.count
        }
        return plan
    }

    private static func normalized(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
