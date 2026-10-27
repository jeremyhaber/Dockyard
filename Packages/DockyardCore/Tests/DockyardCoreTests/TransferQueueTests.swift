import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}

actor Arrivals {
    private(set) var count = 0
    func hit() { count += 1 }
}

final class TransferEnv: Sendable {
    let dir: URL
    let mac = LocalFileSystem()
    init() throws { dir = try makeTempDir("xfer") }
    deinit { try? FileManager.default.removeItem(at: dir) }

    func path(_ rel: String) -> String { dir.appendingPathComponent(rel).path }
    func write(_ rel: String, _ text: String, modified: Date? = nil) throws {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }
    func read(_ rel: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8) }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: path(rel)) }
    var local: TransferEndpoint { .thisMac(mac) }

    func queue(max: Int = 3, policy: ConflictPolicy = .overwrite, resolver: ConflictResolver? = nil) -> TransferQueue {
        TransferQueue(maxConcurrent: max, conflictPolicy: policy, resolver: resolver,
                      tempDirectory: dir.appendingPathComponent(".relay"), progressInterval: 0.005, publishInterval: 0.005)
    }
}

func upload(_ env: TransferEnv, _ rel: String, to server: TransferEndpoint, _ dest: String, dir: Bool = false, size: UInt64? = nil, modified: Date? = nil) -> TransferRequest {
    TransferRequest(source: env.local, sourcePath: env.path(rel), destination: server, destinationPath: dest, isDirectory: dir, size: size, modified: modified)
}

@Suite struct TransferQueueTests {
    @Test func uploadsAFile() async throws {
        let env = try TransferEnv()
        try env.write("a.txt", "hello")
        let server = FakeFileSystem(); server.makeDir("/www")
        let q = env.queue()
        let id = await q.enqueue(upload(env, "a.txt", to: TransferEndpoint(fs: server, label: "PROD"), "/www/a.txt"))
        await q.waitUntilIdle()
        #expect(server.text("/www/a.txt") == "hello")
        let job = try #require(await q.job(id))
        #expect(job.state == .completed)
        #expect(job.fraction == 1)
        #expect(job.bytesDone == 5 && job.bytesTotal == 5)
        #expect(job.route == "This Mac → PROD")
        let snap = await q.snapshot()
        #expect(snap.completedCount == 1 && snap.isIdle)
    }

    @Test func downloadPreservesTimestamp() async throws {
        let env = try TransferEnv()
        let server = FakeFileSystem()
        let mtime = Date(timeIntervalSince1970: 1_600_000_000)
        server.put("/data/f.txt", "payload", modified: mtime)
        let q = env.queue()
        await q.enqueue(items: try await server.list("/data"), from: TransferEndpoint(fs: server, label: "PROD"), to: env.local, into: env.dir.path)
        await q.waitUntilIdle()
        #expect(env.read("f.txt") == "payload")
        let attrs = try FileManager.default.attributesOfItem(atPath: env.path("f.txt"))
        #expect(abs((attrs[.modificationDate] as! Date).timeIntervalSince(mtime)) < 1)
    }

    @Test func timestampPreservationCanBeDisabled() async throws {
        let env = try TransferEnv()
        let server = FakeFileSystem()
        server.put("/f.txt", "x", modified: Date(timeIntervalSince1970: 1_000_000_000))
        let q = TransferQueue(preserveTimestamps: false, tempDirectory: env.dir, progressInterval: 0.005)
        await q.enqueue(items: try await server.list("/"), from: TransferEndpoint(fs: server, label: "S"), to: env.local, into: env.dir.path)
        await q.waitUntilIdle()
        let m = try FileManager.default.attributesOfItem(atPath: env.path("f.txt"))[.modificationDate] as! Date
        #expect(m.timeIntervalSince1970 > 1_500_000_000)
    }

    @Test func respectsConcurrencyLimit() async throws {
        let env = try TransferEnv()
        let server = FakeFileSystem(); server.makeDir("/d")
        for i in 0..<8 { try env.write("f\(i).txt", "data\(i)") }
        let gate = Gate()
        server.setHook { _ in await gate.wait() }
        let q = env.queue(max: 3)
        let ep = TransferEndpoint(fs: server, label: "PROD")
        for i in 0..<8 { await q.enqueue(upload(env, "f\(i).txt", to: ep, "/d/f\(i).txt")) }
        #expect(await waitUntil { await gate.arrivals == 3 })
        try await Task.sleep(nanoseconds: 50_000_000)
        var snap = await q.snapshot()
        #expect(snap.activeCount == 3 && snap.queuedCount == 5)
        #expect(snap.currentRoute == "This Mac → PROD")
        await q.setMaxConcurrent(5)
        #expect(await waitUntil { await gate.arrivals == 5 })
        await gate.open()
        await q.waitUntilIdle()
        snap = await q.snapshot()
        #expect(snap.completedCount == 8)
        #expect(server.maxActive == 5)
    }

    @Test func defaultGlobalCapIsTen() async {
        let q = TransferQueue()
        #expect(await q.maxConcurrent == 10)
        await q.setMaxConcurrent(0)
        #expect(await q.maxConcurrent == 1)
    }

    // MARK: Conflicts

    func conflictSetup() throws -> (TransferEnv, FakeFileSystem, TransferEndpoint) {
        let env = try TransferEnv()
        let server = FakeFileSystem()
        server.put("/d/a.txt", "old", modified: Date(timeIntervalSince1970: 1_700_000_000))
        try env.write("a.txt", "new", modified: Date(timeIntervalSince1970: 1_700_100_000))
        return (env, server, TransferEndpoint(fs: server, label: "PROD"))
    }

    @Test func policyOverwrite() async throws {
        let (env, server, ep) = try conflictSetup()
        let q = env.queue(policy: .overwrite)
        await q.enqueue(upload(env, "a.txt", to: ep, "/d/a.txt"))
        await q.waitUntilIdle()
        #expect(server.text("/d/a.txt") == "new")
    }

    @Test func policySkip() async throws {
        let (env, server, ep) = try conflictSetup()
        let q = env.queue(policy: .skip)
        let id = await q.enqueue(upload(env, "a.txt", to: ep, "/d/a.txt"))
        await q.waitUntilIdle()
        #expect(server.text("/d/a.txt") == "old")
        #expect(await q.job(id)?.state == .skipped)
        #expect(await q.snapshot().skippedCount == 1)
    }

    @Test func policyOverwriteIfNewer() async throws {
        let (env, server, ep) = try conflictSetup()
        let q = env.queue(policy: .overwriteIfNewer)
        // Local file is newer: overwritten.
        await q.enqueue(upload(env, "a.txt", to: ep, "/d/a.txt", modified: Date(timeIntervalSince1970: 1_700_100_000)))
        await q.waitUntilIdle()
        #expect(server.text("/d/a.txt") == "new")
        // Older local file: skipped.
        try env.write("b.txt", "older")
        server.put("/d/b.txt", "server-newer", modified: Date(timeIntervalSince1970: 1_800_000_000))
        let id = await q.enqueue(upload(env, "b.txt", to: ep, "/d/b.txt", modified: Date(timeIntervalSince1970: 1_700_000_000)))
        await q.waitUntilIdle()
        #expect(server.text("/d/b.txt") == "server-newer")
        #expect(await q.job(id)?.state == .skipped)
        // Within tolerance counts as not newer.
        server.put("/d/c.txt", "same", modified: Date(timeIntervalSince1970: 1_700_000_000))
        try env.write("c.txt", "tiny-diff")
        let idc = await q.enqueue(upload(env, "c.txt", to: ep, "/d/c.txt", modified: Date(timeIntervalSince1970: 1_700_000_000.5)))
        await q.waitUntilIdle()
        #expect(await q.job(idc)?.state == .skipped)
    }

    @Test func policyRenameFindsFreeName() async throws {
        let (env, server, ep) = try conflictSetup()
        server.put("/d/a (1).txt", "taken")
        let q = env.queue(policy: .rename)
        let id = await q.enqueue(upload(env, "a.txt", to: ep, "/d/a.txt"))
        await q.waitUntilIdle()
        #expect(server.text("/d/a.txt") == "old")
        #expect(server.text("/d/a (1).txt") == "taken")
        #expect(server.text("/d/a (2).txt") == "new")
        #expect(await q.job(id)?.destinationPath == "/d/a (2).txt")
    }

    @Test func askUsesResolverAndApplyToAllPromptsOnce() async throws {
        let env = try TransferEnv()
        let server = FakeFileSystem()
        for n in ["a", "b", "c"] { server.put("/d/\(n).txt", "old"); try env.write("\(n).txt", "new-\(n)") }
        let asked = LockedBox<[ConflictInfo]>([])
        let q = env.queue(max: 3, policy: .ask) { info in
            asked.withLock { $0.append(info) }
            try? await Task.sleep(nanoseconds: 30_000_000)  // concurrent conflicts must queue behind this prompt
            return ConflictDecision(.overwrite, applyToAll: true)
        }
        let ep = TransferEndpoint(fs: server, label: "PROD")
        for n in ["a", "b", "c"] { await q.enqueue(upload(env, "\(n).txt", to: ep, "/d/\(n).txt")) }
        await q.waitUntilIdle()
        #expect(asked.withLock { $0.count } == 1)
        #expect(["a", "b", "c"].allSatisfy { server.text("/d/\($0).txt") == "new-\($0)" })
        #expect(await q.conflictPolicy == .overwrite)
        let info = try #require(asked.withLock { $0.first })
        #expect(info.destinationSize == 3 && info.route == "This Mac → PROD")
    }

    @Test func askWithoutApplyToAllPromptsEachTime() async throws {
        let env = try TransferEnv()
        let server = FakeFileSystem()
        for n in ["a", "b", "c"] { server.put("/d/\(n).txt", "old"); try env.write("\(n).txt", "new") }
        let count = LockedBox(0)
        let q = env.queue(max: 3, policy: .ask) { info in
            let n = count.withLock { $0 += 1; return $0 }
            return ConflictDecision(n == 2 ? .skip : .overwrite)
        }
        let ep = TransferEndpoint(fs: server, label: "S")
        for n in ["a", "b", "c"] { await q.enqueue(upload(env, "\(n).txt", to: ep, "/d/\(n).txt")) }
        await q.waitUntilIdle()
        #expect(count.withLock { $0 } == 3)
        let snap = await q.snapshot()
        #expect(snap.skippedCount == 1 && snap.completedCount == 2)
    }

    @Test func askWithoutResolverNeverOverwrites() async throws {
        let (env, server, ep) = try conflictSetup()
        let q = env.queue(policy: .ask, resolver: nil)
        await q.enqueue(upload(env, "a.txt", to: ep, "/d/a.txt"))
        await q.waitUntilIdle()
        #expect(server.text("/d/a.txt") == "old")
    }

    @Test func askCancelWithApplyToAllCancelsEverything() async throws {
        let env = try TransferEnv()
        let server = FakeFileSystem()
        for n in ["a", "b"] { server.put("/d/\(n).txt", "old"); try env.write("\(n).txt", "new") }
        let q = env.queue(max: 1, policy: .ask) { _ in ConflictDecision(.cancel, applyToAll: true) }
        let ep = TransferEndpoint(fs: server, label: "S")
        let ids = await q.enqueue(["a", "b"].map { upload(env, "\($0).txt", to: ep, "/d/\($0).txt") })
        await q.waitUntilIdle()
        #expect(server.text("/d/a.txt") == "old" && server.text("/d/b.txt") == "old")
        for id in ids { #expect(await q.job(id)?.state == .cancelled) }
    }

    @Test func folderAtDestinationWhereFileExpectedFails() async throws {
        let (env, server, ep) = try conflictSetup()
        server.makeDir("/d/clash")
        try env.write("clash", "file")
        let q = env.queue()
        let id = await q.enqueue(upload(env, "clash", to: ep, "/d/clash"))
        await q.waitUntilIdle()
        let job = try #require(await q.job(id))
        #expect(job.state == .failed)
        #expect(job.error?.contains("folder") == true)
    }

    // MARK: Folders

    @Test func recursiveFolderUpload() async throws {
        let env = try TransferEnv()
        try env.write("site/index.html", "<html>")
        try env.write("site/css/main.css", "body{}")
        try env.write("site/css/deep/x.css", "x")
        try FileManager.default.createDirectory(at: env.dir.appendingPathComponent("site/empty"), withIntermediateDirectories: true)
        let server = FakeFileSystem(); server.makeDir("/www")
        let q = env.queue()
        let id = await q.enqueue(upload(env, "site", to: TransferEndpoint(fs: server, label: "PROD"), "/www/site", dir: true))
        await q.waitUntilIdle()
        #expect(server.text("/www/site/index.html") == "<html>")
        #expect(server.text("/www/site/css/main.css") == "body{}")
        #expect(server.text("/www/site/css/deep/x.css") == "x")
        #expect(server.hasDir("/www/site/empty"))
        let job = try #require(await q.job(id))
        #expect(job.state == .completed)
        #expect(job.childCount == 3)  // css, empty, index.html
        #expect(job.finishedChildCount == 3)
        #expect(job.bytesTotal == 6 + 6 + 1)
        #expect(job.fraction == 1)
        let snap = await q.snapshot()
        #expect(snap.jobs.count == 1)  // only the top level shows
        #expect(snap.completedCount == 3 && snap.isIdle)
    }

    @Test func recursiveFolderDownloadIsDepthFirstPerFolderAndMergesExisting() async throws {
        let env = try TransferEnv()
        let server = FakeFileSystem()
        server.put("/src/a/1.txt", "1"); server.put("/src/a/b/2.txt", "2"); server.put("/src/3.txt", "3")
        try env.write("dst/src/keep.txt", "keep")
        let q = env.queue(max: 1)
        let item = try #require(try await server.list("/").first)
        await q.enqueue(items: [item], from: TransferEndpoint(fs: server, label: "S"), to: env.local, into: env.path("dst"))
        await q.waitUntilIdle()
        #expect(env.read("dst/src/a/1.txt") == "1")
        #expect(env.read("dst/src/a/b/2.txt") == "2")
        #expect(env.read("dst/src/3.txt") == "3")
        #expect(env.read("dst/src/keep.txt") == "keep")
    }

    @Test func shallowFolderOnlyCreatesDirectory() async throws {
        let env = try TransferEnv()
        try env.write("site/index.html", "x")
        let server = FakeFileSystem()
        let q = env.queue()
        var req = upload(env, "site", to: TransferEndpoint(fs: server, label: "S"), "/a/b/site", dir: true)
        req.recursive = false
        req.createParents = true
        await q.enqueue(req)
        await q.waitUntilIdle()
        #expect(server.hasDir("/a/b/site"))
        #expect(server.text("/a/b/site/index.html") == nil)
    }

    @Test func emptyFolderCompletes() async throws {
        let env = try TransferEnv()
        try FileManager.default.createDirectory(at: env.dir.appendingPathComponent("e"), withIntermediateDirectories: true)
        let server = FakeFileSystem()
        let q = env.queue()
        let id = await q.enqueue(upload(env, "e", to: TransferEndpoint(fs: server, label: "S"), "/e", dir: true))
        await q.waitUntilIdle()
        #expect(await q.job(id)?.state == .completed)
        #expect(server.hasDir("/e"))
    }

    @Test func failedChildFailsFolderAndRetryCompletesIt() async throws {
        let env = try TransferEnv()
        try env.write("site/a.txt", "a"); try env.write("site/b.txt", "b")
        let server = FakeFileSystem()
        server.failNext("/site/b.txt", times: 1)
        let q = env.queue()
        let id = await q.enqueue(upload(env, "site", to: TransferEndpoint(fs: server, label: "S"), "/site", dir: true))
        await q.waitUntilIdle()
        var job = try #require(await q.job(id))
        #expect(job.state == .failed)
        #expect(job.error == "1 item failed")
        #expect(server.text("/site/a.txt") == "a" && server.text("/site/b.txt") == nil)
        let failedChild = try #require(await q.children(of: id).first { $0.state == .failed })
        #expect(failedChild.error == "Protocol error: boom")
        await q.retry(id)  // retrying the folder retries only the failed children
        await q.waitUntilIdle()
        job = try #require(await q.job(id))
        #expect(job.state == .completed)
        #expect(server.text("/site/b.txt") == "b")
        #expect(server.calls.filter { $0 == "upload /site/a.txt resume=false" }.count == 1)
    }

    @Test func folderSymlinksAreNotFollowed() async throws {
        // Real file system: a symlink to a directory must not be descended into.
        let env = try TransferEnv()
        try env.write("src/real/file.txt", "x")
        try FileManager.default.createSymbolicLink(atPath: env.path("src/link"), withDestinationPath: env.path("src/real"))
        let server = FakeFileSystem()
        let q = env.queue()
        let id = await q.enqueue(upload(env, "src", to: TransferEndpoint(fs: server, label: "S"), "/src", dir: true))
        await q.waitUntilIdle()
        #expect(await q.job(id)?.state == .completed)
        #expect(server.text("/src/real/file.txt") == "x")
        #expect(!server.hasDir("/src/link"))
    }

    // MARK: Cancel / retry / resume

    @Test func cancelRunningTransfer() async throws {
        let env = try TransferEnv()
        try env.write("a.txt", "a")
        let server = FakeFileSystem(); server.makeDir("/d")
        let gate = Arrivals()
        server.setHook { _ in await gate.hit(); try await Task.sleep(nanoseconds: 5_000_000_000) }
        let q = env.queue()
        let id = await q.enqueue(upload(env, "a.txt", to: TransferEndpoint(fs: server, label: "S"), "/d/a.txt"))
        #expect(await waitUntil { await gate.count == 1 })
        await q.cancel(id)
        await q.waitUntilIdle()
        #expect(await q.job(id)?.state == .cancelled)
        #expect(server.text("/d/a.txt") == nil)
    }

    @Test func cancelQueuedAndCancelAll() async throws {
        let env = try TransferEnv()
        for i in 0..<4 { try env.write("f\(i)", "x") }
        let server = FakeFileSystem(); server.makeDir("/d")
        let gate = Gate()
        server.setHook { _ in await gate.wait() }
        let q = env.queue(max: 1)
        let ep = TransferEndpoint(fs: server, label: "S")
        let ids = await q.enqueue((0..<4).map { upload(env, "f\($0)", to: ep, "/d/f\($0)") })
        #expect(await waitUntil { await gate.arrivals == 1 })
        await q.cancel(ids[3])
        #expect(await q.job(ids[3])?.state == .cancelled)
        await q.cancelAll()
        await gate.open()
        await q.waitUntilIdle()
        for id in ids { #expect(await q.job(id)?.state == .cancelled) }
        #expect(await q.snapshot().isIdle)
    }

    @Test func cancellingAFolderCancelsItsChildren() async throws {
        let env = try TransferEnv()
        for i in 0..<5 { try env.write("site/f\(i)", "x") }
        let server = FakeFileSystem()
        let gate = Arrivals()
        server.setHook { _ in await gate.hit(); try await Task.sleep(nanoseconds: 5_000_000_000) }
        let q = env.queue(max: 2)
        let id = await q.enqueue(upload(env, "site", to: TransferEndpoint(fs: server, label: "S"), "/site", dir: true))
        #expect(await waitUntil { await gate.count == 2 })
        await q.cancel(id)
        await q.waitUntilIdle()
        #expect(await q.job(id)?.state == .cancelled)
        #expect(await q.children(of: id).allSatisfy { $0.state == .cancelled })
    }

    @Test func failedUploadResumesOnRetry() async throws {
        let env = try TransferEnv()
        let content = String(repeating: "0123456789", count: 10)
        try env.write("big.bin", content)
        let server = FakeFileSystem(); server.makeDir("/d")
        server.failAfter(bytes: 40, path: "/d/big.bin")
        let q = env.queue(policy: .skip)  // a retry must not be treated as a conflict with its own partial file
        let id = await q.enqueue(upload(env, "big.bin", to: TransferEndpoint(fs: server, label: "S"), "/d/big.bin"))
        await q.waitUntilIdle()
        var job = try #require(await q.job(id))
        #expect(job.state == .failed)
        #expect(server.text("/d/big.bin")?.count == 40)
        #expect(job.willResume)
        await q.retry(id)
        await q.waitUntilIdle()
        job = try #require(await q.job(id))
        #expect(job.state == .completed)
        #expect(server.text("/d/big.bin") == content)
        #expect(server.calls.filter { $0.hasPrefix("upload") } == ["upload /d/big.bin resume=false", "upload /d/big.bin resume=true"])
    }

    @Test func failedDownloadResumesOnRetry() async throws {
        let env = try TransferEnv()
        let content = String(repeating: "abcdefghij", count: 10)
        let server = FakeFileSystem(); server.put("/big", content)
        server.failAfter(bytes: 25, path: "/big")
        let q = env.queue(policy: .skip)
        let ids = await q.enqueue(items: try await server.list("/"), from: TransferEndpoint(fs: server, label: "S"), to: env.local, into: env.dir.path)
        await q.waitUntilIdle()
        #expect(await q.job(ids[0])?.state == .failed)
        #expect(env.read("big")?.count == 25)
        await q.retry(ids[0])
        await q.waitUntilIdle()
        #expect(await q.job(ids[0])?.state == .completed)
        #expect(env.read("big") == content)
    }

    @Test func retryFailedRequeuesOnlyFailures() async throws {
        let env = try TransferEnv()
        try env.write("a", "a"); try env.write("b", "b")
        let server = FakeFileSystem(); server.makeDir("/d")
        server.failNext("/d/a", times: 1)
        let q = env.queue()
        let ep = TransferEndpoint(fs: server, label: "S")
        let ids = await q.enqueue(["a", "b"].map { upload(env, $0, to: ep, "/d/\($0)") })
        await q.waitUntilIdle()
        #expect(await q.snapshot().failedCount == 1)
        await q.retryFailed()
        await q.waitUntilIdle()
        #expect(await q.job(ids[0])?.state == .completed)
        #expect(server.calls.filter { $0 == "upload /d/b resume=false" }.count == 1)
    }

    @Test func retryIgnoresCompletedJobs() async throws {
        let env = try TransferEnv()
        try env.write("a", "a")
        let server = FakeFileSystem(); server.makeDir("/d")
        let q = env.queue()
        let id = await q.enqueue(upload(env, "a", to: TransferEndpoint(fs: server, label: "S"), "/d/a"))
        await q.waitUntilIdle()
        await q.retry(id)
        await q.waitUntilIdle()
        #expect(server.calls.filter { $0.hasPrefix("upload") }.count == 1)
    }

    @Test func removeFinishedKeepsFailures() async throws {
        let env = try TransferEnv()
        try env.write("a", "a"); try env.write("b", "b")
        let server = FakeFileSystem(); server.makeDir("/d")
        server.failNext("/d/b", times: 5)
        let q = env.queue()
        let ep = TransferEndpoint(fs: server, label: "S")
        await q.enqueue(["a", "b"].map { upload(env, $0, to: ep, "/d/\($0)") })
        await q.waitUntilIdle()
        await q.removeFinished()
        let snap = await q.snapshot()
        #expect(snap.jobs.count == 1 && snap.jobs[0].state == .failed)
    }

    // MARK: Relay and move

    @Test func relaysBetweenServersAndCleansTempFiles() async throws {
        let env = try TransferEnv()
        let prod = FakeFileSystem(name: "prod"), stg = FakeFileSystem(name: "stg")
        prod.put("/site/index.html", "hello"); prod.put("/site/img/a.png", "png")
        stg.makeDir("/www")
        let q = env.queue()
        let item = try #require(try await prod.list("/").first)
        let ids = await q.enqueue(items: [item], from: TransferEndpoint(fs: prod, label: "PROD"), to: TransferEndpoint(fs: stg, label: "STG"), into: "/www")
        // The snapshot taken while running reports the route.
        await q.waitUntilIdle()
        #expect(stg.text("/www/site/index.html") == "hello")
        #expect(stg.text("/www/site/img/a.png") == "png")
        let job = try #require(await q.job(ids[0]))
        #expect(job.route == "PROD → STG")
        #expect(job.isRelay)
        #expect(job.state == .completed)
        let relayDir = env.dir.appendingPathComponent(".relay")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: relayDir.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func relayReportsRouteWhileRunning() async throws {
        let env = try TransferEnv()
        let prod = FakeFileSystem(), stg = FakeFileSystem()
        prod.put("/f", "x"); stg.makeDir("/d")
        let gate = Gate()
        stg.setHook { _ in await gate.wait() }
        let q = env.queue()
        await q.enqueue(items: try await prod.list("/"), from: TransferEndpoint(fs: prod, label: "PROD"), to: TransferEndpoint(fs: stg, label: "STG"), into: "/d")
        #expect(await waitUntil { await gate.arrivals == 1 })
        let snap = await q.snapshot()
        #expect(snap.currentRoute == "PROD → STG" && snap.currentIsRelay)
        await gate.open()
        await q.waitUntilIdle()
    }

    @Test func relayFailureOnUploadSideLeavesNoTempFile() async throws {
        let env = try TransferEnv()
        let prod = FakeFileSystem(), stg = FakeFileSystem()
        prod.put("/f", "x")  // destination dir missing -> upload fails
        let q = env.queue()
        let ids = await q.enqueue(items: try await prod.list("/"), from: TransferEndpoint(fs: prod, label: "A"), to: TransferEndpoint(fs: stg, label: "B"), into: "/nope")
        await q.waitUntilIdle()
        #expect(await q.job(ids[0])?.state == .failed)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: env.dir.appendingPathComponent(".relay").path)) ?? []).isEmpty)
    }

    @Test func moveDeletesSourceOnlyAfterSuccess() async throws {
        let env = try TransferEnv()
        let a = FakeFileSystem(), b = FakeFileSystem()
        a.put("/x/1", "1"); a.put("/x/2", "2"); a.put("/solo", "s")
        b.makeDir("/in")
        let q = env.queue()
        let items = try await a.list("/")
        await q.enqueue(items: items, from: TransferEndpoint(fs: a, label: "A"), to: TransferEndpoint(fs: b, label: "B"), into: "/in", move: true)
        await q.waitUntilIdle()
        #expect(b.text("/in/x/1") == "1" && b.text("/in/solo") == "s")
        #expect(a.text("/solo") == nil && a.text("/x/1") == nil)
        #expect(!a.hasDir("/x"))
    }

    @Test func moveKeepsSourceFolderWhenSomethingWasSkipped() async throws {
        let env = try TransferEnv()
        let a = FakeFileSystem(), b = FakeFileSystem()
        a.put("/x/1", "1"); a.put("/x/2", "2"); b.put("/in/x/2", "existing")
        let q = env.queue(policy: .skip)
        await q.enqueue(items: try await a.list("/"), from: TransferEndpoint(fs: a, label: "A"), to: TransferEndpoint(fs: b, label: "B"), into: "/in", move: true)
        await q.waitUntilIdle()
        #expect(a.hasDir("/x"))
        #expect(a.text("/x/2") == "2")
        #expect(a.text("/x/1") == nil)
    }

    @Test func createParentsMakesMissingFolders() async throws {
        let env = try TransferEnv()
        try env.write("a", "a")
        let server = FakeFileSystem()
        var req = upload(env, "a", to: TransferEndpoint(fs: server, label: "S"), "/x/y/z/a")
        req.createParents = true
        let q = env.queue()
        await q.enqueue(req)
        await q.waitUntilIdle()
        #expect(server.text("/x/y/z/a") == "a")
    }

    @Test func missingSourceFails() async throws {
        let env = try TransferEnv()
        let server = FakeFileSystem(); server.makeDir("/d")
        let q = env.queue()
        let id = await q.enqueue(upload(env, "nope.txt", to: TransferEndpoint(fs: server, label: "S"), "/d/nope.txt"))
        await q.waitUntilIdle()
        #expect(await q.job(id)?.state == .failed)
    }

    // MARK: Observation and log

    @Test func updatesStreamEndsAtIdleSnapshot() async throws {
        let env = try TransferEnv()
        try env.write("a", "aaaa")
        let server = FakeFileSystem(); server.makeDir("/d")
        let q = env.queue()
        let stream = await q.updates()
        let watcher = Task { await firstValue(stream) { $0.completedCount == 1 && $0.isIdle } }
        await q.enqueue(upload(env, "a", to: TransferEndpoint(fs: server, label: "S"), "/d/a"))
        #expect(await watcher.value != nil)
    }

    @Test func logGetsStatusAndErrorLinesWithoutSecrets() async throws {
        let env = try TransferEnv()
        try env.write("a", "a")
        let server = FakeFileSystem()  // no /d -> failure
        let q = env.queue()
        let logs = q.log.stream()
        let collector = Task { () -> [LogLine] in
            var out: [LogLine] = []
            for await l in logs { out.append(l); if l.kind == .error { break } }
            return out
        }
        await q.enqueue(upload(env, "a", to: TransferEndpoint(fs: server, label: "PROD"), "/d/a"))
        let lines = await collector.value
        #expect(lines.first?.message.contains("Uploading a (This Mac → PROD)") == true)
        #expect(lines.last?.kind == .error)
    }
}

@Suite struct LocalFileSystemTests {
    @Test func listStatAndBasicOperations() async throws {
        let env = try TransferEnv()
        try env.write("d/a.txt", "hello")
        let fs = LocalFileSystem()
        let items = try await fs.list(env.path("d"))
        #expect(items.count == 1 && items[0].size == 5 && !items[0].isDirectory && items[0].modified != nil)
        #expect(items[0].permissions != nil)
        try await fs.mkdir(env.path("d/sub/deeper"))
        #expect(try await fs.exists(env.path("d/sub/deeper")))
        try await fs.rename(env.path("d/a.txt"), env.path("d/b.txt"))
        #expect(env.exists("d/b.txt") && !env.exists("d/a.txt"))
        await #expect(throws: RemoteError.self) { try await fs.delete(env.path("d"), recursive: false) }
        try await fs.delete(env.path("d"), recursive: true)
        #expect(!env.exists("d"))
        await #expect(throws: RemoteError.notFound(env.path("nope"))) { _ = try await fs.list(env.path("nope")) }
    }

    @Test func copyResumesPartialFile() async throws {
        let env = try TransferEnv()
        try env.write("src", "0123456789")
        try env.write("dst", "01234")
        let p = Progress(totalUnitCount: 0)
        try await LocalFileSystem().upload(URL(fileURLWithPath: env.path("src")), to: env.path("dst"), progress: p, resume: true)
        #expect(env.read("dst") == "0123456789")
        #expect(p.completedUnitCount == 10)
        // Without resume the file is rewritten.
        try env.write("dst", "garbage-longer-than-source")
        try await LocalFileSystem().upload(URL(fileURLWithPath: env.path("src")), to: env.path("dst"), progress: Progress(totalUnitCount: 0), resume: false)
        #expect(env.read("dst") == "0123456789")
    }

    @Test func chmodAndHome() async throws {
        let env = try TransferEnv()
        try env.write("f", "x")
        let fs = LocalFileSystem()
        try await fs.chmod(env.path("f"), mode: 0o600)
        #expect(try await fs.list(env.dir.path).first { $0.name == "f" }?.permissions == 0o600)
        #expect(try await fs.homeDirectory() == NSHomeDirectory())
    }
}
