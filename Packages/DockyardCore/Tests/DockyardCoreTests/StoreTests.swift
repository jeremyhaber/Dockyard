import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct StoreTests {
    @Test func connectionRoundTripsAllFields() async throws {
        let db = try DockyardDatabase()
        let repo = ConnectionRepository(database: db)
        let folder = try await ClientFolderRepository(database: db).create(name: "Acme")
        let whm = UUID()
        var c = Connection(
            name: "Acme Prod", clientFolderId: folder.id, protocol: .ftps, host: "ftp.acme.com", port: 990,
            username: "acme", authMethods: .both, keyPath: "/Users/j/.ssh/id", elevation: .sudo,
            elevateFileBrowsing: true, askBeforeElevatingOnProd: false, isProd: true, favorite: true,
            tags: ["wp", "prod \"quoted\""], notes: "n", source: .whm(whm), restoreSession: false,
            mountInFinder: true, mountOnLaunch: true, mountReadOnly: false,
            lastConnectedAt: Date(timeIntervalSince1970: 1_700_000_500), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            removedFromSource: true, isNew: true, userEditedFields: [.name, .notes], initialRemotePath: "/var/www")
        try await repo.save(c)
        let loaded = try #require(await repo.connection(id: c.id))
        #expect(loaded == c)
        c.name = "changed"
        try await repo.save(c)
        #expect(try await repo.count() == 1)
    }

    @Test func mountReadOnlyDefaultsToIsProd() {
        #expect(makeConn().mountReadOnly == false)
        #expect(Connection(name: "p", host: "h", username: "u", isProd: true).mountReadOnly == true)
        #expect(Connection(name: "p", host: "h", username: "u", isProd: true, mountReadOnly: false).mountReadOnly == false)
    }

    @Test func sourceRawValueRoundTrips() {
        let id = UUID()
        for s: ConnectionSource in [.manual, .quickConnect, .filezillaImport, .whm(id)] {
            #expect(ConnectionSource(rawValue: s.rawValue) == s)
        }
        #expect(ConnectionSource(rawValue: "whm:nope") == nil)
        #expect(ConnectionSource.whm(id).rawValue == "whm:\(id.uuidString)")
    }

    @Test func filtersFavoritesRecentAndAdded() async throws {
        let repo = ConnectionRepository(database: try DockyardDatabase())
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<10 {
            try await repo.save(makeConn("S\(i)", host: "h\(i).com", created: t0.addingTimeInterval(Double(i)),
                                         favorite: i % 5 == 0, lastConnected: i < 4 ? t0.addingTimeInterval(Double(i) * 10) : nil))
        }
        #expect(try await repo.fetch(.favorites).map(\.name).sorted() == ["S0", "S5"])
        #expect(try await repo.fetch(.recent(3)).map(\.name) == ["S3", "S2", "S1"])
        #expect(try await repo.fetch(.recentlyAdded(2)).map(\.name) == ["S9", "S8"])
        #expect(try await repo.fetch(.all).count == 10)
    }

    @Test func filtersBySourceProtocolServerTagAndLastUsed() async throws {
        let clock = ManualClock()
        let repo = ConnectionRepository(database: try DockyardDatabase(), clock: clock)
        let whmA = UUID(), whmB = UUID()
        try await repo.save(makeConn("a", host: "a", source: .whm(whmA), tags: ["wp"]))
        try await repo.save(makeConn("b", host: "b", proto: .ftp, source: .whm(whmB), tags: ["wp", "prod"]))
        try await repo.save(makeConn("c", host: "c", source: .quickConnect))
        try await repo.save(makeConn("d", host: "d", source: .filezillaImport, lastConnected: clock.now().addingTimeInterval(-86_400 * 2)))
        try await repo.save(makeConn("e", host: "e", lastConnected: clock.now().addingTimeInterval(-86_400 * 40)))

        #expect(try await repo.fetch(.source(.quickConnect)).map(\.name) == ["c"])
        #expect(try await repo.fetch(.init(scope: .anyWHM)).map(\.name) == ["a", "b"])
        #expect(try await repo.fetch(.init(whmServer: whmB)).map(\.name) == ["b"])
        #expect(try await repo.fetch(.init(protocols: [.ftp])).map(\.name) == ["b"])
        #expect(try await repo.fetch(.init(tag: "prod")).map(\.name) == ["b"])
        #expect(try await repo.fetch(.init(tag: "wp")).map(\.name) == ["a", "b"])
        #expect(try await repo.fetch(.init(tag: "pro")).isEmpty)
        #expect(try await repo.fetch(.init(lastUsed: .within(days: 7))).map(\.name) == ["d"])
        #expect(try await repo.fetch(.init(lastUsed: .within(days: 60))).map(\.name) == ["d", "e"])
        #expect(try await repo.fetch(.init(lastUsed: .never)).map(\.name) == ["a", "b", "c"])
        #expect(try await repo.fetch(.init(scope: .ids([]))).isEmpty)
    }

    @Test func searchMatchesNameClientHostTagsAndAllTokens() async throws {
        let db = try DockyardDatabase()
        let repo = ConnectionRepository(database: db)
        let acme = try await ClientFolderRepository(database: db).create(name: "Acme Corp")
        try await repo.save(makeConn("Prod", host: "ftp.acme.com", client: acme.id))
        try await repo.save(makeConn("Staging", host: "stg.other.net", tags: ["wordpress"]))
        try await repo.save(makeConn("100%_odd", host: "x.io"))
        #expect(try await repo.fetch(.search("acme")).map(\.name).sorted() == ["Prod"])
        #expect(try await repo.fetch(.search("corp prod")).map(\.name) == ["Prod"])
        #expect(try await repo.fetch(.search("corp stag")).isEmpty)
        #expect(try await repo.fetch(.search("WORDPRESS")).map(\.name) == ["Staging"])
        #expect(try await repo.fetch(.search("other.net")).map(\.name) == ["Staging"])
        #expect(try await repo.fetch(.search("%")).map(\.name) == ["100%_odd"])
        #expect(try await repo.fetch(.search("_")).map(\.name) == ["100%_odd"])
        #expect(try await repo.fetch(.search("   ")).count == 3)
    }

    @Test func searchIsFastWith500Rows() async throws {
        let repo = ConnectionRepository(database: try DockyardDatabase())
        try await repo.save((0..<500).map { makeConn("Client \($0)", host: "host\($0).example.com", tags: ["t\($0 % 7)"]) })
        let start = Date()
        for _ in 0..<20 { #expect(try await repo.fetch(.search("client 499")).count == 1) }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func userEditTrackingMarksOnlyChangedFields() async throws {
        let repo = ConnectionRepository(database: try DockyardDatabase())
        let c = makeConn("Orig", host: "h")
        try await repo.save(c)
        var edited = c
        edited.name = "Mine"
        edited.favorite = true
        let saved = try await repo.saveEdited(edited)
        #expect(saved.userEditedFields == [.name])
        edited.notes = "hello"
        let again = try await repo.saveEdited(edited)
        #expect(again.userEditedFields == [.name, .notes])
        #expect(try await repo.connection(id: c.id)?.userEditedFields == [.name, .notes])
    }

    @Test func markConnectedClearsNewAndSetsLastUsed() async throws {
        let clock = ManualClock()
        let repo = ConnectionRepository(database: try DockyardDatabase(), clock: clock)
        var c = makeConn()
        c.isNew = true
        try await repo.save(c)
        try await repo.markConnected(c.id)
        let l = try #require(await repo.connection(id: c.id))
        #expect(l.isNew == false)
        #expect(l.lastConnectedAt == clock.now())
    }

    @Test func observationEmitsOnChange() async throws {
        let repo = ConnectionRepository(database: try DockyardDatabase())
        let stream = repo.observe(.favorites)
        let collector = Task { await firstValues(stream, count: 3) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let c = makeConn()
        try await repo.save(c)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await repo.setFavorite(c.id, true)
        let values = await collector.value
        #expect(values.count == 3)
        #expect(values.first?.isEmpty == true)
        #expect(values.last?.map(\.id) == [c.id])
    }

    @Test func openNowTracksInMemorySetInOrder() async throws {
        let repo = ConnectionRepository(database: try DockyardDatabase())
        let a = makeConn("A", host: "a"), b = makeConn("B", host: "b")
        try await repo.save([a, b])
        let stream = repo.observeOpenNow()
        let collector = Task { await firstValue(stream) { $0.map(\.name) == ["B", "A"] } }
        try await Task.sleep(nanoseconds: 200_000_000)
        repo.openConnections.open(b.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        repo.openConnections.open(a.id)
        #expect(await collector.value != nil)
        repo.openConnections.close(b.id)
        #expect(repo.openConnections.ids == [a.id])
    }

    @Test func folderHistoryCapsAndDedupesConsecutive() async throws {
        let db = try DockyardDatabase()
        let repo = ConnectionRepository(database: db)
        let c = makeConn()
        try await repo.save(c)
        let history = FolderHistoryRepository(database: db, cap: 200)
        for i in 0..<250 { try await history.record(connectionId: c.id, path: "/p\(i)") }
        try await history.record(connectionId: c.id, path: "/p249")
        let all = try await history.entries(connectionId: c.id, limit: 1000)
        #expect(all.count == 200)
        #expect(all.first?.path == "/p249")
        #expect(all.last?.path == "/p50")
        // Non-consecutive repeats are kept in storage but collapsed on read.
        try await history.record(connectionId: c.id, path: "/a")
        try await history.record(connectionId: c.id, path: "/b")
        try await history.record(connectionId: c.id, path: "/a")
        let paths = try await history.entries(connectionId: c.id, limit: 3).map(\.path)
        #expect(paths == ["/a", "/b", "/p249"])
    }

    @Test func historyIgnoresUnknownConnectionAndCascadesOnDelete() async throws {
        let db = try DockyardDatabase()
        let repo = ConnectionRepository(database: db)
        let history = FolderHistoryRepository(database: db)
        let sessions = SessionRepository(database: db)
        try await history.record(connectionId: UUID(), path: "/x")
        let c = makeConn()
        try await repo.save(c)
        try await history.record(connectionId: c.id, path: "/x")
        try await sessions.save(SessionState(connectionId: c.id, remoteTabs: [TabState(path: "/x")]))
        try await repo.delete(c.id)
        #expect(try await history.entries(connectionId: c.id).isEmpty)
        #expect(try await sessions.load(c.id) == nil)
    }

    @Test func sessionStateRoundTrips() async throws {
        let db = try DockyardDatabase()
        let repo = ConnectionRepository(database: db)
        let c = makeConn()
        try await repo.save(c)
        let s = SessionState(connectionId: c.id, localTabs: [TabState(path: "/Users/j")], remoteTabs: [TabState(path: "/a"), TabState(path: "/b")],
                             activeLocalTab: 0, activeRemoteTab: 1, localTreeExpanded: ["/Users"], remoteTreeExpanded: ["/a", "/a/x"],
                             savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let sessions = SessionRepository(database: db)
        try await sessions.save(s)
        #expect(try await sessions.load(c.id) == s)
        try await sessions.clear(c.id)
        #expect(try await sessions.load(c.id) == nil)
    }

    @Test func whmSourceSnippetAndFolderCrud() async throws {
        let db = try DockyardDatabase()
        let whm = WHMSourceRepository(database: db)
        let s = WHMSource(label: "Main", host: "whm.example.com")
        try await whm.save(s)
        #expect(try await whm.all() == [s])
        #expect(s.apiTokenKeychainRef == s.id.uuidString)
        try await whm.delete(s.id)
        #expect(try await whm.all().isEmpty)

        let c = makeConn()
        try await ConnectionRepository(database: db).save(c)
        let snippets = SnippetRepository(database: db)
        try await snippets.save(Snippet(name: "Global", command: "ls", sortOrder: 1))
        try await snippets.save(Snippet(name: "Mine", command: "top", connectionId: c.id, sortOrder: 0))
        #expect(try await snippets.snippets(for: c.id).map(\.name) == ["Mine", "Global"])
        #expect(try await snippets.snippets(for: nil).count == 1)

        let folders = ClientFolderRepository(database: db)
        let f = try await folders.findOrCreate(name: "Acme")
        #expect(try await folders.findOrCreate(name: "acme").id == f.id)
        var conn = makeConn(client: f.id)
        conn.clientFolderId = f.id
        try await ConnectionRepository(database: db).save(conn)
        try await folders.delete(f.id)
        #expect(try await ConnectionRepository(database: db).connection(id: conn.id)?.clientFolderId == nil)
    }

    @Test func noSecretsInDatabaseFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("dockyard.sqlite").path
        let password = "Sup3r-Secret-Pa55word-\(UUID().uuidString)"
        let keyPass = "KEY-PASSPHRASE-\(UUID().uuidString)"
        let secrets = InMemorySecretStore()
        do {
            let db = try DockyardDatabase(path: path)
            let repo = ConnectionRepository(database: db)
            let qc = QuickConnectService(repository: repo, secrets: secrets)
            // Password in a pasted URL, in the password field and as key passphrase.
            let r1 = try await qc.connect(QuickConnectInput(host: "sftp://bob:\(password)@box.example.com:2222/srv"))
            _ = try await qc.connect(QuickConnectInput(protocolChoice: .ftp, host: "ftp.example.com", username: "u", password: password))
            await secrets.setSecret(keyPass, for: r1.connection.id, purpose: .keyPassphrase)
            try await repo.markConnected(r1.connection.id)
            try await FolderHistoryRepository(database: db).record(connectionId: r1.connection.id, path: "/srv")
            try await SessionRepository(database: db).save(SessionState(connectionId: r1.connection.id, remoteTabs: [TabState(path: "/srv")]))
            try await repo.setFavorite(r1.connection.id, true)
            #expect(await secrets.secret(for: r1.connection.id, purpose: .password) == password)
        }
        // Also covers the WAL / journal side files.
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains("dockyard.sqlite"))
        for f in files {
            let data = try Data(contentsOf: dir.appendingPathComponent(f))
            for needle in [password, keyPass, "Sup3r-Secret"] {
                #expect(data.range(of: Data(needle.utf8)) == nil, "found secret in \(f)")
            }
        }
        // Sanity check that the scan can actually find a stored string.
        let db2 = try DockyardDatabase(path: path)
        try await ConnectionRepository(database: db2).save(makeConn("CanaryName-123"))
        let all = try Data(contentsOf: URL(fileURLWithPath: path))
        let wal = (try? Data(contentsOf: URL(fileURLWithPath: path + "-wal"))) ?? Data()
        #expect(all.range(of: Data("CanaryName-123".utf8)) != nil || wal.range(of: Data("CanaryName-123".utf8)) != nil)
    }

    @Test func readOnlyOpenSeesData() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("db.sqlite").path
        let c = makeConn("Shared")
        do {
            let db = try DockyardDatabase(path: path)
            try await ConnectionRepository(database: db).save(c)
            // Make sure WAL content is checkpointed so a plain read-only open sees it.
            _ = try await db.writer.barrierWriteWithoutTransaction { try $0.checkpoint(.truncate) }
        }
        let ro = try DockyardDatabase.openReadOnly(path: path)
        #expect(try await ConnectionRepository(database: ro).connection(id: c.id)?.name == "Shared")
    }
}
