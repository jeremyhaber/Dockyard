import Foundation
import ConnectionKit

/// One side of a transfer: a file system and the name to show for it in route labels.
public struct TransferEndpoint: Sendable {
    /// The caller's own session. Used directly only when the queue has no `TransferSite` for `siteId`.
    public let fs: any RemoteFileSystem
    /// e.g. `PROD`, `STG`, `This Mac`.
    public let label: String
    /// Identifies the saved connection. With a `TransferSite` registered for it, the queue opens its own
    /// pooled sessions (limits, back-off, persistence across restarts) instead of using `fs`.
    public let siteId: UUID?

    public init(fs: any RemoteFileSystem, label: String, siteId: UUID? = nil) {
        self.fs = fs
        self.label = label
        self.siteId = siteId
    }

    public static func thisMac(_ fs: LocalFileSystem = LocalFileSystem()) -> TransferEndpoint {
        TransferEndpoint(fs: fs, label: "This Mac")
    }

    public var isLocal: Bool { fs is LocalFileSystem }
}

/// A server the queue may open connections to. Register it with `TransferQueue.register(site:)`.
public struct TransferSite: Sendable {
    public var id: UUID
    public var label: String
    /// Upper bound for simultaneous connections (the site's setting, 1...10).
    public var maxConnections: Int
    /// Minimum time between opening two connections.
    public var connectDelayMs: Int
    /// Creates a new, not yet connected session. The queue connects it and closes it when idle.
    public var makeSession: @Sendable () async throws -> any RemoteFileSystem

    public init(
        id: UUID, label: String, maxConnections: Int = Connection.defaultMaxConnections, connectDelayMs: Int = 0,
        makeSession: @escaping @Sendable () async throws -> any RemoteFileSystem
    ) {
        self.id = id
        self.label = label
        self.maxConnections = min(max(1, maxConnections), 10)
        self.connectDelayMs = max(0, connectDelayMs)
        self.makeSession = makeSession
    }

    public init(connection: Connection, makeSession: @escaping @Sendable () async throws -> any RemoteFileSystem) {
        self.init(id: connection.id, label: connection.name, maxConnections: connection.maxConnections,
                  connectDelayMs: connection.connectDelayMs, makeSession: makeSession)
    }

    /// The endpoint to put in a `TransferRequest`. `fs` is only a fallback; see `TransferEndpoint.siteId`.
    public func endpoint(fs: any RemoteFileSystem) -> TransferEndpoint {
        TransferEndpoint(fs: fs, label: label, siteId: id)
    }
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
    /// Folder jobs: number of direct children created by the listing and how many of them are finished.
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

