import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct ImmediateTransferTests {
    @Test func startsWhileThePausedQueueIsFull() async throws {
        let env = try TransferEnv()
        try env.write("big.txt", "big")
        try env.write("edit.txt", "edit")
        let busy = FakeFileSystem(); busy.makeDir("/d")
        let gate = Gate()
        busy.setHook { _ in await gate.wait() }
        let server = FakeFileSystem(); server.makeDir("/d")
        let q = env.queue(max: 1)
        await q.enqueue(upload(env, "big.txt", to: TransferEndpoint(fs: busy, label: "BUSY"), "/d/big.txt"))
        #expect(await waitUntil { await gate.arrivals == 1 })
        await q.pause()
        var request = upload(env, "edit.txt", to: TransferEndpoint(fs: server, label: "PROD"), "/d/edit.txt")
        request.immediate = true
        let id = await q.enqueue(request)
        #expect(await q.waitUntilFinished(id) == .completed)
        #expect(server.text("/d/edit.txt") == "edit")
        await gate.open()
        await q.shutdown()
    }

    @Test func pauseDoesNotInterruptARunningImmediateJob() async throws {
        let env = try TransferEnv()
        try env.write("edit.txt", "edit")
        let server = FakeFileSystem(); server.makeDir("/d")
        let gate = Gate()
        server.setHook { _ in await gate.wait() }
        let q = env.queue()
        var request = upload(env, "edit.txt", to: TransferEndpoint(fs: server, label: "PROD"), "/d/edit.txt")
        request.immediate = true
        let id = await q.enqueue(request)
        #expect(await waitUntil { await gate.arrivals == 1 })
        await q.pause()
        await gate.open()
        #expect(await q.waitUntilFinished(id) == .completed)
        #expect(server.calls.filter { $0.hasPrefix("upload") }.count == 1)
    }

    @Test func failuresAreNotRetriedFromTheListAndCanBeRemoved() async throws {
        let env = try TransferEnv()
        try env.write("edit.txt", "edit")
        let server = FakeFileSystem(); server.makeDir("/d")
        server.failNext("/d/edit.txt", times: 1, error: RemoteError.permissionDenied("/d/edit.txt"))
        let q = env.queue()
        var request = upload(env, "edit.txt", to: TransferEndpoint(fs: server, label: "PROD"), "/d/edit.txt")
        request.immediate = true
        let id = await q.enqueue(request)
        #expect(await q.waitUntilFinished(id) == .failed)
        #expect(await q.job(id)?.canRetry == false)
        await q.retry(id)
        await q.retryFailed()
        await q.waitUntilIdle()
        #expect(await q.job(id)?.state == .failed)
        #expect(server.text("/d/edit.txt") == nil)
        await q.remove([id])
        #expect(await q.job(id) == nil)
        #expect(await q.snapshot().failedCount == 0)
    }

    @Test func unfinishedAndFailedOnesAreDroppedAtLaunch() async throws {
        let env = try TransferEnv()
        let path = env.path("queue.sqlite")
        try env.write("a.txt", "a")
        try env.write("b.txt", "b")
        let server = FakeFileSystem(); server.makeDir("/d")
        server.failNext("/d/b.txt", times: 1)
        let gate = Gate()
        let q1 = TransferQueue(conflictPolicy: .overwrite, tempDirectory: env.dir.appendingPathComponent(".relay"),
                               progressInterval: 0.005, publishInterval: 0.005, database: try DockyardDatabase(path: path))
        var failing = upload(env, "b.txt", to: TransferEndpoint(fs: server, label: "PROD"), "/d/b.txt")
        failing.immediate = true
        let failed = await q1.enqueue(failing)
        #expect(await q1.waitUntilFinished(failed) == .failed)
        server.setHook { _ in await gate.wait() }
        var running = upload(env, "a.txt", to: TransferEndpoint(fs: server, label: "PROD"), "/d/a.txt")
        running.immediate = true
        await q1.enqueue(running)
        #expect(await waitUntil { await gate.arrivals == 1 })
        await q1.flush()

        let q2 = TransferQueue(conflictPolicy: .overwrite, tempDirectory: env.dir.appendingPathComponent(".relay"),
                               progressInterval: 0.005, publishInterval: 0.005, database: try DockyardDatabase(path: path))
        #expect(await q2.restoredJobCount == 0)
        #expect(await q2.restoredFailedCount == 0)
        #expect(await q2.isPaused == false)
        #expect(await q2.count() == 0)
        await gate.open()
        await q1.shutdown()
    }
}
