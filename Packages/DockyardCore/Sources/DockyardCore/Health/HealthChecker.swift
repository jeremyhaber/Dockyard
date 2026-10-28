import Foundation
import ConnectionKit

public struct HealthCheckOptions: Sendable, Equatable {
    /// Seconds for one connection to connect, log in and list its folder.
    public var timeout: TimeInterval
    /// Tests in flight across all hosts.
    public var maxConcurrent: Int
    /// Tests in flight against one host. Many cPanel accounts share a single WHM server.
    public var maxPerHost: Int
    /// Consecutive login failures on a host after which its remaining connections are not contacted.
    public var authFailureLimit: Int

    public init(timeout: TimeInterval = 15, maxConcurrent: Int = 8, maxPerHost: Int = 2, authFailureLimit: Int = 3) {
        self.timeout = timeout
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxPerHost = max(1, maxPerHost)
        self.authFailureLimit = max(1, authFailureLimit)
    }
}

public struct HealthProgress: Sendable, Equatable {
    /// Connections with an outcome so far, tested or skipped.
    public var completed: Int
    public var total: Int
}

public enum HealthSkipReason: Sendable, Equatable {
    /// The host rejected several logins in a row; more attempts could get the user's IP blocked.
    case pausedToAvoidLockout

    public var message: String {
        switch self {
        case .pausedToAvoidLockout: "Paused to avoid lockout"
        }
    }
}

public struct HealthSummary: Sendable, Equatable {
    public var total: Int
    /// Connections that got a stored result (including Needs password and Removed from WHM).
    public var tested: Int
    public var skipped: Int
    /// True when the run was cancelled; connections not reached are in neither count.
    public var cancelled: Bool
    public var counts: [HealthStatus: Int]
}

public enum HealthEvent: Sendable, Equatable {
    case started(connectionId: UUID, progress: HealthProgress)
    case result(ConnectionHealth, progress: HealthProgress)
    /// Not contacted and not stored: the previous result still stands.
    case skipped(connectionId: UUID, reason: HealthSkipReason, progress: HealthProgress)
    case finished(HealthSummary)
}

/// Tests connections in the background: connect, log in, list the home folder (or initial path), disconnect.
/// It never prompts for secrets and spaces out contact with each host.
public actor HealthChecker {
    public typealias FileSystemMaker = @Sendable (Connection) throws -> any RemoteFileSystem

    private let options: HealthCheckOptions
    private let clock: any DockyardClock
    private let repository: ConnectionHealthRepository?
    private var current: Task<Void, Never>?

    /// With a `repository`, every result is stored before its event is emitted.
    public init(options: HealthCheckOptions = HealthCheckOptions(), clock: any DockyardClock = SystemClock(), repository: ConnectionHealthRepository? = nil) {
        self.options = options
        self.clock = clock
        self.repository = repository
    }

    /// Starts a run, cancelling any run still going. Ending the stream's consumer, or `cancel()`, stops it.
    public func run(connections: [Connection], makeFileSystem: @escaping FileSystemMaker, secrets: any SecretStore) -> AsyncStream<HealthEvent> {
        current?.cancel()
        let (stream, continuation) = AsyncStream<HealthEvent>.makeStream(bufferingPolicy: .unbounded)
        let run = HealthRun(
            options: options, clock: clock, repository: repository, connections: connections,
            makeFileSystem: makeFileSystem, secrets: secrets)
        let task = Task {
            await run.execute(continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        current = task
        return stream
    }

    public func cancel() {
        current?.cancel()
        current = nil
    }

    /// The key limits apply to: case-insensitive, port-agnostic. Connections without a host (cloud) never share a key.
    static func hostKey(for connection: Connection) -> String {
        var host = connection.host.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? "id:\(connection.id.uuidString)" : host
    }
}

private struct HealthRun: Sendable {
    struct Pending: Sendable {
        var connection: Connection
        var host: String
        var secretsToRedact: [String]
    }

    struct Finished: Sendable {
        var host: String
        var health: ConnectionHealth?
    }

    let options: HealthCheckOptions
    let clock: any DockyardClock
    let repository: ConnectionHealthRepository?
    let connections: [Connection]
    let makeFileSystem: HealthChecker.FileSystemMaker
    let secrets: any SecretStore

    func execute(_ out: AsyncStream<HealthEvent>.Continuation) async {
        var completed = 0
        var skipped = 0
        var counts: [HealthStatus: Int] = [:]
        let total = connections.count

        func progress() -> HealthProgress { HealthProgress(completed: completed, total: total) }
        func record(_ health: ConnectionHealth) async {
            try? await repository?.record(health)
            completed += 1
            counts[health.status, default: 0] += 1
            out.yield(.result(health, progress: progress()))
        }

        var queue: [Pending] = []
        for connection in connections {
            if Task.isCancelled { break }
            if connection.removedFromSource {
                await record(health(connection, .removedFromSource, message: "No longer listed by its WHM server"))
                continue
            }
            let check = await secretCheck(connection)
            if check.missing {
                await record(health(connection, .needsSecret, message: "No password stored"))
                continue
            }
            queue.append(Pending(connection: connection, host: HealthChecker.hostKey(for: connection), secretsToRedact: check.known))
        }

        await withTaskGroup(of: Finished.self) { group in
            var running = 0
            var perHost: [String: Int] = [:]
            var authFailures: [String: Int] = [:]
            var paused: Set<String> = []

            while !Task.isCancelled {
                var index = 0
                while index < queue.count {
                    let next = queue[index]
                    if paused.contains(next.host) {
                        queue.remove(at: index)
                        completed += 1
                        skipped += 1
                        out.yield(.skipped(connectionId: next.connection.id, reason: .pausedToAvoidLockout, progress: progress()))
                    } else if running < options.maxConcurrent, perHost[next.host, default: 0] < options.maxPerHost {
                        queue.remove(at: index)
                        running += 1
                        perHost[next.host, default: 0] += 1
                        out.yield(.started(connectionId: next.connection.id, progress: progress()))
                        group.addTask { Finished(host: next.host, health: await probe(next)) }
                    } else {
                        index += 1
                    }
                }
                guard running > 0, let finished = await group.next() else { break }
                running -= 1
                perHost[finished.host, default: 1] -= 1
                guard let result = finished.health else { continue }
                await record(result)
                if result.status == .authFailed {
                    authFailures[finished.host, default: 0] += 1
                    if authFailures[finished.host, default: 0] >= options.authFailureLimit { paused.insert(finished.host) }
                } else {
                    authFailures[finished.host] = 0
                }
            }
            group.cancelAll()
        }

        out.yield(.finished(HealthSummary(total: total, tested: completed - skipped, skipped: skipped, cancelled: Task.isCancelled, counts: counts)))
    }

    /// Nil when the run was cancelled before the test ended.
    private func probe(_ pending: Pending) async -> ConnectionHealth? {
        let connection = pending.connection
        let started = ContinuousClock.now
        let system: any RemoteFileSystem
        do { system = try makeFileSystem(connection) } catch {
            return failure(connection, error, redacting: pending.secretsToRedact)
        }
        var outcome: ConnectionHealth
        do {
            try await Deadline.run(seconds: options.timeout) {
                try await system.connect()
                let path: String
                if let initial = connection.initialRemotePath, !initial.isEmpty { path = initial } else { path = try await system.homeDirectory() }
                _ = try await system.list(path)
            }
            let elapsed = ContinuousClock.now - started
            let milliseconds = Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            outcome = health(connection, .ok, latencyMs: milliseconds)
        } catch is CancellationError {
            _ = try? await Deadline.run(seconds: 5) { await system.disconnect() }
            return nil
        } catch {
            outcome = failure(connection, error, redacting: pending.secretsToRedact)
        }
        _ = try? await Deadline.run(seconds: 5) { await system.disconnect() }
        return Task.isCancelled ? nil : outcome
    }

    private func failure(_ connection: Connection, _ error: any Error, redacting secrets: [String]) -> ConnectionHealth {
        health(connection, HealthClassifier.status(for: error), message: HealthClassifier.message(for: error, redacting: secrets))
    }

    private func health(_ connection: Connection, _ status: HealthStatus, latencyMs: Int? = nil, message: String? = nil) -> ConnectionHealth {
        ConnectionHealth(connectionId: connection.id, status: status, latencyMs: latencyMs, message: message, testedAt: clock.now())
    }

    /// Whether a password the connection cannot do without is missing, plus stored secrets to keep out of messages.
    /// References (`op://`) are not resolved: that could prompt, so a connection that has one is tested.
    private func secretCheck(_ connection: Connection) async -> (missing: Bool, known: [String]) {
        func stored(_ purpose: SecretPurpose) async -> String? {
            guard connection.secretReferences[purpose] == nil,
                  let value = try? await secrets.secret(for: connection.id, purpose: purpose), !value.isEmpty else { return nil }
            return value
        }
        let password = await stored(.password)
        var known = [password].compactMap { $0 }
        for purpose in [SecretPurpose.keyPassphrase, .elevationPassword] { if let value = await stored(purpose) { known.append(value) } }

        let hasPassword = password != nil || connection.secretReferences[.password] != nil
        switch connection.protocol {
        case .sftp:
            let methods = connection.authMethods
            let usesPassword = methods.contains(.password) || methods.contains(.keyboardInteractive)
            return (usesPassword && !methods.contains(.key) && !methods.contains(.agent) && !hasPassword, known)
        case .ftp, .ftps:
            return (!connection.username.isEmpty && !hasPassword, known)
        case .rclone:
            return (false, known)
        }
    }
}

/// Runs an operation with a time limit. The operation is cancelled when time runs out, but a backend stuck in a
/// blocking call may keep running; the caller stops waiting for it.
enum Deadline {
    static func run<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let (results, continuation) = AsyncStream<Result<T, any Error>>.makeStream()
        let work = Task {
            do { continuation.yield(.success(try await operation())) } catch { continuation.yield(.failure(error)) }
        }
        let timer = Task {
            guard (try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))) != nil else { return }
            continuation.yield(.failure(HealthTimeoutError(seconds: seconds)))
        }
        defer {
            work.cancel()
            timer.cancel()
            continuation.finish()
        }
        for await result in results { return try result.get() }
        throw CancellationError()
    }
}
