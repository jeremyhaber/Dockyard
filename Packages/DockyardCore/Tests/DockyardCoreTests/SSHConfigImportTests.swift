import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

private func parse(_ config: String) -> SSHConfigResult {
    struct Files: SSHConfigFiles {
        var text: String
        func contents(of path: String) -> String? { text }
        func expand(_ pattern: String) -> [String] { [] }
    }
    return SSHConfigParser(home: "/Users/j", files: Files(text: config)).parse(path: "/Users/j/.ssh/config")
}

@Suite struct SSHConfigImportTests {
    func setup() throws -> (SSHConfigImporter, ConnectionRepository) {
        let repo = ConnectionRepository(database: try DockyardDatabase())
        return (SSHConfigImporter(repository: repo, defaultUser: "jeremy"), repo)
    }

    let config = """
    Host bastion
        HostName bastion.example.com
        User ops
        IdentityFile ~/.ssh/bastion
    Host app1
        HostName 10.0.1.5
        ProxyJump bastion
    Host db
        HostName 10.0.2.9
        User dba
        ProxyJump bastion,dba@inner.example.com:2022
    Host plain
        HostName plain.example.com
        Port 2200
    Host *
        ServerAliveInterval 30
    """

    @Test func createsConnectionsWithDefaultsAndKeys() async throws {
        let (importer, repo) = try setup()
        let summary = try await importer.apply(parse(config))
        #expect(summary.created == 5 && summary.updated == 0)  // four aliases plus the inner.example.com hop
        let bastion = try #require(try await repo.fetch(.search("bastion")).first)
        #expect(bastion.host == "bastion.example.com" && bastion.username == "ops" && bastion.keyPath == "/Users/j/.ssh/bastion")
        #expect(bastion.authMethods == [.key, .agent] && bastion.source == .sshConfigImport)
        let plain = try #require(try await repo.fetch(.search("plain")).first)
        #expect(plain.username == "jeremy" && plain.port == 2200 && plain.authMethods == [.agent, .password])
    }

    @Test func proxyJumpBecomesAChain() async throws {
        let (importer, repo) = try setup()
        _ = try await importer.apply(parse(config))
        let all = try await repo.fetch(.all)
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        let bastion = try #require(byName["bastion"]), app1 = try #require(byName["app1"]), db = try #require(byName["db"])
        let inner = try #require(byName["inner.example.com"])
        #expect(app1.jumpHost == bastion.id)
        #expect(inner.port == 2022 && inner.username == "dba" && inner.jumpHost == bastion.id)
        #expect(db.jumpHost == inner.id)
        let chain = try JumpChain.resolve(for: db, lookup: { id in all.first { $0.id == id } })
        #expect(chain.map(\.name) == ["bastion", "inner.example.com"])
        #expect(byName["plain"]?.jumpHost == nil)
    }

    @Test func reimportUpdatesWhatItCreatedAndRespectsEdits() async throws {
        let (importer, repo) = try setup()
        _ = try await importer.apply(parse("Host web\n  HostName old.example.com\n  User a\n"))
        var web = try #require(try await repo.fetch(.search("web")).first)
        web.notes = "my notes"
        try await repo.saveEdited(web)

        let summary = try await importer.apply(parse("Host web\n  HostName new.example.com\n  User b\n  Port 2022\n"))
        #expect(summary.created == 0 && summary.updated == 1)
        let updated = try #require(try await repo.fetch(.search("web")).first)
        #expect(updated.id == web.id && updated.host == "new.example.com" && updated.username == "b" && updated.port == 2022)
        #expect(updated.notes == "my notes")

        var edited = updated
        edited.host = "user-chose.example.com"
        try await repo.saveEdited(edited)
        _ = try await importer.apply(parse("Host web\n  HostName new.example.com\n"))
        #expect(try await repo.connection(id: web.id)?.host == "user-chose.example.com")
        #expect(try await repo.count() == 1)
    }

    @Test func existingManualConnectionIsNotDuplicated() async throws {
        let (importer, repo) = try setup()
        try await repo.save(Connection(name: "Mine", protocol: .sftp, host: "x.example.com", port: 22, username: "jeremy"))
        let summary = try await importer.apply(parse("Host x\n  HostName x.example.com\n"))
        let count = try await repo.count()
        #expect(summary.skippedExisting == 1 && summary.created == 0 && count == 1)
    }

    @Test func warningsFlowThrough() async throws {
        let (importer, _) = try setup()
        let summary = try await importer.apply(parse("Host a\n  ProxyCommand nc %h %p\nMatch host b\n  User x\n"))
        #expect(summary.warnings.count == 2)
        #expect(summary.warnings.contains { $0.contains("ProxyCommand") } && summary.warnings.contains { $0.contains("Match") })
    }
}

@Suite struct JumpChainTests {
    func conn(_ name: String, jump: Connection? = nil, proto: ConnectionProtocol = .sftp) -> Connection {
        var c = makeConn(name, proto: proto)
        c.jumpHost = jump?.id
        return c
    }

    @Test func resolvesOutermostFirstAndBuildsHops() throws {
        let a = conn("a"), b = conn("b", jump: a), target = conn("t", jump: b)
        let all = [a, b, target]
        let lookup: (UUID) -> Connection? = { id in all.first { $0.id == id } }
        #expect(try JumpChain.resolve(for: target, lookup: lookup).map(\.name) == ["a", "b"])
        #expect(try JumpChain.resolve(for: a, lookup: lookup).isEmpty)
        let hops = try JumpChain.hops(for: target, lookup: lookup, secrets: InMemorySecretStore())
        #expect(hops.map(\.config.id) == [a.id, b.id])
    }

    @Test func detectsLoopsMissingAndNonSSH() throws {
        var a = conn("a"), b = conn("b", jump: a)
        a.jumpHost = b.id
        let lookup: (UUID) -> Connection? = { id in [a, b].first { $0.id == id } }
        #expect(throws: JumpChainError.self) { try JumpChain.resolve(for: b, lookup: lookup) }

        let orphan = conn("o", jump: conn("gone"))
        #expect(throws: JumpChainError.self) { try JumpChain.resolve(for: orphan, lookup: { _ in nil }) }

        let ftp = conn("ftp", proto: .ftp)
        let viaFtp = conn("t", jump: ftp)
        #expect(throws: JumpChainError.notSSH("ftp")) { try JumpChain.resolve(for: viaFtp, lookup: { _ in ftp }) }

        let selfLoop = { () -> Connection in var c = conn("s"); c.jumpHost = c.id; return c }()
        #expect(throws: JumpChainError.self) { try JumpChain.resolve(for: selfLoop, lookup: { _ in selfLoop }) }
    }
}
