import Foundation
import ConnectionKit
import GRDB

/// Global transfer queue.
///
/// Jobs live in SQLite (`transferJob`); memory holds only counters, a small window of ready rows per
/// site, and the jobs that are running. Folders expand lazily: a folder is one job whose listing inserts
/// children in batches while workers already transfer the first ones. A scheduler picks work round-robin
/// across sites, bounded by each site's live connection limit, its connect delay and a global cap, and
/// sessions come from a per-site pool. See `docs/HANDOFF.md` section 10.
public actor TransferQueue {
    // MARK: Configuration

    /// Global cap on simultaneous transfers across all sites.
    public private(set) var maxConcurrent: Int
    public private(set) var conflictPolicy: ConflictPolicy
    public var preserveTimestamps: Bool
    /// Source newer than destination by more than this counts as "newer".
    public var timestampTolerance: TimeInterval = 1
    /// How many top-level jobs `TransferSnapshot.jobs` carries.
    public var topLevelPreviewLimit = 100
    public nonisolated let log = LogHub()
    /// Minimum time between published snapshots (about 4 per second by default).
    public nonisolated let publishInterval: TimeInterval

    let resolver: ConflictResolver?
    let tempDirectory: URL
    let progressInterval: TimeInterval
    let clock: any DockyardClock
    let writer: any DatabaseWriter
    let siteProvider: (@Sendable (UUID) async -> TransferSite?)?
    let idleTimeout: TimeInterval
    let recoverAfter: Int
    let refusalRetryDelay: TimeInterval
    let maxRefusalRetries: Int
    let localFS = LocalFileSystem()

    // MARK: State

    final class ActiveJob {
        var record: JobRecord
        var task: Task<Void, Never>?
        var leases: [(site: SiteState, lease: SessionLease)] = []
        var cancelRequested = false
        var interrupted = false
        var progressDone: UInt64 = 0
        var progressTotal: UInt64 = 0
        init(_ record: JobRecord) { self.record = record }
    }

    struct Tracker {
        var record: JobRecord
        var pending: Int
        var failed = 0, cancelled = 0, skipped = 0
        /// The listing is still adding children, so a count of zero does not mean the folder is done.
        var listing = false
    }

    typealias Op = @Sendable (Database) throws -> Void

    var sites: [String: SiteState] = [:]
    var siteOrder: [String] = []
    var roundRobin = 0
    var active: [Int64: ActiveJob] = [:]
    var trackers: [Int64: Tracker] = [:]
    var stats = TransferStats()
    var nextId: Int64
    var adoptedKeys: [ObjectIdentifier: String] = [:]
    public internal(set) var isPaused = false
    /// Unfinished jobs found in the database when the queue was created. They stay paused until `resume()`.
    public let restoredJobCount: Int
    /// File-level counts left by the previous session: waiting to run, and failed (failed items stay listed until retried or cleared).
    public let restoredQueuedCount: Int
    public let restoredFailedCount: Int

    var ops: [Op] = []
    var rollupTotal: [Int64: Int64] = [:]
    var rollupDone: [Int64: Int64] = [:]
    var childrenDoneDelta: [Int64: Int] = [:]
    var flushTask: Task<Void, Never>?

    var wakeAt: Date?
    var wakeTask: Task<Void, Never>?
    var resolvingSites: Set<String> = []

    var subscribers: [UUID: AsyncStream<TransferSnapshot>.Continuation] = [:]
    var publishScheduled = false
    var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var finishWaiters: [Int64: [CheckedContinuation<TransferState, Never>]] = [:]
    var lastRateSample: (time: Date, bytes: UInt64)?
    var smoothedRate = 0.0

    /// Folder children skipped by transfer filters (in memory; reset by `removeFinished`).
    var filteredCount = 0
    var skipReasons: [SkipReason: Int] = [:]
    /// Decisions the user applied beyond one file. Batch, uploads and downloads end when the queue empties.
    var rememberedBatch: ConflictAction?
    var rememberedUploads: ConflictAction?
    var rememberedDownloads: ConflictAction?
    var rememberedSession: ConflictAction?
    /// Source path of each expanding top-level folder, to turn child paths into paths relative to the transfer root.
    var rootPaths: [Int64: String] = [:]

    var resolving = false
    var resolveWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        maxConcurrent: Int = 10,
        conflictPolicy: ConflictPolicy = .ask,
        resolver: ConflictResolver? = nil,
        preserveTimestamps: Bool = true,
        tempDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("dockyard-relay"),
        progressInterval: TimeInterval = 0.1,
        publishInterval: TimeInterval = 0.25,
        database: DockyardDatabase? = nil,
        clock: any DockyardClock = SystemClock(),
        siteProvider: (@Sendable (UUID) async -> TransferSite?)? = nil,
        idleTimeout: TimeInterval = 30,
        recoverAfter: Int = 10,
        refusalRetryDelay: TimeInterval = 2,
        maxRefusalRetries: Int = 8
    ) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.conflictPolicy = conflictPolicy
        self.resolver = resolver
        self.preserveTimestamps = preserveTimestamps
        self.tempDirectory = tempDirectory
        self.progressInterval = progressInterval
        self.publishInterval = publishInterval
        self.clock = clock
        self.siteProvider = siteProvider
        self.idleTimeout = idleTimeout
        self.recoverAfter = max(1, recoverAfter)
        self.refusalRetryDelay = refusalRetryDelay
        self.maxRefusalRetries = maxRefusalRetries
        // An in-memory database cannot fail to open.
        let db = database ?? (try! DockyardDatabase())
        writer = db.writer
        let recovered = (try? Self.recover(db.writer)) ?? Recovered()
        nextId = recovered.maxId + 1
        stats = recovered.stats
        restoredJobCount = recovered.unfinished
        restoredQueuedCount = recovered.stats.queued
        restoredFailedCount = recovered.stats.failed
        isPaused = recovered.unfinished > 0
        trackers = recovered.trackers
        for (key, label) in recovered.siteKeys {
            let state = SiteState(key: key, label: label)
            sites[key] = state
            siteOrder.append(key)
        }
        if sites[JobRecord.localKey] == nil {
            sites[JobRecord.localKey] = SiteState(key: JobRecord.localKey, label: "This Mac", empty: true)
            siteOrder.append(JobRecord.localKey)
        }
        if !recovered.trackers.isEmpty { Task { await self.settleRecoveredFolders() } }
    }

    // MARK: Sites

    /// Adds or updates a server. Jobs for it (including restored ones) use its pool and limits.
    public func register(site: TransferSite) {
        let key = site.id.uuidString
        let state = siteState(key, label: site.label)
        state.apply(site)
        pump()
    }

    public func setMaxConcurrent(_ n: Int) {
        maxConcurrent = max(1, n)
        pump()
    }

    /// Sets the policy for everything not yet decided (also clears a previous "apply to all").
    public func setConflictPolicy(_ policy: ConflictPolicy) { conflictPolicy = policy }

    /// Forgets every remembered "apply to" decision, including "this session".
    public func forgetConflictDecisions() {
        rememberedBatch = nil; rememberedUploads = nil; rememberedDownloads = nil; rememberedSession = nil
    }

    func siteState(_ key: String, label: String) -> SiteState {
        if let s = sites[key] { return s }
        let s = SiteState(key: key, label: label, empty: true)
        sites[key] = s
        siteOrder.append(key)
        return s
    }

    /// Scheduling key for an endpoint; nil for this Mac.
    func key(for endpoint: TransferEndpoint) -> String? {
        if endpoint.isLocal { return nil }
        let key: String
        if let id = endpoint.siteId {
            key = id.uuidString
        } else {
            let oid = ObjectIdentifier(endpoint.fs as AnyObject)
            if let existing = adoptedKeys[oid] { key = existing } else {
                key = UUID().uuidString
                adoptedKeys[oid] = key
            }
        }
        let state = siteState(key, label: endpoint.label)
        if !state.isPooled { state.shared = endpoint.fs }
        return key
    }

    // MARK: Enqueueing

    @discardableResult
    public func enqueue(_ request: TransferRequest) -> UUID {
        let id = enqueueRecord(request)
        pump()
        publishSoon()
        return id
    }

    @discardableResult
    public func enqueue(_ requests: [TransferRequest]) -> [UUID] {
        let ids = requests.map(enqueueRecord)
        pump()
        publishSoon()
        return ids
    }

    /// Queues listing items for copy/move into `destinationDirectory`.
    @discardableResult
    public func enqueue(
        items: [RemoteItem], from source: TransferEndpoint, to destination: TransferEndpoint,
        into destinationDirectory: String, move: Bool = false, conflict: ConflictPolicy? = nil
    ) -> [UUID] {
        enqueue(items.map { item in
            TransferRequest(
                source: source, sourcePath: item.path, destination: destination,
                destinationPath: RemotePath.join(destinationDirectory, item.name),
                isDirectory: item.isDirectory, size: item.size, modified: item.modified, deleteSourceAfter: move,
                conflictOverride: conflict)
        })
    }

    private func enqueueRecord(_ request: TransferRequest) -> UUID {
        let id = nextId
        nextId += 1
        let src = key(for: request.source), dst = key(for: request.destination)
        var record = JobRecord(
            id: id, parentId: nil, rootId: id, siteKey: src ?? dst ?? JobRecord.localKey, srcSite: src, dstSite: dst,
            srcLabel: request.source.label, dstLabel: request.destination.label,
            sourcePath: request.sourcePath, destPath: request.destinationPath, isDirectory: request.isDirectory,
            size: request.size, modified: request.modified, createParents: request.createParents,
            recursive: request.recursive, deleteSource: request.deleteSourceAfter, conflict: request.conflictOverride)
        record.state = .queued
        addQueued(record)
        return JobID.uuid(id)
    }

    /// Registers a new queued row: stats, persistence and the site's ready window.
    func addQueued(_ record: JobRecord) {
        stats.add(record)
        ops.append { db in try db.run(JobRecord.insertSQL, record.arguments) }
        scheduleFlush()
        let site = siteState(record.siteKey, label: record.siteKey == JobRecord.localKey ? "This Mac" : record.srcLabel)
        if record.isDirectory { site.dirs.add(record) } else { site.files.add(record) }
    }

    // MARK: Scheduling

    func pump() {
        let now = clock.now()
        reapIdle(now: now)
        if !isPaused {
            while active.count < maxConcurrent, let (site, record) = nextRunnable(now: now) {
                start(record, on: site, now: now)
            }
        }
        for site in sites.values {
            startRefills(site)
            if !site.isResolved { resolve(site) }
        }
        armWake(now: now)
        checkIdle()
    }

    private func nextRunnable(now: Date) -> (SiteState, JobRecord)? {
        let count = siteOrder.count
        guard count > 0 else { return nil }
        for offset in 0..<count {
            let index = (roundRobin + offset) % count
            guard let site = sites[siteOrder[index]], !site.isPaused, site.canStart(now: now) else { continue }
            guard let record = takeNext(from: site, now: now) else { continue }
            roundRobin = index + 1
            return (site, record)
        }
        return nil
    }

    /// Removes and returns the next record of `site` whose other side can also start.
    private func takeNext(from site: SiteState, now: Date) -> JobRecord? {
        func ready(_ r: JobRecord) -> Bool { otherSideCanStart(r, primary: site, now: now) }
        if let i = site.retry.firstIndex(where: { $0.due <= now && ready($0.record) }) {
            return site.retry.remove(at: i).record
        }
        let preferDirectory = site.files.window.count < 8
        let order: [ReferenceWritableKeyPath<SiteState, Lane>] = preferDirectory ? [\.dirs, \.files] : [\.files, \.dirs]
        for path in order {
            guard let head = site[keyPath: path].window.first, ready(head) else { continue }
            return site[keyPath: path].window.popFirst()
        }
        return nil
    }

    private func otherSideCanStart(_ record: JobRecord, primary: SiteState, now: Date) -> Bool {
        for key in [record.srcSite, record.dstSite] {
            guard let key, key != primary.key else { continue }
            guard let other = sites[key], !other.isPaused, other.canStart(now: now) else { return false }
        }
        return true
    }

    private func start(_ record: JobRecord, on primary: SiteState, now: Date) {
        var record = record
        stats.add(record, sign: -1)
        record.state = .running
        stats.add(record)
        persist(record)
        let job = ActiveJob(record)
        var seen = Set<String>()
        for key in [record.srcSite, record.dstSite, record.siteKey] {
            guard let key, seen.insert(key).inserted, let site = sites[key] else { continue }
            job.leases.append((site, site.reserve(now: now)))
        }
        if job.leases.isEmpty, let local = sites[JobRecord.localKey] { job.leases.append((local, .local)) }
        active[record.id] = job
        let id = record.id
        job.task = Task { await self.execute(id) }
        publishSoon()
    }

    /// Sessions beyond a lowered limit and sessions idle for too long are closed.
    private func reapIdle(now: Date) {
        for site in sites.values where site.isPooled && !site.idle.isEmpty {
            let doomed = site.excessIdle() + site.expiredIdle(now: now, timeout: idleTimeout)
            for fs in doomed { Task { await fs.disconnect() } }
        }
    }

    private func armWake(now: Date) {
        var next: Date?
        func consider(_ date: Date) { if date > now, next.map({ date < $0 }) ?? true { next = date } }
        for site in sites.values {
            for entry in site.retry { consider(entry.due) }
            if site.isPooled {
                if site.hasReadyWork && site.inUse < site.liveLimit { consider(site.nextConnectAt) }
                for entry in site.idle { consider(entry.since.addingTimeInterval(idleTimeout)) }
            }
        }
        guard let next else { return }
        if let wakeAt, wakeAt <= next, wakeTask != nil { return }
        wakeTask?.cancel()
        wakeAt = next
        let delay = next.timeIntervalSince(now)
        wakeTask = Task {
            do { try await clock.sleep(seconds: delay) } catch { return }
            self.wakeFired(next)
        }
    }

    /// Looks up a restored site's connection details; fails its jobs when the connection is gone.
    private func resolve(_ site: SiteState) {
        guard !resolvingSites.contains(site.key) else { return }
        resolvingSites.insert(site.key)
        let key = site.key
        let id = UUID(uuidString: key)
        let provider = siteProvider
        Task {
            var profile: TransferSite?
            if let id, let provider { profile = await provider(id) }
            self.siteResolved(key, profile)
        }
    }

    private func siteResolved(_ key: String, _ profile: TransferSite?) {
        resolvingSites.remove(key)
        guard let site = sites[key] else { return }
        if let profile {
            site.apply(profile)
        } else {
            persistActive()
            flushSync()
            try? writer.write { db in
                try db.run("UPDATE transferJob SET state = 3, error = ? WHERE siteKey = ? AND state = 0",
                           ["This connection no longer exists", key])
            }
            reloadStats()
            resetLanes()
            reloadTrackers()
            log.emit(.warning, "Dropped queued transfers for \(site.label): the connection no longer exists")
            site.shared = nil
        }
        pump()
    }

    private func wakeFired(_ at: Date) {
        guard wakeAt == at else { return }
        wakeAt = nil
        wakeTask = nil
        pump()
    }

    // MARK: Running a job

    struct Route {
        let src: any RemoteFileSystem
        let dst: any RemoteFileSystem
    }

    enum Outcome {
        case completed, skipped
        /// Folder listed; it now waits for its children.
        case waitingForChildren
    }

    private func execute(_ id: Int64) async {
        guard let job = active[id] else { return }
        var sessions: [String: any RemoteFileSystem] = [:]
        var connectingSite: SiteState?
        do {
            for (site, lease) in job.leases {
                connectingSite = site
                sessions[site.key] = try await session(for: site, lease: lease)
            }
            connectingSite = nil
        } catch {
            await conclude(job, sessions: sessions, outcome: .failure(error), phase: .connecting, culprit: connectingSite)
            return
        }
        let route = Route(
            src: job.record.srcSite.flatMap { sessions[$0] } ?? localFS,
            dst: job.record.dstSite.flatMap { sessions[$0] } ?? localFS)
        do {
            let outcome: Outcome
            if job.record.isDirectory {
                outcome = try await runFolder(job, route)
            } else {
                outcome = try await transferFile(job, route)
            }
            await conclude(job, sessions: sessions, outcome: .success(outcome), phase: .working, culprit: nil)
        } catch {
            await conclude(job, sessions: sessions, outcome: .failure(error), phase: .working, culprit: nil)
        }
    }

    private func session(for site: SiteState, lease: SessionLease) async throws -> any RemoteFileSystem {
        switch lease {
        case .idle(let fs), .shared(let fs): return fs
        case .local: return localFS
        case .connect:
            guard let profile = site.profile else { throw RemoteError.notConnected }
            log.emit(.status, "Opening connection to \(site.label) (\(site.inUse) of \(site.liveLimit))")
            let fs = try await profile.makeSession()
            do { try await fs.connect() } catch {
                await fs.disconnect()
                throw error
            }
            return fs
        }
    }

    /// Releases the job's sessions and applies the result: finish, retry or back off.
    private func conclude(
        _ job: ActiveJob, sessions: [String: any RemoteFileSystem], outcome: Result<Outcome, any Error>,
        phase: FailurePhase, culprit: SiteState?
    ) async {
        var failure: ConnectionFailure = .other
        var keepSessions = true
        if case .failure(let error) = outcome {
            failure = ConnectionFailureClassifier.classify(error, phase: phase)
            // A caller-owned session cannot be replaced, so there is nothing to retry or back off.
            if !job.leases.contains(where: { $0.site.isPooled }) { failure = .other }
            keepSessions = failure == .other && ConnectionFailureClassifier.sessionSurvives(error) && !job.cancelRequested && !job.interrupted
        }
        let primaryForRefusal = culprit ?? job.leases.map(\.site).first { $0.isPooled } ?? job.leases.first?.site

        if case .failure = outcome, failure == .refused, let site = primaryForRefusal, site.isPooled {
            site.noteRefusal(openConnections: site.inUse)
        }
        var toClose: [any RemoteFileSystem] = []
        for (site, lease) in job.leases {
            guard site.isPooled else { continue }
            site.inUse -= 1
            guard let fs = sessions[site.key] else { continue }
            let healthy: Bool
            if case .success = outcome { healthy = true } else { healthy = keepSessions }
            if healthy && site.live < site.liveLimit { site.idle.append((fs, clock.now())) } else { toClose.append(fs) }
            _ = lease
        }
        for fs in toClose { await fs.disconnect() }

        let finished: Bool
        switch outcome {
        case .success(let result):
            for (site, _) in job.leases where site.isPooled {
                if site.noteSuccess(recoverAfter: recoverAfter) {
                    log.emit(.status, "Raised the connection limit for \(site.label) to \(site.liveLimit)")
                }
            }
            switch result {
            case .completed: finish(job, .completed, error: nil)
            case .skipped: finish(job, .skipped, error: nil)
            case .waitingForChildren: if !job.record.state.isFinished { folderListed(job) }
            }
            finished = true
        case .failure(let error):
            finished = settleFailure(job, error: error, failure: failure, culprit: primaryForRefusal)
        }
        _ = finished
        active.removeValue(forKey: job.record.id)
        pump()
        publishSoon()
    }

    /// Decides what a failed run becomes. Returns false when the job was requeued.
    @discardableResult
    private func settleFailure(_ job: ActiveJob, error: any Error, failure: ConnectionFailure, culprit: SiteState?) -> Bool {
        if job.interrupted && !job.cancelRequested {
            requeue(job, after: 0, countAttempt: false)
            return false
        }
        if job.cancelRequested || error is CancellationError {
            finish(job, .cancelled, error: nil)
            return true
        }
        let site = culprit
        switch failure {
        case .refused:
            let attempts = job.record.attempts + 1
            if attempts > maxRefusalRetries {
                fail(job, "Server keeps refusing connections: \(Self.describe(error))")
                return true
            }
            let delay = min(30, refusalRetryDelay * pow(2, Double(attempts - 1)))
            log.emit(.warning, "\(site?.label ?? "Server") refused a connection (\(Self.describe(error))); allowing \(site.map { "\($0.liveLimit)" } ?? "fewer") at a time, retrying \(job.record.name) in \(Int(delay.rounded(.up))) s")
            requeue(job, after: delay, countAttempt: true)
            return false
        case .sessionLost:
            if job.record.attempts < 2 {
                log.emit(.warning, "Connection lost while transferring \(job.record.name); retrying on a new connection")
                requeue(job, after: 0, countAttempt: true)
                return false
            }
            fail(job, Self.describe(error))
            return true
        case .other:
            fail(job, Self.describe(error))
            return true
        }
    }

    func fail(_ job: ActiveJob, _ message: String) {
        if job.record.bytesDone > 0 { job.record.resume = true }
        log.emit(.error, "Failed: \(job.record.name) (\(job.record.route)): \(message)")
        finish(job, .failed, error: message)
    }

    private func requeue(_ job: ActiveJob, after delay: TimeInterval, countAttempt: Bool) {
        var record = job.record
        stats.add(record, sign: -1)
        record.state = .queued
        if countAttempt { record.attempts += 1 }
        if record.bytesDone > 0 && !record.isDirectory { record.resume = true }
        if record.isDirectory && !record.expanded {
            record.resume = true  // the listing may have added children already
            trackers.removeValue(forKey: record.id)
        }
        stats.add(record)
        persist(record)
        let site = siteState(record.siteKey, label: record.srcLabel)
        site.retry.append((clock.now().addingTimeInterval(delay), record))
    }

    // MARK: Finishing

    /// Marks the job finished and updates counters, persistence, parent folder and waiters.
    func finish(_ job: ActiveJob, _ state: TransferState, error: String?) {
        finish(&job.record, state, error: error)
    }

    func finish(_ record: inout JobRecord, _ state: TransferState, error: String?) {
        guard !record.state.isFinished else { return }
        stats.add(record, sign: -1)
        record.state = state
        record.error = error
        if state == .completed, !record.isDirectory {
            record.bytesDone = max(record.bytesDone, record.bytesTotal)
            record.bytesTotal = record.bytesDone
        }
        stats.add(record)
        persist(record)
        trackers.removeValue(forKey: record.id)
        if record.parentId == nil { rootPaths.removeValue(forKey: record.id) }
        if let parent = record.parentId {
            if !record.isDirectory, state == .completed { rollupDone[record.rootId, default: 0] += Int64(clamping: record.bytesDone) }
            childFinished(parent, state: state)
        }
        if let waiters = finishWaiters.removeValue(forKey: record.id) { for w in waiters { w.resume(returning: state) } }
    }

    func persist(_ record: JobRecord) {
        let r = record
        if r.isDirectory {
            ops.append { db in
                try db.run(
                    "UPDATE transferJob SET state=?, error=?, expanded=?, childCount=?, resume=?, attempts=?, destPath=? WHERE id=?",
                    [r.state.dbValue, r.error, r.expanded, r.childCount, r.resume, r.attempts, r.destPath, r.id])
            }
        } else {
            ops.append { db in
                try db.run(
                    "UPDATE transferJob SET state=?, bytesDone=?, bytesTotal=?, error=?, destPath=?, size=?, modified=?, resume=?, attempts=? WHERE id=?",
                    [r.state.dbValue, Int64(clamping: r.bytesDone), Int64(clamping: r.bytesTotal), r.error, r.destPath,
                                r.size.map { Int64(clamping: $0) }, r.modified?.timeIntervalSince1970, r.resume, r.attempts, r.id])
            }
        }
        scheduleFlush()
    }

    // MARK: Files

    private enum ConflictOutcome { case proceed, resume, skip(SkipReason), cancel }

    private func transferFile(_ job: ActiveJob, _ route: Route) async throws -> Outcome {
        let rec = job.record
        if rec.createParents { try await Self.ensureDirectory(route.dst, RemotePath.parent(of: rec.destPath)) }

        var resume = rec.resume
        var replacing = false
        if !resume, let existing = try await route.dst.lookup(rec.destPath) {
            switch try await resolveConflict(job, existing: existing, route: route) {
            case .proceed: replacing = job.record.destPath == rec.destPath
            case .resume: resume = true
            case .skip(let reason):
                skipReasons[reason, default: 0] += 1
                log.emit(.status, "Skipped \(job.record.name): \(reason == .unchanged ? "unchanged" : "already exists")")
                return .skipped
            case .cancel:
                job.cancelRequested = true
                throw CancellationError()
            }
        }
        job.record.resume = false
        if replacing, let hook = job.record.dstSite.flatMap({ sites[$0]?.profile?.beforeOverwrite }) {
            try await hook(job.record.destPath, route.dst)
        }
        if job.record.modified == nil && preserveTimestamps {
            job.record.modified = try? await route.src.lookup(rec.sourcePath)?.modified
        }
        if job.record.size == nil, let item = try? await route.src.lookup(rec.sourcePath) {
            updateTotal(job, size: item.size ?? 0)
        }
        let req = job.record
        log.emit(.status, "\(req.isRelay ? "Relaying" : (req.srcSite == nil ? "Uploading" : "Downloading")) \(req.name) (\(req.route))\(resume ? ", resuming" : "")")

        let id = req.id
        let sample: @Sendable (UInt64, UInt64) async -> Void = { [weak self] done, total in
            await self?.setProgress(id, done: done, total: total)
        }
        try await Self.perform(req, route: route, resume: resume, tempRoot: tempDirectory,
                               preserveTimestamps: preserveTimestamps, interval: progressInterval, sample: sample)
        if job.cancelRequested { throw CancellationError() }
        try await verifyChecksum(job.record, route)
        job.record.bytesDone = max(job.progressDone, job.record.bytesTotal)
        if req.deleteSource { try await route.src.delete(req.sourcePath, recursive: false) }
        log.emit(.status, "Completed \(req.name) (\(req.route))")
        return .completed
    }

    /// After an upload or download on a site that asks for it. Server to server copies are not checked.
    private func verifyChecksum(_ rec: JobRecord, _ route: Route) async throws {
        guard (rec.srcSite == nil) != (rec.dstSite == nil) else { return }
        let uploading = rec.srcSite == nil
        guard let key = uploading ? rec.dstSite : rec.srcSite, sites[key]?.profile?.verifyChecksums == true else { return }
        let result = await ChecksumVerifier.verify(
            local: URL(fileURLWithPath: uploading ? rec.sourcePath : rec.destPath),
            remote: uploading ? rec.destPath : rec.sourcePath, on: uploading ? route.dst : route.src)
        switch result {
        case .match: log.emit(.status, "Verified checksum of \(rec.name)")
        case .unavailable(let reason): log.emit(.warning, "Checksum of \(rec.name) not verified: \(reason)")
        case .mismatch(let local, let remote):
            log.emit(.error, "Checksum mismatch for \(rec.name): this Mac \(local), server \(remote)")
            throw RemoteError.protocolError("Checksum mismatch: the copy on the server differs from the local file")
        }
    }

    private func updateTotal(_ job: ActiveJob, size: UInt64) {
        stats.add(job.record, sign: -1)
        let old = job.record.bytesTotal
        job.record.size = size
        job.record.bytesTotal = size
        stats.add(job.record)
        if job.record.parentId != nil { rollupTotal[job.record.rootId, default: 0] += Int64(clamping: size) - Int64(clamping: old) }
    }

    private func setProgress(_ id: Int64, done: UInt64, total: UInt64) {
        guard let job = active[id], !job.record.isDirectory else { return }
        let known = max(total, done)
        if known > job.record.bytesTotal { updateTotal(job, size: known) }
        job.progressDone = done
        job.record.bytesDone = done
        job.progressTotal = max(total, job.record.bytesTotal)
        publishSoon()
    }

    private func resolveConflict(_ job: ActiveJob, existing: RemoteItem, route: Route) async throws -> ConflictOutcome {
        if existing.isDirectory {
            throw RemoteError.protocolError("A folder named \(job.record.name) already exists at the destination")
        }
        let action = await decideConflict(job, existing: existing)
        switch action {
        case .overwrite: return .proceed
        case .skip: return .skip(.kept)
        case .cancel: return .cancel
        case .overwriteIfNewer, .overwriteIfDifferent, .overwriteIfSizeDiffers, .resume:
            var size = job.record.size, modified = job.record.modified
            if size == nil || modified == nil, let source = try? await route.src.lookup(job.record.sourcePath) {
                size = size ?? source.size
                modified = modified ?? source.modified
            }
            if action == .resume {
                guard let size, let have = existing.size else { return .proceed }
                if have == size { return .skip(.unchanged) }
                return have < size ? .resume : .proceed
            }
            let replace = action.replaces(
                sourceSize: size, sourceModified: modified, destinationSize: existing.size,
                destinationModified: existing.modified, tolerance: timestampTolerance)
            return replace ? .proceed : .skip(.unchanged)
        case .rename:
            var n = 1
            let dir = RemotePath.parent(of: job.record.destPath)
            let base = RemotePath.lastComponent(of: job.record.destPath)
            while true {
                let candidate = RemotePath.join(dir, FileNaming.numbered(base, n))
                if try await route.dst.lookup(candidate) == nil {
                    job.record.destPath = candidate
                    return .proceed
                }
                n += 1
            }
        }
    }

    /// The per-batch override, then remembered "apply to" decisions, the site's default and the queue's policy; otherwise ask.
    /// Prompts are serialised, so a decision applied to later files is in place before the next one is asked.
    private func decideConflict(_ job: ActiveJob, existing: RemoteItem) async -> ConflictAction {
        while resolving { await withCheckedContinuation { resolveWaiters.append($0) } }
        resolving = true
        defer {
            resolving = false
            if !resolveWaiters.isEmpty { resolveWaiters.removeFirst().resume() }
        }
        let rec = job.record
        let direction = rec.direction
        let siteDefault = [rec.dstSite, rec.srcSite].compactMap { $0.flatMap { sites[$0]?.profile?.defaultConflict } }.first { $0 != .ask }
        let known = rec.conflict?.action
            ?? (direction == .upload ? rememberedUploads : nil)
            ?? (direction == .download ? rememberedDownloads : nil)
            ?? rememberedBatch ?? rememberedSession
            ?? siteDefault?.action ?? conflictPolicy.action
        if let known { return known }
        guard let resolver else { return .skip }  // nobody to ask: never overwrite silently
        let info = ConflictInfo(
            jobId: JobID.uuid(rec.id), name: rec.name, route: rec.route, sourcePath: rec.sourcePath, destinationPath: rec.destPath,
            sourceSize: rec.size, sourceModified: rec.modified, destinationSize: existing.size, destinationModified: existing.modified,
            direction: direction)
        let decision = await resolver(info)
        if decision.action == .cancel {
            if decision.scope != .thisFile { Task { await self.cancelAll() } }
            return .cancel
        }
        switch decision.scope {
        case .thisFile: break
        case .allRemaining: rememberedBatch = decision.action
        case .uploadsOnly: rememberedUploads = decision.action
        case .downloadsOnly: rememberedDownloads = decision.action
        case .session: rememberedSession = decision.action
        }
        return decision.action
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
        _ req: JobRecord, route: Route, resume: Bool, tempRoot: URL, preserveTimestamps: Bool, interval: TimeInterval,
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
            try await move(req, route: route, resume: resume, box: box, tempRoot: tempRoot)
        } catch {
            let (d, t) = box.sample
            await sample(d, t)  // so a retry knows a partial file exists
            throw error
        }
        let (d, t) = box.sample
        await sample(max(d, t), t)
        if preserveTimestamps, req.dstSite == nil, let m = req.modified {
            try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: req.destPath)
        }
    }

    private static func move(_ req: JobRecord, route: Route, resume: Bool, box: ProgressBox, tempRoot: URL) async throws {
        if req.srcSite == nil {
            try await route.dst.upload(URL(fileURLWithPath: req.sourcePath), to: req.destPath, progress: box.first, resume: resume)
        } else if req.dstSite == nil {
            try await route.src.download(req.sourcePath, to: URL(fileURLWithPath: req.destPath), progress: box.first, resume: resume)
        } else {
            let dir = tempRoot.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let temp = dir.appendingPathComponent(RemotePath.lastComponent(of: req.sourcePath))
            try await route.src.download(req.sourcePath, to: temp, progress: box.first, resume: false)
            try Task.checkCancellation()
            try await route.dst.upload(temp, to: req.destPath, progress: box.second, resume: resume)
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
