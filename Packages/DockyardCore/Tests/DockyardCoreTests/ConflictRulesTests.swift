import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Suite struct ConflictRulesTests {
    // MARK: Pure rules

    @Test func conditionalRules() {
        let old = t0, new = t0.addingTimeInterval(60)
        #expect(ConflictAction.overwriteIfNewer.replaces(sourceSize: 1, sourceModified: new, destinationSize: 1, destinationModified: old))
        #expect(!ConflictAction.overwriteIfNewer.replaces(sourceSize: 1, sourceModified: old, destinationSize: 1, destinationModified: new))
        #expect(!ConflictAction.overwriteIfNewer.replaces(sourceSize: 1, sourceModified: old.addingTimeInterval(0.5), destinationSize: 1, destinationModified: old))

        #expect(ConflictAction.overwriteIfDifferent.replaces(sourceSize: 2, sourceModified: old, destinationSize: 3, destinationModified: old))
        #expect(ConflictAction.overwriteIfDifferent.replaces(sourceSize: 2, sourceModified: old, destinationSize: 2, destinationModified: new))
        #expect(!ConflictAction.overwriteIfDifferent.replaces(sourceSize: 2, sourceModified: old, destinationSize: 2, destinationModified: old.addingTimeInterval(0.4)))
        #expect(!ConflictAction.overwriteIfDifferent.replaces(sourceSize: 2, sourceModified: nil, destinationSize: 2, destinationModified: old))

        #expect(ConflictAction.overwriteIfSizeDiffers.replaces(sourceSize: 2, sourceModified: old, destinationSize: 3, destinationModified: old))
        #expect(!ConflictAction.overwriteIfSizeDiffers.replaces(sourceSize: 2, sourceModified: old, destinationSize: 2, destinationModified: new))
        #expect(ConflictAction.overwriteIfSizeDiffers.replaces(sourceSize: nil, sourceModified: old, destinationSize: 2, destinationModified: old))
    }

    @Test func policiesMapToActionsAndStoreAsText() {
        #expect(ConflictPolicy.ask.action == nil)
        for policy in ConflictPolicy.allCases where policy != .ask {
            #expect(policy.action?.rawValue == policy.rawValue)
            #expect(ConflictPolicy(dbValue: policy.dbValue) == policy)
        }
    }

    @Test func siteDefaultIsStoredOnTheConnection() async throws {
        let db = try DockyardDatabase()
        let repo = ConnectionRepository(database: db)
        var c = Connection(name: "Staging", protocol: .sftp, host: "stage.example", username: "u")
        c.defaultConflictAction = .overwriteIfDifferent
        try await repo.save(c)
        let loaded = try #require(try await repo.connection(id: c.id))
        #expect(loaded.defaultConflictAction == .overwriteIfDifferent)
        var plain = Connection(name: "Prod", protocol: .sftp, host: "p.example", username: "u")
        plain.defaultConflictAction = nil
        try await repo.save(plain)
        #expect(try await repo.connection(id: plain.id)?.defaultConflictAction == nil)
    }

    // MARK: Queue

    func setup(_ files: [String: (local: String, remote: String)], localAge: TimeInterval = 0, remoteAge: TimeInterval = 0) throws -> (TransferEnv, FakeFileSystem, TransferEndpoint) {
        let env = try TransferEnv()
        let server = FakeFileSystem(); server.makeDir("/d")
        for (name, content) in files {
            try env.write(name, content.local, modified: t0.addingTimeInterval(localAge))
            server.put("/d/\(name)", content.remote, modified: t0.addingTimeInterval(remoteAge))
        }
        return (env, server, TransferEndpoint(fs: server, label: "S"))
    }

    func run(_ env: TransferEnv, _ ep: TransferEndpoint, _ names: [String], policy: ConflictPolicy, site: ConflictPolicy? = nil,
             resolver: ConflictResolver? = nil) async throws -> TransferQueue {
        let q = env.queue(policy: policy, resolver: resolver)
        let id = UUID()
        let siteProfile = TransferSite(id: id, label: "S", defaultConflict: site) { ep.fs }
        await q.register(site: siteProfile)
        let endpoint = siteProfile.endpoint(fs: ep.fs)
        for name in names {
            await q.enqueue(TransferRequest(
                source: env.local, sourcePath: env.path(name), destination: endpoint, destinationPath: "/d/\(name)",
                modified: try? FileManager.default.attributesOfItem(atPath: env.path(name))[.modificationDate] as? Date))
        }
        await q.waitUntilIdle()
        return q
    }

    @Test func overwriteIfDifferentSkipsUnchangedFilesAndCountsThem() async throws {
        let (env, server, ep) = try setup(["same.txt": ("abc", "abc"), "size.txt": ("longer", "abc")])
        let q = try await run(env, ep, ["same.txt", "size.txt"], policy: .overwriteIfDifferent)
        #expect(server.text("/d/same.txt") == "abc")
        #expect(server.text("/d/size.txt") == "longer")
        let snap = await q.snapshot()
        #expect(snap.skippedCount == 1 && snap.skipReasons == [.unchanged: 1])
        await q.removeFinished()
        #expect(await q.snapshot().skipReasons.isEmpty)
    }

    @Test func overwriteIfSizeDiffersIgnoresTimes() async throws {
        let (env, server, ep) = try setup(["a.txt": ("new", "old")], localAge: 500)
        _ = try await run(env, ep, ["a.txt"], policy: .overwriteIfSizeDiffers)
        #expect(server.text("/d/a.txt") == "old")  // same size, newer locally: left alone
    }

    @Test func explicitSkipIsCountedAsKeptNotUnchanged() async throws {
        let (env, _, ep) = try setup(["a.txt": ("new", "old")])
        let q = try await run(env, ep, ["a.txt"], policy: .skip)
        #expect(await q.snapshot().skipReasons == [.kept: 1])
    }

    @Test func resumeAppendsToAPartialFileAndSkipsACompleteOne() async throws {
        let (env, server, ep) = try setup(["part.txt": ("0123456789", "01234"), "done.txt": ("abc", "abc")])
        let q = try await run(env, ep, ["part.txt", "done.txt"], policy: .resume)
        #expect(server.text("/d/part.txt") == "0123456789")
        #expect(await q.snapshot().skipReasons == [.unchanged: 1])
        let uploads = server.state.withLock { $0.calls }.filter { $0.contains("part.txt") }
        #expect(uploads.contains { $0.lowercased().contains("resume") || $0.contains("upload") })
    }

    @Test func siteDefaultAppliesBeforeTheGlobalPolicy() async throws {
        let (env, server, ep) = try setup(["a.txt": ("new", "old")])
        _ = try await run(env, ep, ["a.txt"], policy: .skip, site: .overwrite)
        #expect(server.text("/d/a.txt") == "new")
    }

    @Test func askingSiteDefaultDefersToTheQueuePolicy() async throws {
        let (env, server, ep) = try setup(["a.txt": ("new", "old")])
        _ = try await run(env, ep, ["a.txt"], policy: .overwrite, site: .ask)
        #expect(server.text("/d/a.txt") == "new")
    }

    @Test func perBatchOverrideBeatsEverything() async throws {
        let (env, server, ep) = try setup(["a.txt": ("new", "old")])
        let q = env.queue(policy: .skip)
        let site = TransferSite(id: UUID(), label: "S", defaultConflict: .skip) { ep.fs }
        await q.register(site: site)
        await q.enqueue(TransferRequest(
            source: env.local, sourcePath: env.path("a.txt"), destination: site.endpoint(fs: ep.fs), destinationPath: "/d/a.txt",
            conflictOverride: .overwrite))
        await q.waitUntilIdle()
        #expect(server.text("/d/a.txt") == "new")
    }

    // MARK: Apply-to scopes

    func asking(_ scope: ConflictScope, action: ConflictAction = .overwrite, count: LockedBox<Int>) -> ConflictResolver {
        { _ in count.withLock { $0 += 1 }; return ConflictDecision(action, scope: scope) }
    }

    @Test func thisFileAsksEveryTime() async throws {
        let (env, _, ep) = try setup(["a": ("1", "0"), "b": ("2", "0"), "c": ("3", "0")])
        let asked = LockedBox(0)
        _ = try await run(env, ep, ["a", "b", "c"], policy: .ask, resolver: asking(.thisFile, count: asked))
        #expect(asked.withLock { $0 } == 3)
    }

    @Test func allRemainingAsksOnce() async throws {
        let (env, server, ep) = try setup(["a": ("1", "0"), "b": ("2", "0"), "c": ("3", "0")])
        let asked = LockedBox(0)
        _ = try await run(env, ep, ["a", "b", "c"], policy: .ask, resolver: asking(.allRemaining, count: asked))
        #expect(asked.withLock { $0 } == 1)
        #expect(["a", "b", "c"].allSatisfy { server.text("/d/\($0)") != "0" })
    }

    @Test func uploadsOnlyDoesNotCoverDownloads() async throws {
        let env = try TransferEnv()
        let server = FakeFileSystem(); server.makeDir("/d")
        try env.write("up.txt", "new"); server.put("/d/up.txt", "old")
        server.put("/d/down.txt", "remote"); try env.write("down.txt", "local")
        let asked = LockedBox<[ConflictDirection]>([])
        let q = env.queue(max: 1, policy: .ask) { info in
            asked.withLock { $0.append(info.direction) }
            return ConflictDecision(.overwrite, scope: .uploadsOnly)
        }
        let ep = TransferEndpoint(fs: server, label: "S")
        await q.enqueue(upload(env, "up.txt", to: ep, "/d/up.txt"))
        await q.enqueue(upload(env, "up.txt", to: ep, "/d/up.txt"))
        await q.enqueue(TransferRequest(source: ep, sourcePath: "/d/down.txt", destination: env.local, destinationPath: env.path("down.txt")))
        await q.waitUntilIdle()
        #expect(asked.withLock { $0 } == [.upload, .download])
    }

    @Test func sessionDecisionOutlivesTheQueueRunButBatchDoesNot() async throws {
        let (env, _, ep) = try setup(["a": ("1", "0"), "b": ("2", "0")])
        let asked = LockedBox(0)
        let q = try await run(env, ep, ["a"], policy: .ask, resolver: asking(.session, count: asked))
        await q.enqueue(upload(env, "b", to: ep, "/d/b"))
        await q.waitUntilIdle()
        #expect(asked.withLock { $0 } == 1)

        let (env2, _, ep2) = try setup(["a": ("1", "0"), "b": ("2", "0")])
        let asked2 = LockedBox(0)
        let q2 = try await run(env2, ep2, ["a"], policy: .ask, resolver: asking(.allRemaining, count: asked2))
        await q2.enqueue(upload(env2, "b", to: ep2, "/d/b"))
        await q2.waitUntilIdle()
        #expect(asked2.withLock { $0 } == 2)
    }

    @Test func forgettingDecisionsAsksAgain() async throws {
        let (env, _, ep) = try setup(["a": ("1", "0"), "b": ("2", "0")])
        let asked = LockedBox(0)
        let q = try await run(env, ep, ["a"], policy: .ask, resolver: asking(.session, count: asked))
        await q.forgetConflictDecisions()
        await q.enqueue(upload(env, "b", to: ep, "/d/b"))
        await q.waitUntilIdle()
        #expect(asked.withLock { $0 } == 2)
    }

    @Test func promptReportsBothSidesAndDirection() async throws {
        let (env, _, ep) = try setup(["a": ("12345", "123")], localAge: 100)
        let info = LockedBox<ConflictInfo?>(nil)
        _ = try await run(env, ep, ["a"], policy: .ask) { i in info.withLock { $0 = i }; return ConflictDecision(.skip) }
        let seen = try #require(info.withLock { $0 })
        #expect(seen.direction == .upload && seen.destinationSize == 3)
        #expect(seen.destinationModified == t0)
    }
}
