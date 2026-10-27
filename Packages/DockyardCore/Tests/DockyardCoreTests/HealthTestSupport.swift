import Foundation
import ConnectionKit
@testable import DockyardCore

/// Counts how many sessions are open per host and how often each host was contacted.
final class SessionTracker: Sendable {
    struct State {
        var active: [String: Int] = [:]
        var peak: [String: Int] = [:]
        var peakTotal = 0
        var connects: [String: Int] = [:]
        var connectOrder: [UUID] = []
    }
    private let state = LockedBox(State())

    var peakPerHost: [String: Int] { state.withLock { $0.peak } }
    var peakTotal: Int { state.withLock { $0.peakTotal } }
    var connects: [String: Int] { state.withLock { $0.connects } }
    var connectOrder: [UUID] { state.withLock { $0.connectOrder } }

    func opened(host: String, id: UUID) {
        state.withLock { s in
            s.active[host, default: 0] += 1
            s.peak[host] = max(s.peak[host] ?? 0, s.active[host] ?? 0)
            s.peakTotal = max(s.peakTotal, s.active.values.reduce(0, +))
            s.connects[host, default: 0] += 1
            s.connectOrder.append(id)
        }
    }

    func closed(host: String) { state.withLock { $0.active[host, default: 1] -= 1 } }
}

/// Wraps a file system and records its open sessions, from the start of `connect` until `disconnect`.
final class TrackedFileSystem: RemoteFileSystem {
    let inner: any RemoteFileSystem
    let tracker: SessionTracker
    let host: String
    let id: UUID
    private let open = LockedBox(false)

    init(_ inner: any RemoteFileSystem, tracker: SessionTracker, connection: Connection) {
        self.inner = inner
        self.tracker = tracker
        self.host = HealthChecker.hostKey(for: connection)
        self.id = connection.id
    }

    var logStream: AsyncStream<LogLine> { inner.logStream }
    var supportsShell: Bool { inner.supportsShell }

    func connect() async throws {
        if open.withLock({ let was = $0; $0 = true; return !was }) { tracker.opened(host: host, id: id) }
        try await inner.connect()
    }

    func disconnect() async {
        await inner.disconnect()
        if open.withLock({ let was = $0; $0 = false; return was }) { tracker.closed(host: host) }
    }

    func list(_ path: String) async throws -> [RemoteItem] { try await inner.list(path) }
    func download(_ remote: String, to local: URL, progress: Progress, resume: Bool) async throws {
        try await inner.download(remote, to: local, progress: progress, resume: resume)
    }
    func upload(_ local: URL, to remote: String, progress: Progress, resume: Bool) async throws {
        try await inner.upload(local, to: remote, progress: progress, resume: resume)
    }
    func mkdir(_ path: String) async throws { try await inner.mkdir(path) }
    func rename(_ from: String, _ to: String) async throws { try await inner.rename(from, to) }
    func delete(_ path: String, recursive: Bool) async throws { try await inner.delete(path, recursive: recursive) }
    func chmod(_ path: String, mode: UInt16) async throws { try await inner.chmod(path, mode: mode) }
    func homeDirectory() async throws -> String { try await inner.homeDirectory() }
}

/// A server that answers a scripted way.
struct ScriptedFileSystem: RemoteFileSystem {
    enum Behavior: Sendable {
        case ok
        case fail(RemoteError)
        case failWith(any Error)
        case hang
    }

    var behavior: Behavior
    var delay: Duration = .milliseconds(20)

    var logStream: AsyncStream<LogLine> { AsyncStream { $0.finish() } }
    var supportsShell: Bool { false }

    func connect() async throws {
        switch behavior {
        case .ok: try await Task.sleep(for: delay)
        case .fail(let error): try await Task.sleep(for: delay); throw error
        case .failWith(let error): try await Task.sleep(for: delay); throw error
        case .hang: try await Task.sleep(for: .seconds(600))
        }
    }

    func disconnect() async {}
    func homeDirectory() async throws -> String { "/home/u" }
    func list(_ path: String) async throws -> [RemoteItem] { [] }
    func download(_ remote: String, to local: URL, progress: Progress, resume: Bool) async throws {}
    func upload(_ local: URL, to remote: String, progress: Progress, resume: Bool) async throws {}
    func mkdir(_ path: String) async throws {}
    func rename(_ from: String, _ to: String) async throws {}
    func delete(_ path: String, recursive: Bool) async throws {}
    func chmod(_ path: String, mode: UInt16) async throws {}
}

func healthResults(_ events: [HealthEvent]) -> [UUID: ConnectionHealth] {
    var out: [UUID: ConnectionHealth] = [:]
    for case .result(let health, _) in events { out[health.connectionId] = health }
    return out
}

func healthSkips(_ events: [HealthEvent]) -> [UUID] {
    events.compactMap { if case .skipped(let id, _, _) = $0 { id } else { nil } }
}

func collect(_ stream: AsyncStream<HealthEvent>) async -> [HealthEvent] {
    var events: [HealthEvent] = []
    for await event in stream { events.append(event) }
    return events
}
