import Foundation
import ConnectionKit

/// Which of the two safety switches are on for a site.
public struct SafetyPolicy: Sendable, Equatable {
    public var trashOnDelete: Bool
    public var keepVersionsOnOverwrite: Bool

    public init(trashOnDelete: Bool = false, keepVersionsOnOverwrite: Bool = false) {
        self.trashOnDelete = trashOnDelete
        self.keepVersionsOnOverwrite = keepVersionsOnOverwrite
    }

    public init(_ connection: Connection) {
        self.init(trashOnDelete: connection.trashOnDelete, keepVersionsOnOverwrite: connection.keepVersionsOnOverwrite)
    }

    public static let off = SafetyPolicy()
}

/// An item that was moved or copied into the remote trash.
public struct TrashEntry: Sendable, Equatable, Identifiable, Hashable {
    public var trashPath: String
    public var originalPath: String
    /// `YYYY-MM-DD`
    public var day: String
    public var isDirectory: Bool
    public var size: UInt64?
    public var modified: Date?
    /// 1 for the first item trashed under this name that day.
    public var version: Int

    public var id: String { trashPath }
    public var name: String { RemotePath.lastComponent(of: originalPath) }
}

public enum SafetyOutcome: Sendable, Equatable {
    /// Nothing to do: the switch is off, the path does not exist or it is already in the trash.
    case notApplicable
    /// The old item is safe in the trash. `originalRemoved` is true when it was moved (so a delete is already done).
    case preserved(TrashEntry, originalRemoved: Bool)
    /// The backup failed and the user chose to go ahead anyway.
    case proceedUnprotected

    /// True when the caller must still perform the real delete or overwrite.
    public var originalStillInPlace: Bool {
        if case .preserved(_, let removed) = self { return !removed }
        return true
    }
}

public struct SafetyFailure: Sendable, Equatable {
    public enum Operation: Sendable, Equatable { case delete, overwrite }
    public var path: String
    public var operation: Operation
    public var reason: String
}

/// Asked when neither rename nor copy into the trash worked. Return true to continue without a backup.
public typealias SafetyDecision = @Sendable (SafetyFailure) async -> Bool

/// Moves files into `~/.dockyard-trash/<date>/<original path>` before they are deleted or overwritten.
///
/// Entry points for the transfer queue and the file operations:
/// - `prepareDelete(path:on:)` before a delete. If the result's `originalStillInPlace` is false, skip the delete.
/// - `prepareOverwrite(path:on:)` before an upload to an existing path.
public struct SafetyNet: Sendable {
    public var policy: SafetyPolicy
    public var clock: any DockyardClock
    public var timeZone: TimeZone
    public var decision: SafetyDecision
    public var log: @Sendable (LogLine.Kind, String) -> Void

    private let opsCache = LockedBox<RemoteOps?>(nil)
    private let homeCache = LockedBox<String?>(nil)

    public init(
        policy: SafetyPolicy,
        clock: any DockyardClock = SystemClock(),
        timeZone: TimeZone = .current,
        decision: @escaping SafetyDecision = { _ in false },
        log: @escaping @Sendable (LogLine.Kind, String) -> Void = { _, _ in }
    ) {
        self.policy = policy
        self.clock = clock
        self.timeZone = timeZone
        self.decision = decision
        self.log = log
    }

    public func prepareDelete(path: String, on fs: any RemoteFileSystem) async throws -> SafetyOutcome {
        guard policy.trashOnDelete else { return .notApplicable }
        return try await preserve(path, on: fs, operation: .delete)
    }

    public func prepareOverwrite(path: String, on fs: any RemoteFileSystem) async throws -> SafetyOutcome {
        guard policy.keepVersionsOnOverwrite else { return .notApplicable }
        return try await preserve(path, on: fs, operation: .overwrite)
    }

    // MARK: Implementation

    private func preserve(_ path: String, on fs: any RemoteFileSystem, operation: SafetyFailure.Operation) async throws -> SafetyOutcome {
        if TrashLayout.isInsideTrash(path) { return .notApplicable }
        let ops = opsCache.withLock { cached in
            if let cached { return cached }
            let made = RemoteOps(fs, log: log)
            cached = made
            return made
        }
        let home: String, root: TrashLayout.Root
        do {
            if let cached = homeCache.withLock({ $0 }) { home = cached } else {
                home = try await fs.homeDirectory()
                homeCache.withLock { $0 = home }
            }
            root = try TrashLayout.root(forHome: home)
        } catch {
            return try await giveUp(path, operation, "no usable trash location: \(error)")
        }
        if let warning = root.warning { log(.warning, warning) }

        let original = TrashLayout.normalize(path, home: home)
        guard !TrashLayout.isInsideTrash(original) else { return .notApplicable }
        let item: RemoteItem
        do {
            guard let found = try await fs.stat(original) else { return .notApplicable }
            item = found
        } catch {
            return try await giveUp(path, operation, "cannot inspect it: \(error)")
        }
        let day = FileNaming.dayString(clock.now(), timeZone: timeZone)

        do {
            let (destination, version) = try await freeDestination(root: root.path, day: day, original: original, ops: ops)
            do { try await ops.ensureDirectory(RemotePath.parent(of: destination)) } catch {
                ops.forgetAll()
                try await ops.ensureDirectory(RemotePath.parent(of: destination))
            }
            let entry = TrashEntry(
                trashPath: destination, originalPath: original, day: day, isDirectory: item.isDirectory,
                size: item.size, modified: item.modified, version: version)

            var moved = false
            do {
                try await fs.rename(item.path, destination)
                moved = true
            } catch {
                log(.warning, "Cannot move \(path) into the trash (\(error)); copying it instead")
                try await ops.copy(item, to: destination)
            }
            if item.isDirectory {
                do { try await ops.touch(destination + TrashLayout.folderMarkerSuffix) } catch {
                    log(.warning, "Could not mark \(destination) as a trashed folder: \(error)")
                }
            }
            log(.status, "\(moved ? "Moved" : "Copied") \(original) to \(destination)")
            return .preserved(entry, originalRemoved: moved)
        } catch {
            return try await giveUp(path, operation, "\(error)")
        }
    }

    private func freeDestination(root: String, day: String, original: String, ops: RemoteOps) async throws -> (String, Int) {
        for version in 1...200 {
            let candidate = TrashLayout.destination(root: root, day: day, original: original, version: version)
            // The parent may not exist yet, which means the name is free.
            let parent = RemotePath.parent(of: candidate)
            guard (try? await ops.fs.stat(parent)) != nil else { return (candidate, version) }
            if try await ops.fs.stat(candidate) == nil { return (candidate, version) }
        }
        throw RemoteError.protocolError("Too many items named \(RemotePath.lastComponent(of: original)) in today's trash")
    }

    private func giveUp(_ path: String, _ operation: SafetyFailure.Operation, _ reason: String) async throws -> SafetyOutcome {
        log(.warning, "Could not back up \(path): \(reason)")
        if await decision(SafetyFailure(path: path, operation: operation, reason: reason)) {
            return .proceedUnprotected
        }
        throw SafetyNetError.declined(path)
    }
}
