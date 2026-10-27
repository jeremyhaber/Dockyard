import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

/// 100,000 tiny files against a fake with no per-file cost. Numbers are printed so they can be recorded.
@Suite(.serialized) struct QueueScaleTests {
    private func makeQueue(_ dir: URL) -> TransferQueue {
        TransferQueue(maxConcurrent: 10, conflictPolicy: .overwrite, tempDirectory: dir.appendingPathComponent(".relay"),
                      progressInterval: 0.5, publishInterval: 0.25)
    }

    private func megabytes(_ bytes: UInt64) -> Int { Int(bytes / 1_048_576) }

    @Test func folderOf100kFilesStartsAtOnceAndCompletes() async throws {
        let env = try TransferEnv()
        let source = GeneratedFileSystem(folders: 0, filesPerFolder: 100_000)
        let target = GeneratedFileSystem(folders: 0, filesPerFolder: 0)
        let q = makeQueue(env.dir)
        let src = TransferSite(id: UUID(), label: "SRC", maxConnections: 10) { source }
        let dst = TransferSite(id: UUID(), label: "DST", maxConnections: 10) { target }
        await q.register(site: src)
        await q.register(site: dst)
        let memoryBefore = residentMemory()

        let started = Date()
        let id = await q.enqueue(TransferRequest(
            source: src.endpoint(fs: source), sourcePath: "/big", destination: dst.endpoint(fs: target),
            destinationPath: "/out", isDirectory: true))
        let enqueueTime = Date().timeIntervalSince(started)
        #expect(enqueueTime < 0.25)
        #expect(await waitUntil(timeout: 10) { target.transfers.withLock { $0 } > 0 })
        let firstTransfer = (target.firstTransfer.withLock { $0 } ?? Date()).timeIntervalSince(started)
        #expect(firstTransfer < 1.0)

        // The actor stays responsive while the folder is listed and worked off.
        var worstPause = 0.0
        while await q.snapshot().queuedCount + (await q.snapshot().activeCount) > 0 {
            let t = Date()
            _ = await q.snapshot()
            worstPause = max(worstPause, Date().timeIntervalSince(t))
            try await Task.sleep(nanoseconds: 200_000_000)
            if Date().timeIntervalSince(started) > 300 { break }
        }
        await q.waitUntilIdle()
        let total = Date().timeIntervalSince(started)
        let snap = await q.snapshot()
        #expect(snap.completedCount == 100_000 && snap.failedCount == 0)
        #expect(await q.job(id)?.state == .completed)
        #expect(target.transfers.withLock { $0 } == 100_000)
        #expect(await q.job(id)?.bytesTotal == 400_000)

        let peak = residentMemory()
        print("SCALE folder: enqueue \(Int(enqueueTime * 1000)) ms, first transfer \(Int(firstTransfer * 1000)) ms, "
              + "total \(String(format: "%.1f", total)) s, worst snapshot \(Int(worstPause * 1000)) ms, "
              + "memory \(memoryBefore.map(megabytes) ?? -1) -> \(peak.map(megabytes) ?? -1) MB")
        if let before = memoryBefore, let after = peak { #expect(megabytes(after) - megabytes(before) < 300) }
        #expect(worstPause < 1.0)
    }

    @Test func foldersWithManySubfoldersAlsoStartAtOnce() async throws {
        let env = try TransferEnv()
        let source = GeneratedFileSystem(folders: 500, filesPerFolder: 200)
        let target = GeneratedFileSystem(folders: 0, filesPerFolder: 0)
        let q = makeQueue(env.dir)
        let src = TransferSite(id: UUID(), label: "SRC", maxConnections: 10) { source }
        let dst = TransferSite(id: UUID(), label: "DST", maxConnections: 10) { target }
        await q.register(site: src)
        await q.register(site: dst)
        let started = Date()
        await q.enqueue(TransferRequest(
            source: src.endpoint(fs: source), sourcePath: "/big", destination: dst.endpoint(fs: target),
            destinationPath: "/out", isDirectory: true))
        #expect(await waitUntil(timeout: 10) { target.transfers.withLock { $0 } > 0 })
        let first = (target.firstTransfer.withLock { $0 } ?? Date()).timeIntervalSince(started)
        #expect(first < 1.0)
        await q.waitUntilIdle()
        let snap = await q.snapshot()
        print("SCALE 500x200: first transfer \(Int(first * 1000)) ms, total \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        #expect(snap.completedCount == 100_000 && snap.failedCount == 0)
    }

    @Test func hundredThousandIndividuallyEnqueuedFiles() async throws {
        let env = try TransferEnv()
        let source = GeneratedFileSystem(folders: 0, filesPerFolder: 0)
        let q = makeQueue(env.dir)
        let src = TransferSite(id: UUID(), label: "SRC", maxConnections: 10) { source }
        await q.register(site: src)
        let endpoint = src.endpoint(fs: source)
        let mac = env.local
        let memoryBefore = residentMemory()

        let started = Date()
        for i in 0..<100_000 {
            await q.enqueue(TransferRequest(
                source: endpoint, sourcePath: "/big/f\(i)", destination: mac, destinationPath: env.path("out/f\(i)"), size: 4))
        }
        let enqueueTime = Date().timeIntervalSince(started)
        let first = (source.firstTransfer.withLock { $0 } ?? Date()).timeIntervalSince(started)
        #expect(first < 1.0)
        let memoryQueued = residentMemory()
        await q.waitUntilIdle()
        let total = Date().timeIntervalSince(started)
        let snap = await q.snapshot()
        #expect(snap.completedCount + snap.skippedCount == 100_000 && snap.failedCount == 0)
        #expect(source.transfers.withLock { $0 } == 100_000)
        print("SCALE singles: enqueue loop \(String(format: "%.1f", enqueueTime)) s, first transfer \(Int(first * 1000)) ms, "
              + "total \(String(format: "%.1f", total)) s, memory \(memoryBefore.map(megabytes) ?? -1) -> \(memoryQueued.map(megabytes) ?? -1) MB")
        if let before = memoryBefore, let after = memoryQueued { #expect(megabytes(after) - megabytes(before) < 300) }
        #expect(await q.count(TransferJobFilter(states: [.completed])) == 100_000)
    }

    @Test func pagingStaysFastWithHugeQueues() async throws {
        let env = try TransferEnv()
        let source = GeneratedFileSystem(folders: 0, filesPerFolder: 20_000)
        let q = makeQueue(env.dir)
        let src = TransferSite(id: UUID(), label: "SRC", maxConnections: 10) { source }
        await q.register(site: src)
        await q.pause()
        await q.enqueue(TransferRequest(
            source: src.endpoint(fs: source), sourcePath: "/big", destination: env.local, destinationPath: env.path("out"), isDirectory: true))
        await q.resume()
        await q.waitUntilIdle()
        let t = Date()
        let page = await q.page(offset: 19_000, limit: 100)
        let elapsed = Date().timeIntervalSince(t)
        #expect(page.count == 100 && page.allSatisfy { $0.state == .completed })
        #expect(elapsed < 0.5)
    }
}
