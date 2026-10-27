import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct TransferHooksTests {
    func register(_ q: TransferQueue, _ fs: any RemoteFileSystem, filter: TransferFilter = .none, verify: Bool = false,
                  before: (@Sendable (String, any RemoteFileSystem) async throws -> Void)? = nil) async -> TransferEndpoint {
        let site = TransferSite(id: UUID(), label: "PROD", filter: filter, verifyChecksums: verify, beforeOverwrite: before) { fs }
        await q.register(site: site)
        return site.endpoint(fs: fs)
    }

    // MARK: Overwrite hook

    @Test func beforeOverwriteRunsOnlyWhenAFileIsReplaced() async throws {
        let env = try TransferEnv()
        try env.write("a.txt", "new")
        try env.write("b.txt", "fresh")
        let server = FakeFileSystem(); server.makeDir("/www"); server.put("/www/a.txt", "old")
        let calls = LockedBox<[String]>([])
        let q = env.queue()
        let ep = await register(q, server) { path, _ in calls.withLock { $0.append(path) } }
        await q.enqueue([upload(env, "a.txt", to: ep, "/www/a.txt"), upload(env, "b.txt", to: ep, "/www/b.txt")])
        await q.waitUntilIdle()
        #expect(calls.withLock { $0 } == ["/www/a.txt"])
        #expect(server.text("/www/a.txt") == "new" && server.text("/www/b.txt") == "fresh")
    }

    @Test func overwriteKeepsTheOldVersionThroughTheSafetyNet() async throws {
        let env = try TransferEnv()
        try env.write("a.txt", "new")
        let server = ShellFakeFileSystem(home: "/home/u")
        server.base.makeDir("/home/u/www"); server.base.put("/home/u/www/a.txt", "old")
        let net = SafetyNet(
            policy: SafetyPolicy(keepVersionsOnOverwrite: true), clock: ManualClock(start: Date(timeIntervalSince1970: 1_793_102_400)),
            timeZone: TimeZone(identifier: "UTC")!)
        let q = env.queue()
        let ep = await register(q, server) { path, fs in _ = try await net.prepareOverwrite(path: path, on: fs) }
        await q.enqueue(upload(env, "a.txt", to: ep, "/home/u/www/a.txt"))
        await q.waitUntilIdle()
        #expect(server.base.text("/home/u/www/a.txt") == "new")
        #expect(server.base.text("/home/u/.dockyard-trash/2026-10-27/home/u/www/a.txt") == "old")
    }

    @Test func declinedBackupFailsTheItemAndLeavesTheFile() async throws {
        let env = try TransferEnv()
        try env.write("a.txt", "new")
        let server = FakeFileSystem(); server.makeDir("/www"); server.put("/www/a.txt", "old")
        let q = env.queue()
        let ep = await register(q, server) { path, _ in throw SafetyNetError.declined(path) }
        let id = await q.enqueue(upload(env, "a.txt", to: ep, "/www/a.txt"))
        await q.waitUntilIdle()
        #expect(server.text("/www/a.txt") == "old")
        #expect(try #require(await q.job(id)).state == .failed)
    }

    @Test func renamedConflictDoesNotCallTheHook() async throws {
        let env = try TransferEnv()
        try env.write("a.txt", "new")
        let server = FakeFileSystem(); server.makeDir("/www"); server.put("/www/a.txt", "old")
        let calls = Arrivals()
        let q = env.queue(policy: .rename)
        let ep = await register(q, server) { _, _ in await calls.hit() }
        await q.enqueue(upload(env, "a.txt", to: ep, "/www/a.txt"))
        await q.waitUntilIdle()
        #expect(await calls.count == 0)
        #expect(server.text("/www/a.txt") == "old")
    }

    // MARK: Filters

    @Test func folderUploadSkipsFilteredChildrenAndCountsThem() async throws {
        let env = try TransferEnv()
        try env.write("site/index.html", "<html>")
        try env.write("site/.DS_Store", "junk")
        try env.write("site/node_modules/x/y.js", "y")
        try env.write("site/src/app.js", "app")
        try env.write("site/src/debug.log", "log")
        let server = FakeFileSystem(); server.makeDir("/www")
        let q = env.queue()
        let ep = await register(q, server, filter: TransferFilter(site: ["*.log"]))
        let id = await q.enqueue(upload(env, "site", to: ep, "/www/site", dir: true))
        await q.waitUntilIdle()
        #expect(server.text("/www/site/index.html") == "<html>")
        #expect(server.text("/www/site/src/app.js") == "app")
        #expect(server.text("/www/site/.DS_Store") == nil)
        #expect(!server.hasDir("/www/site/node_modules"))
        #expect(server.text("/www/site/src/debug.log") == nil)
        #expect(try #require(await q.job(id)).state == .completed)
        #expect(await q.snapshot().filteredCount == 3)
        await q.removeFinished()
        #expect(await q.snapshot().filteredCount == 0)
    }

    @Test func anchoredRulesAreRelativeToTheTransferRoot() async throws {
        let env = try TransferEnv()
        try env.write("site/build/out.js", "x")
        try env.write("site/src/build/keep.js", "k")
        let server = FakeFileSystem(); server.makeDir("/www")
        let q = env.queue()
        let ep = await register(q, server, filter: TransferFilter(site: ["/build"], includeDefaults: false))
        await q.enqueue(upload(env, "site", to: ep, "/www/site", dir: true))
        await q.waitUntilIdle()
        #expect(server.text("/www/site/build/out.js") == nil)
        #expect(server.text("/www/site/src/build/keep.js") == "k")
    }

    @Test func explicitlyChosenTopLevelItemsAreNotFiltered() async throws {
        let env = try TransferEnv()
        try env.write(".DS_Store", "x")
        let server = FakeFileSystem(); server.makeDir("/www")
        let q = env.queue()
        let ep = await register(q, server, filter: .defaults)
        await q.enqueue(upload(env, ".DS_Store", to: ep, "/www/.DS_Store"))
        await q.waitUntilIdle()
        #expect(server.text("/www/.DS_Store") == "x")
    }

    @Test func comparatorHidesFilteredEntries() async throws {
        let left = FakeFileSystem(); left.makeDir("/l"); left.put("/l/a.txt", "a"); left.put("/l/.DS_Store", "x")
        left.makeDir("/l/node_modules"); left.put("/l/node_modules/m.js", "m")
        let right = FakeFileSystem(); right.makeDir("/r")
        let entries = try await FolderComparator(filter: .defaults).compare(
            left: TransferEndpoint(fs: left, label: "L"), leftPath: "/l",
            right: TransferEndpoint(fs: right, label: "R"), rightPath: "/r", recursive: true)
        #expect(entries.map(\.relativePath) == ["a.txt"])
    }

    // MARK: Checksums

    func shellServer(hash: String) -> ScriptedShellFileSystem {
        let fs = ScriptedShellFileSystem()
        fs.base.makeDir("/srv")
        fs.script { _ in ("\(hash)  x\n", "", 0) }
        return fs
    }

    @Test func matchingChecksumCompletes() async throws {
        let env = try TransferEnv()
        try env.write("a.txt", "hello")
        let server = shellServer(hash: ChecksumVerifier.sha256(of: Data("hello".utf8)))
        let q = env.queue()
        let ep = await register(q, server, verify: true)
        let id = await q.enqueue(upload(env, "a.txt", to: ep, "/srv/a.txt"))
        await q.waitUntilIdle()
        #expect(try #require(await q.job(id)).state == .completed)
        #expect(server.commands.withLock { $0 }.count == 1)
    }

    @Test func corruptedUploadFailsWithAnErrorLogLine() async throws {
        let env = try TransferEnv()
        try env.write("a.txt", "hello")
        let server = shellServer(hash: String(repeating: "0", count: 64))
        let q = env.queue()
        let lines = LockedBox<[LogLine]>([])
        let stream = q.log.stream()
        let collector = Task { for await line in stream { lines.withLock { $0.append(line) } } }
        let ep = await register(q, server, verify: true)
        let id = await q.enqueue(upload(env, "a.txt", to: ep, "/srv/a.txt"))
        await q.waitUntilIdle()
        let job = try #require(await q.job(id))
        #expect(job.state == .failed)
        #expect(job.error?.contains("Checksum mismatch") == true)
        try await Task.sleep(nanoseconds: 100_000_000)
        collector.cancel()
        #expect(lines.withLock { $0 }.contains { $0.kind == .error && $0.message.contains("Checksum mismatch") })
    }

    @Test func downloadsAreVerifiedToo() async throws {
        let env = try TransferEnv()
        let server = shellServer(hash: String(repeating: "f", count: 64))
        server.base.put("/srv/a.txt", "hello")
        let q = env.queue()
        let ep = await register(q, server, verify: true)
        let id = await q.enqueue(TransferRequest(source: ep, sourcePath: "/srv/a.txt", destination: env.local, destinationPath: env.path("a.txt")))
        await q.waitUntilIdle()
        #expect(try #require(await q.job(id)).state == .failed)
    }

    @Test func noExtraCommandsWhenOffOrWithoutAShell() async throws {
        let env = try TransferEnv()
        try env.write("a.txt", "hello")
        let off = shellServer(hash: "bad")
        let q = env.queue()
        let offEp = await register(q, off, verify: false)
        let plain = FakeFileSystem(); plain.makeDir("/srv")
        let plainEp = await register(q, plain, verify: true)
        let a = await q.enqueue(upload(env, "a.txt", to: offEp, "/srv/a.txt"))
        let b = await q.enqueue(upload(env, "a.txt", to: plainEp, "/srv/a.txt"))
        await q.waitUntilIdle()
        #expect(off.commands.withLock { $0 }.isEmpty)
        #expect(try #require(await q.job(a)).state == .completed)
        #expect(try #require(await q.job(b)).state == .completed)
    }
}
