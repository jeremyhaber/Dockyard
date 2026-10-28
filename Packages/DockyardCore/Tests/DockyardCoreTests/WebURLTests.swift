import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct WebURLTests {
    private let mappings = [
        WebURLMapping(path: "/home/acme/public_html/", baseURL: "https://acme.example/"),
        WebURLMapping(path: "/home/acme/public_html/shop", baseURL: "shop.acme.example"),
    ]

    @Test func deepestMappingWins() {
        #expect(WebURLResolver.url(for: "/home/acme/public_html/shop/cart/index.php", in: mappings)?.absoluteString
            == "https://shop.acme.example/cart/index.php")
        #expect(WebURLResolver.url(for: "/home/acme/public_html/about.html", in: mappings)?.absoluteString
            == "https://acme.example/about.html")
        #expect(WebURLResolver.url(for: "/home/acme/public_html", in: mappings)?.absoluteString == "https://acme.example")
    }

    @Test func pathsOutsideAnyMappingHaveNoURL() {
        #expect(WebURLResolver.url(for: "/home/acme/logs/error.log", in: mappings) == nil)
        // A sibling whose name starts with the mapped folder's name is not inside it.
        #expect(WebURLResolver.url(for: "/home/acme/public_html_old/a.html", in: mappings) == nil)
    }

    @Test func rootMappingAndEncoding() {
        let root = [WebURLMapping(path: "/", baseURL: "http://files.example/static")]
        #expect(WebURLResolver.url(for: "/My Docs/a#1?.pdf", in: root)?.absoluteString
            == "http://files.example/static/My%20Docs/a%231%3F.pdf")
    }

    @Test func baseValidation() {
        #expect(WebURLResolver.normalizeBase("example.com/") == "https://example.com")
        #expect(WebURLResolver.normalizeBase("  http://example.com/sub/ ") == "http://example.com/sub")
        #expect(WebURLResolver.normalizeBase("") == nil)
        #expect(WebURLResolver.normalizeBase("ftp://example.com") == nil)
    }

    @Test func mappingsAndIconAreStoredOnTheConnection() async throws {
        let db = try DockyardDatabase()
        let repo = ConnectionRepository(database: db)
        var c = Connection(name: "Acme", protocol: .sftp, host: "acme.example", username: "u")
        c.webURLs = mappings
        c.icon = .symbol(name: "cart", color: "#0B63CE")
        c.color = .teal
        c.faviconSite = "brand.example"
        try await repo.save(c)
        var loaded = try #require(try await repo.connection(id: c.id))
        #expect(loaded.webURLs == mappings && loaded.icon == c.icon && loaded.color == .teal && loaded.faviconSite == "brand.example")

        try await repo.update(c.id) { $0.icon = .image(Data([1, 2, 3])); $0.webURLs = [] }
        loaded = try #require(try await repo.connection(id: c.id))
        #expect(loaded.webURLs.isEmpty && loaded.icon == .image(Data([1, 2, 3])))
    }

    @Test func exportCarriesMappingsAndIcon() throws {
        var c = Connection(name: "Acme", protocol: .sftp, host: "acme.example", username: "u")
        c.webURLs = mappings
        c.icon = .symbol(name: "globe", color: nil)
        c.color = .purple
        let dto = ExportPayload.ConnectionDTO(c)
        let decoded = try JSONDecoder().decode(ExportPayload.ConnectionDTO.self, from: JSONEncoder().encode(dto))
        #expect(decoded.connection.webURLs == mappings && decoded.connection.icon == c.icon && decoded.connection.color == .purple)
    }
}

@Suite struct FaviconCandidateTests {
    @Test func hostThenParentDomainsThenWebURLs() {
        var c = Connection(name: "Test", protocol: .sftp, host: "test.something.com", username: "u")
        c.webURLs = [WebURLMapping(path: "/www", baseURL: "http://shop.example:8080/store"), WebURLMapping(path: "/x", baseURL: "something.com")]
        #expect(FaviconCandidates.origins(for: c) == [
            "https://test.something.com", "https://something.com", "http://shop.example:8080",
        ])
    }

    @Test func chosenIconSiteComesFirst() {
        var c = Connection(name: "Test", protocol: .sftp, host: "test.something.com", username: "u")
        c.faviconSite = "brand.example/about"
        #expect(FaviconCandidates.origins(for: c).first == "https://brand.example")
        c.faviconSite = "not a url"
        #expect(FaviconCandidates.origins(for: c).first == "https://test.something.com")
    }

    @Test func registrableDomainStopsAtPublicSecondLevel() {
        #expect(FaviconCandidates.hostOrigins("ftp.acme.co.uk") == ["https://ftp.acme.co.uk", "https://acme.co.uk"])
        #expect(FaviconCandidates.hostOrigins("acme.com") == ["https://acme.com"])
    }

    @Test func addressesAndBareHostsAreSkipped() {
        #expect(FaviconCandidates.hostOrigins("192.168.1.10").isEmpty)
        #expect(FaviconCandidates.hostOrigins("localhost").isEmpty)
        #expect(FaviconCandidates.hostOrigins("::1").isEmpty)
        let cloud = Connection(name: "S3", protocol: .rclone, host: "s3.amazonaws.com", username: "")
        #expect(FaviconCandidates.origins(for: cloud).isEmpty)
    }

    @Test func whmAccountsSkipTheSharedServer() {
        var c = Connection(name: "acme.com", protocol: .sftp, host: "host.hosting.example", username: "acme", source: .whm(UUID()))
        c.faviconSite = "acme.com"
        #expect(FaviconCandidates.origins(for: c) == ["https://acme.com"])
        c.userEditedFields.insert(.host)
        c.host = "acme.com"
        #expect(FaviconCandidates.origins(for: c) == ["https://acme.com"])
    }
}
