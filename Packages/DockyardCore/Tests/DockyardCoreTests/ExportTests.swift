import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

private let fastIterations = 1_000

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

private func sampleContents(includeSecrets: Bool = true) -> ExportContents {
    let folder = ClientFolder(name: "Acme Corp")
    let source = WHMSource(label: "Main WHM", host: "whm.example.com")
    var jump = makeConn("Bastion", host: "bastion.example.com", user: "ops")
    jump.keyPath = "/Users/j/.ssh/id"
    jump.authMethods = .key
    var site = makeConn("Acme Prod", host: "acme.example.com", user: "deploy", client: folder.id)
    site.isProd = true
    site.readOnly = true
    site.trashOnDelete = true
    site.keepVersionsOnOverwrite = true
    site.verifyChecksums = true
    site.jumpHost = jump.id
    site.pinnedFolders = [PinnedFolder(path: "/var/www/html", label: "Web")]
    site.transferFilters = ["*.log", "/build"]
    site.tags = ["client", "prod"]
    site.notes = "Notes with ünïcode and \"quotes\""
    site.initialRemotePath = "/var/www"
    var whm = makeConn("cPanel acme", host: "cp.example.com", user: "acme", source: .whm(source.id))
    whm.favorite = true
    var contents = ExportContents(
        connections: [site, jump, whm], folders: [folder], whmSources: [source],
        settings: ["maxConnections": .int(3), "theme": .string("dark"), "nested": .object(["a": .array([.bool(true), .double(1.5)])])],
        createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    if includeSecrets {
        contents.secrets = [site.id: [.password: "pw-1", .elevationPassword: "root-pw"], jump.id: [.keyPassphrase: "phrase"]]
        contents.whmTokens = [source.apiTokenKeychainRef: "TOKEN"]
    }
    return contents
}

@Suite struct PBKDF2Tests {
    @Test(arguments: [
        (1, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"),
        (2, "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"),
        (4096, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"),
    ])
    func rfcVectors(iterations: Int, expected: String) {
        let out = PBKDF2.derive(passphrase: Data("password".utf8), salt: Data("salt".utf8), iterations: iterations, length: 32)
        #expect(hex(out) == expected)
    }

    @Test func longerOutputExtendsTheShorterOne() {
        let short = PBKDF2.derive(passphrase: Data("password".utf8), salt: Data("salt".utf8), iterations: 3, length: 32)
        let long = PBKDF2.derive(passphrase: Data("password".utf8), salt: Data("salt".utf8), iterations: 3, length: 64)
        #expect(long.count == 64 && long.prefix(32) == short)
    }

    @Test func longPassphrasesAreHashedFirst() {
        // 131-byte key and salt from RFC 6070's style of check: just make sure it differs from a truncated key.
        let long = Data(repeating: 0x61, count: 131)
        let a = PBKDF2.derive(passphrase: long, salt: Data("s".utf8), iterations: 2, length: 32)
        let b = PBKDF2.derive(passphrase: long.prefix(64), salt: Data("s".utf8), iterations: 2, length: 32)
        #expect(a != b && a.count == 32)
    }
}

@Suite struct EncryptedExportTests {
    @Test func roundTripKeepsEverything() throws {
        let contents = sampleContents()
        let file = try EncryptedExport.seal(contents, passphrase: "correct horse", iterations: fastIterations)
        let opened = try EncryptedExport.open(file, passphrase: "correct horse")
        #expect(opened == contents)
        #expect(opened.includesSecrets)
    }

    @Test func fileRevealsNothingInPlainText() throws {
        let file = try EncryptedExport.seal(sampleContents(), passphrase: "pw", iterations: fastIterations)
        let text = String(decoding: file, as: UTF8.self)
        for needle in ["acme.example.com", "pw-1", "phrase", "TOKEN", "Acme Corp", "deploy"] { #expect(!text.contains(needle)) }
        #expect(EncryptedExport.inspect(file) == EncryptedExport.Header(version: 1, iterations: fastIterations))
    }

    @Test func eachSealIsDifferent() throws {
        let a = try EncryptedExport.seal(sampleContents(), passphrase: "pw", iterations: fastIterations)
        let b = try EncryptedExport.seal(sampleContents(), passphrase: "pw", iterations: fastIterations)
        #expect(a != b && a.count == b.count)
    }

    @Test func wrongPassphraseIsDistinctFromTampering() throws {
        let file = try EncryptedExport.seal(sampleContents(), passphrase: "right", iterations: fastIterations)
        #expect(throws: ExportError.wrongPassphrase) { try EncryptedExport.open(file, passphrase: "wrong") }
        #expect(throws: ExportError.wrongPassphrase) { try EncryptedExport.open(file, passphrase: "Right") }
        #expect(throws: ExportError.emptyPassphrase) { try EncryptedExport.open(file, passphrase: "") }
        #expect(throws: ExportError.emptyPassphrase) { try EncryptedExport.seal(sampleContents(), passphrase: "") }
    }

    @Test func everySingleByteChangeIsDetected() throws {
        var contents = sampleContents(includeSecrets: false)
        contents.connections = Array(contents.connections.prefix(1))
        let file = try EncryptedExport.seal(contents, passphrase: "pw", iterations: 50)
        // Bytes 10..<14 hold the work factor; flipping them just asks for a different (huge) amount of work.
        for index in 0..<file.count where !(10..<14).contains(index) {
            var damaged = file
            damaged[index] ^= 0x01
            #expect(throws: (any Error).self, "byte \(index)") { try EncryptedExport.open(damaged, passphrase: "pw") }
        }
    }

    @Test func ciphertextTamperingReportsTampered() throws {
        let file = try EncryptedExport.seal(sampleContents(), passphrase: "pw", iterations: fastIterations)
        var damaged = file
        damaged[EncryptedExport.headerLength + 5] ^= 0xFF
        #expect(throws: ExportError.tampered) { try EncryptedExport.open(damaged, passphrase: "pw") }
        var badTag = file
        badTag[badTag.count - 1] ^= 0xFF
        #expect(throws: ExportError.tampered) { try EncryptedExport.open(badTag, passphrase: "pw") }
        #expect(throws: (any Error).self) { try EncryptedExport.open(file.dropLast(20), passphrase: "pw") }
    }

    @Test func notAnExportAndFutureVersions() throws {
        #expect(throws: ExportError.notAnExportFile) { try EncryptedExport.open(Data("hello".utf8), passphrase: "pw") }
        #expect(throws: ExportError.notAnExportFile) { try EncryptedExport.open(Data(), passphrase: "pw") }
        var future = try EncryptedExport.seal(sampleContents(), passphrase: "pw", iterations: fastIterations)
        future[8] = 9
        #expect(throws: ExportError.unsupportedVersion(9)) { try EncryptedExport.open(future, passphrase: "pw") }
    }

    @Test func absurdWorkFactorFromAHostileFileIsRefused() throws {
        var file = try EncryptedExport.seal(sampleContents(), passphrase: "pw", iterations: fastIterations)
        file.replaceSubrange(10..<14, with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: ExportError.tampered) { try EncryptedExport.open(file, passphrase: "pw") }
    }

    @Test func unicodePassphrasesAreNormalised() throws {
        let composed = "caf\u{00E9}", decomposed = "cafe\u{0301}"
        let contents = sampleContents()
        let file = try EncryptedExport.seal(contents, passphrase: composed, iterations: fastIterations)
        #expect(try EncryptedExport.open(file, passphrase: decomposed) == contents)
    }

    @Test func defaultWorkFactorIsHighAndStillFastEnough() throws {
        #expect(EncryptedExport.defaultIterations >= 600_000)
        let start = Date()
        let contents = sampleContents()
        let file = try EncryptedExport.seal(contents, passphrase: "pw")
        #expect(try EncryptedExport.open(file, passphrase: "pw") == contents)
        #expect(Date().timeIntervalSince(start) < 60)
    }
}

@Suite struct ExportMergeTests {
    struct Env {
        let db: DockyardDatabase
        let connections: ConnectionRepository
        let folders: ClientFolderRepository
        let whm: WHMSourceRepository
        let secrets: InMemorySecretStore
        var collector: ExportCollector { ExportCollector(connections: connections, folders: folders, whmSources: whm, secrets: secrets) }
        var merger: ExportMerger { ExportMerger(connections: connections, folders: folders, whmSources: whm, secrets: secrets) }
    }

    func env() throws -> Env {
        let db = try DockyardDatabase()
        return Env(db: db, connections: ConnectionRepository(database: db), folders: ClientFolderRepository(database: db),
                   whm: WHMSourceRepository(database: db), secrets: InMemorySecretStore())
    }

    @Test func exportFromOneMacImportsIntoAnother() async throws {
        let a = try env()
        let contents = sampleContents()
        // Populate A directly from the sample so the collector has something real to read.
        for folder in contents.folders { try await a.db.writer.write { try folder.insert($0) } }
        for source in contents.whmSources { try await a.whm.save(source) }
        try await a.connections.save(contents.connections.filter { $0.jumpHost == nil })
        try await a.connections.save(contents.connections.filter { $0.jumpHost != nil })
        for (id, byPurpose) in contents.secrets { for (purpose, value) in byPurpose { try await a.secrets.setSecret(value, for: id, purpose: purpose) } }

        let collected = try await a.collector.collect(includeSecrets: true, settings: contents.settings)
        #expect(collected.connections.count == 3 && collected.secrets.count == 2)
        let file = try EncryptedExport.seal(collected, passphrase: "pw", iterations: fastIterations)

        let b = try env()
        let summary = try await b.merger.merge(try EncryptedExport.open(file, passphrase: "pw"))
        #expect(summary.connectionsCreated == 3 && summary.connectionsSkipped == 0)
        #expect(summary.foldersCreated == 1 && summary.whmSourcesCreated == 1 && summary.secretsRestored == 3)
        #expect(summary.settings["theme"] == .string("dark"))

        let site = try #require(try await b.connections.connection(protocol: .sftp, host: "acme.example.com", port: 22, username: "deploy"))
        let jump = try #require(try await b.connections.connection(protocol: .sftp, host: "bastion.example.com", port: 22, username: "ops"))
        #expect(site.jumpHost == jump.id && site.readOnly && site.trashOnDelete && site.pinnedFolders.count == 1)
        #expect(site.transferFilters == ["*.log", "/build"] && site.clientFolderId != nil)
        #expect(try await b.secrets.secret(for: site.id, purpose: .password) == "pw-1")
        #expect(try await b.secrets.secret(for: jump.id, purpose: .keyPassphrase) == "phrase")
        let cpanel = try #require(try await b.connections.fetch(ConnectionFilter(scope: .anyWHM)).first)
        #expect(cpanel.source.whmServerId == contents.whmSources[0].id)
    }

    @Test func importingTwiceDoesNotDuplicate() async throws {
        let b = try env()
        let contents = sampleContents()
        _ = try await b.merger.merge(contents)
        let again = try await b.merger.merge(contents)
        #expect(again.connectionsCreated == 0 && again.connectionsSkipped == 3 && again.foldersCreated == 0 && again.whmSourcesCreated == 0)
        #expect(again.secretsRestored == 0)
        #expect(try await b.connections.count() == 3)
    }

    @Test func existingConnectionsAndTheirSecretsAreNeverTouched() async throws {
        let b = try env()
        var mine = Connection(name: "My own name", protocol: .sftp, host: "ACME.example.com", port: 22, username: "deploy")
        mine.notes = "local notes"
        try await b.connections.save(mine)
        try await b.secrets.setSecret("local-pw", for: mine.id, purpose: .password)
        let summary = try await b.merger.merge(sampleContents())
        #expect(summary.connectionsSkipped == 1 && summary.connectionsCreated == 2)
        let kept = try #require(try await b.connections.connection(id: mine.id))
        #expect(kept.name == "My own name" && kept.notes == "local notes" && !kept.readOnly)
        #expect(try await b.secrets.secret(for: mine.id, purpose: .password) == "local-pw")
        #expect(try await b.secrets.secret(for: mine.id, purpose: .elevationPassword) == nil)
    }

    @Test func jumpHostPointsAtTheExistingDuplicate() async throws {
        let b = try env()
        let existing = Connection(name: "Local bastion", protocol: .sftp, host: "bastion.example.com", port: 22, username: "ops")
        try await b.connections.save(existing)
        _ = try await b.merger.merge(sampleContents())
        let site = try #require(try await b.connections.connection(protocol: .sftp, host: "acme.example.com", port: 22, username: "deploy"))
        #expect(site.jumpHost == existing.id)
    }

    @Test func idCollisionGetsANewId() async throws {
        let b = try env()
        let contents = sampleContents()
        let clash = contents.connections[1]
        try await b.connections.save(Connection(id: clash.id, name: "Different", protocol: .ftp, host: "other.example.com", username: "u"))
        let summary = try await b.merger.merge(contents)
        #expect(summary.connectionsCreated == 3)
        let imported = try #require(try await b.connections.connection(protocol: .sftp, host: "bastion.example.com", port: 22, username: "ops"))
        #expect(imported.id != clash.id)
        let site = try #require(try await b.connections.connection(protocol: .sftp, host: "acme.example.com", port: 22, username: "deploy"))
        #expect(site.jumpHost == imported.id)
    }

    @Test func duplicateEndpointsInsideOneFileCollapse() async throws {
        let b = try env()
        let a = makeConn("A", host: "same.example.com", user: "u")
        let dup = makeConn("A again", host: "same.example.com", user: "u")
        let summary = try await b.merger.merge(ExportContents(connections: [a, dup]))
        #expect(summary.connectionsCreated == 1 && summary.connectionsSkipped == 1)
    }

    @Test func foldersMergeByNameIgnoringCase() async throws {
        let b = try env()
        let existing = try await b.folders.create(name: "ACME corp")
        let summary = try await b.merger.merge(sampleContents())
        #expect(summary.foldersCreated == 0)
        let site = try #require(try await b.connections.connection(protocol: .sftp, host: "acme.example.com", port: 22, username: "deploy"))
        #expect(site.clientFolderId == existing.id)
    }

    @Test func collectorSkipsSecretsUnlessAsked() async throws {
        let a = try env()
        let c = makeConn()
        try await a.connections.save(c)
        try await a.secrets.setSecret("x", for: c.id, purpose: .password)
        #expect(try await a.collector.collect(includeSecrets: false).secrets.isEmpty)
        #expect(try await a.collector.collect(includeSecrets: true).secrets[c.id] == [.password: "x"])
    }
}
