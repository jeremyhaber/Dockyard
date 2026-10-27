import Foundation
import Testing
@testable import DockyardCore

private let root = "/Users/j/site"
private func link(mirror: Bool = false, filters: [String] = []) -> WatchLink {
    WatchLink(connectionId: UUID(), localRoot: root, remoteRoot: "/var/www/html", mirrorDeletes: mirror, filterPatterns: filters)
}
private func e(_ rel: String, _ kind: WatchEvent.Kind = .modified, dir: Bool = false) -> WatchEvent {
    WatchEvent(path: "\(root)/\(rel)", kind: kind, isDirectory: dir)
}
private func plan(_ events: [WatchEvent], mirror: Bool = false, filters: [String] = []) -> WatchPlan {
    WatchPlanner.plan(events, for: link(mirror: mirror, filters: filters))
}

@Suite struct WatchPlannerTests {
    @Test func uploadsChangedFilesOnce() {
        let p = plan([e("index.php"), e("css/site.css", .created), e("index.php"), e("css/site.css")])
        #expect(p.items == [
            .upload(local: "\(root)/css/site.css", remote: "/var/www/html/css/site.css"),
            .upload(local: "\(root)/index.php", remote: "/var/www/html/index.php"),
        ])
    }

    @Test func foldersComeFirstShallowToDeep() {
        let p = plan([e("a/b/c.txt", .created), e("a/b", .created, dir: true), e("a", .created, dir: true)])
        #expect(p.items == [
            .makeDirectory(remote: "/var/www/html/a"), .makeDirectory(remote: "/var/www/html/a/b"),
            .upload(local: "\(root)/a/b/c.txt", remote: "/var/www/html/a/b/c.txt"),
        ])
    }

    @Test func folderModifiedEventsAreNoise() {
        #expect(plan([e("a", .modified, dir: true)]).items.isEmpty)
    }

    @Test func filtersApplyAndAreCounted() {
        let p = plan([e(".DS_Store"), e("node_modules/x/index.js", .created), e("debug.log"), e("notes.txt~"), e("page.php.swp"), e("ok.php")],
                     filters: ["*.log"])
        #expect(p.items == [.upload(local: "\(root)/ok.php", remote: "/var/www/html/ok.php")])
        #expect(p.skippedByFilter == 5)
    }

    @Test func eventsOutsideTheRootAreCountedNotUsed() {
        let p = plan([WatchEvent(path: "/Users/j/other/file", kind: .modified), WatchEvent(path: "\(root)-sibling/x", kind: .modified)])
        #expect(p.items.isEmpty && p.outsideRoot == 2)
    }

    @Test func createdThenDeletedInOneBatchCancelsOut() {
        let p = plan([e("tmp.txt", .created), e("tmp.txt", .modified), e("tmp.txt", .deleted)], mirror: true)
        #expect(p.items.isEmpty && p.unmirroredDeletes == 0)
    }

    @Test func deletesAreNeverSentUnlessMirroring() {
        let events = [e("old.txt", .deleted), e("gone", .deleted, dir: true)]
        let off = plan(events)
        #expect(off.items.isEmpty && off.unmirroredDeletes == 2)
        let on = plan(events, mirror: true)
        #expect(on.items == [.delete(remote: "/var/www/html/old.txt", isDirectory: false), .delete(remote: "/var/www/html/gone", isDirectory: true)]
                || on.items == [.delete(remote: "/var/www/html/gone", isDirectory: true), .delete(remote: "/var/www/html/old.txt", isDirectory: false)])
        #expect(on.unmirroredDeletes == 0)
    }

    @Test func deletingAFolderSwallowsItsChildren() {
        let p = plan([e("dir/a.txt", .deleted), e("dir/sub", .deleted, dir: true), e("dir", .deleted, dir: true)], mirror: true)
        #expect(p.items == [.delete(remote: "/var/www/html/dir", isDirectory: true)])
    }

    @Test func childrenAreDeletedBeforeParentsWhenOnlySomeGoAway() {
        let p = plan([e("a", .deleted, dir: true), e("b/c/d.txt", .deleted)], mirror: true)
        #expect(p.items == [.delete(remote: "/var/www/html/b/c/d.txt", isDirectory: false), .delete(remote: "/var/www/html/a", isDirectory: true)])
    }

    @Test func recreatedFileIsAnUploadNotADelete() {
        let p = plan([e("a.txt", .deleted), e("a.txt", .created)], mirror: true)
        #expect(p.items == [.upload(local: "\(root)/a.txt", remote: "/var/www/html/a.txt")])
    }

    @Test func renamesMirrorAsServerSideRenames() {
        let p = plan([e("new.txt", .renamed(from: "\(root)/old.txt"))], mirror: true)
        #expect(p.items == [.rename(fromRemote: "/var/www/html/old.txt", toRemote: "/var/www/html/new.txt")])
    }

    @Test func renamesWithoutMirroringUploadTheNewName() {
        let p = plan([e("new.txt", .renamed(from: "\(root)/old.txt"))])
        #expect(p.items == [.upload(local: "\(root)/new.txt", remote: "/var/www/html/new.txt")])
        #expect(p.unmirroredDeletes == 1)
    }

    @Test func createdThenRenamedIsJustTheNewName() {
        let p = plan([e("draft.txt", .created), e("final.txt", .renamed(from: "\(root)/draft.txt"))], mirror: true)
        #expect(p.items == [.upload(local: "\(root)/final.txt", remote: "/var/www/html/final.txt")])
    }

    @Test func atomicSaveFromAnEditor() {
        // Editors write `file~`/temp, then rename over the real file.
        let p = plan([e("page.php.swp", .created), e("page.php", .renamed(from: "\(root)/.page.php.tmp1234"))])
        #expect(p.items == [.upload(local: "\(root)/page.php", remote: "/var/www/html/page.php")])
    }

    @Test func renamingIntoAnIgnoredNameDropsTheOldOne() {
        let p = plan([e("build.log", .renamed(from: "\(root)/real.txt"))], mirror: true, filters: ["*.log"])
        #expect(p.items == [.delete(remote: "/var/www/html/real.txt", isDirectory: false)])
        #expect(p.skippedByFilter == 1)
    }

    @Test func movedInFromOutsideIsNew() {
        let p = plan([e("in.txt", .renamed(from: "/tmp/in.txt"))])
        #expect(p.items == [.upload(local: "\(root)/in.txt", remote: "/var/www/html/in.txt")])
    }

    @Test func nastyNamesSurvive() {
        let name = "weird 'name' $(x); ünï.txt"
        let p = plan([e("dir with space/\(name)", .created)])
        #expect(p.items == [.upload(local: "\(root)/dir with space/\(name)", remote: "/var/www/html/dir with space/\(name)")])
    }

    @Test func trailingSlashOnRootsIsFine() {
        var l = link()
        l.localRoot = root + "/"
        l.remoteRoot = "/var/www/html/"
        let p = WatchPlanner.plan([e("a.txt")], for: l)
        #expect(p.items == [.upload(local: "\(root)/a.txt", remote: "/var/www/html/a.txt")])
    }

    @Test func linkRoundTripsThroughJSON() throws {
        let l = link(mirror: true, filters: ["*.map"])
        let decoded = try JSONDecoder().decode(WatchLink.self, from: JSONEncoder().encode(l))
        #expect(decoded == l)
    }
}

@Suite struct WatchCoordinatorTests {
    func makeCoordinator(mirror: Bool = false) -> (WatchCoordinator, ManualClock) {
        let clock = ManualClock()
        return (WatchCoordinator(link: link(mirror: mirror), clock: clock, debounce: 0.5, maxDelay: 5), clock)
    }

    @Test func burstBecomesOnePlan() async throws {
        let (c, clock) = makeCoordinator()
        for i in 0..<20 { await c.ingest(e("file\(i % 3).txt")) }
        await waitUntil { clock.sleeperCount >= 1 }
        clock.advance(by: 0.6)
        let plans = await firstValues(c.plans, count: 1)
        #expect(plans.count == 1 && plans[0].items.count == 3)
        #expect(await c.pendingEventCount == 0)
    }

    @Test func eachEventRestartsTheQuietPeriod() async throws {
        let (c, clock) = makeCoordinator()
        await c.ingest(e("a.txt"))
        await waitUntil { clock.sleeperCount >= 1 }
        clock.advance(by: 0.4)
        await c.ingest(e("b.txt"))
        await waitUntil { clock.sleeperCount >= 2 }
        clock.advance(by: 0.4)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await c.pendingEventCount == 2)
        clock.advance(by: 0.2)
        let plans = await firstValues(c.plans, count: 1)
        #expect(plans.first?.items.count == 2)
    }

    @Test func constantActivityStillFlushesAtMaxDelay() async throws {
        let (c, clock) = makeCoordinator()
        for step in 0..<14 {
            await c.ingest(e("busy\(step).txt"))
            await waitUntil { clock.sleeperCount >= 1 }
            clock.advance(by: 0.4)
            try await Task.sleep(for: .milliseconds(5))
        }
        let plans = await firstValues(c.plans, count: 1)
        #expect(plans.count == 1)
        #expect((plans.first?.items.count ?? 0) >= 12)
    }

    @Test func pausedLinkDropsEventsAndAsksForARescan() async throws {
        let (c, clock) = makeCoordinator()
        await c.pause()
        await c.ingest(e("a.txt"))
        #expect(await c.pendingEventCount == 0 && clock.sleeperCount == 0)
        #expect(await c.resume() == true)
        #expect(await c.resume() == false)
        await c.ingest(e("b.txt"))
        await waitUntil { clock.sleeperCount >= 1 }
        clock.advance(by: 1)
        let plans = await firstValues(c.plans, count: 1)
        #expect(plans.first?.items == [.upload(local: "\(root)/b.txt", remote: "/var/www/html/b.txt")])
    }

    @Test func pausingDiscardsTheWaitingBatch() async throws {
        let (c, clock) = makeCoordinator()
        await c.ingest(e("a.txt"))
        await c.pause()
        #expect(await c.pendingEventCount == 0)
        clock.advance(by: 10)
        #expect(await c.resume() == true)
    }

    @Test func emptyPlansAreNotPublished() async throws {
        let (c, clock) = makeCoordinator()
        await c.ingest(e("only-modified-dir", .modified, dir: true))
        await waitUntil { clock.sleeperCount >= 1 }
        clock.advance(by: 1)
        await c.ingest(e("real.txt"))
        // A cancelled timer from the first batch may still be registered, so keep advancing until the batch is flushed.
        await waitUntil { clock.advance(by: 1); return await c.pendingEventCount == 0 }
        let plans = await firstValues(c.plans, count: 1)
        #expect(plans.first?.items == [.upload(local: "\(root)/real.txt", remote: "/var/www/html/real.txt")])
    }

    @Test func flushNowAndStop() async throws {
        let (c, _) = makeCoordinator()
        await c.ingest(e("a.txt"))
        await c.flushNow()
        await c.stop()
        var received: [WatchPlan] = []
        for await plan in c.plans { received.append(plan) }
        #expect(received.count == 1)
        await c.ingest(e("late.txt"))
        #expect(await c.pendingEventCount == 0)
    }

    @Test func runConsumesAnEventSource() async throws {
        let (c, clock) = makeCoordinator(mirror: true)
        let (source, feed) = AsyncStream<WatchEvent>.makeStream()
        let task = Task { await c.run(source: source) }
        feed.yield(e("a.txt", .deleted))
        feed.yield(e("b.txt"))
        feed.finish()
        await task.value
        await waitUntil { clock.sleeperCount >= 1 }
        clock.advance(by: 1)
        let plans = await firstValues(c.plans, count: 1)
        #expect(plans.first?.items.count == 2)
    }

    @Test func mirrorSettingAppliesToLaterBatches() async throws {
        let (c, clock) = makeCoordinator()
        await c.setMirrorDeletes(true)
        await c.ingest(e("gone.txt", .deleted))
        await waitUntil { clock.sleeperCount >= 1 }
        clock.advance(by: 1)
        let plans = await firstValues(c.plans, count: 1)
        #expect(plans.first?.items == [.delete(remote: "/var/www/html/gone.txt", isDirectory: false)])
    }
}
