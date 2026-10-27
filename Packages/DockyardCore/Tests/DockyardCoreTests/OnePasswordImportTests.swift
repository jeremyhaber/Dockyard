import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

private func item(_ name: String) throws -> OnePasswordItem {
    try JSONDecoder().decode(OnePasswordItem.self, from: try Fixtures.data("onepassword/\(name).json"))
}

private func json(_ name: String) throws -> String {
    String(decoding: try Fixtures.data("onepassword/\(name).json"), as: UTF8.self)
}

private final class FakeOp: CommandExecuting {
    let handler: @Sendable (CommandInvocation) -> CommandResult
    let calls = LockedBox<[[String]]>([])

    init(_ handler: @escaping @Sendable (CommandInvocation) -> CommandResult) { self.handler = handler }

    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        calls.withLock { $0.append(invocation.arguments) }
        return handler(invocation)
    }
}

private func ok(_ text: String) -> CommandResult { CommandResult(exitCode: 0, stdout: Data(text.utf8)) }

private struct StubResolver: SecretReferenceResolving {
    var values: [String: String]
    func resolve(reference: String) async throws -> String {
        guard let value = values[reference] else { throw OnePasswordError.notFound("reference") }
        return value
    }
}

private struct Rig {
    let repo: ConnectionRepository
    let folders: ClientFolderRepository
    let secrets = InMemorySecretStore()

    init() throws {
        let db = try DockyardDatabase()
        repo = ConnectionRepository(database: db)
        folders = ClientFolderRepository(database: db)
    }

    var importer: SiteImporter { SiteImporter(repository: repo, folders: folders, source: .onePasswordImport, secrets: secrets) }
}

@Suite struct OnePasswordMappingTests {
    @Test func fixturesDecodeLikeCLIOutput() throws {
        let server = try item("server")
        #expect(server.category == .server && server.vault.name == "Infrastructure" && server.tags == ["acme", "production"])
        let password = try #require(server.field(purpose: "PASSWORD"))
        #expect(password.type == "CONCEALED" && password.reference == "op://Infrastructure/Acme web01/password")
        #expect(server.fields.first { $0.id == "admin_url" }?.section?.label == "Admin Console")
        #expect(try item("sshkey").category == .sshKey)
    }

    @Test func descriptionsNeverShowSecrets() throws {
        let server = try item("server")
        let text = String(describing: server) + String(reflecting: server.fields) + "\(server.fields)"
        #expect(!text.contains("correct-horse"))
        let key = try item("sshkey")
        #expect(!String(describing: key.fields).contains("BEGIN PRIVATE KEY"))
    }

    @Test func serverItemMapsUrlFieldPortUserAndPasswordReference() throws {
        let scan = OnePasswordImporter.map([try item("server")])
        let site = try #require(scan.parsed.sites.first)
        #expect(site.name == "Acme web01" && site.protocol == .sftp)
        #expect(site.host == "web01.acme.example" && site.port == 2222 && site.username == "deploy")
        #expect(site.remotePath == "/var/www/acme")
        #expect(site.tags == ["acme", "production"])
        #expect(site.authMethods == .password && site.agentSocket == .system)
        #expect(site.secretReferences == [.password: "op://Infrastructure/Acme web01/password"])
        #expect(site.onePasswordItemId == "x7k2m4qv5nj6h3tdwl2ofp7e3a" && site.keychain == nil)
        #expect(!site.copyReferencesToKeychain)
    }

    @Test func serverWithBareHostAndPortField() throws {
        let site = try #require(OnePasswordImporter.map([try item("server-bare-host")]).parsed.sites.first)
        #expect(site.host == "staging.globex.example" && site.port == 2200 && site.protocol == .sftp && site.username == "ops")
    }

    @Test func loginPrefersAnFTPUrlOverTheWebsite() throws {
        let site = try #require(OnePasswordImporter.map([try item("login")]).parsed.sites.first)
        #expect(site.protocol == .ftps && site.host == "ftp.initech.example" && site.port == 990)
        #expect(site.username == "bill" && site.remotePath == "/uploads")
        #expect(site.secretReferences[.password] == "op://Clients/Initech FTP/password")
        #expect(site.authMethods == .password)
    }

    @Test func loginWithOnlyAWebsiteUsesItsHostAndDefaultPort() throws {
        let site = try #require(OnePasswordImporter.map([try item("login-website-only")]).parsed.sites.first)
        #expect(site.host == "panel.umbrella.example" && site.protocol == .sftp && site.port == 22)
    }

    @Test func itemsWithoutAHostAreSkippedWithAWarning() throws {
        let scan = OnePasswordImporter.map([try item("login-no-host")])
        #expect(scan.parsed.sites.isEmpty)
        #expect(scan.parsed.warnings.contains { $0.contains("Notes login") })
    }

    @Test func itemWithoutAUsernameIsSkippedForSFTP() throws {
        var server = try item("server-bare-host")
        server.fields.removeAll { $0.purpose == "USERNAME" }
        let scan = OnePasswordImporter.map([server])
        #expect(scan.parsed.sites.isEmpty && scan.parsed.warnings.contains { $0.contains("no username") })
    }

    @Test func sshKeyWithoutHostIsOfferedAndTurnsOnTheAgentForSFTPSites() throws {
        let scan = OnePasswordImporter.map([try item("server"), try item("sshkey")])
        let key = try #require(scan.sshKeys.first)
        #expect(key.title == "Deploy key" && key.keyType == "ed25519" && key.publicKey?.hasPrefix("ssh-ed25519") == true)
        #expect(key.fingerprint?.hasPrefix("SHA256:") == true)
        let site = try #require(scan.parsed.sites.first)
        #expect(site.authMethods == [.agent, .password] && site.agentSocket == .onePassword && site.keyPath == nil)
    }

    @Test func agentStaysOffWithoutKeysUnlessAsked() throws {
        let off = OnePasswordImporter.map([try item("server")]).parsed.sites[0]
        #expect(off.agentSocket == .system)
        let forced = OnePasswordImporter.map([try item("server")], options: .init(useSSHAgent: true)).parsed.sites[0]
        #expect(forced.agentSocket == .onePassword && forced.authMethods == [.agent, .password])
        let declined = OnePasswordImporter.map([try item("server"), try item("sshkey")], options: .init(useSSHAgent: false)).parsed.sites[0]
        #expect(declined.agentSocket == .system && declined.authMethods == .password)
    }

    @Test func sshKeyWithAHostBecomesAnAgentSite() throws {
        let scan = OnePasswordImporter.map([try item("sshkey-hosted")])
        let site = try #require(scan.parsed.sites.first)
        #expect(site.host == "box.hetzner.example" && site.username == "root" && site.protocol == .sftp)
        #expect(site.authMethods == .agent && site.agentSocket == .onePassword && site.secretReferences.isEmpty)
        #expect(scan.sshKeys.isEmpty)
    }

    @Test func folderOptions() throws {
        let items = [try item("server"), try item("login-website-only")]
        let byVault = OnePasswordImporter.map(items, options: .init(folder: .vault)).parsed.sites
        #expect(byVault.map(\.clientFolderName) == ["Infrastructure", "Clients"])
        let byTag = OnePasswordImporter.map(items, options: .init(folder: .firstTag)).parsed.sites
        #expect(byTag.map(\.clientFolderName) == ["acme", nil])
        #expect(OnePasswordImporter.map(items).parsed.sites.allSatisfy { $0.folderPath.isEmpty })
    }

    @Test func endpointParsing() {
        let e = OnePasswordImporter.parseEndpoint("sftp://me@[::1]:2022/srv")
        #expect(e?.host == "::1" && e?.port == 2022 && e?.user == "me" && e?.protocol == .sftp && e?.path == "/srv")
        #expect(OnePasswordImporter.parseEndpoint("https://example.com:8443")?.port == nil)
        #expect(OnePasswordImporter.parseEndpoint("not a url") == nil)
        #expect(OnePasswordImporter.parseEndpoint("") == nil)
    }
}

@Suite struct OnePasswordScanTests {
    private func cli(_ handler: @escaping @Sendable (CommandInvocation) -> CommandResult) -> (OnePasswordCLI, FakeOp) {
        let fake = FakeOp(handler)
        return (OnePasswordCLI(executor: fake, locator: { "/fake/op" }), fake)
    }

    @Test func scanListsThenGetsEachItemAndKeepsOrder() async throws {
        let server = try json("server"), login = try json("login")
        let (cli, fake) = cli { invocation in
            let a = invocation.arguments
            if a.starts(with: ["item", "list"]) {
                return ok(#"[{"id":"x7k2m4qv5nj6h3tdwl2ofp7e3a","title":"Acme web01","category":"SERVER","vault":{"id":"v","name":"Infrastructure"}},{"id":"m5v8t1zc3yb7e2nq9hw4kx6duj","title":"Initech FTP","category":"LOGIN","vault":{"id":"v","name":"Infrastructure"}}]"#)
            }
            if a.starts(with: ["item", "get"]) { return ok(a[2] == "x7k2m4qv5nj6h3tdwl2ofp7e3a" ? server : login) }
            return CommandResult(exitCode: 1, stderr: "unexpected")
        }
        let scan = try await OnePasswordImporter(cli: cli).scan(vaults: ["Infrastructure"])
        #expect(scan.parsed.sites.map(\.name) == ["Acme web01", "Initech FTP"])
        let list = try #require(fake.calls.withLock { $0.first })
        #expect(list == ["item", "list", "--vault", "Infrastructure", "--categories", "Server,Login,SSH Key", "--format", "json"])
    }

    @Test func oneUnreadableItemBecomesAWarning() async throws {
        let server = try json("server")
        let (cli, _) = cli { invocation in
            let a = invocation.arguments
            if a.starts(with: ["item", "list"]) {
                return ok(#"[{"id":"x7k2m4qv5nj6h3tdwl2ofp7e3a","title":"Acme web01","category":"SERVER"},{"id":"gone","title":"Broken","category":"LOGIN"}]"#)
            }
            return a[2] == "gone" ? CommandResult(exitCode: 1, stderr: "[ERROR] 2026/01/02 10:00:00 \"gone\" isn't an item in the \"V\" vault.") : ok(server)
        }
        let scan = try await OnePasswordImporter(cli: cli).scan(vaults: ["V"])
        #expect(scan.parsed.sites.count == 1)
        #expect(scan.parsed.warnings.contains { $0.contains("Broken") })
    }

    @Test func aLockedAppStopsTheScan() async throws {
        let (cli, _) = cli { _ in CommandResult(exitCode: 1, stderr: "[ERROR] 2026/01/02 10:00:00 authorization prompt dismissed, please try again") }
        await #expect(throws: OnePasswordError.authorizationDismissed) { try await OnePasswordImporter(cli: cli).scan(vaults: ["V"]) }
    }
}

@Suite struct OnePasswordApplyTests {
    private func scan(_ names: String...) throws -> ImportParseResult {
        OnePasswordImporter.map(try names.map(item)).parsed
    }

    @Test func importStoresReferencesNotPasswords() async throws {
        let rig = try Rig()
        let summary = try await rig.importer.apply(try scan("server", "login"))
        #expect(summary.created == 2 && summary.referencesStored == 2 && summary.passwordsStored == 0 && summary.needingPassword == 0)

        let c = try #require(try await rig.repo.connection(onePasswordItemId: "x7k2m4qv5nj6h3tdwl2ofp7e3a"))
        #expect(c.source == .onePasswordImport && c.secretReferences == [.password: "op://Infrastructure/Acme web01/password"])
        #expect(await rig.secrets.secret(for: c.id, purpose: .password) == nil)
        #expect(try await rig.repo.fetch(.source(.onePasswordImport)).count == 2)
    }

    @Test func agentSitesCarryTheSocketAndNeedNoPassword() async throws {
        let rig = try Rig()
        let summary = try await rig.importer.apply(OnePasswordImporter.map([try item("sshkey-hosted")]).parsed)
        #expect(summary.created == 1 && summary.needingPassword == 0)
        let c = try #require(try await rig.repo.fetch(.all).first)
        #expect(c.agentSocket == .onePassword && c.authMethods == .agent && c.config.agentSocket == .onePassword)
    }

    @Test func copyModeResolvesIntoTheKeychainAndStoresNoReference() async throws {
        let rig = try Rig()
        var parsed = OnePasswordImporter.map([try item("server")], options: .init(secrets: .copyToKeychain)).parsed
        #expect(parsed.sites[0].copyReferencesToKeychain)
        let resolver = StubResolver(values: ["op://Infrastructure/Acme web01/password": "from-op"])
        let summary = try await rig.importer.apply(parsed, referenceResolver: resolver)
        #expect(summary.passwordsStored == 1 && summary.referencesStored == 0 && summary.needingPassword == 0)
        let c = try #require(try await rig.repo.fetch(.all).first)
        #expect(c.secretReferences.isEmpty)
        #expect(await rig.secrets.secret(for: c.id, purpose: .password) == "from-op")

        parsed = try scan("login")
        parsed.sites[0].copyReferencesToKeychain = true
        let failed = try await rig.importer.apply(parsed, referenceResolver: StubResolver(values: [:]))
        #expect(failed.created == 1 && failed.needingPassword == 1 && failed.warnings.contains { $0.contains("Initech FTP") })
    }

    @Test func copyModeSurfacesALockedApp() async throws {
        struct Locked: SecretReferenceResolving {
            func resolve(reference: String) async throws -> String { throw OnePasswordError.appLocked }
        }
        let rig = try Rig()
        let parsed = OnePasswordImporter.map([try item("server")], options: .init(secrets: .copyToKeychain)).parsed
        await #expect(throws: OnePasswordError.appLocked) { try await rig.importer.apply(parsed, referenceResolver: Locked()) }
    }

    @Test func reimportUpdatesItsOwnEntries() async throws {
        let rig = try Rig()
        _ = try await rig.importer.apply(try scan("server"))
        var changed = try item("server")
        changed.title = "Acme web01 (new)"
        changed.urls = []
        changed.fields = changed.fields.map { f in
            var f = f
            if f.id == "url" { f.value = "sftp://web02.acme.example" }
            if f.id == "username" { f.value = "ci" }
            if f.id == "password" { f.reference = "op://Infrastructure/Acme web01/rotated" }
            return f
        }
        let summary = try await rig.importer.apply(OnePasswordImporter.map([changed]).parsed)
        #expect(summary.created == 0 && summary.updated == 1 && summary.skippedDuplicates == 0)
        let all = try await rig.repo.fetch(.all)
        #expect(all.count == 1)
        let c = all[0]
        #expect(c.name == "Acme web01 (new)" && c.host == "web02.acme.example" && c.port == 22 && c.username == "ci")
        #expect(c.secretReferences[.password] == "op://Infrastructure/Acme web01/rotated")
    }

    @Test func reimportRespectsUserEditedFieldsAndLocalSettings() async throws {
        let rig = try Rig()
        _ = try await rig.importer.apply(try scan("server"))
        var mine = try #require(try await rig.repo.fetch(.all).first)
        mine.name = "Production web"
        mine.port = 2022
        mine.favorite = true
        mine.tags.append("mine")
        try await rig.repo.saveEdited(mine)

        var changed = try item("server")
        changed.tags = ["acme", "fresh"]
        changed.fields = changed.fields.map { f in
            var f = f
            if f.id == "url" { f.value = "sftp://web09.acme.example:2299" }
            return f
        }
        let summary = try await rig.importer.apply(OnePasswordImporter.map([changed]).parsed)
        #expect(summary.updated == 1)
        let c = try #require(try await rig.repo.fetch(.all).first)
        #expect(c.name == "Production web" && c.port == 2022 && c.favorite)
        #expect(c.host == "web09.acme.example")
        #expect(c.tags == ["acme", "production", "mine", "fresh"])
        #expect(c.userEditedFields == [.name, .port])
    }

    @Test func reimportOnlyTouchesItsOwnSource() async throws {
        let rig = try Rig()
        var manual = makeConn("Manual", host: "web01.acme.example", user: "deploy", port: 2222)
        manual.onePasswordItemId = "x7k2m4qv5nj6h3tdwl2ofp7e3a"
        try await rig.repo.save(manual)
        let summary = try await rig.importer.apply(try scan("server"))
        #expect(summary.updated == 0 && summary.skippedDuplicates == 1)
        #expect(try await rig.repo.connection(id: manual.id)?.name == "Manual")
    }
}

@Suite struct OnePasswordStoreTests {
    @Test func referencesAgentSocketAndItemIdRoundTrip() async throws {
        let repo = ConnectionRepository(database: try DockyardDatabase())
        var c = makeConn("A")
        c.secretReferences = [.password: "op://V/I/password", .keyPassphrase: "op://V/I/passphrase"]
        c.agentSocket = .custom("/tmp/agent.sock")
        c.onePasswordItemId = "item1"
        try await repo.save(c)
        let loaded = try #require(try await repo.connection(id: c.id))
        #expect(loaded.secretReferences == c.secretReferences && loaded.agentSocket == .custom("/tmp/agent.sock") && loaded.onePasswordItemId == "item1")
        #expect(await repo.reference(for: c.id, purpose: .keyPassphrase) == "op://V/I/passphrase")
        #expect(await repo.reference(for: c.id, purpose: .elevationPassword) == nil)
    }

    @Test func defaultsAreEmpty() async throws {
        let repo = ConnectionRepository(database: try DockyardDatabase())
        let c = makeConn("A")
        try await repo.save(c)
        let loaded = try #require(try await repo.connection(id: c.id))
        #expect(loaded.secretReferences.isEmpty && loaded.agentSocket == .system && loaded.onePasswordItemId == nil)
    }

    @Test func migrationComesAfterTheExistingOnes() throws {
        let db = try DockyardDatabase()
        let applied = try db.writer.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") }
        let journal = try #require(applied.firstIndex(of: "journal_v1"))
        let onePassword = try #require(applied.firstIndex(of: "onepassword_v1"))
        let health = try #require(applied.firstIndex(of: "connection_health_v1"))
        #expect(journal < onePassword && onePassword < health)
    }

    @Test func sourceRawValueIsStable() {
        #expect(ConnectionSource.onePasswordImport.rawValue == "onePasswordImport")
        #expect(ConnectionSource(rawValue: "onePasswordImport") == .onePasswordImport)
    }

    @Test func resolvingStoreReadsReferencesFromTheDatabase() async throws {
        let repo = ConnectionRepository(database: try DockyardDatabase())
        var c = makeConn("A")
        c.secretReferences = [.password: "op://V/I/password"]
        try await repo.save(c)
        let keychain = InMemorySecretStore()
        await keychain.setSecret("old", for: c.id, purpose: .keyPassphrase)
        let store = ResolvingSecretStore(fallback: keychain, references: repo, resolver: StubResolver(values: ["op://V/I/password": "fresh"]))
        #expect(try await store.secret(for: c.id, purpose: .password) == "fresh")
        #expect(try await store.secret(for: c.id, purpose: .keyPassphrase) == "old")
    }
}
