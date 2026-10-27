import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct SessionTests {
    func setup() async throws -> (Connection, SessionRepository, ManualClock, SessionSaver) {
        let db = try DockyardDatabase()
        let c = makeConn()
        try await ConnectionRepository(database: db).save(c)
        let repo = SessionRepository(database: db)
        let clock = ManualClock()
        return (c, repo, clock, SessionSaver(repository: repo, clock: clock, debounce: 2))
    }

    @Test func debouncesRapidUpdatesIntoOneWrite() async throws {
        let (c, repo, clock, saver) = try await setup()
        await saver.update(SessionState(connectionId: c.id, remoteTabs: [TabState(path: "/a")]))
        await clock.waitForSleepers(1)
        clock.advance(by: 1)
        await saver.update(SessionState(connectionId: c.id, remoteTabs: [TabState(path: "/a"), TabState(path: "/b")]))
        await clock.waitForSleepers(1)
        clock.advance(by: 1.5)  // first timer's deadline passed but it was cancelled
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(try await repo.load(c.id) == nil)
        clock.advance(by: 1)
        #expect(await waitUntil { (try? await repo.load(c.id))?.remoteTabs.count == 2 })
        #expect(try await repo.load(c.id)?.savedAt == clock.now())
        #expect(await saver.hasPending == false)
    }

    @Test func flushSavesImmediately() async throws {
        let (c, repo, _, saver) = try await setup()
        await saver.update(SessionState(connectionId: c.id, remoteTabs: [TabState(path: "/a")]))
        await saver.flush(c.id)
        #expect(try await repo.load(c.id)?.remoteTabs == [TabState(path: "/a")])
    }

    @Test func flushAllCoversEveryConnection() async throws {
        let db = try DockyardDatabase()
        let crepo = ConnectionRepository(database: db)
        let a = makeConn("a", host: "a"), b = makeConn("b", host: "b")
        try await crepo.save([a, b])
        let repo = SessionRepository(database: db)
        let saver = SessionSaver(repository: repo, clock: ManualClock(), debounce: 100)
        await saver.update(SessionState(connectionId: a.id, localTabs: [TabState(path: "/x")]))
        await saver.update(SessionState(connectionId: b.id, localTabs: [TabState(path: "/y")]))
        await saver.flushAll()
        #expect(try await repo.load(a.id) != nil)
        #expect(try await repo.load(b.id) != nil)
    }

    @Test func discardAndStartFresh() async throws {
        let (c, repo, clock, saver) = try await setup()
        let svc = SessionService(repository: repo, saver: saver)
        try await repo.save(SessionState(connectionId: c.id, remoteTabs: [TabState(path: "/old")]))
        await saver.update(SessionState(connectionId: c.id, remoteTabs: [TabState(path: "/new")]))
        try await svc.startFresh(connectionId: c.id)
        clock.advance(by: 10)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(try await repo.load(c.id) == nil)
    }

    @Test func restoreDropsMissingPathsAndFixesActive() async throws {
        let remote = FakeFileSystem()
        remote.makeDir("/www"); remote.makeDir("/logs/old"); remote.put("/file.txt", "x")
        let local = FakeFileSystem()
        local.makeDir("/Users/j/proj")
        let logs = LockedBox<[String]>([])
        let saved = SessionState(
            connectionId: UUID(),
            localTabs: [TabState(path: "/Users/j/proj"), TabState(path: "/Users/j/gone")],
            remoteTabs: [TabState(path: "/www"), TabState(path: "/missing"), TabState(path: "/file.txt"), TabState(path: "/logs/old")],
            activeLocalTab: 1, activeRemoteTab: 3,
            localTreeExpanded: ["/Users", "/Users/j/gone/sub"], remoteTreeExpanded: ["/missing/a", "/www"],
            savedAt: Date(timeIntervalSince1970: 1_729_900_000))  // Oct 26 2024 UTC
        let r = await SessionRestorer.restore(saved, local: local, remote: remote,
                                              log: { k, m in logs.withLock { $0.append("\(k):\(m)") } }, timeZone: TimeZone(identifier: "UTC")!)
        #expect(r.state.remoteTabs.map(\.path) == ["/www", "/logs/old"])
        #expect(r.state.activeRemoteTab == 1)  // /logs/old moved from index 3
        #expect(r.state.localTabs.map(\.path) == ["/Users/j/proj"])
        #expect(r.state.activeLocalTab == 0)  // active was dropped: clamp
        #expect(r.droppedRemote == ["/missing", "/file.txt"])
        #expect(r.state.remoteTreeExpanded == ["/www"])
        #expect(r.state.localTreeExpanded == ["/Users"])
        let l = logs.withLock { $0 }
        #expect(l.count == 3)
        #expect(l.allSatisfy { $0.hasPrefix("warning:") })
        #expect(r.notice == "Restored your last session: 2 server folders and 1 local folder, as you left them Oct 25")
    }

    @Test func noticeWordingMatchesSpec() {
        let utc = TimeZone(identifier: "UTC")!
        let d = Date(timeIntervalSince1970: 1_729_814_400)  // Oct 25 2024 00:00 UTC
        #expect(SessionRestorer.notice(remote: 3, local: 2, savedAt: d, timeZone: utc) == "Restored your last session: 3 server folders and 2 local folders, as you left them Oct 25")
        #expect(SessionRestorer.notice(remote: 1, local: 0, savedAt: d, timeZone: utc) == "Restored your last session: 1 server folder, as you left them Oct 25")
        #expect(SessionRestorer.notice(remote: 0, local: 0, savedAt: d, timeZone: utc) == nil)
    }

    @Test func allTabsGoneYieldsNoNotice() async {
        let r = await SessionRestorer.restore(
            SessionState(connectionId: UUID(), remoteTabs: [TabState(path: "/nope")], activeRemoteTab: 0),
            local: FakeFileSystem(), remote: FakeFileSystem())
        #expect(r.state.remoteTabs.isEmpty)
        #expect(r.notice == nil)
        #expect(r.state.activeRemoteTab == 0)
    }

    @Test func parentListingFailureFallsBackToListingFolder() async {
        let remote = FakeFileSystem()
        remote.makeDir("/locked/inner")
        remote.state.withLock { $0.listFailures["/locked"] = RemoteError.permissionDenied("/locked") }
        let r = await SessionRestorer.restore(
            SessionState(connectionId: UUID(), remoteTabs: [TabState(path: "/locked/inner")]),
            local: FakeFileSystem(), remote: remote)
        #expect(r.state.remoteTabs.count == 1)
    }

    @Test func prepareRestoreHonoursConnectionFlagAndEmptyState() async throws {
        let (c, repo, _, saver) = try await setup()
        let svc = SessionService(repository: repo, saver: saver)
        let remote = FakeFileSystem(); remote.makeDir("/a")
        #expect(try await svc.prepareRestore(for: c, local: FakeFileSystem(), remote: remote) == nil)  // nothing saved
        try await repo.save(SessionState(connectionId: c.id, remoteTabs: [TabState(path: "/a")]))
        #expect(try await svc.prepareRestore(for: c, local: FakeFileSystem(), remote: remote)?.restoredRemoteTabs == 1)
        var off = c; off.restoreSession = false
        #expect(try await svc.prepareRestore(for: off, local: FakeFileSystem(), remote: remote) == nil)
    }

    @Test func restoreWorksAgainstLocalFileSystem() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let r = await SessionRestorer.restore(
            SessionState(connectionId: UUID(), localTabs: [TabState(path: dir.appendingPathComponent("sub").path), TabState(path: dir.appendingPathComponent("zz").path)]),
            local: LocalFileSystem(), remote: FakeFileSystem())
        #expect(r.restoredLocalTabs == 1)
    }
}
