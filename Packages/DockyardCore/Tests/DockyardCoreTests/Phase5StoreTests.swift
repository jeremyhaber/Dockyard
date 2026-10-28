import Foundation
import Testing
import GRDB
import ConnectionKit
@testable import DockyardCore

@Suite struct Phase5StoreTests {
    @Test func newFieldsDefaultToOff() async throws {
        let repo = ConnectionRepository(database: try DockyardDatabase())
        let c = makeConn()
        try await repo.save(c)
        let loaded = try #require(try await repo.connection(id: c.id))
        #expect(!loaded.trashOnDelete && !loaded.keepVersionsOnOverwrite && !loaded.readOnly && !loaded.verifyChecksums)
        #expect(loaded.jumpHost == nil && loaded.pinnedFolders.isEmpty && loaded.transferFilters.isEmpty)
    }

    @Test func fieldsRoundTrip() async throws {
        let repo = ConnectionRepository(database: try DockyardDatabase())
        let jump = makeConn("Bastion")
        var c = makeConn("Target")
        c.trashOnDelete = true
        c.keepVersionsOnOverwrite = true
        c.readOnly = true
        c.verifyChecksums = true
        c.jumpHost = jump.id
        c.pinnedFolders = [PinnedFolder(path: "/var/www/html/wp-content/themes", label: "Themes"), PinnedFolder(path: "/etc/nginx")]
        c.transferFilters = ["*.log", "/build", "cache/"]
        try await repo.save([jump, c])
        let loaded = try #require(try await repo.connection(id: c.id))
        #expect(loaded == c)
    }

    @Test func deletingTheJumpHostClearsTheReference() async throws {
        let repo = ConnectionRepository(database: try DockyardDatabase())
        let jump = makeConn("Bastion")
        var c = makeConn("Target")
        c.jumpHost = jump.id
        try await repo.save([jump, c])
        try await repo.delete(jump.id)
        #expect(try await repo.connection(id: c.id)?.jumpHost == nil)
    }

    @Test func importSourcesRoundTrip() {
        for source in [ConnectionSource.transmitImport, .cyberduckImport, .sshConfigImport] {
            #expect(ConnectionSource(rawValue: source.rawValue) == source)
        }
        #expect(ConnectionSource.transmitImport.rawValue == "transmitImport")
        #expect(ConnectionSource.cyberduckImport.rawValue == "cyberduckImport")
    }

    @Test func migrationIsRegisteredAfterTheFirstOne() throws {
        let db = try DockyardDatabase()
        let applied = try db.writer.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") }
        #expect(applied.first == "v1" && applied.contains("v_phase5_safety"))
    }
}
