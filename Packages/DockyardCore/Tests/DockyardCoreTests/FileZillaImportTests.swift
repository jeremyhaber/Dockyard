import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

enum Fixtures {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.resourceURL?.appendingPathComponent("Fixtures/\(name)") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}

@Suite struct FileZillaImportTests {
    func parsed() throws -> FileZillaParseResult { try FileZillaParser.parse(Fixtures.data("sitemanager-plain.xml")) }

    func site(_ name: String) throws -> FileZillaSite {
        try #require(parsed().sites.first { $0.name == name }, "site \(name)")
    }

    @Test func parsesAllSupportedSitesAndSkipsOthers() throws {
        let r = try parsed()
        #expect(r.sites.map(\.name) == [
            "Acme Production", "Acme Staging", "Globex Public Mirror", "Globex (ask for password)",
            "Old plain-text entry", "nopass.example.net",
        ])
        #expect(r.warnings.contains { $0.contains("Backup bucket") && $0.contains("S3") })
        #expect(r.warnings.contains { $0.contains("Broken entry") && $0.contains("no host") })
        #expect(!r.masterPasswordDetected)
    }

    @Test func nestedFoldersBecomeClientFolders() throws {
        #expect(try site("Acme Production").folderPath == ["Clients", "Acme Corp"])
        #expect(try site("Acme Production").clientFolderName == "Clients / Acme Corp")
        #expect(try site("Globex (ask for password)").folderPath == ["Clients", "Globex", "Legacy"])
        #expect(try site("Old plain-text entry").folderPath == [])
        #expect(try site("Old plain-text entry").clientFolderName == nil)
    }

    @Test func ftpesWithBase64Password() throws {
        let s = try site("Acme Production")
        #expect(s.protocol == .ftps)
        #expect(s.host == "ftp.acme.example" && s.port == 21 && s.username == "acme_web")
        #expect(s.password == "test-password-1")
        #expect(!s.needsPasswordPrompt && !s.passwordWasEncrypted)
        #expect(s.notes == "Main site & shop. Deploy to public_html")
        #expect(s.authMethods == .password)
    }

    @Test func bookmarkNamesDoNotOverrideSiteName() throws {
        #expect(try parsed().sites.contains { $0.name == "Logs" } == false)
    }

    @Test func sftpWithKeyFile() throws {
        let s = try site("Acme Staging")
        #expect(s.protocol == .sftp && s.port == 2222)
        #expect(s.authMethods == .key)
        #expect(s.keyPath == "/Users/jeremy/.ssh/acme_ed25519")
        #expect(s.password == nil)
        #expect(s.notes == "")
    }

    @Test func anonymousFTPUsesDefaultPortWhenZero() throws {
        let s = try site("Globex Public Mirror")
        #expect(s.protocol == .ftp && s.port == 21 && s.username == "anonymous")
        #expect(s.password == nil)
        #expect(!s.needsPasswordPrompt)
    }

    @Test func askPasswordLogonPromptsOnConnect() throws {
        let s = try site("Globex (ask for password)")
        #expect(s.needsPasswordPrompt && s.password == nil && s.username == "gx")
    }

    @Test func unencodedPasswordAndImplicitFTPS() throws {
        let s = try site("Old plain-text entry")
        #expect(s.protocol == .ftps && s.port == 990)
        #expect(s.password == "plain-text-secret")
    }

    @Test func siteWithoutNameFallsBackToHostAndPromptsForMissingPassword() throws {
        let s = try site("nopass.example.net")
        #expect(s.host == "nopass.example.net" && s.needsPasswordPrompt && s.password == nil)
    }

    @Test func masterPasswordFileImportsWithoutPasswords() throws {
        let r = try FileZillaParser.parse(Fixtures.data("sitemanager-master-password.xml"))
        #expect(r.masterPasswordDetected)
        #expect(r.sites.count == 2)
        for s in r.sites {
            #expect(s.password == nil && s.passwordWasEncrypted && s.needsPasswordPrompt)
        }
        #expect(r.sites[1].authMethods == .key && r.sites[1].keyPath == "/Users/alice/.ssh/id_rsa")
        #expect(r.warnings.filter { $0.contains("master password") }.count == 2)
        #expect(!r.warnings.joined().contains("QmFzZTY0"))  // never echo the stored blob
    }

    @Test func rejectsOtherXMLAndBrokenXML() {
        #expect(throws: FileZillaImportError.notASiteManagerFile) { try FileZillaParser.parse("<html><body/></html>") }
        #expect(throws: FileZillaImportError.self) { try FileZillaParser.parse("<FileZilla3><Servers><Server>") }
        #expect(throws: FileZillaImportError.self) { try FileZillaParser.parse("") }
    }

    @Test func emptyServersListIsFine() throws {
        let r = try FileZillaParser.parse("<FileZilla3><Servers/></FileZilla3>")
        #expect(r.sites.isEmpty && r.warnings.isEmpty)
    }

    @Test func badBase64FallsBackToPrompt() throws {
        let xml = """
        <FileZilla3><Servers><Server><Host>h</Host><Protocol>1</Protocol><User>u</User>
        <Pass encoding="base64">%%%not-base64%%%</Pass><Logontype>1</Logontype><Name>x</Name></Server></Servers></FileZilla3>
        """
        let r = try FileZillaParser.parse(xml)
        #expect(r.sites[0].password == nil && r.sites[0].needsPasswordPrompt)
        #expect(r.warnings.count == 1)
    }

    @Test func invalidPortFallsBackToProtocolDefault() throws {
        let xml = "<FileZilla3><Servers><Server><Host>h</Host><Port>99999</Port><Protocol>1</Protocol><User>u</User><Name>n</Name></Server></Servers></FileZilla3>"
        #expect(try FileZillaParser.parse(xml).sites[0].port == 22)
    }

    @Test func defaultPath() {
        #expect(FileZillaParser.defaultPath(home: "/Users/j") == "/Users/j/.config/filezilla/sitemanager.xml")
    }

    // MARK: Applying

    @Test func importCreatesFoldersConnectionsAndSecrets() async throws {
        let db = try DockyardDatabase()
        let repo = ConnectionRepository(database: db)
        let folders = ClientFolderRepository(database: db)
        let secrets = InMemorySecretStore()
        let importer = FileZillaImporter(repository: repo, folders: folders, secrets: secrets)
        let summary = try await importer.apply(parsed())
        #expect(summary.created == 6)
        #expect(summary.foldersCreated == 2)
        #expect(summary.passwordsStored == 2)
        #expect(summary.needingPassword == 2)
        let all = try await repo.fetch(.source(.filezillaImport))
        #expect(all.count == 6)
        let prod = try #require(all.first { $0.name == "Acme Production" })
        #expect(await secrets.secret(for: prod.id, purpose: .password) == "test-password-1")
        let acmeFolder = try #require(try await folders.all().first { $0.name == "Clients / Acme Corp" })
        #expect(prod.clientFolderId == acmeFolder.id)
        let staging = try #require(all.first { $0.name == "Acme Staging" })
        #expect(staging.clientFolderId == acmeFolder.id)
        #expect(await secrets.secret(for: staging.id, purpose: .password) == nil)
        #expect(staging.authMethods == .key && staging.keyPath != nil)
    }

    @Test func reimportSkipsDuplicatesAndKeepsUserEdits() async throws {
        let db = try DockyardDatabase()
        let repo = ConnectionRepository(database: db)
        let importer = FileZillaImporter(repository: repo, folders: ClientFolderRepository(database: db), secrets: InMemorySecretStore())
        _ = try await importer.apply(parsed())
        var prod = try #require(try await repo.fetch(.search("Acme Production")).first)
        prod.name = "Renamed by me"
        try await repo.saveEdited(prod)
        let second = try await importer.apply(parsed())
        #expect(second.created == 0 && second.skippedDuplicates == 6)
        #expect(try await repo.count() == 6)
        #expect(try await repo.connection(id: prod.id)?.name == "Renamed by me")
    }

    @Test func importedMasterPasswordSitesStoreNoSecrets() async throws {
        let db = try DockyardDatabase()
        let repo = ConnectionRepository(database: db)
        let secrets = InMemorySecretStore()
        let importer = FileZillaImporter(repository: repo, folders: ClientFolderRepository(database: db), secrets: secrets)
        let summary = try await importer.apply(FileZillaParser.parse(Fixtures.data("sitemanager-master-password.xml")))
        #expect(summary.passwordsStored == 0 && summary.needingPassword == 2)
        for c in try await repo.fetch() { #expect(await secrets.secret(for: c.id, purpose: .password) == nil) }
    }
}
