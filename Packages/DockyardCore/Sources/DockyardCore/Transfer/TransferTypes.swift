import Foundation
import ConnectionKit

/// One side of a transfer: a file system and the name to show for it in route labels.
public struct TransferEndpoint: Sendable {
    public let fs: any RemoteFileSystem
    /// e.g. `PROD`, `STG`, `This Mac`.
    public let label: String

    public init(fs: any RemoteFileSystem, label: String) {
        self.fs = fs
        self.label = label
    }

    public static func thisMac(_ fs: LocalFileSystem = LocalFileSystem()) -> TransferEndpoint {
        TransferEndpoint(fs: fs, label: "This Mac")
    }

    public var isLocal: Bool { fs is LocalFileSystem }
}

public struct TransferRequest: Sendable {
    public var source: TransferEndpoint
    public var sourcePath: String
    public var destination: TransferEndpoint
    /// Full path of the item to create (including its name).
    public var destinationPath: String
    public var isDirectory: Bool
    public var size: UInt64?
    public var modified: Date?
    /// Create missing parent folders on the destination first (used by sync plans).
    public var createParents: Bool
    /// For folders: false only creates the destination folder.
    public var recursive: Bool
    /// Delete the source after a successful copy (move).
    public var deleteSourceAfter: Bool
    /// Overrides the queue's conflict policy for this request (sync plans overwrite on purpose).
    public var conflictOverride: ConflictPolicy?

    public init(
        source: TransferEndpoint, sourcePath: String, destination: TransferEndpoint, destinationPath: String,
        isDirectory: Bool = false, size: UInt64? = nil, modified: Date? = nil,
        createParents: Bool = false, recursive: Bool = true, deleteSourceAfter: Bool = false,
        conflictOverride: ConflictPolicy? = nil
    ) {
        self.source = source; self.sourcePath = sourcePath
        self.destination = destination; self.destinationPath = destinationPath
        self.isDirectory = isDirectory; self.size = size; self.modified = modified
        self.createParents = createParents; self.recursive = recursive; self.deleteSourceAfter = deleteSourceAfter
        self.conflictOverride = conflictOverride
    }

    public var route: String { "\(source.label) → \(destination.label)" }
    /// Server to server: the bytes pass through this Mac.
    public var isRelay: Bool { !source.isLocal && !destination.isLocal }
}

public enum ConflictPolicy: Sendable, Equatable {
    case ask, overwrite, overwriteIfNewer, skip, rename
}

public enum ConflictAction: Sendable, Equatable {
    case overwrite, overwriteIfNewer, skip, rename
    /// Abort this transfer (with apply-to-all: everything queued).
    case cancel
}

public struct ConflictDecision: Sendable, Equatable {
    public var action: ConflictAction
    public var applyToAll: Bool
    public init(_ action: ConflictAction, applyToAll: Bool = false) { self.action = action; self.applyToAll = applyToAll }
}

public struct ConflictInfo: Sendable, Equatable {
    public var jobId: UUID
    public var name: String
    public var route: String
    public var sourcePath: String
    public var destinationPath: String
    public var sourceSize: UInt64?
    public var sourceModified: Date?
    public var destinationSize: UInt64?
    public var destinationModified: Date?
}

/// Asked once per conflicting file when the policy is `.ask`. Calls are serialised.
public typealias ConflictResolver = @Sendable (ConflictInfo) async -> ConflictDecision

public enum TransferState: String, Sendable, Equatable {
    case queued, running, completed, failed, cancelled, skipped

    public var isFinished: Bool { self != .queued && self != .running }
}

public struct TransferJobInfo: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var parentId: UUID?
    public var name: String
    public var sourcePath: String
    public var destinationPath: String
    public var route: String
    public var isRelay: Bool
    public var isDirectory: Bool
    public var state: TransferState
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    public var error: String?
    /// Folder jobs: number of file/folder children created by expansion and how many are done.
    public var childCount: Int
    public var finishedChildCount: Int
    /// The next run will resume a partial file.
    public var willResume: Bool

    /// 0...1, or nil when the size is unknown.
    public var fraction: Double? {
        if state == .completed { return 1 }
        return bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : nil
    }
}

public struct TransferSnapshot: Sendable, Equatable {
    /// Top-level jobs, in the order they were added. Folder jobs carry aggregated progress.
    public var jobs: [TransferJobInfo]
    /// File-level counts across all jobs (folder jobs themselves are not counted).
    public var activeCount: Int
    public var queuedCount: Int
    public var completedCount: Int
    public var failedCount: Int
    public var skippedCount: Int
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    /// Route of the oldest running transfer, e.g. `PROD → STG`.
    public var currentRoute: String?
    public var currentIsRelay: Bool
    public var currentName: String?

    public var isIdle: Bool { activeCount == 0 && queuedCount == 0 }
    public var fraction: Double? { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : nil }

    public static let empty = TransferSnapshot(
        jobs: [], activeCount: 0, queuedCount: 0, completedCount: 0, failedCount: 0, skippedCount: 0,
        bytesDone: 0, bytesTotal: 0, currentRoute: nil, currentIsRelay: false, currentName: nil)
}
