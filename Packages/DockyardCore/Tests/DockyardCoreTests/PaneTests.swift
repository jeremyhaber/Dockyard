import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct PanePathTests {
    @Test func normalize() {
        #expect(PathTools.normalize("/a//b/./c/../d/") == "/a/b/d")
        #expect(PathTools.normalize("/../..") == "/")
        #expect(PathTools.normalize("") == "/")
    }

    @Test func resolveTypedPaths() {
        #expect(PathTools.resolve("/var/www", current: "/x", home: nil) == "/var/www")
        #expect(PathTools.resolve("  \"/var/my dir\"  ", current: "/x", home: nil) == "/var/my dir")
        #expect(PathTools.resolve("sub/dir", current: "/var", home: nil) == "/var/sub/dir")
        #expect(PathTools.resolve("../up", current: "/var/www", home: nil) == "/var/up")
        #expect(PathTools.resolve("~", current: "/", home: "/home/me") == "/home/me")
        #expect(PathTools.resolve("~/public_html", current: "/", home: "/home/me") == "/home/me/public_html")
        #expect(PathTools.resolve("~/x", current: "/", home: nil) == nil)
        #expect(PathTools.resolve("   ", current: "/", home: nil) == nil)
        #expect(PathTools.resolve("file:///Users/j/My%20Docs", current: "/", home: nil) == "/Users/j/My Docs")
    }

    @Test func breadcrumbs() {
        let b = PathTools.breadcrumbs(for: "/var/www/html")
        #expect(b.map(\.title) == ["/", "var", "www", "html"])
        #expect(b.map(\.path) == ["/", "/var", "/var/www", "/var/www/html"])
        #expect(PathTools.breadcrumbs(for: "/").count == 1)
    }

    @Test func parentRowRule() {
        let fs = PathRules.filesystem
        #expect(!fs.hasParentRow("/"))
        #expect(fs.hasParentRow("/a"))
        let bucket = PathRules.cloudBucket
        #expect(!bucket.hasParentRow("/"))
        #expect(!bucket.hasParentRow("/my-bucket"))
        #expect(bucket.hasParentRow("/my-bucket/dir"))
        #expect(bucket.parent(of: "/my-bucket") == "/my-bucket")
        #expect(fs.parent(of: "/a/b") == "/a")
        #expect(fs.parent(of: "/") == "/")
    }
}

@Suite struct PaneStateTests {
    @Test func backForwardUp() {
        var p = PaneState(initialPath: "/")
        #expect(!p.canGoBack && !p.canGoUp)
        p.navigate(to: "/a")
        p.navigate(to: "/a/b")
        #expect(p.goUp() == "/a")
        #expect(p.goBack() == "/a/b")
        #expect(p.goBack() == "/a")
        #expect(p.goForward() == "/a/b")
        // Navigating clears forward history.
        p.goBack()
        p.navigate(to: "/z")
        #expect(!p.canGoForward)
        #expect(p.navigate(to: "/z") == nil)  // same folder: no history entry
        #expect(p.activeTab.backStack == ["/", "/a"])
    }

    @Test func upStopsAtRoot() {
        var p = PaneState(initialPath: "/a")
        #expect(p.goUp() == "/")
        #expect(p.goUp() == nil)
        var cloud = PaneState(initialPath: "/bucket/x", rules: .cloudBucket)
        #expect(cloud.goUp() == "/bucket")
        #expect(cloud.goUp() == nil)
    }

    @Test func tabsOpenCloseActivate() {
        var p = PaneState(initialPath: "/a")
        let i = p.openTab(at: "/b")
        #expect(i == 1 && p.activeIndex == 1)
        p.openTab(at: "/c", activate: false)
        #expect(p.activeIndex == 1 && p.tabs.count == 3)
        // Closing a tab before the active one shifts the active index.
        let closed0 = p.closeTab(at: 0); #expect(closed0)
        #expect(p.activeIndex == 0 && p.currentPath == "/b")
        // Closing the active last tab moves to the previous.
        p.activate(1)
        let closed1 = p.closeTab(at: 1); #expect(closed1)
        #expect(p.currentPath == "/b")
        let closedLast = p.closeTab(at: 0); #expect(!closedLast)  // last tab stays
        let closedBad = p.closeTab(at: 9); #expect(!closedBad)
    }

    @Test func openTabDefaultsToCurrentFolderAndInheritsSort() {
        var p = PaneState(initialPath: "/a")
        p.setSort(SortDescriptor(key: .size, ascending: false))
        p.openTab()
        #expect(p.currentPath == "/a")
        #expect(p.activeTab.sort == SortDescriptor(key: .size, ascending: false))
    }

    @Test func tabsKeepSeparateHistory() {
        var p = PaneState(initialPath: "/")
        p.navigate(to: "/a")
        p.openTab(at: "/x")
        p.navigate(to: "/x/y")
        p.activate(0)
        #expect(p.goBack() == "/")
        p.activate(1)
        #expect(p.goBack() == "/x")
    }

    @Test func typedPathNavigation() {
        var p = PaneState(initialPath: "/var")
        #expect(p.navigate(toTyped: "www", home: nil) == "/var/www")
        #expect(p.navigate(toTyped: "~", home: "/home/me") == "/home/me")
        #expect(p.navigate(toTyped: "", home: nil) == nil)
        #expect(p.navigate(toTyped: "/home/me", home: nil) == nil)
    }

    @Test func restoringFromSession() {
        let p = PaneState(restoring: [TabState(path: "/a"), TabState(path: "/b")], active: 1, fallbackPath: "/")
        #expect(p.sessionTabs.map(\.path) == ["/a", "/b"])
        #expect(p.currentPath == "/b")
        let empty = PaneState(restoring: [], active: 5, fallbackPath: "/home")
        #expect(empty.currentPath == "/home")
        #expect(PaneState(restoring: [TabState(path: "/a")], active: 9, fallbackPath: "/").activeIndex == 0)
    }

    @Test func tabIndexLookup() {
        var p = PaneState(initialPath: "/a")
        p.openTab(at: "/b/")
        #expect(p.tabIndex(showing: "/b") == 1)
        #expect(p.tabIndex(showing: "/nope") == nil)
    }

    @Test func recoverFromDeletedFolder() {
        var p = PaneState(initialPath: "/a/b/c")
        p.recoverFromMissingFolder { $0 == "/a" || $0 == "/" }
        #expect(p.currentPath == "/a")
    }
}

@Suite struct FileListTests {
    func item(_ name: String, dir: Bool = false, size: UInt64? = nil, mod: Double? = nil, perms: UInt16? = nil) -> RemoteItem {
        RemoteItem(name: name, path: "/x/" + name, isDirectory: dir, size: size, modified: mod.map { Date(timeIntervalSince1970: $0) }, permissions: perms)
    }

    @Test func parentRowAndFoldersFirst() {
        let items = [item("b.txt"), item("A", dir: true), item("a.txt"), item("z", dir: true)]
        let rows = FileListModel.rows(for: items, at: "/x")
        #expect(rows.first == .parent(path: "/"))
        #expect(rows.dropFirst().map { if case .item(let i) = $0 { i.name } else { "" } } == ["A", "z", "a.txt", "b.txt"])
        #expect(FileListModel.rows(for: items, at: "/").first != .parent(path: "/"))
        #expect(FileListModel.rows(for: items, at: "/").count == 4)
    }

    @Test func naturalCaseInsensitiveNameSort() {
        let names = FileListModel.sorted([item("file10"), item("File2"), item("file1")], by: SortDescriptor()).map(\.name)
        #expect(names == ["file1", "File2", "file10"])
        let desc = FileListModel.sorted([item("a", dir: true), item("b"), item("c")], by: SortDescriptor(key: .name, ascending: false)).map(\.name)
        #expect(desc == ["a", "c", "b"])  // folders stay first
    }

    @Test func sortBySizeModifiedPerms() {
        let items = [item("a", size: 5, mod: 30, perms: 0o644), item("b", size: nil, mod: nil, perms: nil),
                     item("c", size: 1, mod: 10, perms: 0o600), item("d", dir: true, size: nil)]
        #expect(FileListModel.sorted(items, by: .init(key: .size)).map(\.name) == ["d", "c", "a", "b"])
        #expect(FileListModel.sorted(items, by: .init(key: .size, ascending: false)).map(\.name) == ["d", "a", "c", "b"])
        #expect(FileListModel.sorted(items, by: .init(key: .modified)).map(\.name) == ["d", "c", "a", "b"])
        #expect(FileListModel.sorted(items, by: .init(key: .permissions)).map(\.name) == ["d", "c", "a", "b"])
    }

    @Test func hiddenFilesCanBeHidden() {
        let rows = FileListModel.rows(for: [item(".git", dir: true), item("a")], at: "/", showHidden: false)
        #expect(rows.count == 1)
    }

    @Test func footerText() {
        #expect(FileListModel.footer(for: [item("a"), item("b"), item("c", dir: true)]) == "2 files, 1 folder")
        #expect(FileListModel.footer(for: []) == "0 files, 0 folders")
        #expect(FileListModel.footer(for: [item("a")]) == "1 file, 0 folders")
    }

    @Test func sortToggle() {
        let s = SortDescriptor()
        #expect(s.toggled(to: .name) == SortDescriptor(key: .name, ascending: false))
        #expect(s.toggled(to: .size) == SortDescriptor(key: .size, ascending: true))
    }
}

@Suite struct FolderTreeTests {
    func fs() -> FakeFileSystem {
        let f = FakeFileSystem()
        f.makeDir("/a/b/c"); f.makeDir("/a/d"); f.makeDir("/e"); f.put("/a/file.txt", "x")
        return f
    }

    @Test func lazyExpansionLoadsOnlyWhenNeeded() async {
        let f = fs()
        var tree = FolderTree()
        let loader: FolderTree.Loader = { try await f.list($0) }
        #expect(tree.root.children == nil)
        await tree.expand("/", loader: loader)
        #expect(tree.root.children?.map(\.name) == ["a", "e"])
        #expect(f.calls == ["list /"])
        await tree.expand("/a", loader: loader)
        #expect(tree.node(at: "/a")?.children?.map(\.name) == ["b", "d"])  // files excluded
        tree.collapse("/a")
        await tree.expand("/a", loader: loader)  // no reload
        #expect(f.calls == ["list /", "list /a"])
    }

    @Test func revealExpandsAncestors() async {
        let f = fs()
        var tree = FolderTree()
        await tree.reveal("/a/b/c", loader: { try await f.list($0) })
        #expect(tree.expandedPaths.sorted() == ["/", "/a", "/a/b"])
        let pane = PaneState(initialPath: "/a/b/c")
        let rows = tree.visibleRows(for: pane)
        #expect(rows.map(\.path) == ["/", "/a", "/a/b", "/a/b/c", "/a/d", "/e"])
        #expect(rows.map(\.depth) == [0, 1, 2, 3, 2, 1])
        #expect(rows.first { $0.isCurrent }?.path == "/a/b/c")
    }

    @Test func openInOtherTabMarkers() async {
        let f = fs()
        var tree = FolderTree()
        await tree.reveal("/a/b", loader: { try await f.list($0) })
        var pane = PaneState(initialPath: "/a/b")
        pane.openTab(at: "/e", activate: false)
        pane.openTab(at: "/a/b", activate: false)  // duplicate of active: no marker
        let rows = tree.visibleRows(for: pane)
        #expect(rows.first { $0.path == "/e" }?.openInTabIndex == 1)
        #expect(rows.first { $0.path == "/a/b" }?.openInTabIndex == 2)  // active is tab 0, tab 2 also shows it
        pane.activate(2)
        let rows2 = tree.visibleRows(for: pane)
        #expect(rows2.first { $0.path == "/a/b" }?.openInTabIndex == 0)
    }

    @Test func emptyFolderBecomesNonExpandable() async {
        let f = fs()
        var tree = FolderTree()
        await tree.reveal("/a/b/c", loader: { try await f.list($0) })
        await tree.expand("/a/b/c", loader: { try await f.list($0) })
        let row = tree.visibleRows(for: PaneState(initialPath: "/")).first { $0.path == "/a/b/c" }
        #expect(row?.isExpandable == false)
    }

    @Test func loadFailureMarksNodeButDoesNotCrash() async {
        let f = fs()
        f.state.withLock { $0.listFailures["/a"] = RemoteError.permissionDenied("/a") }
        var tree = FolderTree()
        await tree.expand("/", loader: { try await f.list($0) })
        await tree.expand("/a", loader: { try await f.list($0) })
        #expect(tree.node(at: "/a")?.loadFailed == true)
    }

    @Test func restoreExpandedSkipsMissingAndOrdersParentsFirst() async {
        let f = fs()
        var tree = FolderTree()
        await tree.restoreExpanded(["/a/b", "/gone/x", "/", "/a"], loader: { try await f.list($0) })
        #expect(tree.expandedPaths.sorted() == ["/", "/a", "/a/b"])
    }

    @Test func siblingStatePreservedOnRefresh() async {
        let f = fs()
        var tree = FolderTree()
        let loader: FolderTree.Loader = { try await f.list($0) }
        await tree.reveal("/a/b", loader: loader)
        f.makeDir("/f")
        tree.setChildren(of: "/", from: try! await f.list("/"))
        #expect(tree.node(at: "/")?.children?.map(\.name) == ["a", "e", "f"])
        #expect(tree.node(at: "/a")?.isExpanded == true)
    }

    @Test func toggle() async {
        let f = fs()
        var tree = FolderTree()
        let loader: FolderTree.Loader = { try await f.list($0) }
        await tree.toggle("/", loader: loader)
        #expect(tree.root.isExpanded)
        await tree.toggle("/", loader: loader)
        #expect(!tree.root.isExpanded)
    }
}

@Suite struct JumpTests {
    func conns() -> [Connection] {
        [makeConn("Acme Production", host: "ftp.acme.com", favorite: true),
         makeConn("Beta Staging", host: "beta.example.net"),
         makeConn("Acme Staging", host: "stg.acme.com", lastConnected: Date(timeIntervalSince1970: 1_700_000_000)),
         makeConn("Zeta", host: "zeta.io", tags: ["wordpress"])]
    }

    @Test func prefixBeatsSubstringAndFavoriteBoosts() {
        let c = conns()
        let hits = JumpSearch.search("acme", connections: c, now: Date(timeIntervalSince1970: 1_700_000_000))
        // Acme Staging was used recently (+10) which outweighs the favorite star (+8).
        #expect(hits.map(\.title) == ["Acme Staging", "Acme Production"])
    }

    @Test func allTokensMustMatch() {
        let hits = JumpSearch.search("acme stag", connections: conns())
        #expect(hits.map(\.title) == ["Acme Staging"])
        #expect(JumpSearch.search("acme zzz", connections: conns()).isEmpty)
    }

    @Test func matchesTagsAndFuzzy() {
        #expect(JumpSearch.search("wordpress", connections: conns()).map(\.title) == ["Zeta"])
        #expect(JumpSearch.search("prd", connections: conns()).map(\.title) == ["Acme Production"])  // subsequence
    }

    @Test func recentFoldersRankedBelowEquallyGoodConnection() {
        let c = conns()
        let folders = [JumpFolder(connectionId: c[0].id, path: "/var/www/acme-theme", visitedAt: Date()),
                       JumpFolder(connectionId: c[3].id, path: "/srv/logs", visitedAt: Date())]
        let hits = JumpSearch.search("logs", connections: c, folders: folders)
        #expect(hits.count == 1)
        if case .folder(let f, let conn) = hits[0].target {
            #expect(f.path == "/srv/logs"); #expect(conn.name == "Zeta")
        } else { Issue.record("expected folder hit") }
        let both = JumpSearch.search("acme", connections: c, folders: folders)
        #expect(both.last?.id.hasPrefix("f:") == true)
    }

    @Test func folderMatchesByLastComponentOverFullPath() {
        let c = conns()
        let folders = [JumpFolder(connectionId: c[0].id, path: "/uploads/2024", visitedAt: Date()),
                       JumpFolder(connectionId: c[0].id, path: "/uploads", visitedAt: Date())]
        let hits = JumpSearch.search("uploads", connections: c, folders: folders)
        #expect(hits.first?.title == "/uploads")
    }

    @Test func emptyQueryShowsFavoritesRecentAndOpen() {
        let c = conns()
        let hits = JumpSearch.search("", connections: c, openNow: [c[3].id], now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(Set(hits.map(\.title)) == ["Acme Production", "Acme Staging", "Zeta"])
        #expect(hits.first?.title == "Zeta" || hits.first?.title == "Acme Staging" || hits.first?.title == "Acme Production")
    }

    @Test func removedFromSourceSinksAndLimitApplies() {
        var c = conns()
        c[1].removedFromSource = true
        c.append(makeConn("Beta Live", host: "beta.live"))
        let hits = JumpSearch.search("beta", connections: c)
        #expect(hits.map(\.title) == ["Beta Live", "Beta Staging"])
        #expect(JumpSearch.search("a", connections: c, limit: 2).count == 2)
    }

    @Test func clientNameIsSearchable() {
        let client = UUID()
        let c = [makeConn("Prod", host: "h", client: client)]
        #expect(JumpSearch.search("globex", connections: c, clientNames: [client: "Globex"]).count == 1)
        #expect(JumpSearch.search("globex", connections: c).isEmpty)
    }
}
