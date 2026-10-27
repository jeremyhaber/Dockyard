import Foundation

/// Debounces change events for one `WatchLink` and publishes a `WatchPlan` per quiet period.
///
/// A batch is flushed `debounce` seconds after the last event, or `maxDelay` seconds after the first one when
/// changes keep arriving. While paused, events are dropped and `resume()` says whether a rescan is needed.
/// The event source is injected: the app feeds FSEvents into `ingest(_:)` or `run(source:)`.
public actor WatchCoordinator {
    public private(set) var link: WatchLink
    public nonisolated let plans: AsyncStream<WatchPlan>

    private let continuation: AsyncStream<WatchPlan>.Continuation
    private let clock: any DockyardClock
    private let debounce: TimeInterval
    private let maxDelay: TimeInterval

    private var pending: [WatchEvent] = []
    private var quietTimer: Task<Void, Never>?
    private var maxTimer: Task<Void, Never>?
    private var missedWhilePaused = false
    private var stopped = false
    /// Guards against a timer that fired just before it was cancelled.
    private var eventSerial = 0
    private var batchSerial = 0

    public init(link: WatchLink, clock: any DockyardClock = SystemClock(), debounce: TimeInterval = 0.5, maxDelay: TimeInterval = 5) {
        self.link = link
        self.clock = clock
        self.debounce = debounce
        self.maxDelay = max(maxDelay, debounce)
        (plans, continuation) = AsyncStream<WatchPlan>.makeStream(bufferingPolicy: .unbounded)
    }

    public var isPaused: Bool { link.paused }
    public var pendingEventCount: Int { pending.count }

    /// Consumes `source` until it ends (or the task is cancelled).
    public func run(source: AsyncStream<WatchEvent>) async {
        for await event in source {
            if Task.isCancelled { break }
            ingest(event)
        }
    }

    public func ingest(_ event: WatchEvent) {
        guard !stopped else { return }
        guard !link.paused else { missedWhilePaused = true; return }
        if pending.isEmpty { startMaxTimer() }
        pending.append(event)
        eventSerial += 1
        let serial = eventSerial
        quietTimer?.cancel()
        quietTimer = Task { [weak self, clock, debounce] in
            guard (try? await clock.sleep(seconds: debounce)) != nil else { return }
            await self?.quietPeriodElapsed(serial)
        }
    }

    public func pause() {
        link.paused = true
        // Whatever was waiting is stale once the user pauses; it will be found again by a rescan.
        if !pending.isEmpty { missedWhilePaused = true }
        discardPending()
    }

    /// Returns true when changes may have been missed while paused, so the caller should rescan the folder.
    @discardableResult
    public func resume() -> Bool {
        link.paused = false
        defer { missedWhilePaused = false }
        return missedWhilePaused
    }

    public func setMirrorDeletes(_ on: Bool) { link.mirrorDeletes = on }

    /// Publishes the current batch immediately.
    public func flushNow() { flush() }

    public func stop() {
        stopped = true
        discardPending()
        continuation.finish()
    }

    private func quietPeriodElapsed(_ serial: Int) { if serial == eventSerial { flush() } }
    private func maxDelayElapsed(_ batch: Int) { if batch == batchSerial { flush() } }

    private func flush() {
        quietTimer?.cancel(); quietTimer = nil
        maxTimer?.cancel(); maxTimer = nil
        batchSerial += 1
        guard !pending.isEmpty else { return }
        let events = pending
        pending.removeAll()
        let plan = WatchPlanner.plan(events, for: link)
        if !plan.isEmpty { continuation.yield(plan) }
    }

    private func startMaxTimer() {
        maxTimer?.cancel()
        let batch = batchSerial
        maxTimer = Task { [weak self, clock, maxDelay] in
            guard (try? await clock.sleep(seconds: maxDelay)) != nil else { return }
            await self?.maxDelayElapsed(batch)
        }
    }

    private func discardPending() {
        quietTimer?.cancel(); quietTimer = nil
        maxTimer?.cancel(); maxTimer = nil
        batchSerial += 1
        pending.removeAll()
    }
}
