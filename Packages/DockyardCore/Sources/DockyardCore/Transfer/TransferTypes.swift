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
    /// Skip rules for the children of folder transfers on this site.
    public var filter: TransferFilter
    /// Runs before an upload replaces an existing file (the safety net keeps the old version). Throwing fails the item.
    public var beforeOverwrite: (@Sendable (_ path: String, _ fs: any RemoteFileSystem) async throws -> Void)?
    /// Compare SHA-256 of the local and remote copy after each upload or download; a mismatch fails the item.
    public var verifyChecksums: Bool
    /// What to do about existing files on this site when nothing else decides (nil or `.ask` defers to the queue's policy).
    public var defaultConflict: ConflictPolicy?

    public init(
        id: UUID, label: String, maxConnections: Int = Connection.defaultMaxConnections, connectDelayMs: Int = 0,
        filter: TransferFilter = .none, verifyChecksums: Bool = false, defaultConflict: ConflictPolicy? = nil,
        beforeOverwrite: (@Sendable (_ path: String, _ fs: any RemoteFileSystem) async throws -> Void)? = nil,
        makeSession: @escaping @Sendable () async throws -> any RemoteFileSystem
    ) {
        self.filter = filter
        self.verifyChecksums = verifyChecksums
        self.defaultConflict = defaultConflict
        self.beforeOverwrite = beforeOverwrite
        self.id = id
        self.label = label
        self.maxConnections = min(max(1, maxConnections), 10)
        self.connectDelayMs = max(0, connectDelayMs)
        self.makeSession = makeSession
    }

    public init(
        connection: Connection, filter: TransferFilter = .none, verifyChecksums: Bool = false,
        defaultConflict: ConflictPolicy? = nil,
        beforeOverwrite: (@Sendable (_ path: String, _ fs: any RemoteFileSystem) async throws -> Void)? = nil,
        makeSession: @escaping @Sendable () async throws -> any RemoteFileSystem
    ) {
        self.init(id: connection.id, label: connection.name, maxConnections: connection.maxConnections,
                  connectDelayMs: connection.connectDelayMs, filter: filter, verifyChecksums: verifyChecksums,
                  defaultConflict: defaultConflict ?? connection.defaultConflictAction, beforeOverwrite: beforeOverwrite, makeSession: makeSession)
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

/// What to do when a file already exists at the destination (FileZilla's set of rules).
public enum ConflictPolicy: String, Sendable, Equatable, CaseIterable, Codable {
    case ask, overwrite, overwriteIfNewer, overwriteIfDifferent, overwriteIfSizeDiffers, resume, skip, rename

    public var title: String {
        switch self {
        case .ask: "Ask"
        case .overwrite: "Overwrite"
        case .overwriteIfNewer: "Overwrite if newer"
        case .overwriteIfDifferent: "Overwrite if different"
        case .overwriteIfSizeDiffers: "Overwrite if size differs"
        case .resume: "Resume"
        case .skip: "Skip"
        case .rename: "Rename"
        }
    }

    /// The action this policy stands for; nil for `.ask`.
    public var action: ConflictAction? { ConflictAction(rawValue: rawValue) }
}

public enum ConflictAction: String, Sendable, Equatable, CaseIterable {
    case overwrite, overwriteIfNewer, overwriteIfDifferent, overwriteIfSizeDiffers
    /// Append to a partial file at the destination.
    case resume
    case skip, rename
    /// Abort this transfer (with a scope wider than this file: everything queued).
    case cancel

    public var title: String { ConflictPolicy(rawValue: rawValue)?.title ?? "Cancel" }

    /// For the conditional overwrite actions: whether the source should replace the destination.
    public func replaces(
        sourceSize: UInt64?, sourceModified: Date?, destinationSize: UInt64?, destinationModified: Date?, tolerance: TimeInterval = 1
    ) -> Bool {
        switch self {
        case .overwriteIfNewer:
            guard let new = sourceModified, let old = destinationModified else { return true }
            return new.timeIntervalSince(old) > tolerance
        case .overwriteIfDifferent:
            if let a = sourceSize, let b = destinationSize, a != b { return true }
            if let new = sourceModified, let old = destinationModified { return abs(new.timeIntervalSince(old)) > tolerance }
            return sourceSize == nil || destinationSize == nil
        case .overwriteIfSizeDiffers:
            guard let a = sourceSize, let b = destinationSize else { return true }
            return a != b
        default:
            return true
        }
    }
}

/// How far a decision reaches.
public enum ConflictScope: Sendable, Equatable, CaseIterable {
    case thisFile
    /// Everything still in the queue; forgotten when the queue empties.
    case allRemaining
    case uploadsOnly
    case downloadsOnly
    /// Until the app quits.
    case session

    public var title: String {
        switch self {
        case .thisFile: "This file only"
        case .allRemaining: "All remaining items in the queue"
        case .uploadsOnly: "Only uploads"
        case .downloadsOnly: "Only downloads"
        case .session: "This session"
        }
    }
}

public struct ConflictDecision: Sendable, Equatable {
    public var action: ConflictAction
    public var scope: ConflictScope
    public var applyToAll: Bool { scope == .allRemaining }

    public init(_ action: ConflictAction, applyToAll: Bool = false) {
        self.action = action
        scope = applyToAll ? .allRemaining : .thisFile
    }

    public init(_ action: ConflictAction, scope: ConflictScope) {
        self.action = action
        self.scope = scope
    }
}

/// Why the queue left an existing file alone.
public enum SkipReason: String, Sendable, Equatable, CaseIterable, Hashable {
    /// A conditional rule found nothing to update, or a partial file was already complete.
    case unchanged
    /// The user (or a rule) chose Skip.
    case kept

    public var title: String { self == .unchanged ? "unchanged" : "kept existing" }
}

public enum ConflictDirection: Sendable, Equatable { case upload, download, relay }

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
    public var direction: ConflictDirection = .upload

    public init(
        jobId: UUID, name: String, route: String, sourcePath: String, destinationPath: String,
        sourceSize: UInt64? = nil, sourceModified: Date? = nil, destinationSize: UInt64? = nil, destinationModified: Date? = nil,
        direction: ConflictDirection = .upload
    ) {
        self.jobId = jobId; self.name = name; self.route = route
        self.sourcePath = sourcePath; self.destinationPath = destinationPath
        self.sourceSize = sourceSize; self.sourceModified = sourceModified
        self.destinationSize = destinationSize; self.destinationModified = destinationModified
        self.direction = direction
    }
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

