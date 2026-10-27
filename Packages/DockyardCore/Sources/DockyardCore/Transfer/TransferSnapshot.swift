import Foundation

public struct TransferSiteStatus: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var label: String
    /// Connections in use plus idle ones in the pool.
    public var liveConnections: Int
    public var busyConnections: Int
    /// Current limit after back-off, and the configured maximum.
    public var liveLimit: Int
    public var maxConnections: Int
    public var isPaused: Bool
}

/// What the queue UI shows. Published at most a few times a second (`TransferQueue.publishInterval`).
public struct TransferSnapshot: Sendable, Equatable {
    /// The first `TransferQueue.topLevelPreviewLimit` top-level jobs in the order they were added.
    /// Use `TransferQueue.page` for the full list.
    public var jobs: [TransferJobInfo]
    /// Items being transferred (or folders being listed) right now.
    public var active: [TransferJobInfo]
    /// File-level counts across all jobs (a folder only counts while it waits for or performs its listing).
    public var activeCount: Int
    public var queuedCount: Int
    public var completedCount: Int
    public var failedCount: Int
    public var skippedCount: Int
    public var cancelledCount: Int
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    /// Bytes per second, smoothed over the last publishes.
    public var rate: Double
    public var isPaused: Bool
    public var sites: [TransferSiteStatus]
    /// Route of the oldest running transfer, e.g. `PROD → STG`.
    public var currentRoute: String?
    public var currentIsRelay: Bool
    public var currentName: String?

    public var isIdle: Bool { activeCount == 0 && queuedCount == 0 }
    public var fraction: Double? { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : nil }

    public static let empty = TransferSnapshot(
        jobs: [], active: [], activeCount: 0, queuedCount: 0, completedCount: 0, failedCount: 0, skippedCount: 0,
        cancelledCount: 0, bytesDone: 0, bytesTotal: 0, rate: 0, isPaused: false, sites: [],
        currentRoute: nil, currentIsRelay: false, currentName: nil)
}

/// Selects rows for `TransferQueue.page` and `count`.
public struct TransferFilter: Sendable, Equatable {
    public enum Scope: Sendable, Equatable {
        /// Files only (no folder jobs): what a flat queue table shows.
        case files
        case topLevel
        case children(of: UUID)
        case all
    }

    public var scope: Scope
    /// nil matches every state.
    public var states: Set<TransferState>?

    public init(scope: Scope = .files, states: Set<TransferState>? = nil) {
        self.scope = scope
        self.states = states
    }
}
