import Foundation
import ConnectionKit

/// Global transfer queue: bounded concurrency, folder expansion, conflict handling, resume, relay.
public actor TransferQueue {
    // MARK: Configuration

    public private(set) var maxConcurrent: Int
    public private(set) var conflictPolicy: ConflictPolicy
    public var preserveTimestamps: Bool
    /// Source newer than destination by more than this counts as "newer".
    public var timestampTolerance: TimeInterval = 1
    public nonisolated let log = LogHub()

    private let resolver: ConflictResolver?
    private let tempDirectory: URL
    private let progressInterval: TimeInterval
    private let publishInterval: TimeInterval

    // MARK: State

    private final class Job {
        let id: UUID
        let parentId: UUID?
        var request: TransferRequest
        var state: TransferState = .queued
        var bytesDone: UInt64 = 0
        var bytesTotal: UInt64
        var error: String?
        var task: Task<Void, Never>?
        var cancelRequested = false
        var resumeNext = false
        var holdsSlot = false
        var children: [UUID] = []
        var expanded = false
        var pending = 0
        var failedChildren = 0
        var cancelledChildren = 0
        var skippedChildren = 0

        init(id: UUID = UUID(), parentId: UUID?, request: TransferRequest) {
            self.id = id; self.parentId = parentId; self.request = request
            self.bytesTotal = request.size ?? 0
        }
        var name: String { RemotePath.lastComponent(of: request.destinationPath) }
    }

    private var jobs: [UUID: Job] = [:]
    private var topLevel: [UUID] = []
    private var pendingIds: [UUID] = []
    private var running = 0
    private var runningOrder: [UUID] = []

    private var subscribers: [UUID: AsyncStream<TransferSnapshot>.Continuation] = [:]
    private var publishScheduled = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    private var resolving = false
    private var resolveWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        maxConcurrent: Int = 3,
        conflictPolicy: ConflictPolicy = .ask,
        resolver: ConflictResolver? = nil,
        preserveTimestamps: Bool = true,
        tempDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("dockyard-relay"),
        progressInterval: TimeInterval = 0.1,
        publishInterval: TimeInterval = 0.1
    ) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.conflictPolicy = conflictPolicy
        self.resolver = resolver
        self.preserveTimestamps = preserveTimestamps
        self.tempDirectory = tempDirectory
        self.progressInterval = progressInterval
        self.publishInterval = publishInterval
    }

    // MARK: Public API

    public func setMaxConcurrent(_ n: Int) {
        maxConcurrent = max(1, n)
        pump()
    }

    /// Sets the policy for everything not yet decided (also clears a previous "apply to all").
    public func setConflictPolicy(_ policy: ConflictPolicy) { conflictPolicy = policy }

    @discardableResult
    public func enqueue(_ request: TransferRequest) -> UUID {
        let job = Job(parentId: nil, request: request)
        jobs[job.id] = job
        topLevel.append(job.id)
        pendingIds.append(job.id)
        pump()
        publishSoon()
        return job.id
    }

    @discardableResult
    public func enqueue(_ requests: [TransferRequest]) -> [UUID] {
        requests.map { enqueue($0) }
    }

    /// Queues listing items for copy/move into `destinationDirectory`.
    @discardableResult
    public func enqueue(
        items: [RemoteItem], from source: TransferEndpoint, to destination: TransferEndpoint,
        into destinationDirectory: String, move: Bool = false
    ) -> [UUID] {
        enqueue(items.map { item in
            TransferRequest(
                source: source, sourcePath: item.path, destination: destination,
                destinationPath: RemotePath.join(destinationDirectory, item.name),
                isDirectory: item.isDirectory, size: item.size, modified: item.modified, deleteSourceAfter: move)
        })
    }

    public func cancel(_ id: UUID) async {
        guard let job = jobs[id], !job.state.isFinished else { return }
        job.cancelRequested = true
        if job.state == .queued {
            await finish(job, .cancelled, error: nil)
        } else if job.holdsSlot {
            job.task?.cancel()
        } else {
            // Folder waiting for its children.
            for child in job.children { await cancel(child) }
        }
    }

    public func cancelAll() async {
        for id in topLevel { await cancel(id) }
    }

    /// Re-queues a failed or cancelled job. Partial files are resumed where the protocol supports it.
    public func retry(_ id: UUID) {
        guard let job = jobs[id], job.state == .failed || job.state == .cancelled else { return }
        reset(job)
        pump()
        publishSoon()
    }

    public func retryFailed() {
        for id in topLevel { if let j = jobs[id], j.state == .failed { reset(j) } }
        pump()
        publishSoon()
    }

    /// Forgets completed and skipped top-level jobs.
    public func removeFinished() {
        let drop = topLevel.filter { jobs[$0].map { $0.state == .completed || $0.state == .skipped } ?? true }
        for id in drop { remove(id) }
        topLevel.removeAll { drop.contains($0) }
        publishSoon()
    }

    public func snapshot() -> TransferSnapshot { buildSnapshot() }

    public func children(of id: UUID) -> [TransferJobInfo] {
        (jobs[id]?.children ?? []).compactMap { jobs[$0].map(info(for:)) }
    }

    public func job(_ id: UUID) -> TransferJobInfo? { jobs[id].map(info(for:)) }

    /// Emits the current snapshot, then a new one after changes (throttled).
    public func updates() -> AsyncStream<TransferSnapshot> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<TransferSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[key] = continuation
        continuation.yield(buildSnapshot())
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(key) } }
        return stream
    }

    /// Returns when nothing is queued or running.
    public func waitUntilIdle() async {
        if isIdle() { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: Scheduling

    private func isIdle() -> Bool {
        running == 0 && !jobs.values.contains { $0.state == .queued || ($0.state == .running && !$0.holdsSlot) }
    }

    private func pump() {
        while running < maxConcurrent, let job = nextPending() {
            job.state = .running
            job.holdsSlot = true
            running += 1
            runningOrder.append(job.id)
            let id = job.id
            job.task = Task { await self.execute(id) }
        }
    }

    private func nextPending() -> Job? {
        while !pendingIds.isEmpty {
            let id = pendingIds.removeFirst()
            if let j = jobs[id], j.state == .queued, !j.cancelRequested { return j }
        }
        return nil
    }

    private func execute(_ id: UUID) async {
        guard let job = jobs[id] else { return }
        do {
            if job.request.isDirectory { try await expand(job) } else { try await transferFile(job) }
        } catch {
            if job.cancelRequested || error is CancellationError || Task.isCancelled {
                await finish(job, .cancelled, error: nil)
            } else {
                if job.bytesDone > 0 { job.resumeNext = true }
                let message = Self.describe(error)
                log.emit(.error, "Failed: \(job.name) (\(job.request.route)): \(message)")
                await finish(job, .failed, error: message)
            }
        }
        pump()
    }

    private func finish(_ job: Job, _ state: TransferState, error: String?) async {
        guard !job.state.isFinished else { return }
        job.state = state
        job.error = error
        job.task = nil
        if job.holdsSlot { job.holdsSlot = false; running -= 1 }
        runningOrder.removeAll { $0 == job.id }
        if state == .completed, !job.request.isDirectory {
            job.bytesDone = max(job.bytesDone, job.bytesTotal)
            job.bytesTotal = max(job.bytesTotal, job.bytesDone)
        }
        if let pid = job.parentId, let parent = jobs[pid] {
            parent.pending -= 1
            switch state {
            case .failed: parent.failedChildren += 1
            case .cancelled: parent.cancelledChildren += 1
            case .skipped: parent.skippedChildren += 1
            default: break
            }
            if parent.pending == 0, parent.expanded { await finalizeDirectory(parent) }
        }
        pump()
        publishSoon()
    }

    private func finalizeDirectory(_ dir: Job) async {
        if dir.failedChildren > 0 {
            await finish(dir, .failed, error: "\(dir.failedChildren) item\(dir.failedChildren == 1 ? "" : "s") failed")
        } else if dir.cancelledChildren > 0 {
            await finish(dir, .cancelled, error: nil)
        } else {
            if dir.request.deleteSourceAfter && dir.skippedChildren == 0 {
                do { try await dir.request.source.fs.delete(dir.request.sourcePath, recursive: true) } catch {
                    await finish(dir, .failed, error: "Copied, but could not remove source: \(Self.describe(error))")
                    return
                }
            }
            log.emit(.status, "Finished folder \(dir.name) (\(dir.request.route))")
            await finish(dir, .completed, error: nil)
        }
    }

    // MARK: Folders

    private func expand(_ job: Job) async throws {
        let req = job.request
        if req.createParents { try await Self.ensureDirectory(req.destination.fs, RemotePath.parent(of: req.destinationPath)) }
        try await Self.ensureDirectory(req.destination.fs, req.destinationPath)
        guard req.recursive else { await finish(job, .completed, error: nil); return }
        log.emit(.status, "Listing \(req.sourcePath) (\(req.route))")
        let items = try await req.source.fs.list(req.sourcePath)
        try Task.checkCancellation()
        let kids: [Job] = items
            .filter { !($0.isDirectory && $0.isSymlink) }  // never follow folder symlinks
            .sorted { $0.name < $1.name }
            .map { item in
                var child = req
                child.sourcePath = item.path
                child.destinationPath = RemotePath.join(req.destinationPath, item.name)
                child.isDirectory = item.isDirectory
                child.size = item.size
                child.modified = item.modified
                child.createParents = false
                return Job(parentId: job.id, request: child)
            }
        for k in kids { jobs[k.id] = k }
        job.children = kids.map(\.id)
        job.pending = kids.count
        job.expanded = true
        pendingIds.insert(contentsOf: kids.map(\.id), at: 0)
        // The folder no longer needs a slot; its children do.
        if job.holdsSlot { job.holdsSlot = false; running -= 1 }
        if kids.isEmpty { await finalizeDirectory(job) }
        publishSoon()
    }

    // MARK: Files

    private enum ConflictOutcome { case proceed, skip, cancel }

    private func transferFile(_ job: Job) async throws {
        var req = job.request
        if req.createParents { try await Self.ensureDirectory(req.destination.fs, RemotePath.parent(of: req.destinationPath)) }

        let resume = job.resumeNext
        if !resume, let existing = try await req.destination.fs.lookup(req.destinationPath) {
            switch try await resolveConflict(job, existing: existing) {
            case .proceed: break
            case .skip:
                log.emit(.status, "Skipped \(job.name): already exists")
                await finish(job, .skipped, error: nil)
                return
            case .cancel:
                job.cancelRequested = true
                throw CancellationError()
            }
            req = job.request  // rename may have changed the destination
        }
        job.resumeNext = false
        if req.modified == nil && preserveTimestamps {
            req.modified = try? await req.source.fs.lookup(req.sourcePath)?.modified
            job.request.modified = req.modified
        }
        if req.size == nil, let item = try? await req.source.fs.lookup(req.sourcePath) {
            job.bytesTotal = item.size ?? 0
            job.request.size = item.size
            req.size = item.size
        }
        log.emit(.status, "\(req.isRelay ? "Relaying" : (req.source.isLocal ? "Uploading" : "Downloading")) \(job.name) (\(req.route))\(resume ? ", resuming" : "")")

        let id = job.id
        let sample: @Sendable (UInt64, UInt64) async -> Void = { [weak self] done, total in
            await self?.setProgress(id, done: done, total: total)
        }
        try await Self.perform(req, resume: resume, tempRoot: tempDirectory, preserveTimestamps: preserveTimestamps,
                               interval: progressInterval, sample: sample)
        if job.cancelRequested { throw CancellationError() }
        if req.deleteSourceAfter { try await req.source.fs.delete(req.sourcePath, recursive: false) }
        log.emit(.status, "Completed \(job.name) (\(req.route))")
        await finish(job, .completed, error: nil)
    }

    private func setProgress(_ id: UUID, done: UInt64, total: UInt64) {
        guard let job = jobs[id], job.state == .running else { return }
        job.bytesDone = done
        if total > 0 { job.bytesTotal = max(total, job.request.size ?? 0) }
        publishSoon()
    }

    private func resolveConflict(_ job: Job, existing: RemoteItem) async throws -> ConflictOutcome {
        if existing.isDirectory {
            throw RemoteError.protocolError("A folder named \(job.name) already exists at the destination")
        }
        let req = job.request
        let action = await decideConflict(job, existing: existing)
        switch action {
        case .overwrite: return .proceed
        case .skip: return .skip
        case .cancel: return .cancel
        case .overwriteIfNewer:
            guard let src = req.modified, let dst = existing.modified else { return .proceed }
            return src.timeIntervalSince(dst) > timestampTolerance ? .proceed : .skip
        case .rename:
            var n = 1
            let dir = RemotePath.parent(of: req.destinationPath)
            while true {
                let candidate = RemotePath.join(dir, FileNaming.numbered(RemotePath.lastComponent(of: req.destinationPath), n))
                if try await req.destination.fs.lookup(candidate) == nil {
                    job.request.destinationPath = candidate
                    return .proceed
                }
                n += 1
            }
        }
    }

    /// Serialises "ask" prompts; once the user chose apply-to-all, later files skip the prompt.
    private func decideConflict(_ job: Job, existing: RemoteItem) async -> ConflictAction {
        while resolving { await withCheckedContinuation { resolveWaiters.append($0) } }
        resolving = true
        defer {
            resolving = false
            if !resolveWaiters.isEmpty { resolveWaiters.removeFirst().resume() }
        }
        switch job.request.conflictOverride ?? conflictPolicy {
        case .overwrite: return .overwrite
        case .overwriteIfNewer: return .overwriteIfNewer
        case .skip: return .skip
        case .rename: return .rename
        case .ask: break
        }
        guard let resolver else { return .skip }  // nobody to ask: never overwrite silently
        let req = job.request
        let info = ConflictInfo(
            jobId: job.id, name: job.name, route: req.route, sourcePath: req.sourcePath, destinationPath: req.destinationPath,
            sourceSize: req.size, sourceModified: req.modified, destinationSize: existing.size, destinationModified: existing.modified)
        let decision = await resolver(info)
        if decision.applyToAll {
            switch decision.action {
            case .overwrite: conflictPolicy = .overwrite
            case .overwriteIfNewer: conflictPolicy = .overwriteIfNewer
            case .skip: conflictPolicy = .skip
            case .rename: conflictPolicy = .rename
            case .cancel:
                Task { await self.cancelAll() }
            }
        }
        return decision.action
    }

    // MARK: Retry / removal

    private func reset(_ job: Job) {
        let old = job.state
        guard old == .failed || old == .cancelled else { return }
        job.cancelRequested = false
        if job.request.isDirectory && job.expanded {
            // Retry the failed/cancelled children; the folder reopens through them.
            job.error = nil
            let retryable = job.children.compactMap { jobs[$0] }.filter { $0.state == .failed || $0.state == .cancelled }
            if retryable.isEmpty {
                // Folder itself failed after its children finished (e.g. source removal).
                job.state = .running
                reopenParents(of: job, was: old)
                Task { await self.finalizeDirectory(job) }
            } else {
                for c in retryable { reset(c) }
            }
            return
        }
        job.state = .queued
        job.error = nil
        job.resumeNext = job.bytesDone > 0 && !job.request.isDirectory
        job.expanded = false
        reopenParents(of: job, was: old)
        pendingIds.append(job.id)
    }

    private func reopenParents(of job: Job, was old: TransferState) {
        guard let pid = job.parentId, let parent = jobs[pid] else { return }
        parent.pending += 1
        if old == .failed { parent.failedChildren -= 1 } else if old == .cancelled { parent.cancelledChildren -= 1 }
        if parent.state.isFinished {
            let parentOld = parent.state
            parent.state = .running
            parent.error = nil
            reopenParents(of: parent, was: parentOld)
        }
    }

    private func remove(_ id: UUID) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        for c in job.children { remove(c) }
    }

    // MARK: Snapshots

    private func info(for job: Job) -> TransferJobInfo {
        var done = job.bytesDone, total = job.bytesTotal
        var finishedChildren = 0
        if job.request.isDirectory {
            (done, total) = aggregate(job)
            finishedChildren = job.children.filter { jobs[$0]?.state.isFinished == true }.count
        }
        return TransferJobInfo(
            id: job.id, parentId: job.parentId, name: job.name, sourcePath: job.request.sourcePath,
            destinationPath: job.request.destinationPath, route: job.request.route, isRelay: job.request.isRelay,
            isDirectory: job.request.isDirectory, state: job.state, bytesDone: done, bytesTotal: total, error: job.error,
            childCount: job.children.count, finishedChildCount: finishedChildren, willResume: job.resumeNext)
    }

    private func aggregate(_ job: Job) -> (UInt64, UInt64) {
        var done: UInt64 = 0, total: UInt64 = 0
        for cid in job.children {
            guard let c = jobs[cid] else { continue }
            if c.request.isDirectory {
                let (d, t) = aggregate(c); done += d; total += t
            } else {
                done += c.state == .completed ? max(c.bytesDone, c.bytesTotal) : c.bytesDone
                total += max(c.bytesTotal, c.bytesDone)
            }
        }
        return (done, total)
    }

    private func buildSnapshot() -> TransferSnapshot {
        var s = TransferSnapshot.empty
        s.jobs = topLevel.compactMap { jobs[$0].map(info(for:)) }
        for job in jobs.values where !job.request.isDirectory {
            switch job.state {
            case .running: s.activeCount += 1
            case .queued: s.queuedCount += 1
            case .completed: s.completedCount += 1
            case .failed: s.failedCount += 1
            case .skipped: s.skippedCount += 1
            case .cancelled: break
            }
            if job.state != .cancelled && job.state != .skipped {
                s.bytesDone += job.state == .completed ? max(job.bytesDone, job.bytesTotal) : job.bytesDone
                s.bytesTotal += max(job.bytesTotal, job.bytesDone)
            }
        }
        // Folders that are still expanding count as pending work.
        for job in jobs.values where job.request.isDirectory && !job.expanded && !job.state.isFinished {
            if job.state == .running { s.activeCount += 1 } else { s.queuedCount += 1 }
        }
        if let id = runningOrder.first(where: { jobs[$0]?.request.isDirectory == false }) ?? runningOrder.first, let j = jobs[id] {
            s.currentRoute = j.request.route
            s.currentIsRelay = j.request.isRelay
            s.currentName = j.name
        }
        return s
    }

    private func removeSubscriber(_ key: UUID) { subscribers.removeValue(forKey: key) }

    private func publishSoon() {
        if isIdle() { publishNow() ; return }
        guard !publishScheduled else { return }
        publishScheduled = true
        let delay = publishInterval
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.publishNow()
        }
    }

    private func publishNow() {
        publishScheduled = false
        if !subscribers.isEmpty {
            let snap = buildSnapshot()
            for c in subscribers.values { c.yield(snap) }
        }
        if isIdle() {
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }

    // MARK: Moving bytes

    private final class ProgressBox: @unchecked Sendable {
        let first = Progress(totalUnitCount: 0)
        let second = Progress(totalUnitCount: 0)
        let relay: Bool
        let size: UInt64
        init(relay: Bool, size: UInt64) { self.relay = relay; self.size = size }
        var sample: (UInt64, UInt64) {
            if relay {
                let done = (UInt64(max(0, first.completedUnitCount)) + UInt64(max(0, second.completedUnitCount))) / 2
                return (done, max(size, UInt64(max(0, first.totalUnitCount)), UInt64(max(0, second.totalUnitCount))))
            }
            return (UInt64(max(0, first.completedUnitCount)), max(size, UInt64(max(0, first.totalUnitCount))))
        }
    }

    private static func perform(
        _ req: TransferRequest, resume: Bool, tempRoot: URL, preserveTimestamps: Bool, interval: TimeInterval,
        sample: @escaping @Sendable (UInt64, UInt64) async -> Void
    ) async throws {
        let box = ProgressBox(relay: req.isRelay, size: req.size ?? 0)
        let sampler = Task {
            while !Task.isCancelled {
                let (d, t) = box.sample
                await sample(d, t)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        defer { sampler.cancel() }

        do {
            try await move(req, resume: resume, box: box, tempRoot: tempRoot)
        } catch {
            let (d, t) = box.sample
            await sample(d, t)  // so a retry knows a partial file exists
            throw error
        }
        let (d, t) = box.sample
        await sample(max(d, t), t)
        if preserveTimestamps, req.destination.isLocal, let m = req.modified {
            try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: req.destinationPath)
        }
    }

    private static func move(_ req: TransferRequest, resume: Bool, box: ProgressBox, tempRoot: URL) async throws {
        if req.source.isLocal {
            try await req.destination.fs.upload(URL(fileURLWithPath: req.sourcePath), to: req.destinationPath, progress: box.first, resume: resume)
        } else if req.destination.isLocal {
            try await req.source.fs.download(req.sourcePath, to: URL(fileURLWithPath: req.destinationPath), progress: box.first, resume: resume)
        } else {
            let dir = tempRoot.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let temp = dir.appendingPathComponent(RemotePath.lastComponent(of: req.sourcePath))
            try await req.source.fs.download(req.sourcePath, to: temp, progress: box.first, resume: false)
            try Task.checkCancellation()
            try await req.destination.fs.upload(temp, to: req.destinationPath, progress: box.second, resume: resume)
        }
    }

    /// Creates `path` and any missing parents.
    static func ensureDirectory(_ fs: any RemoteFileSystem, _ path: String) async throws {
        if path == "/" || path.isEmpty || path == "." { return }
        if let existing = try await fs.lookup(path) {
            guard existing.isDirectory else { throw RemoteError.protocolError("\(path) exists and is not a folder") }
            return
        }
        try await ensureDirectory(fs, RemotePath.parent(of: path))
        try await fs.mkdir(path)
    }

    static func describe(_ error: any Error) -> String {
        if let r = error as? RemoteError { return r.description }
        return error.localizedDescription
    }
}
