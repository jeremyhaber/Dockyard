import Foundation
import ConnectionKit

/// Time source and sleeper that tests can replace. All debouncing and periodic work in this package uses it.
public protocol DockyardClock: Sendable {
    func now() -> Date
    /// Suspends for `seconds`. Throws `CancellationError` when the calling task is cancelled.
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemClock: DockyardClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// A clock that only moves when `advance(by:)` is called. For tests.
public final class ManualClock: DockyardClock {
    private struct Sleeper {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct State {
        var current: Date
        var sleepers: [Sleeper] = []
        var cancelledEarly: Set<UUID> = []
    }
    private let state: LockedBox<State>

    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        state = LockedBox(State(current: start))
    }

    public func now() -> Date { state.withLock { $0.current } }

    /// Number of tasks currently suspended in `sleep`.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let action: (() -> Void)? = state.withLock { s in
                    if s.cancelledEarly.remove(id) != nil {
                        return { continuation.resume(throwing: CancellationError()) }
                    }
                    if seconds <= 0 { return { continuation.resume() } }
                    s.sleepers.append(Sleeper(id: id, deadline: s.current.addingTimeInterval(seconds), continuation: continuation))
                    return nil
                }
                action?()
            }
        } onCancel: {
            let found: Sleeper? = state.withLock { s in
                if let i = s.sleepers.firstIndex(where: { $0.id == id }) { return s.sleepers.remove(at: i) }
                s.cancelledEarly.insert(id)
                return nil
            }
            found?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed (in deadline order).
    public func advance(by seconds: TimeInterval) {
        let due: [Sleeper] = state.withLock { s in
            s.current = s.current.addingTimeInterval(seconds)
            let due = s.sleepers.filter { $0.deadline <= s.current }.sorted { $0.deadline < $1.deadline }
            s.sleepers.removeAll { $0.deadline <= s.current }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Yields until `count` tasks are sleeping (test helper to avoid races).
    public func waitForSleepers(_ count: Int = 1, timeout: TimeInterval = 5) async {
        let end = Date().addingTimeInterval(timeout)
        while sleeperCount < count && Date() < end { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
    }
}
