import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct PinnedFolderTests {
    func setup() async throws -> (PinnedFolderRepository, ConnectionRepository, Connection) {
        let db = try DockyardDatabase()
        let connections = ConnectionRepository(database: db)
        let c = makeConn("Acme", host: "acme.example")
        try await connections.save(c)
        return (PinnedFolderRepository(database: db), connections, c)
    }

    @Test func pinAndUnpin() async throws {
        let (pins, _, c) = try await setup()
        #expect(try await pins.pin("/var/www/html/wp-content/themes", on: c.id))
        #expect(try await pins.pin("/etc/nginx/", label: "Nginx", on: c.id))
        #expect(try await pins.pins(for: c.id) == [PinnedFolder(path: "/var/www/html/wp-content/themes"), PinnedFolder(path: "/etc/nginx", label: "Nginx")])
        #expect(try await pins.isPinned("/etc/nginx", on: c.id))
        #expect(try await pins.unpin("/etc/nginx/", on: c.id))
        #expect(try await pins.unpin("/etc/nginx", on: c.id) == false)
        #expect(try await pins.pins(for: c.id).map(\.path) == ["/var/www/html/wp-content/themes"])
    }

    @Test func pinningTwiceKeepsOneAndUpdatesTheLabel() async throws {
        let (pins, _, c) = try await setup()
        try await pins.pin("/a", on: c.id)
        try await pins.pin("/a/", label: "Alpha", on: c.id)
        #expect(try await pins.pins(for: c.id) == [PinnedFolder(path: "/a", label: "Alpha")])
        try await pins.setLabel("", for: "/a", on: c.id)
        #expect(try await pins.pins(for: c.id) == [PinnedFolder(path: "/a")])
        #expect(PinnedFolder(path: "/srv/site/themes").title == "themes")
    }

    @Test func rootCanBePinned() async throws {
        let (pins, _, c) = try await setup()
        try await pins.pin("/", on: c.id)
        #expect(try await pins.isPinned("/", on: c.id))
    }

    @Test func reordering() async throws {
        let (pins, _, c) = try await setup()
        for p in ["/a", "/b", "/c"] { try await pins.pin(p, on: c.id) }
        try await pins.move(from: 2, to: 0, on: c.id)
        #expect(try await pins.pins(for: c.id).map(\.path) == ["/c", "/a", "/b"])
        try await pins.move(from: 0, to: 9, on: c.id)  // ignored
        #expect(try await pins.pins(for: c.id).map(\.path) == ["/c", "/a", "/b"])
    }

    @Test func capAndUnknownConnection() async throws {
        let (pins, _, c) = try await setup()
        for i in 0..<PinnedFolderRepository.maxPins { try await pins.pin("/p\(i)", on: c.id) }
        #expect(try await pins.pin("/one-too-many", on: c.id) == false)
        #expect(try await pins.pin("/x", on: UUID()) == false)
        #expect(try await pins.pins(for: UUID()).isEmpty)
    }

    @Test func pinsSurviveConnectionEditsAndGoWithTheConnection() async throws {
        let (pins, connections, c) = try await setup()
        try await pins.pin("/keep", on: c.id)
        var edited = try #require(try await connections.connection(id: c.id))
        edited.name = "Renamed"
        try await connections.saveEdited(edited)
        #expect(try await pins.pins(for: c.id).map(\.path) == ["/keep"])
        try await connections.delete(c.id)
        #expect(try await pins.pins(for: c.id).isEmpty)
    }

    @Test func observeEmitsChanges() async throws {
        let (pins, _, c) = try await setup()
        let stream = pins.observe(c.id)
        try await pins.pin("/watched", on: c.id)
        let seen = await firstValue(stream) { $0.map(\.path) == ["/watched"] }
        #expect(seen != nil)
    }
}

@Suite struct PinnedJumpSearchTests {
    func conns() -> (Connection, Connection) {
        var acme = makeConn("Acme Shop", host: "acme.example")
        acme.pinnedFolders = [PinnedFolder(path: "/var/www/html/wp-content/themes", label: "Themes"), PinnedFolder(path: "/etc/nginx")]
        let other = makeConn("Other", host: "other.example")
        return (acme, other)
    }

    @Test func pinnedFoldersAreFoundByPathOrLabel() {
        let (acme, other) = conns()
        let byPath = JumpSearch.search("wp-content", connections: [acme, other])
        guard case .folder(let f, let owner) = byPath.first?.target else { Issue.record("expected a folder"); return }
        #expect(f.path == "/var/www/html/wp-content/themes" && f.isPinned && owner.id == acme.id)

        let byLabel = JumpSearch.search("themes", connections: [acme, other])
        guard case .folder(let labelled, _) = byLabel.first?.target else { Issue.record("expected a folder"); return }
        #expect(labelled.label == "Themes")
    }

    @Test func connectionAndFolderTokensCombine() {
        let (acme, other) = conns()
        let hits = JumpSearch.search("acme nginx", connections: [acme, other])
        #expect(hits.count == 1)
        guard case .folder(let f, _) = hits[0].target else { Issue.record("expected a folder"); return }
        #expect(f.path == "/etc/nginx")
    }

    @Test func pinWinsOverTheSameRecentFolder() {
        let (acme, other) = conns()
        let recent = [JumpFolder(connectionId: acme.id, path: "/etc/nginx", visitedAt: Date()),
                      JumpFolder(connectionId: acme.id, path: "/etc/nginx/conf.d", visitedAt: Date())]
        let hits = JumpSearch.search("nginx", connections: [acme, other], folders: recent)
        let folders = hits.compactMap { hit -> JumpFolder? in if case .folder(let f, _) = hit.target { f } else { nil } }
        #expect(folders.filter { $0.path == "/etc/nginx" }.count == 1)
        #expect(folders.first { $0.path == "/etc/nginx" }?.isPinned == true)
        #expect(folders.first?.path == "/etc/nginx")  // pinned ranks above the recent sibling
    }

    @Test func idsAreUnique() {
        let (acme, other) = conns()
        let hits = JumpSearch.search("a", connections: [acme, other], folders: [JumpFolder(connectionId: acme.id, path: "/etc/nginx", visitedAt: Date())])
        #expect(Set(hits.map(\.id)).count == hits.count)
    }

    @Test func emptyQueryStillOnlyShowsConnections() {
        let (acme, other) = conns()
        var fav = acme
        fav.favorite = true
        let hits = JumpSearch.search("", connections: [fav, other])
        #expect(hits.count == 1)
        if case .connection = hits[0].target {} else { Issue.record("expected a connection") }
    }
}
