import Foundation
import Testing
import ConnectionKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import DockyardCore

final class FakeTransport: HTTPTransport {
    struct State {
        var requests: [URLRequest] = []
        var responses: [(Int, Data)] = []
        var error: (any Error)?
    }
    let state = LockedBox(State())

    func enqueue(_ status: Int, _ data: Data) { state.withLock { $0.responses.append((status, data)) } }
    func enqueue(_ status: Int, fixture: String) throws { enqueue(status, try Fixtures.data(fixture)) }
    var requests: [URLRequest] { state.withLock { $0.requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (resp, err): ((Int, Data)?, (any Error)?) = state.withLock { s in
            s.requests.append(request)
            return (s.responses.isEmpty ? nil : s.responses.removeFirst(), s.error)
        }
        if let err { throw err }
        guard let resp else { throw WHMError.transport("no response queued") }
        return (resp.1, HTTPURLResponse(url: request.url!, statusCode: resp.0, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

let testToken = "WHMTOKEN0123456789ABCDEF"

@Suite struct WHMClientTests {
    @Test func buildsAuthorizedRequest() throws {
        let c = WHMClient(host: "whm.example.com", token: testToken, transport: FakeTransport())
        let r = try c.listAccountsRequest()
        #expect(r.url?.absoluteString == "https://whm.example.com:2087/json-api/listaccts?api.version=1")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "whm root:\(testToken)")
        #expect(r.httpMethod == "GET")
        // The token must not leak into the URL.
        #expect(r.url?.absoluteString.contains(testToken) == false)
        let reseller = try WHMClient(host: "h", port: 2086, apiUser: "reseller1", token: "t", transport: FakeTransport()).listAccountsRequest()
        #expect(reseller.value(forHTTPHeaderField: "Authorization") == "whm reseller1:t")
        #expect(reseller.url?.port == 2086)
    }

    @Test func rejectsBadHosts() {
        #expect(throws: WHMError.invalidURL) { try WHMClient(host: "", token: "t").listAccountsRequest() }
        #expect(throws: WHMError.invalidURL) { try WHMClient(host: "a/b", token: "t").listAccountsRequest() }
    }

    @Test func parsesRealisticListaccts() async throws {
        let t = FakeTransport()
        try t.enqueue(200, fixture: "whm-listaccts.json")
        let accounts = try await WHMClient(host: "whm.example.com", token: testToken, transport: t).listAccounts()
        #expect(accounts.map(\.user) == ["acmeshop", "bluebird", "newsite"])
        let a = accounts[0]
        #expect(a.domain == "acme-shop.example" && a.plan == "Standard" && a.email == "owner@acme-shop.example")
        #expect(a.ip == "203.0.113.10" && a.diskUsed == "154M" && !a.suspended && a.suspendReason == nil)
        #expect(a.startDate == Date(timeIntervalSince1970: 1_680_603_700))
        #expect(accounts[1].suspended && accounts[1].suspendReason == "Unpaid invoice")
        #expect(accounts[2].plan == nil)  // empty strings become nil
        #expect(accounts[2].owner == "reseller1")
        #expect(t.requests.count == 1)
    }

    @Test func emptyListAndMissingAcct() throws {
        #expect(try WHMClient.parse(Fixtures.data("whm-listaccts-empty.json")).isEmpty)
        #expect(try WHMClient.parse(Data(#"{"data":{},"metadata":{"result":1}}"#.utf8)).isEmpty)
        #expect(try WHMClient.parse(Data(#"{"data":{"acct":null},"metadata":{"result":1}}"#.utf8)).isEmpty)
    }

    @Test func apiErrorSurfacesReason() async throws {
        let t = FakeTransport()
        try t.enqueue(200, fixture: "whm-listaccts-error.json")
        await #expect(throws: WHMError.api("Access denied: this API token does not have the list-accts privilege.")) {
            _ = try await WHMClient(host: "h", token: testToken, transport: t).listAccounts()
        }
    }

    @Test func httpFailures() async throws {
        let t = FakeTransport()
        t.enqueue(403, Data("<html>Forbidden</html>".utf8))
        t.enqueue(401, Data())
        t.enqueue(500, Data())
        t.enqueue(200, Data("<html>login</html>".utf8))
        let c = WHMClient(host: "h", token: testToken, transport: t)
        await #expect(throws: WHMError.unauthorized) { _ = try await c.listAccounts() }
        await #expect(throws: WHMError.unauthorized) { _ = try await c.listAccounts() }
        await #expect(throws: WHMError.http(500)) { _ = try await c.listAccounts() }
        await #expect(throws: WHMError.invalidResponse("not a JSON object")) { _ = try await c.listAccounts() }
    }

    @Test func transportErrorsNeverContainTheToken() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "connection to https://x/?t=\(testToken) failed" } }
        let t = FakeTransport()
        t.state.withLock { $0.error = Boom() }
        do {
            _ = try await WHMClient(host: "h", token: testToken, transport: t).listAccounts()
            Issue.record("expected failure")
        } catch {
            #expect(!String(describing: error).contains(testToken))
            #expect(String(describing: error).contains("****"))
        }
    }

    @Test func skipsRowsWithoutUserAndAcceptsStringSuspendedFlag() throws {
        let json = #"{"data":{"acct":[{"user":"","domain":"x"},{"user":"a","domain":"a.com","suspended":"1"},{"domain":"nouser"}]},"metadata":{"result":1}}"#
        let accts = try WHMClient.parse(Data(json.utf8))
        #expect(accts.count == 1 && accts[0].suspended)
    }
}

@Suite struct WHMSyncTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func setup() async throws -> (WHMSource, ConnectionRepository, WHMSourceRepository, InMemorySecretStore, FakeTransport, WHMSyncService, ManualClock) {
        let db = try DockyardDatabase()
        let clock = ManualClock(start: t0)
        let repo = ConnectionRepository(database: db, clock: clock)
        let sources = WHMSourceRepository(database: db)
        let secrets = InMemorySecretStore()
        let source = WHMSource(label: "Main WHM", host: "whm.example.com")
        try await sources.save(source)
        try await WHMSyncService.storeToken(testToken, for: source, in: secrets)
        let transport = FakeTransport()
        let svc = WHMSyncService(repository: repo, sources: sources, secrets: secrets, clock: clock, transportFactory: { _ in transport })
        return (source, repo, sources, secrets, transport, svc, clock)
    }

    @Test func firstSyncCreatesOneConnectionPerAccount() async throws {
        let (source, repo, sources, _, transport, svc, clock) = try await setup()
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        let report = try await svc.sync(source)
        #expect(report == WHMSyncReport(accountCount: 3, created: 3, updated: 0, unchanged: 0, removed: 0, restored: 0))
        let conns = try await repo.fetch(.source(.whm(source.id)))
        #expect(conns.count == 3)
        let shop = try #require(conns.first { $0.username == "acmeshop" })
        #expect(shop.name == "acme-shop.example")
        #expect(shop.host == "whm.example.com" && shop.port == 22 && shop.protocol == .sftp)
        #expect(shop.notes == "Plan: Standard\nContact: owner@acme-shop.example")
        #expect(shop.source == .whm(source.id) && shop.createdAt == t0 && !shop.removedFromSource)
        let blue = try #require(conns.first { $0.username == "bluebird" })
        #expect(blue.tags == ["suspended"])
        #expect(blue.notes.contains("Suspended: Unpaid invoice"))
        #expect(try await sources.source(id: source.id)?.lastSyncAt == clock.now())
        #expect(try await sources.source(id: source.id)?.lastSyncError == nil)
    }

    @Test func secondSyncIsIdempotent() async throws {
        let (source, repo, _, _, transport, svc, _) = try await setup()
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        try transport.enqueue(200, fixture: "whm-get-domain-info.json")
        try await svc.sync(source)
        let before = try await repo.fetch()
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        try transport.enqueue(200, fixture: "whm-get-domain-info.json")
        let report = try await svc.sync(source)
        #expect(report.created == 0 && report.updated == 0 && report.unchanged == 3 && report.removed == 0)
        #expect(try await repo.fetch() == before)
    }

    @Test func neverOverwritesUserEditedNameOrNotes() async throws {
        let (source, repo, _, _, transport, svc, _) = try await setup()
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        try await svc.sync(source)
        var shop = try #require(try await repo.fetch(.search("acmeshop")).first)
        shop.name = "Acme Shop (live)"
        shop.notes = "Call Dana before deploying"
        shop.favorite = true
        try await repo.saveEdited(shop)
        var other = try #require(try await repo.fetch(.search("newsite")).first)
        other.notes = "only notes edited"
        try await repo.saveEdited(other)

        // WHM now reports a different domain and plan.
        let changed = #"{"data":{"acct":[{"user":"acmeshop","domain":"acme-new.example","plan":"Premium","email":"o@acme.example"},{"user":"newsite","domain":"newsite-renamed.example","plan":"Basic"}]},"metadata":{"result":1}}"#
        transport.enqueue(200, Data(changed.utf8))
        let report = try await svc.sync(source)
        let after = try #require(try await repo.connection(id: shop.id))
        #expect(after.name == "Acme Shop (live)")
        #expect(after.notes == "Call Dana before deploying")
        #expect(after.favorite)
        let after2 = try #require(try await repo.connection(id: other.id))
        #expect(after2.name == "newsite-renamed.example")  // name was not edited, so it follows WHM
        #expect(after2.notes == "only notes edited")
        #expect(after.faviconSite == "acme-new.example")  // the icon site was not edited, so it follows the domain
        #expect(report.updated == 2 && report.unchanged == 0)
        #expect(report.removed == 1)  // bluebird is gone
    }

    @Test func updatesHostWhenWHMHostChangesUnlessUserSetIt() async throws {
        let (source, repo, sources, _, transport, svc, _) = try await setup()
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        try await svc.sync(source)
        var shop = try #require(try await repo.fetch(.search("acmeshop")).first)
        shop.host = "10.0.0.5"  // user points this one at an IP
        try await repo.saveEdited(shop)
        var moved = source
        moved.host = "whm2.example.com"
        try await sources.save(moved)
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        try await svc.sync(moved)
        #expect(try await repo.connection(id: shop.id)?.host == "10.0.0.5")
        #expect(try await repo.fetch(.search("bluebird")).first?.host == "whm2.example.com")
    }

    @Test func removedAccountsAreFlaggedNotDeletedAndRestoredWhenTheyReturn() async throws {
        let (source, repo, _, _, transport, svc, _) = try await setup()
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        try await svc.sync(source)
        let partial = #"{"data":{"acct":[{"user":"acmeshop","domain":"acme-shop.example","plan":"Standard","email":"owner@acme-shop.example"}]},"metadata":{"result":1}}"#
        transport.enqueue(200, Data(partial.utf8))
        let r1 = try await svc.sync(source)
        #expect(r1.removed == 2)
        let all = try await repo.fetch(.source(.whm(source.id)))
        #expect(all.count == 3)
        #expect(all.filter(\.removedFromSource).map(\.username).sorted() == ["bluebird", "newsite"])
        // Running again does not count them twice.
        transport.enqueue(200, Data(partial.utf8))
        #expect(try await svc.sync(source).removed == 0)
        // They come back.
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        let r3 = try await svc.sync(source)
        #expect(r3.restored == 2)
        #expect(try await repo.fetch(.source(.whm(source.id))).allSatisfy { !$0.removedFromSource })
    }

    @Test func removedAccountKeepsUserFieldsAndSecrets() async throws {
        let (source, repo, _, secrets, transport, svc, _) = try await setup()
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        try await svc.sync(source)
        let shop = try #require(try await repo.fetch(.search("acmeshop")).first)
        await secrets.setSecret("account-pass", for: shop.id, purpose: .password)
        transport.enqueue(200, Data(#"{"data":{"acct":[]},"metadata":{"result":1}}"#.utf8))
        try await svc.sync(source)
        #expect(try await repo.connection(id: shop.id)?.removedFromSource == true)
        #expect(await secrets.secret(for: shop.id, purpose: .password) == "account-pass")
    }

    @Test func suspendedTagFollowsWHM() async throws {
        let (source, repo, _, _, transport, svc, _) = try await setup()
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        try await svc.sync(source)
        let unsuspended = #"{"data":{"acct":[{"user":"bluebird","domain":"bluebird.example","plan":"Business","email":"hello@bluebird.example","suspended":0}]},"metadata":{"result":1}}"#
        transport.enqueue(200, Data(unsuspended.utf8))
        let report = try await svc.sync(source)
        #expect(report.updated == 1)
        #expect(try await repo.fetch(.search("bluebird")).first?.tags == [])
    }

    @Test func userTagsSurviveSync() async throws {
        let (source, repo, _, _, transport, svc, _) = try await setup()
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        try await svc.sync(source)
        var shop = try #require(try await repo.fetch(.search("acmeshop")).first)
        shop.tags = ["wordpress", "client-a"]
        try await repo.saveEdited(shop)
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        try await svc.sync(source)
        #expect(try await repo.connection(id: shop.id)?.tags == ["wordpress", "client-a"])
    }

    @Test func failedSyncRecordsErrorWithoutTouchingConnections() async throws {
        let (source, repo, sources, _, transport, svc, _) = try await setup()
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        try await svc.sync(source)
        transport.enqueue(403, Data())
        await #expect(throws: WHMError.unauthorized) { try await svc.sync(source) }
        #expect(try await repo.fetch(.source(.whm(source.id))).count == 3)
        let stored = try #require(try await sources.source(id: source.id))
        #expect(stored.lastSyncError?.contains("rejected the API token") == true)
        #expect(!(stored.lastSyncError ?? "").contains(testToken))
    }

    @Test func missingTokenFailsClearly() async throws {
        let db = try DockyardDatabase()
        let source = WHMSource(label: "x", host: "h")
        let sources = WHMSourceRepository(database: db)
        try await sources.save(source)
        let svc = WHMSyncService(repository: ConnectionRepository(database: db), sources: sources, secrets: InMemorySecretStore(),
                                 transportFactory: { _ in FakeTransport() })
        await #expect(throws: WHMError.self) { try await svc.sync(source) }
    }

    @Test func syncAllContinuesPastFailingServer() async throws {
        let db = try DockyardDatabase()
        let secrets = InMemorySecretStore()
        let sources = WHMSourceRepository(database: db)
        let good = WHMSource(label: "good", host: "good.example.com"), bad = WHMSource(label: "bad", host: "bad.example.com")
        try await sources.save(good); try await sources.save(bad)
        try await WHMSyncService.storeToken("tokengood", for: good, in: secrets)
        try await WHMSyncService.storeToken("tokenbad", for: bad, in: secrets)
        let tg = FakeTransport(), tb = FakeTransport()
        try tg.enqueue(200, fixture: "whm-listaccts.json")
        tb.enqueue(500, Data())
        let svc = WHMSyncService(repository: ConnectionRepository(database: db), sources: sources, secrets: secrets,
                                 transportFactory: { $0.host == "good.example.com" ? tg : tb })
        let results = await svc.syncAll()
        #expect((try? results[good.id]?.get())?.created == 3)
        if case .failure? = results[bad.id] {} else { Issue.record("bad server should fail") }
    }

    @Test func mergeIsPureAndIgnoresOtherSources() {
        let a = WHMSource(label: "a", host: "a.example.com"), b = WHMSource(label: "b", host: "b.example.com")
        let other = Connection(name: "same user other server", protocol: .sftp, host: "b.example.com", username: "acmeshop", source: .whm(b.id))
        let manual = Connection(name: "manual", host: "x", username: "acmeshop")
        let (changed, report) = WHMMerge.merge(accounts: [WHMAccount(user: "acmeshop", domain: "d.com")], source: a, existing: [other, manual], now: t0)
        #expect(report.created == 1 && report.removed == 0)
        #expect(changed.count == 1 && changed[0].source == .whm(a.id))
    }

    @Test func duplicateAccountRowsCollapse() {
        let a = WHMSource(label: "a", host: "a.example.com")
        let accts = [WHMAccount(user: "x", domain: "one.com"), WHMAccount(user: "x", domain: "two.com")]
        let (changed, report) = WHMMerge.merge(accounts: accts, source: a, existing: [], now: t0)
        #expect(changed.count == 1 && changed[0].name == "one.com" && report.accountCount == 1)
    }

    @Test func accountWithoutDomainUsesUserAsName() {
        let a = WHMSource(label: "a", host: "h")
        let (changed, _) = WHMMerge.merge(accounts: [WHMAccount(user: "svc", domain: "")], source: a, existing: [], now: t0)
        #expect(changed[0].name == "svc")
    }

    @Test func iconSiteFollowsTheDomainUntilEdited() {
        let a = WHMSource(label: "a", host: "h")
        let (created, _) = WHMMerge.merge(accounts: [WHMAccount(user: "acme", domain: "acme.com")], source: a, existing: [], now: t0)
        #expect(created[0].faviconSite == "acme.com")

        var older = created[0]
        older.faviconSite = nil
        let (filled, _) = WHMMerge.merge(accounts: [WHMAccount(user: "acme", domain: "acme.com")], source: a, existing: [older], now: t0)
        #expect(filled.first?.faviconSite == "acme.com")

        var edited = created[0]
        edited.faviconSite = "brand.example"
        edited.userEditedFields.insert(.faviconSite)
        let (kept, _) = WHMMerge.merge(accounts: [WHMAccount(user: "acme", domain: "acme-new.com")], source: a, existing: [edited], now: t0)
        #expect(kept.isEmpty || kept[0].faviconSite == "brand.example")
    }

    @Test func editingTheIconSiteMarksItEdited() async throws {
        let db = try DockyardDatabase()
        let repo = ConnectionRepository(database: db)
        let a = WHMSource(label: "a", host: "h")
        var c = WHMMerge.merge(accounts: [WHMAccount(user: "acme", domain: "acme.com")], source: a, existing: [], now: t0).changed[0]
        try await repo.save(c)
        c.faviconSite = "brand.example"
        let saved = try await repo.saveEdited(c)
        #expect(saved.userEditedFields.contains(.faviconSite))
    }

    @Test func parsesDomainInfo() throws {
        let domains = try WHMClient.parseDomains(try Fixtures.data("whm-get-domain-info.json"))
        #expect(domains.count == 5)
        #expect(domains[0] == WHMDomain(user: "acmeshop", domain: "acme-shop.example", kind: .main, docroot: "/home/acmeshop/public_html"))
    }

    @Test func webURLsMainThenAddonThenSubSkippingParked() throws {
        let domains = try WHMClient.parseDomains(try Fixtures.data("whm-get-domain-info.json"))
        #expect(WHMMerge.webURLs(for: "acmeshop", in: domains) == [
            WebURLMapping(path: "/home/acmeshop/public_html", baseURL: "https://acme-shop.example"),
            WebURLMapping(path: "/home/acmeshop/acme-outlet.example", baseURL: "https://acme-outlet.example"),
            WebURLMapping(path: "/home/acmeshop/public_html/blog", baseURL: "https://blog.acme-shop.example"),
        ])
        #expect(WHMMerge.webURLs(for: "newsite", in: domains) == [
            WebURLMapping(path: "/home/newsite/public_html", baseURL: "https://newsite.example"),
        ])
    }

    @Test func webURLsFollowDomainsUntilEdited() {
        let a = WHMSource(label: "a", host: "h")
        let domains = [WHMDomain(user: "acme", domain: "acme.com", kind: .main, docroot: "/home/acme/public_html")]
        let acct = [WHMAccount(user: "acme", domain: "acme.com")]
        let created = WHMMerge.merge(accounts: acct, domains: domains, source: a, existing: [], now: t0).changed[0]
        #expect(created.webURLs == [WebURLMapping(path: "/home/acme/public_html", baseURL: "https://acme.com")])

        // Domains unavailable (e.g. the token lacks the privilege): keep what is there.
        let (unchanged, _) = WHMMerge.merge(accounts: acct, domains: nil, source: a, existing: [created], now: t0)
        #expect(unchanged.isEmpty)

        var edited = created
        edited.webURLs = [WebURLMapping(path: "/home/acme/www", baseURL: "https://staging.acme.com")]
        edited.userEditedFields.insert(.webURLs)
        let (kept, _) = WHMMerge.merge(accounts: acct, domains: domains, source: a, existing: [edited], now: t0)
        #expect(kept.isEmpty)
    }

    @Test func syncFillsWebURLsFromDomainInfo() async throws {
        let (source, repo, _, _, transport, svc, _) = try await setup()
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        try transport.enqueue(200, fixture: "whm-get-domain-info.json")
        try await svc.sync(source)
        let shop = try #require(try await repo.fetch(.search("acmeshop")).first)
        #expect(shop.webURLs.first == WebURLMapping(path: "/home/acmeshop/public_html", baseURL: "https://acme-shop.example"))
        #expect(transport.requests.last?.url?.path == "/json-api/get_domain_info")
    }

    @Test func newAccountsUseTheServersLogin() {
        let a = WHMSource(label: "a", host: "h", accountLogin: .key(path: "~/.ssh/id_ed25519"))
        let (changed, _) = WHMMerge.merge(accounts: [WHMAccount(user: "svc", domain: "")], source: a, existing: [], now: t0)
        #expect(changed[0].authMethods == .key && changed[0].keyPath == "~/.ssh/id_ed25519")
    }

    @Test func syncNeverChangesAnExistingAccountsLogin() {
        let a = WHMSource(label: "a", host: "h", accountLogin: .agent(.onePassword))
        let existing = Connection(name: "svc", protocol: .sftp, host: "h", port: 22, username: "svc", source: .whm(a.id))
        let (changed, report) = WHMMerge.merge(accounts: [WHMAccount(user: "svc", domain: "")], source: a, existing: [existing], now: t0)
        #expect(changed.isEmpty && report.unchanged == 1)
    }

    @Test func changingTheLoginMovesOnlyAccountsStillOnTheOldOne() async throws {
        let (source, repo, sources, _, transport, svc, _) = try await setup()
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        try await svc.sync(source)
        var hand = try #require(try await repo.fetch(.source(.whm(source.id))).first { $0.username == "bluebird" })
        hand.authMethods = .agent
        try await repo.saveEdited(hand)

        var updated = source
        updated.accountLogin = .key(path: "/keys/whm")
        #expect(try await svc.save(updated) == 2)
        #expect(try await sources.source(id: source.id)?.accountLogin == .key(path: "/keys/whm"))
        let conns = try await repo.fetch(.source(.whm(source.id)))
        for c in conns where c.username != "bluebird" { #expect(c.authMethods == .key && c.keyPath == "/keys/whm") }
        #expect(conns.first { $0.username == "bluebird" }?.authMethods == .agent)

        updated.accountLogin = .password
        #expect(try await svc.save(updated) == 2)
        for c in try await repo.fetch(.source(.whm(source.id))) where c.username != "bluebird" {
            #expect(c.authMethods == .password && c.keyPath == nil)
        }
    }

    @Test func throughRootLogsInAsRootAndWorksAsTheAccount() async throws {
        let (source, repo, _, _, transport, svc, _) = try await setup()
        var updated = source
        updated.accountLogin = .throughRoot(.key(path: "/keys/root"))
        try await svc.save(updated)
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        try await svc.sync(updated)
        let shop = try #require(try await repo.fetch(.source(.whm(source.id))).first { $0.username == "acmeshop" })
        #expect(shop.loginUser == "root" && shop.authMethods == .key && shop.keyPath == "/keys/root")
        #expect(shop.config.username == "root" && shop.config.runAs == "acmeshop")

        updated.accountLogin = .password
        try await svc.save(updated)
        let back = try #require(try await repo.connection(id: shop.id))
        #expect(back.loginUser == nil && back.config.username == "acmeshop" && back.config.runAs == nil)
    }

    @Test func accountLoginRoundTrips() {
        for login: WHMAccountLogin in [
            .password, .key(path: "/a b/k"), .agent(.system), .agent(.custom("/tmp/s.sock")),
            .throughRoot(.key(path: "~/.ssh/id_ed25519")), .throughRoot(.agent(.onePassword)),
        ] {
            #expect(WHMAccountLogin(rawValue: login.rawValue) == login)
        }
        #expect(WHMAccountLogin(rawValue: "key:") == nil && WHMAccountLogin(rawValue: "bogus") == nil)
        #expect(WHMAccountLogin(rawValue: "root:password") == nil && WHMAccountLogin(rawValue: "root:root:key:/k") == nil)
    }

    @Test func accountsShareTheServersKeyPassphrase() async throws {
        let (source, repo, sources, secrets, transport, svc, _) = try await setup()
        var updated = source
        updated.accountLogin = .key(path: "/keys/whm")
        try await svc.save(updated)
        try transport.enqueue(200, fixture: "whm-listaccts.json")
        try await svc.sync(updated)
        try await secrets.setSecret("shared", for: source.id, purpose: .keyPassphrase)
        let store = WHMPassphraseStore(base: secrets, connections: repo, sources: sources)
        let conns = try await repo.fetch(.source(.whm(source.id)))
        let shop = try #require(conns.first { $0.username == "acmeshop" })
        #expect(try await store.secret(for: shop.id, purpose: .keyPassphrase) == "shared")
        #expect(try await store.secret(for: shop.id, purpose: .password) == nil)

        try await secrets.setSecret("own", for: shop.id, purpose: .keyPassphrase)
        #expect(try await store.secret(for: shop.id, purpose: .keyPassphrase) == "own")

        var other = try #require(conns.first { $0.username == "bluebird" })
        other.keyPath = "/keys/mine"
        try await repo.saveEdited(other)
        #expect(try await store.secret(for: other.id, purpose: .keyPassphrase) == nil)
    }
}

@Suite struct WHMSchedulerTests {
    @Test func runsOnTheInterval() async throws {
        let clock = ManualClock()
        let counter = LockedBox(0)
        let scheduler = WHMSyncScheduler(clock: clock, interval: 3600) { counter.withLock { $0 += 1 } }
        await scheduler.start()
        await clock.waitForSleepers(1)
        #expect(counter.withLock { $0 } == 0)
        clock.advance(by: 3599)
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(counter.withLock { $0 } == 0)
        clock.advance(by: 2)
        #expect(await waitUntil { counter.withLock { $0 } == 1 })
        await clock.waitForSleepers(1)
        clock.advance(by: 3600)
        #expect(await waitUntil { counter.withLock { $0 } == 2 })
        await scheduler.stop()
        #expect(await scheduler.isStarted == false)
        await waitUntil { clock.sleeperCount == 0 }
        clock.advance(by: 10_000)
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(counter.withLock { $0 } == 2)
    }

    @Test func runImmediatelyAndSyncNow() async throws {
        let clock = ManualClock()
        let counter = LockedBox(0)
        let scheduler = WHMSyncScheduler(clock: clock, interval: 3600) { counter.withLock { $0 += 1 } }
        await scheduler.start(runImmediately: true)
        #expect(await waitUntil { counter.withLock { $0 } == 1 })
        await scheduler.syncNow()
        #expect(counter.withLock { $0 } == 2)
        await scheduler.stop()
    }

    @Test func overlappingRunsAreSkipped() async throws {
        let clock = ManualClock()
        let started = LockedBox(0)
        let gate = Gate()
        let scheduler = WHMSyncScheduler(clock: clock, interval: 3600) {
            started.withLock { $0 += 1 }
            await gate.wait()
        }
        let first = Task { await scheduler.syncNow() }
        #expect(await waitUntil { started.withLock { $0 } == 1 })
        await scheduler.syncNow()  // returns immediately: a sync is running
        #expect(started.withLock { $0 } == 1)
        await gate.open()
        await first.value
        #expect(await scheduler.runCount == 1)
    }

    @Test func intervalHasAFloorAndStartIsIdempotent() async {
        let clock = ManualClock()
        let scheduler = WHMSyncScheduler(clock: clock, interval: 1) {}
        await scheduler.start()
        await scheduler.start()
        await clock.waitForSleepers(1)
        #expect(clock.sleeperCount == 1)
        await scheduler.stop()
    }
}
