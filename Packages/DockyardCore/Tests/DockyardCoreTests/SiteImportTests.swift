import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

private func fixtureDirectory(_ relative: String) throws -> String {
    try #require(Bundle.module.resourceURL?.appendingPathComponent("Fixtures/\(relative)").path)
}

private struct StubReader: ImportedPasswordReader {
    var passwords: [String: String]
    func password(for request: KeychainPasswordRequest) async -> String? { passwords["\(request.account)@\(request.server)"] }
}

@Suite struct CyberduckImportTests {
    func parsed() throws -> ImportParseResult {
        CyberduckParser.parseDirectories([try fixtureDirectory("cyberduck/duck/Bookmarks")])
    }

    @Test func knownBookmarkLocations() {
        #expect(CyberduckParser.bookmarkDirectories(home: "/Users/j") == [
            "/Users/j/Library/Group Containers/G69SCX94XU.duck/Library/Application Support/duck/Bookmarks",
            "/Users/j/Library/Application Support/Cyberduck/Bookmarks",
        ])
    }

    @Test func mapsSupportedBookmarksAndSkipsTheRest() throws {
        let r = try parsed()
        #expect(r.sites.map(\.name) == ["Acme web01", "Globex public mirror", "ftp.initech.example"])
        #expect(r.warnings.contains { $0.contains("Backup bucket") && $0.contains("s3") })
        #expect(r.warnings.contains { $0.contains("no host") })
        #expect(r.warnings.contains { $0.contains("implicit FTPS") })
    }

    @Test func sftpWithKeyLabelsAndPath() throws {
        let site = try #require(try parsed().sites.first { $0.name == "Acme web01" })
        #expect(site.protocol == .sftp && site.host == "web01.acme.example" && site.port == 22 && site.username == "deploy")
        #expect(site.authMethods == .key)
        #expect(site.keyPath?.hasSuffix("/.ssh/id_ed25519") == true && site.keyPath?.hasPrefix("~") == false)
        #expect(site.tags == ["production", "acme"] && site.notes == "Primary web node")
        #expect(site.remotePath == "/var/www/acme" && site.keychain == nil)
    }

    @Test func anonymousFtp() throws {
        let site = try #require(try parsed().sites.first { $0.name == "Globex public mirror" })
        #expect(site.protocol == .ftp && site.username == "anonymous" && site.remotePath == nil && site.keychain == nil)
    }

    @Test func passwordSitesCarryAKeychainRequest() throws {
        let site = try #require(try parsed().sites.first { $0.host == "ftp.initech.example" })
        #expect(site.protocol == .ftps && site.port == 990 && site.name == "ftp.initech.example")
        #expect(site.keychain == KeychainPasswordRequest(application: .cyberduck, server: "ftp.initech.example", account: "initech_web", port: 990, protocolName: "ftps"))
    }

    @Test func legacyFolderIsMergedWithoutDuplicates() throws {
        let r = CyberduckParser.parseDirectories([try fixtureDirectory("cyberduck/duck/Bookmarks"), try fixtureDirectory("cyberduck/legacy/Bookmarks"),
                                                   "/does/not/exist"])
        #expect(r.sites.filter { $0.host == "web01.acme.example" }.count == 1)
        let umbrella = try #require(r.sites.first { $0.host == "legacy.umbrella.example" })
        #expect(umbrella.port == 2200 && umbrella.authMethods == .password)
        #expect(r.warnings.contains { $0.contains("sandbox bookmark") })
    }

    @Test func garbageIsReportedNotFatal() {
        let r = CyberduckParser.parseBookmark(Data("not a plist".utf8), fileName: "x.duckbookmark")
        #expect(r.sites.isEmpty && r.warnings == ["x.duckbookmark: not a property list"])
    }

    @Test func readsBinaryPlists() throws {
        let dict: [String: Any] = ["Protocol": "sftp", "Hostname": "bin.example", "Username": "u", "Port": "22"]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        #expect(CyberduckParser.parseBookmark(data).sites.first?.host == "bin.example")
    }
}

@Suite struct TransmitImportTests {
    func parsed() throws -> ImportParseResult { try TransmitParser.parse(Fixtures.data("transmit4-preferences.plist")) }

    @Test func defaultLocation() {
        #expect(TransmitParser.defaultPaths(home: "/Users/j") == ["/Users/j/Library/Preferences/com.panic.Transmit.plist"])
    }

    @Test func collectionsBecomeClientFolders() throws {
        let sites = try parsed().sites
        #expect(sites.map(\.name) == ["Acme Production", "Acme FTP over TLS", "Home server", "Public FTP"])
        #expect(sites[0].folderPath == ["Clients"])
        #expect(sites[1].folderPath == ["Clients", "Acme Legacy"] && sites[1].clientFolderName == "Clients / Acme Legacy")
        #expect(sites[2].folderPath == ["Personal"])
    }

    @Test func protocolsPortsAndPaths() throws {
        let sites = try parsed().sites
        #expect(sites[0].protocol == .sftp && sites[0].port == 22 && sites[0].remotePath == "/home/acme_web/public_html")
        #expect(sites[1].protocol == .ftps && sites[1].port == 21)
        #expect(sites[3].protocol == .ftp && sites[3].port == 21 && sites[3].username == "anonymous")
    }

    @Test func keysAndKeychainRequests() throws {
        let sites = try parsed().sites
        #expect(sites[2].authMethods == .key && sites[2].keyPath?.hasSuffix("/.ssh/id_rsa") == true && sites[2].notes == "NAS")
        #expect(sites[0].keychain == KeychainPasswordRequest(application: .transmit, server: "ftp.acme.example", account: "acme_web", port: 22, protocolName: "sftp"))
    }

    @Test func unsupportedProtocolsAreWarnings() throws {
        let r = try parsed()
        #expect(r.warnings.contains { $0.contains("Photos on S3") && $0.contains("S3") })
        #expect(!r.sites.contains { $0.host.contains("amazonaws") })
    }

    @Test func nonPlistExportIsRefusedWithAnExplanation() {
        let proprietary = Data([0x00, 0x01, 0xFE, 0xFF, 0x7F, 0x45, 0x58, 0x50, 0x00, 0x91])
        #expect(throws: TransmitImportError.self) { try TransmitParser.parse(proprietary) }
        do { _ = try TransmitParser.parse(proprietary) } catch {
            #expect("\(error)".contains(".exportedServers"))
        }
    }

    @Test func emptyPlistWarns() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["Other": 1], format: .xml, options: 0)
        let r = try TransmitParser.parse(data)
        #expect(r.sites.isEmpty && r.warnings.count == 1)
    }

    @Test func favoritesStoredAsNestedData() throws {
        let inner = try PropertyListSerialization.data(fromPropertyList: [["name": "Nested", "Favorites": [
            ["nickname": "Deep", "server": "deep.example", "protocol": "SFTP", "username": "d"] as [String: Any]]] as [String: Any]], format: .binary, options: 0)
        let outer = try PropertyListSerialization.data(fromPropertyList: ["FavoriteCollections": inner], format: .binary, options: 0)
        let r = try TransmitParser.parse(outer)
        #expect(r.sites.map(\.name) == ["Deep"] && r.sites[0].folderPath == ["Nested"])
    }

    @Test func keyedArchiveInXmlForm() throws {
        let r = try TransmitParser.parse(Fixtures.data("transmit-keyed-archive.plist"))
        #expect(r.sites.map(\.host) == ["archived.example"] && r.sites[0].name == "Archived site" && r.sites[0].username == "archiver")
    }
}

@Suite struct SiteImporterTests {
    func setup() throws -> (SiteImporter, ConnectionRepository, ClientFolderRepository, InMemorySecretStore) {
        let db = try DockyardDatabase()
        let repo = ConnectionRepository(database: db)
        let folders = ClientFolderRepository(database: db)
        let secrets = InMemorySecretStore()
        return (SiteImporter(repository: repo, folders: folders, source: .cyberduckImport, secrets: secrets), repo, folders, secrets)
    }

    @Test func createsConnectionsFoldersAndStoresReadablePasswords() async throws {
        let (importer, repo, folders, secrets) = try setup()
        let parsed = try TransmitParser.parse(Fixtures.data("transmit4-preferences.plist"))
        let reader = StubReader(passwords: ["acme_web@ftp.acme.example": "kc-secret"])
        let summary = try await importer.apply(parsed, passwordReader: reader)
        #expect(summary.created == 4 && summary.foldersCreated == 3 && summary.skippedDuplicates == 0)
        #expect(summary.passwordsStored == 1)
        // The FTPS site has no readable password; the key site and the anonymous site never needed one.
        #expect(summary.needingPassword == 1 && summary.pendingPasswords.count == 1)
        #expect(summary.pendingPasswords[0].request.server == "old.acme.example")

        let acme = try #require(try await repo.connection(protocol: .sftp, host: "ftp.acme.example", port: 22, username: "acme_web"))
        #expect(acme.source == .cyberduckImport && acme.initialRemotePath == "/home/acme_web/public_html")
        #expect(try await secrets.secret(for: acme.id, purpose: .password) == "kc-secret")
        #expect(try await folders.all().map(\.name).sorted() == ["Clients", "Clients / Acme Legacy", "Personal"])
        #expect(acme.clientFolderId != nil)
    }

    @Test func withoutAReaderEveryPasswordSiteIsPending() async throws {
        let (importer, _, _, secrets) = try setup()
        let parsed = CyberduckParser.parseDirectories([try fixtureDirectory("cyberduck/duck/Bookmarks")])
        let summary = try await importer.apply(parsed)
        #expect(summary.created == 3 && summary.passwordsStored == 0 && summary.needingPassword == 1)
        #expect(summary.pendingPasswords.map(\.request.account) == ["initech_web"])
        #expect(summary.warnings == parsed.warnings)
        _ = secrets
    }

    @Test func secondRunSkipsDuplicates() async throws {
        let (importer, repo, _, _) = try setup()
        let parsed = CyberduckParser.parseDirectories([try fixtureDirectory("cyberduck/duck/Bookmarks")])
        _ = try await importer.apply(parsed)
        let again = try await importer.apply(parsed)
        #expect(again.created == 0 && again.skippedDuplicates == 3)
        #expect(try await repo.count() == 3)
    }

    @Test func skipsSitesThatAlreadyExistFromAnotherSource() async throws {
        let (importer, repo, _, _) = try setup()
        try await repo.save(Connection(name: "Mine", protocol: .sftp, host: "WEB01.acme.example", port: 22, username: "deploy"))
        let parsed = CyberduckParser.parseDirectories([try fixtureDirectory("cyberduck/duck/Bookmarks")])
        let summary = try await importer.apply(parsed)
        #expect(summary.skippedDuplicates == 1 && summary.created == 2)
    }
}
