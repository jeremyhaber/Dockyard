import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct SoftDeleteTests {
    private let clock = ManualClock()
    private let day: TimeInterval = 86_400

    private func setup() throws -> (DockyardDatabase, ConnectionRepository) {
        let db = try DockyardDatabase()
        return (db, ConnectionRepository(database: db, clock: clock))
    }

    @Test func removedConnectionsAreHiddenEverywhere() async throws {
        let (_, repo) = try setup()
        let keep = makeConn("Keep", host: "keep.example", tags: ["x"], favorite: true)
        let gone = makeConn("Gone", host: "gone.example", tags: ["x"], favorite: true, lastConnected: clock.now())
        try await repo.save([keep, gone])
        #expect(try await repo.softDelete(ids: [gone.id]) == 1)

        #expect(try await repo.fetch().map(\.id) == [keep.id])
        #expect(try await repo.fetch(.favorites).map(\.id) == [keep.id])
        #expect(try await repo.fetch(.recent()).isEmpty)
        #expect(try await repo.fetch(.search("gone")).isEmpty)
        #expect(try await repo.fetch(ConnectionFilter(scope: .ids([gone.id]))).isEmpty)
        #expect(try await repo.count() == 1)
        #expect(try await repo.sourceCounts() == ["manual": 1])
        #expect(try await repo.allTags() == ["x"])
        #expect(try await repo.fetch(ConnectionFilter(includeRemoved: true)).count == 2)
        #expect(try await repo.connection(id: gone.id)?.deletedAt == clock.now())
        let hits = JumpSearch.search("", connections: [keep, try #require(await repo.connection(id: gone.id))])
        #expect(hits.map(\.id) == ["c:\(keep.id)"])
        let named = JumpSearch.search("gone", connections: [try #require(await repo.connection(id: gone.id))])
        #expect(named.isEmpty)
    }

    @Test func removedConnectionsDoNotDedupeQuickConnect() async throws {
        let (db, repo) = try setup()
        let old = makeConn("Old", host: "ex.example", user: "bob")
        try await repo.save(old)
        try await repo.softDelete(ids: [old.id])
        #expect(try await repo.connection(protocol: .sftp, host: "ex.example", port: 22, username: "bob") == nil)

        let quick = QuickConnectService(repository: repo, secrets: InMemorySecretStore(), clock: clock)
        let result = try await quick.connect(QuickConnectInput(host: "ex.example", username: "bob", password: "pw"))
        #expect(result.created)
        #expect(result.connection.id != old.id)
        #expect(try await ConnectionRepository(database: db).count() == 1)
    }

    @Test func observersDropAndRestoreRows() async throws {
        let (_, repo) = try setup()
        let a = makeConn("A"), b = makeConn("B", host: "b.example")
        try await repo.save([a, b])
        let all = repo.observe()
        let removed = repo.observeRecentlyRemoved()
        #expect(await firstValues(all, count: 1).first?.count == 2)
        #expect(await firstValues(removed, count: 1).first?.isEmpty == true)

        try await repo.softDelete(ids: [a.id])
        #expect(await firstValue(all) { $0.map(\.id) == [b.id] } != nil)
        #expect(await firstValue(removed) { $0.map(\.id) == [a.id] } != nil)

        try await repo.restore(ids: [a.id])
        #expect(await firstValue(all) { $0.count == 2 } != nil)
        #expect(await firstValue(removed) { $0.isEmpty } != nil)
    }

    @Test func restoreReturnsConnectionsIntact() async throws {
        let (_, repo) = try setup()
        var c = makeConn("Keeps everything", host: "k.example", tags: ["a", "b"], favorite: true, lastConnected: clock.now())
        c.notes = "important"
        c.pinnedFolders = [PinnedFolder(path: "/www")]
        c.secretReferences = [.password: "op://V/I/password"]
        try await repo.save(c)
        try await repo.softDelete(ids: [c.id])
        #expect(try await repo.softDelete(ids: [c.id]) == 0)

        let restored = try await repo.restore(ids: [c.id, UUID()])
        #expect(restored == [c])
        #expect(try await repo.fetch() == [c])
        #expect(try await repo.recentlyRemoved().isEmpty)
    }

    @Test func recentlyRemovedListsNewestFirst() async throws {
        let (_, repo) = try setup()
        let a = makeConn("A"), b = makeConn("B", host: "b"), c = makeConn("C", host: "c")
        try await repo.save([a, b, c])
        try await repo.softDelete(ids: [a.id])
        clock.advance(by: 60)
        try await repo.softDelete(ids: [b.id])
        #expect(try await repo.recentlyRemoved().map(\.id) == [b.id, a.id])
    }

    @Test func softDeleteClosesOpenTabs() async throws {
        let (_, repo) = try setup()
        let c = makeConn()
        try await repo.save(c)
        repo.openConnections.open(c.id)
        try await repo.softDelete(ids: [c.id])
        #expect(repo.openConnections.ids.isEmpty)
    }

    @Test func secretsAndSessionStateSurviveUntilPurge() async throws {
        let (db, repo) = try setup()
        let secrets = InMemorySecretStore()
        let old = makeConn("Old", host: "old"), recent = makeConn("Recent", host: "recent"), live = makeConn("Live", host: "live")
        try await repo.save([old, recent, live])
        for c in [old, recent, live] {
            for purpose in SecretPurpose.allCases { await secrets.setSecret("s-\(purpose.rawValue)", for: c.id, purpose: purpose) }
        }
        let sessions = SessionRepository(database: db)
        try await sessions.save(SessionState(connectionId: old.id, remoteTabs: [TabState(path: "/a")], savedAt: clock.now()))
        try await ConnectionHealthRepository(database: db).record(ConnectionHealth(connectionId: old.id, status: .authFailed, testedAt: clock.now()))

        try await repo.softDelete(ids: [old.id])
        clock.advance(by: 20 * day)
        try await repo.softDelete(ids: [recent.id])
        clock.advance(by: 10 * day + 1)

        // Old was removed 30 days and a second ago; recent only 10 days ago.
        #expect(try await repo.purgeRemoved(olderThan: 31 * day, secrets: secrets) == 0)
        #expect(await secrets.secret(for: old.id, purpose: .password) == "s-password")
        #expect(try await sessions.load(old.id) != nil)

        #expect(try await repo.purgeRemoved(secrets: secrets) == 1)
        #expect(try await repo.connection(id: old.id) == nil)
        #expect(try await sessions.load(old.id) == nil)
        #expect(try await ConnectionHealthRepository(database: db).latest(for: old.id) == nil)
        for purpose in SecretPurpose.allCases {
            #expect(await secrets.secret(for: old.id, purpose: purpose) == nil)
            #expect(await secrets.secret(for: recent.id, purpose: purpose) != nil)
            #expect(await secrets.secret(for: live.id, purpose: purpose) != nil)
        }
        #expect(try await repo.recentlyRemoved().map(\.id) == [recent.id])
        #expect(try await repo.purgeRemoved(secrets: secrets) == 0)
    }

    @Test func emptyingTheListPurgesChosenOrAllRemovedConnections() async throws {
        let (_, repo) = try setup()
        let secrets = InMemorySecretStore()
        let a = makeConn("A"), b = makeConn("B", host: "b"), live = makeConn("Live", host: "live")
        try await repo.save([a, b, live])
        for c in [a, b, live] { await secrets.setSecret("pw", for: c.id, purpose: .password) }
        try await repo.softDelete(ids: [a.id, b.id])

        #expect(try await repo.emptyRecentlyRemoved(ids: [a.id, live.id], secrets: secrets) == 1)
        #expect(await secrets.secret(for: a.id, purpose: .password) == nil)
        #expect(await secrets.secret(for: live.id, purpose: .password) == "pw")
        #expect(try await repo.emptyRecentlyRemoved(secrets: secrets) == 1)
        #expect(await secrets.secret(for: b.id, purpose: .password) == nil)
        #expect(try await repo.fetch().map(\.id) == [live.id])
    }

    @Test func aFailingSecretStoreLeavesTheRowForRetry() async throws {
        struct FailingStore: SecretStore {
            func secret(for connection: UUID, purpose: SecretPurpose) async throws -> String? { nil }
            func setSecret(_ secret: String, for connection: UUID, purpose: SecretPurpose) async throws {}
            func removeSecret(for connection: UUID, purpose: SecretPurpose) async throws { throw RemoteError.notConnected }
        }
        let (_, repo) = try setup()
        let c = makeConn()
        try await repo.save(c)
        try await repo.softDelete(ids: [c.id])
        await #expect(throws: RemoteError.self) { try await repo.purgeRemoved(olderThan: 0, secrets: FailingStore()) }
        #expect(try await repo.recentlyRemoved().map(\.id) == [c.id])
    }

    @Test func whmSyncDoesNotResurrectRemovedAccounts() async throws {
        let (_, repo) = try setup()
        let source = UUID()
        let c = makeConn("acct", user: "acct", source: .whm(source))
        try await repo.save(c)
        try await repo.softDelete(ids: [c.id])
        let seen = try await repo.fetch(ConnectionFilter(scope: .source(.whm(source)), includeRemoved: true))
        #expect(seen.map(\.id) == [c.id])
    }

    @Test func migrationAddsColumnToExistingRows() async throws {
        let (db, repo) = try setup()
        let c = makeConn()
        try await repo.save(c)
        let columns = try await db.writer.read { try $0.columns(in: "connection").map(\.name) }
        #expect(columns.contains("deletedAt"))
        #expect(try await repo.connection(id: c.id)?.deletedAt == nil)
    }
}
