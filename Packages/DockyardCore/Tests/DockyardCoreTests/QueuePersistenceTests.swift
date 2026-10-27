import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

private func makeQueue(_ env: TransferEnv, database: DockyardDatabase? = nil, provider: (@Sendable (UUID) async -> TransferSite?)? = nil) -> TransferQueue {
    TransferQueue(maxConcurrent: 10, conflictPolicy: .overwrite, tempDirectory: env.dir.appendingPathComponent(".relay"),
                  progressInterval: 0.005, publishInterval: 0.005, database: database, siteProvider: provider)
}

@Suite struct QueuePersistenceTests {
    @Test func jobsSurviveARestartAndStayPausedUntilResumed() async throws {
        let env = try TransferEnv()
        let path = env.path("queue.sqlite")
        let first = FakeServer()
        first.files.makeDir("/d")
        first.files.setHook { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }  // never finishes; cancellable
        let site = first.site(label: "PROD", max: 1)
        let q1 = makeQueue(env, database: try DockyardDatabase(path: path))
        await q1.register(site: site)
        var requests: [TransferRequest] = []
        for i in 0..<6 {
            try env.write("f\(i).txt", "data\(i)")
            requests.append(upload(env, "f\(i).txt", to: first.endpoint(site), "/d/f\(i).txt"))
        }
        let ids = await q1.enqueue(requests)
        #expect(await waitUntil { await q1.snapshot().activeCount == 1 })
        await q1.flush()

        // "Crash": a new queue opens the same file while the first one is still mid-transfer.
        let second = FakeServer()
        second.files.makeDir("/d")
        let site2 = second.site(site.id, label: "PROD", max: 2)
        let q2 = makeQueue(env, database: try DockyardDatabase(path: path)) { id in id == site.id ? site2 : nil }
        #expect(await q2.restoredJobCount == 6)
        #expect(await q2.isPaused)
        var snap = await q2.snapshot()
        #expect(snap.queuedCount == 6 && snap.activeCount == 0 && snap.isPaused)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(second.connects == 0)

        await q2.resume()
        await q2.waitUntilIdle()
        snap = await q2.snapshot()
        #expect(snap.completedCount == 6)
        for i in 0..<6 { #expect(second.files.text("/d/f\(i).txt") == "data\(i)") }
        for id in ids { #expect(await q2.job(id)?.state == .completed) }
        #expect(second.maxLive <= 2)
        await q1.shutdown()
        await q2.shutdown()
    }

    @Test func failedItemsSurviveARestartUntilRetriedOrCleared() async throws {
        let env = try TransferEnv()
        let path = env.path("queue.sqlite")
        try env.write("good.txt", "g"); try env.write("bad.txt", "b")
        let first = FakeServer()
        first.files.makeDir("/d")
        first.files.failNext("/d/bad.txt", times: 9, error: RemoteError.protocolError("550 Permission denied"))
        let site = first.site(label: "PROD", max: 2)
        let q1 = makeQueue(env, database: try DockyardDatabase(path: path))
        await q1.register(site: site)
        await q1.enqueue([upload(env, "good.txt", to: first.endpoint(site), "/d/good.txt"),
                          upload(env, "bad.txt", to: first.endpoint(site), "/d/bad.txt")])
        await q1.waitUntilIdle()
        await q1.flush()
        await q1.shutdown()

        let second = FakeServer()
        second.files.makeDir("/d")
        let site2 = second.site(site.id, label: "PROD", max: 2)
        let q2 = makeQueue(env, database: try DockyardDatabase(path: path)) { id in id == site.id ? site2 : nil }
        #expect(await q2.restoredFailedCount == 1)
        #expect(await q2.restoredQueuedCount == 0)
        #expect(await q2.restoredJobCount == 0)
        var snap = await q2.snapshot()
        #expect(snap.failedCount == 1 && !snap.isPaused)
        let failed = await q2.page(offset: 0, limit: 10, filter: TransferJobFilter(scope: .files, states: [.failed]))
        #expect(failed.count == 1 && failed[0].error?.contains("550 Permission denied") == true)

        await q2.retryFailed()
        await q2.waitUntilIdle()
        #expect(second.files.text("/d/bad.txt") == "b")
        snap = await q2.snapshot()
        #expect(snap.failedCount == 0)
        await q2.shutdown()
    }

    @Test func leftoverCountsCoverQueuedAndFailed() async throws {
        let env = try TransferEnv()
        let path = env.path("queue.sqlite")
        let first = FakeServer()
        first.files.makeDir("/d")
        first.files.setHook { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        let site = first.site(label: "PROD", max: 1)
        let q1 = makeQueue(env, database: try DockyardDatabase(path: path))
        await q1.register(site: site)
        var requests: [TransferRequest] = []
        for i in 0..<4 {
            try env.write("f\(i).txt", "x")
            requests.append(upload(env, "f\(i).txt", to: first.endpoint(site), "/d/f\(i).txt"))
        }
        await q1.enqueue(requests)
        #expect(await waitUntil { await q1.snapshot().activeCount == 1 })
        await q1.flush()
        let q2 = makeQueue(env, database: try DockyardDatabase(path: path))
        #expect(await q2.restoredQueuedCount == 4)
        #expect(await q2.restoredFailedCount == 0)
        await q1.shutdown()
        await q2.shutdown()
    }

    @Test func foldersResumeWhereTheyStopped() async throws {
        let env = try TransferEnv()
        let path = env.path("queue.sqlite")
        for sub in ["a", "b", "c"] { for i in 0..<10 { try env.write("tree/\(sub)/f\(i).txt", "\(sub)\(i)") } }
        let first = FakeServer()
        for d in ["/d", "/d/tree", "/d/tree/a", "/d/tree/b", "/d/tree/c"] { first.files.makeDir(d) }
        let calls = Arrivals()
        first.files.setHook { _ in
            await calls.hit()
            if await calls.count > 10 { try await Task.sleep(nanoseconds: 60_000_000_000) }
        }
        let site = first.site(label: "PROD", max: 1)
        let q1 = makeQueue(env, database: try DockyardDatabase(path: path))
        await q1.register(site: site)
        let id = await q1.enqueue(upload(env, "tree", to: first.endpoint(site), "/d/tree", dir: true))
        #expect(await waitUntil { await q1.snapshot().completedCount == 10 })
        await q1.flush()

        let second = FakeServer()
        for d in ["/d", "/d/tree", "/d/tree/a", "/d/tree/b", "/d/tree/c"] { second.files.makeDir(d) }
        let site2 = second.site(site.id, label: "PROD", max: 3)
        let q2 = makeQueue(env, database: try DockyardDatabase(path: path)) { _ in site2 }
        #expect(await q2.restoredJobCount > 0)
        await q2.resume()
        await q2.waitUntilIdle()
        let snap = await q2.snapshot()
        #expect(snap.completedCount == 30 && snap.failedCount == 0)
        #expect(await q2.job(id)?.state == .completed)
        #expect(await q2.job(id)?.finishedChildCount == 3)
        // The ten files finished before the crash are not sent again.
        let sent = second.files.calls.filter { $0.hasPrefix("upload") }.count
        #expect(sent >= 19 && sent <= 20)
        await q1.shutdown()
        await q2.shutdown()
    }

    @Test func jobsForDeletedConnectionsFailInsteadOfHanging() async throws {
        let env = try TransferEnv()
        let path = env.path("queue.sqlite")
        let server = FakeServer()
        server.files.makeDir("/d")
        let site = server.site(max: 1)
        let q1 = makeQueue(env, database: try DockyardDatabase(path: path))
        await q1.register(site: site)
        await q1.pause()
        try env.write("a", "a")
        await q1.enqueue(upload(env, "a", to: server.endpoint(site), "/d/a"))
        await q1.flush()

        let q2 = makeQueue(env, database: try DockyardDatabase(path: path)) { _ in nil }
        await q2.resume()
        await q2.waitUntilIdle()
        #expect(await q2.snapshot().failedCount == 1)
    }

    @Test func connectionLimitsArePartOfTheStoredConnection() async throws {
        let db = try DockyardDatabase()
        let repo = ConnectionRepository(database: db)
        let connection = Connection(name: "Shared host", host: "h.example", username: "u", maxConnections: 2, connectDelayMs: 750)
        try await repo.save(connection)
        let loaded = try #require(try await repo.connection(id: connection.id))
        #expect(loaded.maxConnections == 2 && loaded.connectDelayMs == 750)
        #expect(Connection(name: "x", host: "h", username: "u", maxConnections: 99).maxConnections == 10)
        #expect(Connection(name: "x", host: "h", username: "u").maxConnections == 3)
    }
}

@Suite struct QueueFolderTests {
    @Test func foldersExpandLazilyAndPersistChildrenAsTheyAreFound() async throws {
        let env = try TransferEnv()
        let server = FakeServer()
        for d in 0..<40 { for f in 0..<20 { server.files.put("/src/d\(String(format: "%02d", d))/f\(f)", "x") } }
        let gate = Gate()
        server.files.setHook { _ in await gate.wait() }
        let site = server.site(max: 1)
        let q = makeQueue(env)
        await q.register(site: site)
        await q.setMaxConcurrent(1)
        let id = await q.enqueue(TransferRequest(
            source: server.endpoint(site), sourcePath: "/src", destination: env.local, destinationPath: env.path("out"), isDirectory: true))
        #expect(await waitUntil { await gate.arrivals == 1 })
        // The first transfer is under way while most folders have not been listed yet.
        let lists = server.files.calls.filter { $0.hasPrefix("list") }.count
        #expect(lists <= 3)
        let known = await q.count(TransferJobFilter(scope: .all))
        #expect(known < 40 * 20)
        #expect(await q.job(id)?.state == .running)
        await gate.open()
        await q.waitUntilIdle()
        #expect(await q.snapshot().completedCount == 800)
        #expect(await q.count(TransferJobFilter(scope: .files, states: [.completed])) == 800)
    }

    @Test func pagingFiltersAndCounts() async throws {
        let env = try TransferEnv()
        let server = FakeServer()
        server.files.makeDir("/d")
        let site = server.site(max: 3)
        let q = makeQueue(env)
        await q.register(site: site)
        var requests: [TransferRequest] = []
        for i in 0..<250 {
            if i % 5 != 0 { try env.write("f\(i)", "x") }  // every fifth source is missing
            requests.append(upload(env, "f\(i)", to: server.endpoint(site), "/d/f\(i)"))
        }
        let ids = await q.enqueue(requests)
        await q.waitUntilIdle()

        #expect(await q.count() == 250)
        #expect(await q.count(TransferJobFilter(states: [.failed])) == 50)
        #expect(await q.count(TransferJobFilter(states: [.completed])) == 200)
        let page = await q.page(offset: 100, limit: 25)
        #expect(page.map(\.id) == Array(ids[100..<125]))
        let failed = await q.page(offset: 10, limit: 100, filter: TransferJobFilter(states: [.failed]))
        #expect(failed.count == 40 && failed.allSatisfy { $0.state == .failed && $0.error != nil })
        #expect(await q.page(offset: 400, limit: 10).isEmpty)
        #expect(await q.page(offset: 0, limit: 10, filter: TransferJobFilter(scope: .topLevel)).count == 10)
    }

    @Test func bulkOperations() async throws {
        let env = try TransferEnv()
        let server = FakeServer()
        server.files.makeDir("/d")
        let site = server.site(max: 3)
        let q = makeQueue(env)
        await q.register(site: site)
        await q.pause()
        var requests: [TransferRequest] = []
        for i in 0..<60 { requests.append(upload(env, "f\(i)", to: server.endpoint(site), "/d/f\(i)")) }
        await q.enqueue(requests)
        await q.cancelAll()
        var snap = await q.snapshot()
        #expect(snap.cancelledCount == 60 && snap.queuedCount == 0 && snap.isIdle)

        await q.removeFinished()  // cancelled jobs stay listed
        #expect(await q.count() == 60)
        await q.resume()
        for i in 0..<60 where i % 2 == 0 { try env.write("f\(i)", "x") }
        await q.retryFailed()  // cancelled is not failed
        #expect(await q.snapshot().queuedCount == 0)

        let ids = await q.enqueue(requests.prefix(10).map { $0 })
        await q.waitUntilIdle()
        snap = await q.snapshot()
        #expect(snap.failedCount + snap.completedCount == 10)
        #expect(snap.failedCount == 5)
        for i in 0..<60 where i % 2 == 1 { try env.write("f\(i)", "x") }
        await q.retryFailed()
        await q.waitUntilIdle()
        #expect(await q.snapshot().failedCount == 0)
        await q.removeFinished()
        #expect(await q.count(TransferJobFilter(scope: .all)) == 60)  // the cancelled ones remain
        _ = ids
    }
}
