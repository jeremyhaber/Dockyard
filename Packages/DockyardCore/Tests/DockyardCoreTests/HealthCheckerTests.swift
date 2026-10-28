import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct HealthCheckerTests {
    /// A connection with a stored password, so it is tested rather than reported as needing one.
    private func site(_ name: String, host: String = "h.example", port: Int? = nil, secrets: InMemorySecretStore) async -> Connection {
        let c = makeConn(name, host: host, port: port)
        await secrets.setSecret("pw-\(name)-secret", for: c.id, purpose: .password)
        return c
    }

    private func run(
        _ connections: [Connection], secrets: any SecretStore, options: HealthCheckOptions = .init(timeout: 2),
        repository: ConnectionHealthRepository? = nil, tracker: SessionTracker = SessionTracker(),
        behavior: @escaping @Sendable (Connection) -> ScriptedFileSystem.Behavior = { _ in .ok }
    ) async -> [HealthEvent] {
        let checker = HealthChecker(options: options, repository: repository)
        let stream = await checker.run(
            connections: connections,
            makeFileSystem: { c in TrackedFileSystem(ScriptedFileSystem(behavior: behavior(c)), tracker: tracker, connection: c) },
            secrets: secrets)
        return await collect(stream)
    }

    @Test func classifiesEachOutcome() async throws {
        let secrets = InMemorySecretStore()
        let ok = await site("ok", host: "a", secrets: secrets)
        let auth = await site("auth", host: "b", secrets: secrets)
        let dns = await site("dns", host: "c", secrets: secrets)
        let refused = await site("refused", host: "d", secrets: secrets)
        let key = await site("key", host: "e", secrets: secrets)
        let hang = await site("hang", host: "f", secrets: secrets)
        let other = await site("other", host: "g", secrets: secrets)
        let behaviors: [UUID: ScriptedFileSystem.Behavior] = [
            ok.id: .ok,
            auth.id: .fail(.authenticationFailed("Authentication failed")),
            dns.id: .fail(.protocolError("Cannot resolve c: Name or service not known")),
            refused.id: .fail(.protocolError("Cannot connect to d:22: Connection refused")),
            key.id: .fail(.hostKeyRejected("SHA256:abc")),
            hang.id: .hang,
            other.id: .fail(.permissionDenied("home folder")),
        ]
        let events = await run(
            [ok, auth, dns, refused, key, hang, other], secrets: secrets, options: .init(timeout: 0.3),
            behavior: { behaviors[$0.id] ?? .ok })
        let results = healthResults(events)

        #expect(results[ok.id]?.status == .ok)
        #expect(results[ok.id]?.latencyMs != nil)
        #expect(results[auth.id]?.status == .authFailed)
        #expect(results[dns.id]?.status == .hostNotFound)
        #expect(results[refused.id]?.status == .refused)
        #expect(results[key.id]?.status == .hostKeyChanged)
        #expect(results[hang.id]?.status == .timedOut)
        #expect(results[other.id]?.status == .otherError)
        #expect(results[ok.id]?.message == nil)

        guard case .finished(let summary) = try #require(events.last) else { Issue.record("no summary"); return }
        #expect(summary.total == 7 && summary.tested == 7 && summary.skipped == 0 && !summary.cancelled)
        #expect(summary.counts[.ok] == 1 && summary.counts[.timedOut] == 1)
    }

    @Test func neverContactsConnectionsWithoutASecretOrRemovedFromSource() async throws {
        let secrets = InMemorySecretStore()
        let noPassword = makeConn("nopw", host: "a")
        let removed = Connection(name: "gone", host: "b", username: "u", removedFromSource: true)
        let withRef = Connection(name: "ref", host: "c", username: "u", secretReferences: [.password: "op://V/I/password"])
        let keyOnly = Connection(name: "key", host: "d", username: "u", authMethods: .key, keyPath: "/k")
        let keyAndPassword = Connection(name: "both", host: "e", username: "u", authMethods: .both, keyPath: "/k")
        let anonymous = Connection(name: "anon", protocol: .ftp, host: "f", username: "")
        let ftpNoPassword = Connection(name: "ftp", protocol: .ftp, host: "g", username: "bob")
        let tracker = SessionTracker()
        let events = await run(
            [noPassword, removed, withRef, keyOnly, keyAndPassword, anonymous, ftpNoPassword], secrets: secrets, tracker: tracker)
        let results = healthResults(events)

        #expect(results[noPassword.id]?.status == .needsSecret)
        #expect(results[removed.id]?.status == .removedFromSource)
        #expect(results[ftpNoPassword.id]?.status == .needsSecret)
        for connection in [withRef, keyOnly, keyAndPassword, anonymous] { #expect(results[connection.id]?.status == .ok) }
        #expect(Set(tracker.connectOrder) == [withRef.id, keyOnly.id, keyAndPassword.id, anonymous.id])
    }

    @Test func limitsConcurrencyPerHostAndOverall() async {
        let secrets = InMemorySecretStore()
        var connections: [Connection] = []
        // The same server spelled three ways, on different ports: one host.
        for (i, host) in ["Web.Example.com", "web.example.com.", "WEB.example.com"].enumerated() {
            for j in 0..<4 { connections.append(await site("w\(i)-\(j)", host: host, port: 22 + j, secrets: secrets)) }
        }
        for j in 0..<6 { connections.append(await site("o\(j)", host: "other\(j).example.com", secrets: secrets)) }
        let tracker = SessionTracker()
        let events = await run(connections, secrets: secrets, options: .init(timeout: 2, maxConcurrent: 5, maxPerHost: 2), tracker: tracker) { _ in .ok }

        #expect(healthResults(events).count == connections.count)
        #expect(tracker.peakPerHost["web.example.com"] == 2)
        #expect(tracker.peakPerHost.values.allSatisfy { $0 <= 2 })
        #expect(tracker.peakTotal <= 5)
        #expect(tracker.peakTotal > 2)
    }

    @Test func circuitBreakerStopsAHostAfterThreeLoginFailures() async {
        let secrets = InMemorySecretStore()
        var bad: [Connection] = []
        for i in 0..<8 { bad.append(await site("bad\(i)", host: "shared.example.com", secrets: secrets)) }
        let fine = await site("fine", host: "elsewhere.example.com", secrets: secrets)
        let tracker = SessionTracker()
        let events = await run(
            bad + [fine], secrets: secrets, options: .init(timeout: 2, maxConcurrent: 8, maxPerHost: 1), tracker: tracker
        ) { $0.name == "fine" ? .ok : .fail(.authenticationFailed("denied")) }

        let results = healthResults(events)
        let skipped = healthSkips(events)
        #expect(tracker.connects["shared.example.com"] == 3)
        #expect(skipped.count == 5)
        #expect(Set(skipped).isDisjoint(with: results.keys))
        #expect(results.values.filter { $0.status == .authFailed }.count == 3)
        #expect(results[fine.id]?.status == .ok)
        guard case .finished(let summary) = events.last else { Issue.record("no summary"); return }
        #expect(summary.skipped == 5 && summary.tested == 4)
        #expect(HealthSkipReason.pausedToAvoidLockout.message == "Paused to avoid lockout")
    }

    @Test func aSuccessResetsTheLoginFailureCount() async {
        let secrets = InMemorySecretStore()
        var connections: [Connection] = []
        for i in 0..<8 { connections.append(await site("c\(i)", host: "shared.example.com", secrets: secrets)) }
        let pattern = Dictionary(uniqueKeysWithValues: connections.enumerated().map { ($0.element.id, $0.offset % 3 == 2) })
        let events = await run(
            connections, secrets: secrets, options: .init(timeout: 2, maxConcurrent: 8, maxPerHost: 1)
        ) { pattern[$0.id] == true ? .ok : .fail(.authenticationFailed("denied")) }

        #expect(healthSkips(events).isEmpty)
        #expect(healthResults(events).count == 8)
    }

    @Test func eventsReportProgressAndStoreResults() async throws {
        let secrets = InMemorySecretStore()
        let db = try DockyardDatabase()
        let connections = ConnectionRepository(database: db)
        let health = ConnectionHealthRepository(database: db)
        let a = await site("a", host: "a.example", secrets: secrets)
        let b = makeConn("b-no-password", host: "b.example")
        try await connections.save([a, b])

        let events = await run([a, b], secrets: secrets, repository: health)
        let progress = events.compactMap { event -> Int? in
            switch event {
            case .result(_, let p): p.completed
            default: nil
            }
        }
        #expect(progress == [1, 2])
        #expect(events.contains { if case .started(a.id, let p) = $0 { p.total == 2 } else { false } })
        guard case .finished = events.last else { Issue.record("no summary"); return }

        let stored = try await health.latest()
        #expect(stored[a.id]?.status == .ok)
        #expect(stored[b.id]?.status == .needsSecret)
    }

    @Test func messagesNeverContainSecrets() async throws {
        let secrets = InMemorySecretStore()
        let c = await site("leaky", secrets: secrets)
        let events = await run([c], secrets: secrets) { _ in
            .fail(.protocolError("Login failed for ftp://leaky:pw-leaky-secret@h.example using pw-leaky-secret"))
        }
        let message = try #require(healthResults(events)[c.id]?.message)
        #expect(!message.contains("pw-leaky-secret"))
        #expect(message.contains("ftp://h.example"))
    }

    @Test func aFactoryFailureIsReportedNotThrown() async {
        let secrets = InMemorySecretStore()
        let c = await site("x", secrets: secrets)
        let checker = HealthChecker()
        let events = await collect(await checker.run(
            connections: [c], makeFileSystem: { _ in throw RemoteError.invalidConfiguration("no provider") }, secrets: secrets))
        #expect(healthResults(events)[c.id]?.status == .otherError)
    }

    @Test func cancelStopsTheRunAndDropsInFlightResults() async throws {
        let secrets = InMemorySecretStore()
        var connections: [Connection] = []
        for i in 0..<6 { connections.append(await site("s\(i)", host: "h\(i).example", secrets: secrets)) }
        let checker = HealthChecker(options: .init(timeout: 30, maxConcurrent: 2))
        let tracker = SessionTracker()
        let stream = await checker.run(
            connections: connections,
            makeFileSystem: { c in TrackedFileSystem(ScriptedFileSystem(behavior: .hang), tracker: tracker, connection: c) },
            secrets: secrets)
        let consumer = Task { await collect(stream) }
        #expect(await waitUntil { tracker.connects.values.reduce(0, +) == 2 })
        await checker.cancel()
        let events = await consumer.value

        guard case .finished(let summary) = try #require(events.last) else { Issue.record("no summary"); return }
        #expect(summary.cancelled)
        #expect(healthResults(events).isEmpty)
        #expect(tracker.connects.values.reduce(0, +) == 2)
    }

    @Test func hostKeysAreCaseInsensitiveAndPortAgnostic() {
        func key(_ host: String, port: Int? = nil) -> String { HealthChecker.hostKey(for: makeConn(host: host, port: port)) }
        #expect(key("Example.COM") == key("example.com", port: 2222))
        #expect(key("example.com.") == "example.com")
        #expect(key("[::1]") == "::1")
        #expect(key("") != key(""))
    }
}

@Suite struct HealthClassifierTests {
    @Test func mapsErrorsToStatuses() {
        #expect(HealthClassifier.status(for: RemoteError.authenticationFailed("x")) == .authFailed)
        #expect(HealthClassifier.status(for: RemoteError.serverRejected(code: 530, message: "Login incorrect")) == .authFailed)
        #expect(HealthClassifier.status(for: RemoteError.hostKeyRejected("fp")) == .hostKeyChanged)
        #expect(HealthClassifier.status(for: RemoteError.connectionRefused("limit")) == .refused)
        #expect(HealthClassifier.status(for: RemoteError.protocolError("Cannot resolve h: Name or service not known")) == .hostNotFound)
        #expect(HealthClassifier.status(for: RemoteError.protocolError("Cannot connect to h:1: Connection refused")) == .refused)
        #expect(HealthClassifier.status(for: RemoteError.protocolError("Cannot connect to h:1: Connection timed out")) == .timedOut)
        #expect(HealthClassifier.status(for: HealthTimeoutError(seconds: 15)) == .timedOut)
        #expect(HealthClassifier.status(for: URLError(.cannotFindHost)) == .hostNotFound)
        #expect(HealthClassifier.status(for: RemoteError.notFound("/x")) == .otherError)
        #expect(HealthClassifier.status(for: RemoteError.invalidConfiguration("key")) == .otherError)
    }

    @Test func sanitizeRemovesSecretsAndTidies() {
        #expect(HealthClassifier.sanitize("bad pass hunter22 for x", redacting: ["hunter22"]) == "bad pass ••• for x")
        #expect(HealthClassifier.sanitize("a ok", redacting: ["a"]) == "a ok")
        #expect(HealthClassifier.sanitize("sftp://bob:s3cret@host/p and ftp://u@h") == "sftp://host/p and ftp://h")
        #expect(HealthClassifier.sanitize("ref op://Vault/Item/password failed") == "ref ••• failed")
        #expect(HealthClassifier.sanitize("line one\n  line\ttwo ") == "line one line two")
        let long = HealthClassifier.sanitize(String(repeating: "x", count: 500))
        #expect(long.count == 200 && long.hasSuffix("…"))
    }

    @Test func timeoutMessageNamesTheLimit() {
        #expect(HealthClassifier.message(for: HealthTimeoutError(seconds: 15)) == "No answer within 15 seconds")
    }
}
