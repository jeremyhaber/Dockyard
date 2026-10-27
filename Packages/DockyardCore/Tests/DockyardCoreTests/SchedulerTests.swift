import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

/// Uploads `count` small local files to `/d` on `endpoint`.
private func uploads(_ env: TransferEnv, _ prefix: String, count: Int, to endpoint: TransferEndpoint) throws -> [TransferRequest] {
    try (0..<count).map { i in
        try env.write("\(prefix)\(i).txt", "data\(i)")
        return upload(env, "\(prefix)\(i).txt", to: endpoint, "/d/\(prefix)\(i).txt")
    }
}

private func slowHook(_ server: FakeServer, milliseconds: UInt64 = 8) {
    server.files.setHook { _ in try await Task.sleep(nanoseconds: milliseconds * 1_000_000) }
}

@Suite struct SchedulerTests {
    @Test func perSiteLimitIsNeverExceededAndSessionsAreReused() async throws {
        let env = try TransferEnv()
        let a = FakeServer(), b = FakeServer()
        a.files.makeDir("/d"); b.files.makeDir("/d")
        slowHook(a); slowHook(b)
        let siteA = a.site(label: "A", max: 2), siteB = b.site(label: "B", max: 3)
        let q = env.queue(max: 10)
        await q.register(site: siteA)
        await q.register(site: siteB)
        await q.enqueue(try uploads(env, "a", count: 30, to: a.endpoint(siteA)))
        await q.enqueue(try uploads(env, "b", count: 30, to: b.endpoint(siteB)))
        await q.waitUntilIdle()
        let snap = await q.snapshot()
        #expect(snap.completedCount == 60 && snap.failedCount == 0)
        #expect(a.maxLive <= 2 && b.maxLive <= 3)
        #expect(a.files.maxActive <= 2 && b.files.maxActive <= 3)
        #expect(a.connects <= 2 && b.connects <= 3)  // pooled: not one login per file
        #expect(a.files.maxActive == 2 && b.files.maxActive == 3)
    }

    @Test func globalCapIsNeverExceeded() async throws {
        let env = try TransferEnv()
        let meter = Meter()
        let servers = (0..<4).map { _ in FakeServer(global: meter) }
        var endpoints: [TransferEndpoint] = []
        let q = env.queue(max: 6)
        for (i, server) in servers.enumerated() {
            server.files.makeDir("/d")
            slowHook(server)
            let site = server.site(label: "S\(i)", max: 5)
            await q.register(site: site)
            endpoints.append(server.endpoint(site))
        }
        for (i, endpoint) in endpoints.enumerated() { await q.enqueue(try uploads(env, "s\(i)-", count: 20, to: endpoint)) }
        await q.waitUntilIdle()
        #expect(await q.snapshot().completedCount == 80)
        // The cap must never be exceeded; how close a busy machine gets to it varies.
        #expect(meter.peak <= 6)
        #expect(meter.peak >= 2)
    }

    @Test func sitesTakeTurns() async throws {
        let env = try TransferEnv()
        let order = LockedBox<[String]>([])
        let q = env.queue(max: 1)
        await q.pause()
        var servers: [FakeServer] = []
        for name in ["A", "B", "C"] {
            let server = FakeServer()
            server.files.makeDir("/d")
            server.files.setHook { path in order.withLock { $0.append(name) }; _ = path }
            servers.append(server)
            let site = server.site(label: name, max: 2)
            await q.register(site: site)
            await q.enqueue(try uploads(env, "\(name)-", count: 12, to: server.endpoint(site)))
        }
        await q.resume()
        await q.waitUntilIdle()
        let first = Array(order.withLock { $0 }.prefix(18))
        for name in ["A", "B", "C"] { #expect(first.filter { $0 == name }.count == 6) }
        // Never the same site more than twice in a row while others have work.
        var run = 1
        for i in 1..<first.count {
            run = first[i] == first[i - 1] ? run + 1 : 1
            #expect(run <= 2)
        }
    }

    @Test func connectDelayIsRespected() async throws {
        let env = try TransferEnv()
        let clock = ManualClock()
        let server = FakeServer(clock: clock)
        server.files.makeDir("/d")
        let gate = Gate()
        server.files.setHook { _ in await gate.wait() }
        let site = server.site(label: "Slow", max: 3, delayMs: 500)
        let q = TransferQueue(maxConcurrent: 10, conflictPolicy: .overwrite, tempDirectory: env.dir, progressInterval: 0.005,
                              publishInterval: 0.005, clock: clock)
        await q.register(site: site)
        await q.enqueue(try uploads(env, "f", count: 3, to: server.endpoint(site)))
        #expect(await waitUntil { server.connects == 1 })
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(server.connects == 1)  // the second connection waits for the delay
        await clock.waitForSleepers(1)
        clock.advance(by: 0.4)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(server.connects == 1)
        clock.advance(by: 0.2)
        #expect(await waitUntil { server.connects == 2 })
        await clock.waitForSleepers(1)
        clock.advance(by: 0.5)
        #expect(await waitUntil { server.connects == 3 })
        let times = server.connectTimes
        for i in 1..<times.count { #expect(times[i].timeIntervalSince(times[i - 1]) >= 0.5) }
        await gate.open()
        await q.waitUntilIdle()
        #expect(await q.snapshot().completedCount == 3)
    }

    @Test func refusalLowersTheLimitWithoutFailingItems() async throws {
        let env = try TransferEnv()
        let server = FakeServer(capacity: 2)
        server.files.makeDir("/d")
        slowHook(server, milliseconds: 15)
        let site = server.site(label: "Strict", max: 6)
        let q = TransferQueue(maxConcurrent: 10, conflictPolicy: .overwrite, tempDirectory: env.dir, progressInterval: 0.005,
                              publishInterval: 0.005, recoverAfter: 1000, refusalRetryDelay: 0.01)
        await q.register(site: site)
        let logs = q.log.stream()
        let warnings = Task { () -> Int in
            var n = 0
            for await line in logs where line.kind == .warning { n += 1 }
            return n
        }
        await q.enqueue(try uploads(env, "f", count: 24, to: server.endpoint(site)))
        await q.waitUntilIdle()
        let snap = await q.snapshot()
        #expect(snap.completedCount == 24 && snap.failedCount == 0)
        #expect(server.maxLive <= 2)
        #expect(server.refusals > 0)
        #expect(snap.sites.first?.liveLimit == 2)
        await q.shutdown()
        q.log.finish()
        #expect(await warnings.value > 0)
    }

    @Test func limitRecoversAfterASeriesOfSuccesses() async throws {
        let env = try TransferEnv()
        let server = FakeServer(refuseFirst: 2)
        server.files.makeDir("/d")
        slowHook(server, milliseconds: 5)
        let site = server.site(label: "Flaky", max: 4)
        let q = TransferQueue(maxConcurrent: 10, conflictPolicy: .overwrite, tempDirectory: env.dir, progressInterval: 0.005,
                              publishInterval: 0.005, recoverAfter: 3, refusalRetryDelay: 0.01)
        await q.register(site: site)
        await q.enqueue(try uploads(env, "f", count: 40, to: server.endpoint(site)))
        let lowest = LockedBox(Int.max)
        let watcher = Task {
            while !Task.isCancelled {
                if let limit = await q.snapshot().sites.first?.liveLimit { lowest.withLock { $0 = min($0, limit) } }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        await q.waitUntilIdle()
        watcher.cancel()
        let snap = await q.snapshot()
        #expect(snap.failedCount == 0 && snap.completedCount == 40)
        #expect(lowest.withLock { $0 } < 4)
        #expect(snap.sites.first?.liveLimit == 4)
    }

    @Test func persistentRefusalEventuallyFailsTheItem() async throws {
        let env = try TransferEnv()
        let server = FakeServer(capacity: 0)
        server.files.makeDir("/d")
        let site = server.site(max: 2)
        let q = TransferQueue(maxConcurrent: 10, conflictPolicy: .overwrite, tempDirectory: env.dir, progressInterval: 0.005,
                              publishInterval: 0.005, refusalRetryDelay: 0.001, maxRefusalRetries: 3)
        await q.register(site: site)
        let id = await q.enqueue(upload(env, try { try env.write("x", "x"); return "x" }(), to: server.endpoint(site), "/d/x"))
        await q.waitUntilIdle()
        let job = try #require(await q.job(id))
        #expect(job.state == .failed)
        #expect(job.error?.contains("refusing") == true)
    }

    @Test func pausingASiteLeavesOthersRunning() async throws {
        let env = try TransferEnv()
        let a = FakeServer(), b = FakeServer()
        a.files.makeDir("/d"); b.files.makeDir("/d")
        let siteA = a.site(label: "A"), siteB = b.site(label: "B")
        let q = env.queue()
        await q.register(site: siteA)
        await q.register(site: siteB)
        await q.pauseSite(siteA.id)
        await q.enqueue(try uploads(env, "a", count: 5, to: a.endpoint(siteA)))
        await q.enqueue(try uploads(env, "b", count: 5, to: b.endpoint(siteB)))
        #expect(await waitUntil { await q.snapshot().completedCount == 5 })
        try await Task.sleep(nanoseconds: 50_000_000)
        var snap = await q.snapshot()
        #expect(snap.completedCount == 5 && snap.queuedCount == 5)
        #expect(snap.sites.first { $0.label == "A" }?.isPaused == true)
        await q.resumeSite(siteA.id)
        await q.waitUntilIdle()
        snap = await q.snapshot()
        #expect(snap.completedCount == 10)
    }

    @Test func globalPauseInterruptsAndResumesPartialFiles() async throws {
        let env = try TransferEnv()
        let server = FakeServer()
        server.files.makeDir("/d")
        let site = server.site(max: 1)
        let started = Arrivals()
        let block = LockedBox(true)
        server.files.setHook { _ in
            await started.hit()
            while block.withLock({ $0 }) { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        let q = env.queue()
        await q.register(site: site)
        let ids = await q.enqueue(try uploads(env, "f", count: 3, to: server.endpoint(site)))
        #expect(await waitUntil { await started.count == 1 })
        await q.pause()
        #expect(await waitUntil { await q.snapshot().activeCount == 0 })
        #expect(await q.snapshot().queuedCount == 3)
        block.withLock { $0 = false }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await q.snapshot().completedCount == 0)  // paused: nothing starts
        await q.resume()
        await q.waitUntilIdle()
        #expect(await q.snapshot().completedCount == 3)
        for id in ids { #expect(await q.job(id)?.state == .completed) }
    }

    @Test func sessionsAreClosedWhenIdleTooLong() async throws {
        let env = try TransferEnv()
        let clock = ManualClock()
        let server = FakeServer(clock: clock)
        server.files.makeDir("/d")
        let site = server.site(max: 2)
        let q = TransferQueue(maxConcurrent: 10, conflictPolicy: .overwrite, tempDirectory: env.dir, progressInterval: 0.005,
                              publishInterval: 0.005, clock: clock, idleTimeout: 30)
        await q.register(site: site)
        await q.enqueue(try uploads(env, "f", count: 2, to: server.endpoint(site)))
        await q.waitUntilIdle()
        #expect(server.state.withLock { $0.live } >= 1)
        await clock.waitForSleepers(1)
        clock.advance(by: 31)
        #expect(await waitUntil { server.state.withLock { $0.live } == 0 })
    }

    @Test func throttledUpdatesAreAtMostAFewPerSecond() async throws {
        let env = try TransferEnv()
        let server = FakeServer()
        server.files.makeDir("/d")
        slowHook(server, milliseconds: 2)
        let site = server.site(max: 3)
        let q = TransferQueue(maxConcurrent: 10, conflictPolicy: .overwrite, tempDirectory: env.dir, progressInterval: 0.005,
                              publishInterval: 0.25)
        await q.register(site: site)
        let stream = await q.updates()
        let count = LockedBox(0)
        let reader = Task { for await _ in stream { count.withLock { $0 += 1 } } }
        let started = Date()
        await q.enqueue(try uploads(env, "f", count: 400, to: server.endpoint(site)))
        await q.waitUntilIdle()
        try await Task.sleep(nanoseconds: 300_000_000)
        reader.cancel()
        let elapsed = Date().timeIntervalSince(started)
        #expect(count.withLock { $0 } <= Int(elapsed / 0.25) + 4)
        #expect(await q.snapshot().completedCount == 400)
    }
}

@Suite struct ClassifierTests {
    @Test(arguments: [
        (RemoteError.connectionRefused("x"), FailurePhase.connecting, ConnectionFailure.refused),
        (RemoteError.connectionRefused("x"), FailurePhase.working, ConnectionFailure.refused),
        (RemoteError.serverRejected(code: 421, message: "Service not available"), FailurePhase.connecting, ConnectionFailure.refused),
        (RemoteError.serverRejected(code: 421, message: "Timeout"), FailurePhase.working, ConnectionFailure.sessionLost),
        (RemoteError.serverRejected(code: 421, message: "Too many connections (5) from this IP"), FailurePhase.working, ConnectionFailure.refused),
        (RemoteError.serverRejected(code: 550, message: "Permission denied"), FailurePhase.working, ConnectionFailure.other),
        (RemoteError.protocolError("SSH handshake: Rate limit exceeded, try again later"), FailurePhase.connecting, ConnectionFailure.refused),
        (RemoteError.protocolError("channel read: Socket disconnect"), FailurePhase.working, ConnectionFailure.sessionLost),
        (RemoteError.protocolError("channel read: Socket disconnect"), FailurePhase.connecting, ConnectionFailure.other),
        (RemoteError.notConnected, FailurePhase.working, ConnectionFailure.sessionLost),
        (RemoteError.notConnected, FailurePhase.connecting, ConnectionFailure.refused),
        (RemoteError.authenticationFailed("Permission denied"), FailurePhase.connecting, ConnectionFailure.other),
        (RemoteError.authenticationFailed("Too many authentication failures"), FailurePhase.connecting, ConnectionFailure.refused),
        (RemoteError.notFound("/x"), FailurePhase.working, ConnectionFailure.other),
    ])
    func classifies(error: RemoteError, phase: FailurePhase, expected: ConnectionFailure) {
        #expect(ConnectionFailureClassifier.classify(error, phase: phase) == expected)
    }

    @Test func cancellationIsNotAConnectionProblem() {
        #expect(ConnectionFailureClassifier.classify(CancellationError(), phase: .working) == .other)
    }

    @Test func limitedSiteStateLowersAndRaisesItsLimit() {
        let site = SiteState(key: "k", label: "S", profile: TransferSite(id: UUID(), label: "S", maxConnections: 4) { FakeSession(server: FakeServer()) })
        site.noteRefusal(openConnections: 4)
        #expect(site.liveLimit == 3)
        site.noteRefusal(openConnections: 2)
        #expect(site.liveLimit == 1)
        site.noteRefusal(openConnections: 1)
        #expect(site.liveLimit == 1)
        #expect(!site.noteSuccess(recoverAfter: 2))
        #expect(site.noteSuccess(recoverAfter: 2) && site.liveLimit == 2)
        for _ in 0..<20 { _ = site.noteSuccess(recoverAfter: 1) }
        #expect(site.liveLimit == 4)
    }
}
