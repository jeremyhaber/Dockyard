import Foundation
import Testing
@testable import DockyardCore

@Suite struct WHMLoginTests {
    @Test func buildsRequestForCpanel() throws {
        let c = WHMClient(host: "whm.example.com", token: testToken, transport: FakeTransport())
        let r = try c.createUserSessionRequest(user: "acme shop&x", service: .cpanel)
        let comps = try #require(URLComponents(url: r.url!, resolvingAgainstBaseURL: false))
        #expect(comps.path == "/json-api/create_user_session" && comps.port == 2087)
        #expect(comps.queryItems?.first { $0.name == "service" }?.value == "cpaneld")
        #expect(comps.queryItems?.first { $0.name == "user" }?.value == "acme shop&x")
        #expect(comps.queryItems?.first { $0.name == "api.version" }?.value == "1")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "whm root:\(testToken)")
        #expect(r.url?.absoluteString.contains(testToken) == false)
        let app = try c.createUserSessionRequest(user: "u", service: .cpanel, app: "Mail")
        #expect(app.url?.absoluteString.contains("app=Mail") == true)
    }

    @Test func cpanelLoginParsesTheUrl() async throws {
        let t = FakeTransport()
        try t.enqueue(200, fixture: "whm-create-session-cpanel.json")
        let session = try await WHMClient(host: "whm.example.com", token: testToken, transport: t).cpanelLogin(for: "acmeshop")
        #expect(session.service == .cpanel)
        #expect(session.url.host == "whm.example.com" && session.url.port == 2083)
        #expect(session.url.path.hasPrefix("/cpsess7041934281/login"))
        #expect(session.url.query?.hasPrefix("session=acmeshop") == true)
        #expect(session.securityToken == "/cpsess7041934281")
        #expect(session.expires == Date(timeIntervalSince1970: 1_761_576_060))
        #expect(t.requests.count == 1 && t.requests[0].url?.query?.contains("user=acmeshop") == true)
    }

    @Test func whmLoginUsesTheApiUserAndWhostmgrd() async throws {
        let t = FakeTransport()
        try t.enqueue(200, fixture: "whm-create-session-whm.json")
        let client = WHMClient(host: "whm.example.com", apiUser: "reseller1", token: testToken, transport: t)
        let session = try await client.whmLogin()
        #expect(session.service == .whm && session.url.port == 2087)
        let query = t.requests[0].url?.query ?? ""
        #expect(query.contains("user=reseller1") && query.contains("service=whostmgrd"))
    }

    @Test func apiErrorAndHttpErrors() async throws {
        let t = FakeTransport()
        try t.enqueue(200, fixture: "whm-create-session-error.json")
        await #expect(throws: WHMError.api("The system could not find the user “nosuchuser”.")) {
            _ = try await WHMClient(host: "h", token: testToken, transport: t).cpanelLogin(for: "nosuchuser")
        }
        t.enqueue(403, Data())
        await #expect(throws: WHMError.unauthorized) { _ = try await WHMClient(host: "h", token: testToken, transport: t).whmLogin() }
        t.enqueue(500, Data())
        await #expect(throws: WHMError.http(500)) { _ = try await WHMClient(host: "h", token: testToken, transport: t).whmLogin() }
    }

    @Test func rejectsMalformedResponses() {
        #expect(throws: WHMError.self) { try WHMClient.parseUserSession(Data("[]".utf8), service: .cpanel) }
        #expect(throws: WHMError.self) { try WHMClient.parseUserSession(Data(#"{"data":{},"metadata":{"result":1}}"#.utf8), service: .cpanel) }
        #expect(throws: WHMError.self) {
            try WHMClient.parseUserSession(Data(#"{"data":{"url":"http://plain.example/login"},"metadata":{"result":1}}"#.utf8), service: .cpanel)
        }
    }

    @Test func emptyUserIsRejected() {
        #expect(throws: WHMError.invalidURL) { try WHMClient(host: "h", token: "t").createUserSessionRequest(user: "", service: .cpanel) }
    }
}
