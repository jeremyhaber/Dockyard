import Foundation

extension TransferQueue {
    /// Counters plus the first top-level jobs. For rows use `page`.
    public func snapshot() async -> TransferSnapshot {
        await flushNow()
        return await makeSnapshot()
    }

    /// Emits the current snapshot, then a new one after changes (at most one per `publishInterval`).
    public func updates() -> AsyncStream<TransferSnapshot> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<TransferSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[key] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(key) } }
        Task { continuation.yield(await self.snapshot()) }
        return stream
    }

    private func removeSubscriber(_ key: UUID) { subscribers.removeValue(forKey: key) }

    func publishSoon() {
        checkIdle()
        if isIdle {
            Task { await self.publishNow() }
            return
        }
        guard !publishScheduled else { return }
        publishScheduled = true
        let delay = publishInterval
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self.publishNow()
        }
    }

    private func publishNow() async {
        publishScheduled = false
        guard !subscribers.isEmpty else { return }
        let idle = isIdle
        if idle { await flushNow() }
        let snapshot = await makeSnapshot()
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    private func makeSnapshot() async -> TransferSnapshot {
        var s = TransferSnapshot.empty
        let activeJobs = active.values.sorted { $0.record.id < $1.record.id }
        let inFlight = activeJobs.reduce(UInt64(0)) { $0 + ($1.record.isDirectory ? 0 : $1.progressDone) }
        s.activeCount = stats.active
        s.queuedCount = stats.queued
        s.completedCount = stats.completed
        s.failedCount = stats.failed
        s.skippedCount = stats.skipped
        s.cancelledCount = stats.cancelled
        s.filteredCount = filteredCount
        s.skipReasons = skipReasons
        s.bytesDone = stats.bytesFinished + inFlight
        s.bytesTotal = max(stats.bytesTotal, s.bytesDone)
        s.rate = sampleRate(bytes: s.bytesDone, running: !activeJobs.isEmpty)
        s.isPaused = isPaused
        s.active = activeJobs.map { info($0.record) }
        s.sites = sites.values.filter { $0.isPooled }.sorted { $0.label < $1.label }.map { site in
            TransferSiteStatus(
                id: UUID(uuidString: site.key) ?? UUID(), label: site.label, liveConnections: site.live,
                busyConnections: site.inUse, liveLimit: site.liveLimit, maxConnections: site.maxLimit, isPaused: site.isPaused)
        }
        if let first = activeJobs.first(where: { !$0.record.isDirectory }) ?? activeJobs.first {
            s.currentRoute = first.record.route
            s.currentIsRelay = first.record.isRelay
            s.currentName = first.record.name
        }
        s.jobs = await fetchPage(offset: 0, limit: topLevelPreviewLimit, filter: TransferJobFilter(scope: .topLevel))
        return s
    }

    private func sampleRate(bytes: UInt64, running: Bool) -> Double {
        let now = Date()
        defer { lastRateSample = (now, bytes) }
        guard running, let last = lastRateSample else { smoothedRate = 0; return 0 }
        let dt = now.timeIntervalSince(last.time)
        guard dt > 0.05 else { return smoothedRate }
        let instant = bytes >= last.bytes ? Double(bytes - last.bytes) / dt : 0
        smoothedRate = smoothedRate == 0 ? instant : smoothedRate * 0.6 + instant * 0.4
        return smoothedRate
    }
}
