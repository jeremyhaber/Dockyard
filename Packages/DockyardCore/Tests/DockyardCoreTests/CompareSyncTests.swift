import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct CompareSyncTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func item(_ name: String, size: UInt64? = 1, mod: Date?, dir: Bool = false) -> RemoteItem {
        RemoteItem(name: name, path: "/" + name, isDirectory: dir, size: dir ? nil : size, modified: mod)
    }

    @Test func classification() {
        let c = FolderComparator(timeTolerance: 2)
        #expect(c.classify(left: item("a", mod: t0), right: item("a", mod: t0.addingTimeInterval(1.5))) == .same)
        #expect(c.classify(left: item("a", mod: t0.addingTimeInterval(10)), right: item("a", mod: t0)) == .newerLeft)
        #expect(c.classify(left: item("a", mod: t0), right: item("a", mod: t0.addingTimeInterval(10))) == .newerRight)
        #expect(c.classify(left: item("a", size: 1, mod: t0), right: item("a", size: 2, mod: t0)) == .differs)
        // A newer file wins even when sizes differ.
        #expect(c.classify(left: item("a", size: 1, mod: t0.addingTimeInterval(60)), right: item("a", size: 9, mod: t0)) == .newerLeft)
        #expect(c.classify(left: item("a", mod: nil), right: item("a", mod: t0)) == .same)
        #expect(c.classify(left: item("a", size: 1, mod: nil), right: item("a", size: 2, mod: nil)) == .differs)
        #expect(c.classify(left: item("d", mod: t0, dir: true), right: item("d", mod: t0.addingTimeInterval(500), dir: true)) == .same)
        #expect(c.classify(left: item("x", mod: t0, dir: true), right: item("x", mod: t0)) == .differs)
        #expect(FolderComparator(timeTolerance: 120).classify(left: item("a", mod: t0.addingTimeInterval(60)), right: item("a", mod: t0)) == .same)
    }

    func trees() -> (FakeFileSystem, FakeFileSystem) {
        let l = FakeFileSystem(), r = FakeFileSystem()
        l.put("/L/same.txt", "s", modified: t0); r.put("/R/same.txt", "s", modified: t0)
        l.put("/L/new-left.txt", "n", modified: t0.addingTimeInterval(100)); r.put("/R/new-left.txt", "n", modified: t0)
        l.put("/L/new-right.txt", "n", modified: t0); r.put("/R/new-right.txt", "n", modified: t0.addingTimeInterval(100))
        l.put("/L/only-left.txt", "l", modified: t0)
        r.put("/R/only-right.txt", "r", modified: t0)
        l.put("/L/sub/a.txt", "a", modified: t0); r.put("/R/sub/a.txt", "aa", modified: t0)
        l.put("/L/leftdir/deep/x.txt", "x", modified: t0)
        r.put("/R/rightdir/y.txt", "y", modified: t0)
        return (l, r)
    }

    @Test func shallowCompareClassifiesAndDoesNotDescend() async throws {
        let (l, r) = trees()
        let entries = try await FolderComparator().compare(left: TransferEndpoint(fs: l, label: "L"), leftPath: "/L", right: TransferEndpoint(fs: r, label: "R"), rightPath: "/R")
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0.status) })
        #expect(byName["same.txt"] == .same)
        #expect(byName["new-left.txt"] == .newerLeft)
        #expect(byName["new-right.txt"] == .newerRight)
        #expect(byName["only-left.txt"] == .onlyLeft)
        #expect(byName["only-right.txt"] == .onlyRight)
        #expect(byName["sub"] == .same)
        #expect(byName["leftdir"] == .onlyLeft)
        #expect(byName["rightdir"] == .onlyRight)
        #expect(byName["sub/a.txt"] == nil && byName["leftdir/deep"] == nil)
    }

    @Test func recursiveCompareListsOneSidedSubtrees() async throws {
        let (l, r) = trees()
        let entries = try await FolderComparator().compare(left: TransferEndpoint(fs: l, label: "L"), leftPath: "/L", right: TransferEndpoint(fs: r, label: "R"), rightPath: "/R", recursive: true)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0.status) })
        #expect(byName["sub/a.txt"] == .differs)
        #expect(byName["leftdir/deep"] == .onlyLeft)
        #expect(byName["leftdir/deep/x.txt"] == .onlyLeft)
        #expect(byName["rightdir/y.txt"] == .onlyRight)
        // Sorted by path components, folders' contents directly after the folder.
        let paths = entries.map(\.relativePath)
        #expect(paths.firstIndex(of: "leftdir")! < paths.firstIndex(of: "leftdir/deep/x.txt")!)
        #expect(paths.firstIndex(of: "sub")! + 1 == paths.firstIndex(of: "sub/a.txt")!)
        #expect(entries.count(of: .onlyLeft) == 2)  // files only: only-left.txt, x.txt
    }

    @Test func compareWorksAgainstLocalDisk() async throws {
        let env = try TransferEnv()
        try env.write("proj/a.txt", "a", modified: t0)
        try env.write("proj/b.txt", "b", modified: t0.addingTimeInterval(500))
        let server = FakeFileSystem()
        server.put("/www/a.txt", "a", modified: t0)
        server.put("/www/b.txt", "b", modified: t0)
        let entries = try await FolderComparator().compare(left: env.local, leftPath: env.path("proj"), right: TransferEndpoint(fs: server, label: "S"), rightPath: "/www")
        #expect(entries.map(\.status) == [.same, .newerLeft])
    }

    @Test func compareFailsWhenAFolderIsMissing() async throws {
        let l = FakeFileSystem(); l.makeDir("/L")
        await #expect(throws: RemoteError.self) {
            _ = try await FolderComparator().compare(left: TransferEndpoint(fs: l, label: "L"), leftPath: "/L", right: TransferEndpoint(fs: FakeFileSystem(), label: "R"), rightPath: "/nope")
        }
    }

    @Test func pushPlanTransfersSelectedAndSkipsWhatCannotGo() async throws {
        let (l, r) = trees()
        let le = TransferEndpoint(fs: l, label: "L"), re = TransferEndpoint(fs: r, label: "R")
        let entries = try await FolderComparator().compare(left: le, leftPath: "/L", right: re, rightPath: "/R", recursive: true)
        let sel = entries.filter { ["only-left.txt", "new-left.txt", "only-right.txt", "same.txt", "leftdir", "leftdir/deep", "leftdir/deep/x.txt"].contains($0.relativePath) }
        let plan = SyncPlan.make(selection: sel, direction: .push, left: le, leftRoot: "/L", right: re, rightRoot: "/R")
        #expect(Set(plan.skipped.map(\.relativePath)) == ["only-right.txt", "same.txt"])
        #expect(plan.requests.count == 5)
        #expect(plan.requests.prefix(2).allSatisfy { $0.isDirectory })  // folders first
        #expect(plan.requests.allSatisfy { $0.conflictOverride == .overwrite && $0.createParents })
        let q = TransferQueue(tempDirectory: FileManager.default.temporaryDirectory, progressInterval: 0.005, publishInterval: 0.005)
        await plan.execute(on: q)
        await q.waitUntilIdle()
        #expect(r.text("/R/only-left.txt") == "l")
        #expect(r.text("/R/leftdir/deep/x.txt") == "x")
        #expect(r.text("/R/only-right.txt") == "r")  // untouched
        #expect(r.modified("/R/new-left.txt") != nil)
        #expect(await q.snapshot().failedCount == 0)
    }

    @Test func pullPlanOverwritesLocalFilesWithoutAsking() async throws {
        let env = try TransferEnv()
        try env.write("proj/a.txt", "old-local", modified: t0)
        let server = FakeFileSystem()
        server.put("/www/a.txt", "server-version", modified: t0.addingTimeInterval(1000))
        server.put("/www/new/b.txt", "b", modified: t0)
        let se = TransferEndpoint(fs: server, label: "S")
        let entries = try await FolderComparator().compare(left: env.local, leftPath: env.path("proj"), right: se, rightPath: "/www", recursive: true)
        let plan = SyncPlan.make(selection: entries, direction: .pull, left: env.local, leftRoot: env.path("proj"), right: se, rightRoot: "/www")
        let q = env.queue(policy: .ask, resolver: nil)  // ask without resolver would skip; the plan overrides
        await plan.execute(on: q)
        await q.waitUntilIdle()
        #expect(env.read("proj/a.txt") == "server-version")
        #expect(env.read("proj/new/b.txt") == "b")
    }

    @Test func fileVersusFolderMismatchIsNotAutoSynced() {
        let l = TransferEndpoint(fs: FakeFileSystem(), label: "L")
        let e = DiffEntry(relativePath: "x", isDirectory: false, status: .differs,
                          left: RemoteItem(name: "x", path: "/L/x", isDirectory: true), right: RemoteItem(name: "x", path: "/R/x", isDirectory: false, size: 1))
        let plan = SyncPlan.make(selection: [e], direction: .push, left: l, leftRoot: "/L", right: l, rightRoot: "/R")
        #expect(plan.requests.isEmpty && plan.skipped.count == 1)
    }
}
