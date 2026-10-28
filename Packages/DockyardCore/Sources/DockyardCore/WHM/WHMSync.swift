import Foundation
import ConnectionKit

public struct WHMSyncReport: Sendable, Equatable {
    public var accountCount = 0
    public var created = 0
    public var updated = 0
    public var unchanged = 0
    /// Accounts no longer listed by WHM; kept and flagged, never deleted.
    public var removed = 0
    /// Previously removed accounts that came back.
    public var restored = 0
}

public enum WHMMerge {
    public static let suspendedTag = "suspended"

    /// Notes written for an account the user has not edited.
    public static func notes(for a: WHMAccount) -> String {
        var lines: [String] = []
        if let plan = a.plan { lines.append("Plan: \(plan)") }
        if let email = a.email { lines.append("Contact: \(email)") }
        if a.suspended { lines.append("Suspended: \(a.suspendReason ?? "yes")") }
        return lines.joined(separator: "\n")
    }

    /// Pure merge of a `listaccts` result into the connections already stored for this WHM server.
    /// Returns only the connections that need saving.
    public static func merge(
        accounts: [WHMAccount], source: WHMSource, existing: [Connection], now: Date
    ) -> (changed: [Connection], report: WHMSyncReport) {
        var report = WHMSyncReport()
        var changed: [Connection] = []
        let mine = existing.filter { $0.source == .whm(source.id) }
        var byUser: [String: Connection] = [:]
        for c in mine { byUser[c.username] = c }

        var seen = Set<String>()
        for account in accounts where !account.user.isEmpty {
            guard seen.insert(account.user).inserted else { continue }  // duplicate rows: first wins
            report.accountCount += 1
            let wantedName = account.domain.isEmpty ? account.user : account.domain
            let wantedNotes = notes(for: account)

            guard var c = byUser[account.user] else {
                var tags: [String] = []
                if account.suspended { tags.append(suspendedTag) }
                changed.append(Connection(
                    name: wantedName, protocol: .sftp, host: source.host, port: 22, username: account.user,
                    authMethods: .password, tags: tags, notes: wantedNotes, source: .whm(source.id), createdAt: now))
                report.created += 1
                continue
            }

            let before = c
            c.removedFromSource = false
            if !c.userEditedFields.contains(.name) { c.name = wantedName }
            if !c.userEditedFields.contains(.notes) { c.notes = wantedNotes }
            if !c.userEditedFields.contains(.host) { c.host = source.host }
            let hasTag = c.tags.contains(suspendedTag)
            if account.suspended && !hasTag { c.tags.append(suspendedTag) }
            if !account.suspended && hasTag { c.tags.removeAll { $0 == suspendedTag } }

            var contentOnly = c
            contentOnly.removedFromSource = before.removedFromSource
            if before.removedFromSource { report.restored += 1 }
            if c != before {
                changed.append(c)
                if contentOnly != before { report.updated += 1 }
            } else {
                report.unchanged += 1
            }
        }

        for var c in mine where !seen.contains(c.username) && !c.removedFromSource {
            c.removedFromSource = true
            changed.append(c)
            report.removed += 1
        }
        return (changed, report)
    }
}

/// Fetches accounts from WHM and merges them into the store.
public struct WHMSyncService: Sendable {
    public typealias TransportFactory = @Sendable (WHMSource) -> any HTTPTransport

    private let repository: ConnectionRepository
    private let sources: WHMSourceRepository
    private let secrets: any SecretStore
    private let clock: any DockyardClock
    private let transportFactory: TransportFactory

    public init(
        repository: ConnectionRepository, sources: WHMSourceRepository, secrets: any SecretStore,
        clock: any DockyardClock = SystemClock(),
        transportFactory: @escaping TransportFactory = { URLSessionTransport(trustSelfSignedFor: $0.host) }
    ) {
        self.repository = repository
        self.sources = sources
        self.secrets = secrets
        self.clock = clock
        self.transportFactory = transportFactory
    }

    /// Where a source's API token lives: purpose `.cloudToken` under the source's id.
    public static func storeToken(_ token: String, for source: WHMSource, in secrets: any SecretStore) async throws {
        try await secrets.setSecret(token, for: source.id, purpose: .cloudToken)
    }

    @discardableResult
    public func sync(_ source: WHMSource) async throws -> WHMSyncReport {
        do {
            guard let token = try await secrets.secret(for: source.id, purpose: .cloudToken), !token.isEmpty else {
                throw WHMError.api("No API token saved for \(source.label)")
            }
            let client = WHMClient(host: source.host, port: source.apiPort, apiUser: source.apiUser, token: token,
                                   transport: transportFactory(source))
            let accounts = try await client.listAccounts()
            let existing = try await repository.fetch(ConnectionFilter(scope: .source(.whm(source.id)), includeRemoved: true))
            let (changed, report) = WHMMerge.merge(accounts: accounts, source: source, existing: existing, now: clock.now())
            try await repository.save(changed)
            var updated = source
            updated.lastSyncAt = clock.now()
            updated.lastSyncError = nil
            try await sources.save(updated)
            return report
        } catch {
            var failed = source
            failed.lastSyncError = String(describing: error)
            try? await sources.save(failed)
            throw error
        }
    }

    /// Syncs every configured server; one failing server does not stop the others.
    public func syncAll() async -> [UUID: Result<WHMSyncReport, any Error>] {
        var out: [UUID: Result<WHMSyncReport, any Error>] = [:]
        for source in (try? await sources.all()) ?? [] {
            do { out[source.id] = .success(try await sync(source)) } catch { out[source.id] = .failure(error) }
        }
        return out
    }
}

/// Runs a sync callback on a timer. Time comes from the injected clock.
public actor WHMSyncScheduler {
    public static let defaultInterval: TimeInterval = 6 * 3600

    private let clock: any DockyardClock
    private var interval: TimeInterval
    private let action: @Sendable () async -> Void
    private var task: Task<Void, Never>?
    private var running = false
    public private(set) var runCount = 0

    public init(clock: any DockyardClock = SystemClock(), interval: TimeInterval = WHMSyncScheduler.defaultInterval,
                action: @escaping @Sendable () async -> Void) {
        self.clock = clock
        self.interval = max(60, interval)
        self.action = action
    }

    public var isStarted: Bool { task != nil }

    /// Starts the timer. `runImmediately` also syncs once right away (e.g. at app launch).
    public func start(runImmediately: Bool = false) {
        guard task == nil else { return }
        let clock = self.clock
        task = Task { [weak self] in
            if runImmediately { await self?.syncNow() }
            while !Task.isCancelled {
                guard let seconds = await self?.interval else { return }
                do { try await clock.sleep(seconds: seconds) } catch { return }
                await self?.syncNow()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func setInterval(_ seconds: TimeInterval) { interval = max(60, seconds) }

    /// "Sync now". A run already in progress is not started twice.
    public func syncNow() async {
        guard !running else { return }
        running = true
        defer { running = false }
        runCount += 1
        await action()
    }
}
