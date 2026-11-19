import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct NameFilterTests {
    func item(_ name: String, dir: Bool = false) -> RemoteItem {
        RemoteItem(name: name, path: "/x/" + name, isDirectory: dir, size: 1, modified: nil, permissions: nil)
    }

    @Test func matchesIgnoringCaseAndDiacritics() {
        #expect(NameFilter.matches("Café Menu.pdf", filter: "cafe"))
        #expect(NameFilter.matches("README.md", filter: " read "))
        #expect(!NameFilter.matches("README.md", filter: "xyz"))
        #expect(NameFilter.matches("anything", filter: "  "))
    }

    @Test func wildcardsMatchAnywhereInTheName() {
        #expect(NameFilter.matches("wp-content", filter: "wp-*ont"))
        #expect(NameFilter.matches("index.PHP", filter: "*.php"))
        #expect(NameFilter.matches("index.php.bak", filter: "*.php"))
        #expect(NameFilter.matches("old-wp-config.php", filter: "wp-*"))
        #expect(!NameFilter.matches("wp-admin", filter: "wp-*ont"))
        #expect(NameFilter.matches("img_07.jpg", filter: "img_??.jpg"))
        #expect(NameFilter.matches("Ärger.txt", filter: "[a-c]rger"))
        #expect(!NameFilter.matches("drger.txt", filter: "[a-c]rger"))
        #expect(NameFilter.matches("a(1).txt", filter: "(?).txt"))
        #expect(NameFilter.matches("star*name", filter: "r\\*n"))
        #expect(!NameFilter.matches("starxname", filter: "r\\*n"))
    }

    @Test func wildcardHighlightCoversTheMatch() throws {
        let name = "old-wp-content"
        let range = try #require(NameFilter.matchRange(in: name, filter: "wp-*ont"))
        #expect(name[range] == "wp-cont")
        let accented = "Café-Menü.pdf"
        let r2 = try #require(NameFilter.matchRange(in: accented, filter: "cafe-*u"))
        #expect(accented[r2] == "Café-Menü")
    }

    @Test func serverPatternMatchesAnywhere() {
        #expect(NameFilter.serverPattern("wp-*ont") == "*wp-*ont*")
        #expect(NameFilter.serverPattern("*.php") == "*.php*")
        #expect(NameFilter.serverPattern("wp-*") == "*wp-*")
        #expect(NameFilter.serverPattern(" uploads ") == "uploads")
    }

    @Test func highlightRange() throws {
        let name = "My Café Menu.pdf"
        let range = try #require(NameFilter.matchRange(in: name, filter: "cafe"))
        #expect(name[range] == "Café")
        #expect(NameFilter.matchRange(in: name, filter: "*.pdf").map { String(name[$0]) } == name)
        #expect(NameFilter.matchRange(in: name, filter: "zzz") == nil)
        #expect(NameFilter.matchRange(in: name, filter: " ") == nil)
    }

    @Test func matchingRowsSkipParentAndKeepOrder() {
        let items = [item("Foo.txt"), item("bar.txt"), item("foods", dir: true)]
        let rows = FileListModel.rows(for: items, at: "/x")
        #expect(rows.count == 4)
        #expect(NameFilter.matchingRows(rows, filter: "foo") == ["/x/foods", "/x/Foo.txt"])
        #expect(NameFilter.matchingRows(rows, filter: "*.txt") == ["/x/bar.txt", "/x/Foo.txt"])
        #expect(NameFilter.matchingRows(rows, filter: "..").isEmpty)
        #expect(NameFilter.matchingRows(rows, filter: "").isEmpty)
    }

    @Test func stepWrapsLikeABrowser() {
        #expect(NameFilter.step(from: nil, count: 3, forward: true) == 0)
        #expect(NameFilter.step(from: nil, count: 3, forward: false) == 2)
        #expect(NameFilter.step(from: 2, count: 3, forward: true) == 0)
        #expect(NameFilter.step(from: 0, count: 3, forward: false) == 2)
        #expect(NameFilter.step(from: 1, count: 3, forward: true) == 2)
        #expect(NameFilter.step(from: 5, count: 3, forward: true) == 0)
        #expect(NameFilter.step(from: 0, count: 0, forward: true) == nil)
    }

    @Test func connectionSearch() {
        let client = UUID()
        let a = Connection(name: "Acme Site", host: "web.example.com", username: "deploy")
        var b = Connection(name: "Other", host: "10.0.0.1", username: "root")
        b.clientFolderId = client
        let names = [client: "Müller GmbH"]
        #expect(NameFilter.connections([a, b], matching: "acme").map(\.id) == [a.id])
        #expect(NameFilter.connections([a, b], matching: "EXAMPLE").map(\.id) == [a.id])
        #expect(NameFilter.connections([a, b], matching: "root").map(\.id) == [b.id])
        #expect(NameFilter.connections([a, b], matching: "muller", clientNames: names).map(\.id) == [b.id])
        #expect(NameFilter.connections([a, b], matching: "").isEmpty)
        #expect(NameFilter.connections([a, b], matching: "o", limit: 1).count == 1)
    }

    @Test func treeMatchesLoadedFoldersDepthFirst() {
        func dir(_ path: String) -> RemoteItem {
            RemoteItem(name: RemotePath.lastComponent(of: path), path: path, isDirectory: true, size: nil, modified: nil, permissions: nil)
        }
        var tree = FolderTree(rootPath: "/")
        tree.setChildren(of: "/", from: [dir("/a"), dir("/b-needle"), dir("/c")])
        tree.setChildren(of: "/a", from: [dir("/a/needle")])
        tree.setChildren(of: "/c", from: [dir("/c/cur"), dir("/c/Needles")])
        #expect(tree.matchingPaths("").isEmpty)
        #expect(tree.matchingPaths("needle") == ["/a/needle", "/b-needle", "/c/Needles"])
        #expect(tree.matchingPaths("n?edles*") == ["/c/Needles"])
    }
}
