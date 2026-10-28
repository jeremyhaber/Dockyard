import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct QuickConnectTests {
    func make() throws -> (QuickConnectService, ConnectionRepository, InMemorySecretStore, ManualClock) {
        let clock = ManualClock()
        let repo = ConnectionRepository(database: try DockyardDatabase(), clock: clock)
        let secrets = InMemorySecretStore()
        return (QuickConnectService(repository: repo, secrets: secrets, clock: clock), repo, secrets, clock)
    }

    @Test func resolvesPlainFields() throws {
        let r = try QuickConnectService.resolve(QuickConnectInput(protocolChoice: .ftp, host: " example.com ", username: "bob", password: "pw"))
        #expect(r == ResolvedQuickConnect(protocol: .ftp, host: "example.com", port: 21, username: "bob", password: "pw", keyPath: nil, path: nil))
    }

    @Test func resolvesPastedURLOverridingFields() throws {
        let r = try QuickConnectService.resolve(QuickConnectInput(protocolChoice: .ftp, host: "sftp://alice:s%40cret@box.io:2200/var/www", username: "ignored", password: "old"))
        #expect(r.protocol == .sftp)
        #expect(r.host == "box.io")
        #expect(r.port == 2200)
        #expect(r.username == "alice")
        #expect(r.password == "s@cret")
        #expect(r.path == "/var/www")
    }

    @Test func urlWithoutPortUsesFieldPortOrDefault() throws {
        #expect(try QuickConnectService.resolve(QuickConnectInput(host: "ftps://u@h.com")).port == 21)
        #expect(try QuickConnectService.resolve(QuickConnectInput(host: "sftp://u@h.com", port: 2022)).port == 2022)
        #expect(try QuickConnectService.resolve(QuickConnectInput(host: "sftp://u@h.com")).port == 22)
    }

    @Test func hostColonPortAndUserAtHost() throws {
        let r = try QuickConnectService.resolve(QuickConnectInput(host: "me@h.com:2222"))
        #expect(r.host == "h.com"); #expect(r.port == 2222); #expect(r.username == "me")
        #expect(throws: QuickConnectError.invalidPort("99999")) { try QuickConnectService.resolve(QuickConnectInput(host: "h.com:99999")) }
        #expect(throws: QuickConnectError.invalidPort("70000")) { try QuickConnectService.resolve(QuickConnectInput(host: "h.com", port: 70000)) }
    }

    @Test func rejectsEmptyAndBadURLs() {
        #expect(throws: QuickConnectError.missingHost) { try QuickConnectService.resolve(QuickConnectInput(host: "  ")) }
        #expect(throws: QuickConnectError.badURL(.unsupportedScheme("http"))) { try QuickConnectService.resolve(QuickConnectInput(host: "http://x.com")) }
    }

    @Test func ftpWithoutUserIsAnonymous() throws {
        #expect(try QuickConnectService.resolve(QuickConnectInput(protocolChoice: .ftp, host: "h")).username == "anonymous")
    }

    @Test func createsSavedConnectionWithNewFlagAndStoresPassword() async throws {
        let (svc, repo, secrets, clock) = try make()
        let r = try await svc.connect(QuickConnectInput(host: "box.example.com", username: "bob", password: "hunter2"))
        #expect(r.created)
        #expect(r.connection.source == .quickConnect)
        #expect(r.connection.isNew)
        #expect(r.connection.name == "box.example.com")
        #expect(r.connection.lastConnectedAt == clock.now())
        #expect(try await repo.fetch(.source(.quickConnect)).count == 1)
        #expect(await secrets.secret(for: r.connection.id, purpose: .password) == "hunter2")
    }

    @Test func dedupesByProtocolHostPortUser() async throws {
        let (svc, repo, secrets, clock) = try make()
        let a = try await svc.connect(QuickConnectInput(host: "Box.Example.com", username: "bob", password: "one"))
        clock.advance(by: 60)
        let b = try await svc.connect(QuickConnectInput(host: "box.example.com", username: "bob", password: "two"))
        #expect(a.connection.id == b.connection.id)
        #expect(!b.created)
        #expect(b.connection.isNew == false)
        #expect(try await repo.count() == 1)
        #expect(await secrets.secret(for: a.connection.id, purpose: .password) == "two")
        // A different port, user or protocol is a different connection.
        _ = try await svc.connect(QuickConnectInput(host: "box.example.com", port: 2222, username: "bob"))
        _ = try await svc.connect(QuickConnectInput(host: "box.example.com", username: "alice"))
        _ = try await svc.connect(QuickConnectInput(protocolChoice: .ftp, host: "box.example.com", username: "bob"))
        #expect(try await repo.count() == 4)
    }

    @Test func reusesAManualConnectionWithSameEndpoint() async throws {
        let (svc, repo, _, _) = try make()
        let manual = Connection(name: "Mine", host: "h.com", username: "u")
        try await repo.save(manual)
        let r = try await svc.connect(QuickConnectInput(host: "h.com", username: "u"))
        #expect(r.connection.id == manual.id)
        #expect(r.connection.source == .manual)
    }

    @Test func historyIsMostRecentFirstAndRestoresInput() async throws {
        let (svc, _, _, clock) = try make()
        _ = try await svc.connect(QuickConnectInput(host: "a.com", username: "u"))
        clock.advance(by: 10)
        _ = try await svc.connect(QuickConnectInput(host: "b.com", port: 2222, username: "u"))
        clock.advance(by: 10)
        _ = try await svc.connect(QuickConnectInput(host: "a.com", username: "u"))
        let h = try await svc.history()
        #expect(h.map(\.host) == ["a.com", "b.com"])
        #expect(h[1].display == "sftp://u@b.com:2222")
        #expect(h[0].display == "sftp://u@a.com")
        #expect(h[1].input.port == 2222)
        #expect(try await svc.history(limit: 1).count == 1)
    }

    @Test func keyAuthSetsMethods() async throws {
        let (svc, _, _, _) = try make()
        let r = try await svc.connect(QuickConnectInput(host: "k.com", username: "u", keyPath: "/keys/id"))
        #expect(r.connection.authMethods == .key)
        #expect(r.connection.keyPath == "/keys/id")
    }

    @Test func initialPathFromURL() async throws {
        let (svc, _, _, _) = try make()
        let r = try await svc.connect(QuickConnectInput(host: "sftp://u@h.com/srv/www"))
        #expect(r.initialPath == "/srv/www")
    }
}
