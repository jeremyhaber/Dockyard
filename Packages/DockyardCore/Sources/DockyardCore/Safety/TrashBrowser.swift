import Foundation
import ConnectionKit

public enum RestoreConflictPolicy: Sendable, Equatable {
    case ask, overwrite, skip, rename
}

/// How to restore one trash entry, after applying the conflict policy.
public struct RestorePlan: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case restore
        /// Replace what is at the destination.
        case overwrite
        /// Restore under another name in the same folder.
        case restoreAs(String)
        case skip
        /// The destination exists and the policy is `.ask`; call `resolving(_:)` with the user's choice.
        case needsDecision(existing: RemoteItem)
    }

    public var entry: TrashEntry
    public var destination: String
    public var action: Action

    public func resolving(_ policy: RestoreConflictPolicy, uniqueName: String? = nil) -> RestorePlan {
        guard case .needsDecision = action else { return self }
        var copy = self
        switch policy {
        case .overwrite: copy.action = .overwrite
        case .skip, .ask: copy.action = .skip
        case .rename:
            let name = uniqueName ?? FileNaming.numbered(RemotePath.lastComponent(of: destination), 2)
            copy.action = .restoreAs(name)
        }
        return copy
    }
}

public struct RestoreResult: Sendable, Equatable {
    public var restoredPath: String?
    public var skipped: Bool
}

/// Lists, restores and purges what `SafetyNet` put in `~/.dockyard-trash`.
public struct TrashBrowser: Sendable {
    public static let defaultRetentionDays = 14

    private let fs: any RemoteFileSystem
    private let clock: any DockyardClock
    private let timeZone: TimeZone
    private let ops: RemoteOps

    public init(
        fs: any RemoteFileSystem,
        clock: any DockyardClock = SystemClock(),
        timeZone: TimeZone = .current,
        log: @escaping @Sendable (LogLine.Kind, String) -> Void = { _, _ in }
    ) {
        self.fs = fs
        self.clock = clock
        self.timeZone = timeZone
        self.ops = RemoteOps(fs, log: log)
    }

    public func rootPath() async throws -> String {
        try TrashLayout.root(forHome: try await fs.homeDirectory()).path
    }

    /// Everything in the trash, newest day first, then by original path.
    public func entries() async throws -> [TrashEntry] {
        let root = try await rootPath()
        guard let days = try? await fs.list(root) else { return [] }
        var out: [TrashEntry] = []
        for day in days where day.isDirectory && TrashLayout.isDayName(day.name) {
            try await collect(directory: day.path, relative: [], day: day.name, into: &out)
        }
        return out.sorted { ($0.day, $1.originalPath) > ($1.day, $0.originalPath) }
    }

    private func collect(directory: String, relative: [String], day: String, into out: inout [TrashEntry]) async throws {
        let children = try await fs.list(directory)
        let names = Set(children.map(\.name))
        for child in children where !child.name.hasSuffix(TrashLayout.folderMarkerSuffix) {
            let isFolder = child.isDirectory && !child.isSymlink
            let marked = names.contains(child.name + TrashLayout.folderMarkerSuffix)
            if isFolder, !marked {
                let inner = try await fs.list(child.path)
                if !inner.isEmpty {
                    try await collect(directory: child.path, relative: relative + [child.name], day: day, into: &out)
                    continue
                }
            }
            let (name, version) = TrashLayout.parseVersion(child.name)
            out.append(TrashEntry(
                trashPath: child.path, originalPath: "/" + (relative + [name]).joined(separator: "/"), day: day,
                isDirectory: child.isDirectory && !child.isSymlink, size: child.size, modified: child.modified, version: version))
        }
    }

    // MARK: Restore

    /// Works out what restoring `entry` to `destination` (default: its original path) would do.
    public func restorePlan(for entry: TrashEntry, policy: RestoreConflictPolicy, destination: String? = nil) async throws -> RestorePlan {
        let target = destination ?? entry.originalPath
        var plan = RestorePlan(entry: entry, destination: target, action: .restore)
        guard let existing = try await fs.stat(target) else { return plan }
        plan.action = .needsDecision(existing: existing)
        switch policy {
        case .ask: return plan
        case .overwrite, .skip: return plan.resolving(policy)
        case .rename:
            let siblings = Set((try? await fs.list(RemotePath.parent(of: target)))?.map(\.name) ?? [])
            let name = FileNaming.uniqueConflictCopy(RemotePath.lastComponent(of: target), date: clock.now(), existing: siblings, timeZone: timeZone)
            return plan.resolving(.rename, uniqueName: name)
        }
    }

    @discardableResult
    public func restore(_ plan: RestorePlan) async throws -> RestoreResult {
        var destination = plan.destination
        switch plan.action {
        case .skip, .needsDecision: return RestoreResult(restoredPath: nil, skipped: true)
        case .restore: break
        case .overwrite: try await fs.delete(destination, recursive: true)
        case .restoreAs(let name): destination = RemotePath.join(RemotePath.parent(of: destination), name)
        }
        try await ops.ensureDirectory(RemotePath.parent(of: destination))
        do {
            try await fs.rename(plan.entry.trashPath, destination)
        } catch {
            guard let item = try await fs.stat(plan.entry.trashPath) else { throw error }
            try await ops.copy(item, to: destination)
            try await fs.delete(plan.entry.trashPath, recursive: true)
        }
        await removeMarker(of: plan.entry)
        await prune(after: plan.entry)
        return RestoreResult(restoredPath: destination, skipped: false)
    }

    // MARK: Deleting

    public func deleteNow(_ entry: TrashEntry) async throws {
        try await fs.delete(entry.trashPath, recursive: true)
        await removeMarker(of: entry)
        await prune(after: entry)
    }

    /// Removes the whole trash.
    public func empty() async throws {
        let root = try await rootPath()
        guard try await fs.stat(root) != nil else { return }
        try await fs.delete(root, recursive: true)
        ops.forgetAll()
    }

    /// Deletes every day folder older than `days` days. Returns the day names that were removed.
    @discardableResult
    public func purge(olderThanDays days: Int = TrashBrowser.defaultRetentionDays) async throws -> [String] {
        let root = try await rootPath()
        guard let folders = try? await fs.list(root) else { return [] }
        let cutoff = FileNaming.dayString(clock.now().addingTimeInterval(-Double(max(0, days)) * 86_400), timeZone: timeZone)
        var removed: [String] = []
        for folder in folders where folder.isDirectory && TrashLayout.isDayName(folder.name) && folder.name < cutoff {
            try await fs.delete(folder.path, recursive: true)
            ops.forget(folder.path)
            removed.append(folder.name)
        }
        return removed.sorted()
    }

    private func removeMarker(of entry: TrashEntry) async {
        guard entry.isDirectory else { return }
        try? await fs.delete(entry.trashPath + TrashLayout.folderMarkerSuffix, recursive: false)
    }

    /// Removes the now empty parent folders of an entry (including its day folder), up to the trash root.
    private func prune(after entry: TrashEntry) async {
        guard let root = try? await rootPath() else { return }
        await ops.pruneEmptyDirectories(from: RemotePath.parent(of: entry.trashPath), upTo: root)
    }
}
