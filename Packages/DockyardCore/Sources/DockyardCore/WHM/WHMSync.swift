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

    /// Website folders for `user`: the main domain, then addon and subdomains by name. Parked domains share the
    /// main domain's folder and are left out, as is any second domain for a folder already mapped.
    public static func webURLs(for user: String, in domains: [WHMDomain]) -> [WebURLMapping] {
        let order: [WHMDomain.Kind: Int] = [.main: 0, .addon: 1, .sub: 2]
        let mine = domains
            .filter { $0.user == user && $0.kind != .parked }
            .sorted { (order[$0.kind] ?? 3, $0.domain) < (order[$1.kind] ?? 3, $1.domain) }
        var seen = Set<String>()
        return mine.compactMap { d in
            let mapping = WebURLMapping(path: d.docroot, baseURL: "https://\(d.domain)")
            return seen.insert(mapping.path).inserted ? mapping : nil
        }
    }

    /// Pure merge of a `listaccts` result into the connections already stored for this WHM server.
    /// With `domains` (from `get_domain_info`), website URLs not edited by the user follow the account's domains;
    /// nil leaves them as they are. Returns only the connections that need saving.
    public static func merge(
        accounts: [WHMAccount], domains: [WHMDomain]? = nil, source: WHMSource, existing: [Connection], now: Date
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
            let wantedIconSite = account.domain.isEmpty ? nil : account.domain

            guard var c = byUser[account.user] else {
                var tags: [String] = []
                if account.suspended { tags.append(suspendedTag) }
                var created = Connection(
                    name: wantedName, protocol: .sftp, host: source.host, port: 22, username: account.user,
                    tags: tags, notes: wantedNotes, source: .whm(source.id), createdAt: now, faviconSite: wantedIconSite)
                source.accountLogin.apply(to: &created)
                if let domains { created.webURLs = webURLs(for: account.user, in: domains) }
                changed.append(created)
                report.created += 1
                continue
            }

            let before = c
            c.removedFromSource = false
            if !c.userEditedFields.contains(.name) { c.name = wantedName }
            if !c.userEditedFields.contains(.notes) { c.notes = wantedNotes }
            if !c.userEditedFields.contains(.host) { c.host = source.host }
            if !c.userEditedFields.contains(.faviconSite) { c.faviconSite = wantedIconSite }
            if let domains, !c.userEditedFields.contains(.webURLs) { c.webURLs = webURLs(for: account.user, in: domains) }
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
            // Optional: a token without the privilege for it still syncs accounts, just without website URLs.
            let domains = try? await client.listDomains()
            let existing = try await repository.fetch(ConnectionFilter(scope: .source(.whm(source.id)), includeRemoved: true))
            let (changed, report) = WHMMerge.merge(
                accounts: accounts, domains: domains, source: source, existing: existing, now: clock.now())
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

    /// Saves `source` (with its new `accountLogin`) and moves the accounts still using the stored login to the new one.
    /// Returns how many accounts changed.
    @discardableResult
    public func save(_ source: WHMSource) async throws -> Int {
        let old = try await sources.source(id: source.id)?.accountLogin ?? source.accountLogin
        let existing = try await repository.fetch(ConnectionFilter(scope: .source(.whm(source.id)), includeRemoved: true))
        let changed = WHMAccountLogin.relogin(existing, source: source, from: old, to: source.accountLogin)
        // Accounts first: if moving them fails, the server keeps its old login and saving again retries.
        try await repository.save(changed)
        try await sources.save(source)
        return changed.count
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
