import ConnectionKit
import DockyardCore
import Foundation
import Observation

/// What a watch link has done so far in this run.
struct WatchStatus: Equatable {
    var uploaded = 0
    var deleted = 0
    var skipped = 0
    var lastActivity: Date?
    var message: String?
}

/// Watch folders: local folders linked to server folders, uploaded automatically through the queue (HANDOFF 11).
@MainActor @Observable
final class WatchCenter {
    private static let storageKey = "watchLinks"

    private(set) var links: [WatchLink] = []
    private(set) var status: [UUID: WatchStatus] = [:]

    @ObservationIgnored private var runners: [UUID: Runner] = [:]

    private final class Runner {
        let coordinator: WatchCoordinator
        var tasks: [Task<Void, Never>] = []
        init(coordinator: WatchCoordinator) { self.coordinator = coordinator }
        func stop() {
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
            let coordinator = coordinator
            Task { await coordinator.stop() }
        }
    }

    init() {
        guard !DemoMode.isEnabled, let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode([WatchLink].self, from: data) else { return }
        links = saved
    }

    /// Links that are watching right now.
    var activeCount: Int { links.filter { !$0.paused }.count }

    func start() {
        for link in links where !link.paused { run(link, catchUp: true) }
    }

    // MARK: Editing

    func add(_ link: WatchLink) {
        links.append(link)
        save()
        run(link, catchUp: false)
    }

    func remove(_ id: UUID) {
        runners.removeValue(forKey: id)?.stop()
        links.removeAll { $0.id == id }
        status.removeValue(forKey: id)
        save()
    }

    func setPaused(_ paused: Bool, for id: UUID) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        links[index].paused = paused
        save()
        guard let runner = runners[id] else {
            if !paused { run(links[index], catchUp: true) }
            return
        }
        let coordinator = runner.coordinator
        if paused {
            Task { await coordinator.pause() }
        } else {
            let link = links[index]
            Task { if await coordinator.resume() { await self.catchUp(link) } }
        }
    }

    func setMirrorDeletes(_ on: Bool, for id: UUID) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        links[index].mirrorDeletes = on
        save()
        // The coordinator plans with its own copy of the link, so a new one takes over.
        runners.removeValue(forKey: id)?.stop()
        if !links[index].paused { run(links[index], catchUp: false) }
    }

    private func save() {
        guard !DemoMode.isEnabled, let data = try? JSONEncoder().encode(links) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    // MARK: Running

    private func run(_ saved: WatchLink, catchUp wantsCatchUp: Bool) {
        guard !DemoMode.isEnabled, runners[saved.id] == nil else { return }
        let app = AppModel.shared
        let userRules = AppSettings.globalFilterPatterns.filter { !TransferFilter.globalDefaults.contains($0) }
        var prepared = saved
        prepared.filterPatterns = userRules + (app.allConnections.first { $0.id == saved.connectionId }?.transferFilters ?? [])
        let link = prepared
        guard FileManager.default.fileExists(atPath: link.localRoot) else {
            status[link.id, default: WatchStatus()].message = "The local folder is missing"
            return
        }
        let coordinator = WatchCoordinator(link: link)
        let runner = Runner(coordinator: coordinator)
        let events = FSEventsSource.events(for: link.localRoot)
        runner.tasks = [
            Task { await coordinator.run(source: events) },
            Task { [weak self] in
                for await plan in coordinator.plans { await self?.apply(plan.items, skipped: plan.skippedByFilter, link: link, override: .overwrite) }
            },
        ]
        runners[link.id] = runner
        if wantsCatchUp { Task { await catchUp(link) } }
    }

    /// Uploads what changed while nothing was watching: newer local files only, found by walking the folder.
    private func catchUp(_ link: WatchLink) async {
        let root = link.localRoot
        let events = await Task.detached(priority: .utility) { Self.walk(root) }.value
        let plan = WatchPlanner.plan(events, for: link)
        let uploads = plan.items.filter { item in
            switch item {
            case .upload, .makeDirectory: true
            default: false
            }
        }
        if !uploads.isEmpty { await apply(uploads, skipped: plan.skippedByFilter, link: link, override: .overwriteIfNewer) }
    }

    private nonisolated static func walk(_ root: String) -> [WatchEvent] {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var out: [WatchEvent] = []
        for case let relative as String in walker {
            let path = root + "/" + relative
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { continue }
            out.append(WatchEvent(path: path, kind: .created, isDirectory: directory.boolValue))
        }
        return out
    }

    // MARK: Applying a plan

    private func apply(_ items: [WatchWorkItem], skipped: Int, link: WatchLink, override: ConflictPolicy) async {
        let app = AppModel.shared
        guard let connection = app.allConnections.first(where: { $0.id == link.connectionId }) else {
            status[link.id, default: WatchStatus()].message = "The connection no longer exists"
            return
        }
        let log = app.session(for: connection.id)?.log
        if case .deny(let reason) = Guardrails.decide(GuardedOperation(.upload, paths: []), for: connection) {
            status[link.id, default: WatchStatus()].message = reason
            log?.append(.warning, "Watch folder: \(reason)")
            return
        }
        var entry = status[link.id, default: WatchStatus()]
        entry.skipped += skipped
        entry.message = nil

        let endpoint = await app.transferEndpoint(for: connection)
        let local = TransferEndpoint.thisMac()
        var requests: [TransferRequest] = []
        var removals: [WatchWorkItem] = []
        for item in items {
            switch item {
            case .makeDirectory(let remote):
                requests.append(TransferRequest(
                    source: local, sourcePath: Self.localPath(for: remote, link: link), destination: endpoint,
                    destinationPath: remote, isDirectory: true, createParents: true, recursive: false))
            case .upload(let path, let remote):
                requests.append(TransferRequest(
                    source: local, sourcePath: path, destination: endpoint, destinationPath: remote,
                    createParents: true, conflictOverride: override))
            case .rename, .delete:
                removals.append(item)
            }
        }
        if !requests.isEmpty {
            let files = requests.filter { !$0.isDirectory }.count
            await app.queue.enqueue(requests)
            entry.uploaded += files
            log?.append(.status, "Watch folder: queued \(files) upload\(files == 1 ? "" : "s") from \(link.localRoot) to \(link.remoteRoot)")
        }
        if !removals.isEmpty { entry.deleted += await mirror(removals, connection: connection, link: link) }
        entry.lastActivity = Date()
        status[link.id] = entry
    }

    private nonisolated static func localPath(for remote: String, link: WatchLink) -> String {
        let prefix = link.remoteRoot.hasSuffix("/") ? link.remoteRoot : link.remoteRoot + "/"
        let relative = remote.hasPrefix(prefix) ? String(remote.dropFirst(prefix.count)) : RemotePath.lastComponent(of: remote)
        return link.localRoot + "/" + relative
    }

    /// Mirrored renames and deletes. They run on a session of their own (or the open tab) after the guardrails.
    private func mirror(_ items: [WatchWorkItem], connection: Connection, link: WatchLink) async -> Int {
        let app = AppModel.shared
        let log = app.session(for: connection.id)?.log
        let deletePaths: [String] = items.compactMap { if case .delete(let remote, _) = $0 { remote } else { nil } }
        switch Guardrails.decide(GuardedOperation(.delete, paths: deletePaths), for: connection) {
        case .deny(let reason):
            log?.append(.warning, "Watch folder: \(reason)")
            return 0
        case .confirm(let summary):
            let request = ConfirmRequest(
                title: "Mirror \(deletePaths.count) delete\(deletePaths.count == 1 ? "" : "s") to \(connection.name)?",
                message: "\(link.localRoot) is linked to a PROD site with Mirror deletes on.", confirmTitle: "Delete on Server",
                items: summary.items)
            guard await app.prompts.askConfirm(request) else { return 0 }
        case .allow:
            break
        }
        let open = app.session(for: connection.id)?.fs
        let fs: any RemoteFileSystem
        if let open { fs = open } else {
            guard let made = try? app.makeQueueSession(for: connection), (try? await made.connect()) != nil else {
                log?.append(.error, "Watch folder: could not connect to mirror deletes")
                return 0
            }
            fs = made
        }
        let net = app.safetyNet(for: connection)
        var done = 0
        for item in items {
            do {
                switch item {
                case .rename(let from, let to):
                    try await fs.rename(from, to)
                    done += 1
                case .delete(let remote, let isDirectory):
                    let outcome = try await net.prepareDelete(path: remote, on: fs)
                    if outcome.originalStillInPlace { try await fs.delete(remote, recursive: isDirectory) }
                    done += 1
                default:
                    break
                }
            } catch {
                log?.append(.error, "Watch folder: \(error.userMessage)")
            }
        }
        if open == nil { await fs.disconnect() }
        if done > 0 { log?.append(.status, "Watch folder: mirrored \(done) change\(done == 1 ? "" : "s") to \(link.remoteRoot)") }
        return done
    }

    // MARK: Demo

    func seedDemo(_ seeded: [WatchLink], status seededStatus: [UUID: WatchStatus]) {
        links = seeded
        status = seededStatus
    }
}
