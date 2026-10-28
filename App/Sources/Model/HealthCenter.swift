import ConnectionKit
import DockyardCore
import Foundation
import Observation

/// Host keys the non-prompting validator turned away because they are not trusted yet.
/// The health run reads this to tell "Unknown host key" apart from "Host key changed".
actor UnknownHostKeys {
    private var endpoints: Set<String> = []

    static func key(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

    func insert(host: String, port: Int) { endpoints.insert(Self.key(host: host, port: port)) }

    func containsAny(_ keys: [String]) -> Bool { keys.contains(where: endpoints.contains) }
}

enum HealthMessages {
    static let unknownHostKey = "Unknown host key: connect once to trust it"
}

/// What one health run needs besides the connections: how to open them without prompting and which secrets to use.
struct HealthEnvironment: Sendable {
    var secrets: any SecretStore
    var makeFileSystem: HealthChecker.FileSystemMaker
    var unknownHosts: UnknownHostKeys
    var connections: [UUID: Connection]

    /// Builds file systems that never ask the user anything. A trusted host key passes, anything else is rejected
    /// (and remembered as unknown when the host was simply not seen before).
    static func make(
        secrets: any SecretStore, knownHosts: KnownHostRepository, connections: [Connection]
    ) -> HealthEnvironment {
        let unknown = UnknownHostKeys()
        let lookup = Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        @Sendable func validator(host: String, port: Int) -> SSHHostKeyValidator {
            SSHHostKeyValidator { key in
                let verdict = (try? await knownHosts.verdict(
                    host: host, port: port, keyType: key.algorithm, fingerprint: key.fingerprint)) ?? .unknown
                switch verdict {
                case .trusted:
                    return true
                case .unknown:
                    await unknown.insert(host: host, port: port)
                    return false
                case .changed:
                    return false
                }
            }
        }

        let maker: HealthChecker.FileSystemMaker = { connection in
            var hops: [SSHJumpHop] = []
            if connection.protocol == .sftp, connection.jumpHost != nil {
                hops = try JumpChain.resolve(for: connection, lookup: { lookup[$0] }).map { hop in
                    SSHJumpHop(config: hop.config, secrets: secrets, hostKeyValidator: validator(host: hop.host, port: hop.port))
                }
            }
            return try FileSystemFactory.make(
                for: connection, secrets: secrets,
                hostKeyValidator: validator(host: connection.host, port: connection.port), jumpHops: hops)
        }
        return HealthEnvironment(secrets: secrets, makeFileSystem: maker, unknownHosts: unknown, connections: lookup)
    }

    /// A rejected host key reads as "Host key changed"; when the key was only unknown the stored message says so.
    func correcting(_ health: ConnectionHealth) async -> ConnectionHealth? {
        guard health.status == .hostKeyChanged, let connection = connections[health.connectionId] else { return nil }
        var endpoints = [UnknownHostKeys.key(host: connection.host, port: connection.port)]
        if let chain = try? JumpChain.resolve(for: connection, lookup: { connections[$0] }) {
            endpoints += chain.map { UnknownHostKeys.key(host: $0.host, port: $0.port) }
        }
        guard await unknownHosts.containsAny(endpoints) else { return nil }
        var corrected = health
        corrected.message = HealthMessages.unknownHostKey
        return corrected
    }
}

/// Connection health for the manager: the stored results, the run in progress and the last run's summary.
@MainActor @Observable
final class HealthCenter {
    struct Run: Equatable {
        var total: Int
        var completed = 0
        var testing: Set<UUID> = []
        var cancelling = false
    }

    struct Summary: Equatable {
        var tested: Int
        var ok: Int
        var failing: Int
        var paused: Int
        var cancelled: Bool

        var text: String {
            var parts = ["\(ok) OK", "\(failing) failing"]
            if paused > 0 { parts.append("\(paused) paused to avoid lockout") }
            return (cancelled ? "Stopped after \(tested): " : "Tested \(tested): ") + parts.joined(separator: ", ")
        }
    }

    private(set) var latest: [UUID: ConnectionHealth] = [:]
    /// Bumped whenever a stored result changes, so lists filtered by status reload.
    private(set) var revision = 0
    private(set) var run: Run?
    /// Connections a run skipped because their host kept rejecting logins. Cleared by the next run.
    private(set) var paused: Set<UUID> = []
    private(set) var summary: Summary?

    @ObservationIgnored let repository: ConnectionHealthRepository
    @ObservationIgnored private let checker: HealthChecker
    @ObservationIgnored private var task: Task<Void, Never>?

    init(repository: ConnectionHealthRepository) {
        self.repository = repository
        self.checker = HealthChecker(repository: repository)
    }

    var isRunning: Bool { run != nil }

    func startObserving() {
        let repository = repository
        Task { [weak self] in
            for await results in repository.observeLatest() {
                guard let self else { return }
                self.latest = results
                self.revision += 1
            }
        }
    }

    // MARK: Runs

    /// Shows the progress bar at once and runs `body`, which prepares the run and calls `execute`.
    func launch(total: Int, _ body: @escaping @MainActor (HealthCenter) async -> Void) {
        run = Run(total: total)
        paused = []
        summary = nil
        task = Task {
            await body(self)
            self.run = nil
            self.task = nil
        }
    }

    func cancel() {
        guard run != nil else { return }
        run?.cancelling = true
        task?.cancel()
        let checker = checker
        Task { await checker.cancel() }
    }

    func dismissSummary() {
        summary = nil
        paused = []
    }

    /// Runs the checker over `connections` and folds the events into `run`. `earlier` counts results already stored
    /// for connections that were not worth contacting (for example, their 1Password is locked).
    func execute(_ connections: [Connection], earlier: [ConnectionHealth], environment: HealthEnvironment) async {
        let offset = earlier.count
        run?.completed = offset
        var ok = earlier.filter { $0.status == .ok }.count
        var failing = earlier.count - ok
        var skipped = 0
        var cancelled = false

        let stream = await checker.run(connections: connections, makeFileSystem: environment.makeFileSystem, secrets: environment.secrets)
        for await event in stream {
            switch event {
            case .started(let id, _):
                run?.testing.insert(id)
            case .result(let health, let progress):
                var result = health
                if let corrected = await environment.correcting(health) {
                    try? await repository.record(corrected)
                    result = corrected
                    latest[corrected.connectionId] = corrected
                }
                run?.testing.remove(result.connectionId)
                run?.completed = offset + progress.completed
                if result.status == .ok { ok += 1 } else { failing += 1 }
            case .skipped(let id, _, let progress):
                run?.testing.remove(id)
                run?.completed = offset + progress.completed
                paused.insert(id)
                skipped += 1
            case .finished(let finished):
                cancelled = finished.cancelled
            }
        }
        cancelled = cancelled || Task.isCancelled
        summary = Summary(tested: ok + failing, ok: ok, failing: failing, paused: skipped, cancelled: cancelled)
    }

    // MARK: Demo

    /// The manager mid-run for screenshots: no connections are contacted.
    func seedDemoRun(total: Int, completed: Int, testing: Set<UUID>, paused: Set<UUID>) {
        run = Run(total: total, completed: completed, testing: testing)
        self.paused = paused
    }
}
