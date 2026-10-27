import Foundation
import ConnectionKit

/// Saves session state with a debounce so rapid tab changes produce one write.
public actor SessionSaver {
    private let repository: SessionRepository
    private let clock: any DockyardClock
    private let debounce: TimeInterval
    private var pending: [UUID: SessionState] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generation: [UUID: Int] = [:]
    private var onError: (@Sendable (any Error) -> Void)?

    public init(repository: SessionRepository, clock: any DockyardClock = SystemClock(), debounce: TimeInterval = 1.0,
                onError: (@Sendable (any Error) -> Void)? = nil) {
        self.repository = repository
        self.clock = clock
        self.debounce = debounce
        self.onError = onError
    }

    /// Call on every tab/tree change. The latest state is written `debounce` seconds after the last call.
    public func update(_ state: SessionState) {
        let id = state.connectionId
        pending[id] = state
        tasks[id]?.cancel()
        let gen = (generation[id] ?? 0) + 1
        generation[id] = gen
        let clock = self.clock, delay = debounce
        tasks[id] = Task { [weak self] in
            do { try await clock.sleep(seconds: delay) } catch { return }
            await self?.fire(id, generation: gen)
        }
    }

    private func fire(_ id: UUID, generation gen: Int) async {
        guard generation[id] == gen else { return }
        tasks[id] = nil
        await write(id)
    }

    private func write(_ id: UUID) async {
        guard var state = pending.removeValue(forKey: id) else { return }
        state.savedAt = clock.now()
        do { try await repository.save(state) } catch { onError?(error) }
    }

    /// Saves immediately (disconnect).
    public func flush(_ connectionId: UUID) async {
        tasks[connectionId]?.cancel()
        tasks[connectionId] = nil
        generation[connectionId] = (generation[connectionId] ?? 0) + 1
        await write(connectionId)
    }

    /// Saves everything pending (quit).
    public func flushAll() async {
        for id in Array(pending.keys) { await flush(id) }
    }

    /// Drops anything pending without saving.
    public func discard(_ connectionId: UUID) {
        tasks[connectionId]?.cancel()
        tasks[connectionId] = nil
        pending[connectionId] = nil
        generation[connectionId] = (generation[connectionId] ?? 0) + 1
    }

    public var hasPending: Bool { !pending.isEmpty }
}

public struct RestoredSession: Sendable, Equatable {
    /// The state with missing paths removed and active indexes fixed up.
    public var state: SessionState
    public var restoredRemoteTabs: Int
    public var restoredLocalTabs: Int
    public var droppedRemote: [String]
    public var droppedLocal: [String]
    /// The text for the slim notice, nil when nothing was restored.
    public var notice: String?
}

public enum SessionRestorer {
    public typealias Logger = @Sendable (LogLine.Kind, String) -> Void

    /// Validates every saved folder against the live file systems. Missing folders are dropped with a log line.
    public static func restore(
        _ saved: SessionState,
        local: any RemoteFileSystem,
        remote: any RemoteFileSystem,
        log: Logger = { _, _ in },
        timeZone: TimeZone = .current
    ) async -> RestoredSession {
        let (rTabs, rActive, rDropped) = await validate(saved.remoteTabs, active: saved.activeRemoteTab, fs: remote, side: "server", log: log)
        let (lTabs, lActive, lDropped) = await validate(saved.localTabs, active: saved.activeLocalTab, fs: local, side: "local", log: log)
        var state = saved
        state.remoteTabs = rTabs
        state.localTabs = lTabs
        state.activeRemoteTab = rActive
        state.activeLocalTab = lActive
        state.remoteTreeExpanded = saved.remoteTreeExpanded.filter { p in !rDropped.contains { p == $0 || p.hasPrefix($0 + "/") } }
        state.localTreeExpanded = saved.localTreeExpanded.filter { p in !lDropped.contains { p == $0 || p.hasPrefix($0 + "/") } }
        return RestoredSession(
            state: state, restoredRemoteTabs: rTabs.count, restoredLocalTabs: lTabs.count,
            droppedRemote: rDropped, droppedLocal: lDropped,
            notice: notice(remote: rTabs.count, local: lTabs.count, savedAt: saved.savedAt, timeZone: timeZone))
    }

    public static func notice(remote: Int, local: Int, savedAt: Date, timeZone: TimeZone = .current) -> String? {
        var parts: [String] = []
        if remote > 0 { parts.append("\(remote) server \(remote == 1 ? "folder" : "folders")") }
        if local > 0 { parts.append("\(local) local \(local == 1 ? "folder" : "folders")") }
        guard !parts.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MMM d"
        return "Restored your last session: \(parts.joined(separator: " and ")), as you left them \(f.string(from: savedAt))"
    }

    private static func validate(_ tabs: [TabState], active: Int, fs: any RemoteFileSystem, side: String, log: Logger)
        async -> ([TabState], Int, [String]) {
        var cache: [String: [RemoteItem]?] = [:]
        var kept: [TabState] = []
        var dropped: [String] = []
        var newActive: Int?
        for (i, tab) in tabs.enumerated() {
            if await isDirectory(tab.path, fs: fs, cache: &cache) {
                if i == active { newActive = kept.count }
                kept.append(tab)
            } else {
                dropped.append(tab.path)
                log(.warning, "Session restore: \(side) folder \(tab.path) no longer exists, tab dropped")
            }
        }
        let fallback = kept.isEmpty ? 0 : min(max(0, active), kept.count - 1)
        return (kept, newActive ?? fallback, dropped)
    }

    private static func isDirectory(_ path: String, fs: any RemoteFileSystem, cache: inout [String: [RemoteItem]?]) async -> Bool {
        if path == "/" { return true }
        let parent = RemotePath.parent(of: path)
        if cache[parent] == nil { cache[parent] = .some(try? await fs.list(parent)) }
        if let listing = cache[parent] ?? nil {
            let name = RemotePath.lastComponent(of: path)
            return listing.contains { $0.name == name && $0.isDirectory }
        }
        // Parent not listable (permissions); try the folder itself.
        return (try? await fs.list(path)) != nil
    }
}

/// High level entry points the app calls when a connection opens and closes.
public struct SessionService: Sendable {
    public let repository: SessionRepository
    public let saver: SessionSaver

    public init(repository: SessionRepository, saver: SessionSaver) {
        self.repository = repository
        self.saver = saver
    }

    /// Returns the validated last session, or nil when the connection opts out or has none.
    public func prepareRestore(
        for connection: Connection, local: any RemoteFileSystem, remote: any RemoteFileSystem,
        log: SessionRestorer.Logger = { _, _ in }, timeZone: TimeZone = .current
    ) async throws -> RestoredSession? {
        guard connection.restoreSession, let saved = try await repository.load(connection.id) else { return nil }
        let restored = await SessionRestorer.restore(saved, local: local, remote: remote, log: log, timeZone: timeZone)
        return restored.restoredLocalTabs + restored.restoredRemoteTabs > 0 ? restored : nil
    }

    /// "Start fresh": forget the saved session.
    public func startFresh(connectionId: UUID) async throws {
        await saver.discard(connectionId)
        try await repository.clear(connectionId)
    }
}
