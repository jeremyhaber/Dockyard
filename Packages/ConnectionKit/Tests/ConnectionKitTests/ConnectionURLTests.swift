import Foundation
import Testing
@testable import ConnectionKit

@Suite struct ConnectionURLTests {
    @Test func sftpWithUserPortAndPath() throws {
        let parsed = try ConnectionConfig.parse(url: "sftp://deploy@example.com:2222/var/www")
        #expect(parsed.config.protocol == .sftp)
        #expect(parsed.config.host == "example.com")
        #expect(parsed.config.port == 2222)
        #expect(parsed.config.username == "deploy")
        #expect(parsed.path == "/var/www")
        #expect(parsed.password == nil)
    }

    @Test func defaultPortsPerProtocol() throws {
        #expect(try ConnectionConfig.parse(url: "sftp://u@h").config.port == 22)
        #expect(try ConnectionConfig.parse(url: "ftp://u@h").config.port == 21)
        #expect(try ConnectionConfig.parse(url: "ftps://u@h").config.protocol == .ftps)
        #expect(try ConnectionConfig.parse(url: "ssh://u@h").config.protocol == .sftp)
    }

    @Test func passwordIsReturnedSeparatelyAndDecoded() throws {
        let parsed = try ConnectionConfig.parse(url: "ftp://bob:p%40ss%3Aword@ftp.example.com/")
        #expect(parsed.config.username == "bob")
        #expect(parsed.password == "p@ss:word")
        #expect(parsed.path == nil)
    }

    @Test func hostOnlyHasEmptyUser() throws {
        let parsed = try ConnectionConfig.parse(url: "  sftp://example.com  ")
        #expect(parsed.config.username == "")
        #expect(parsed.config.host == "example.com")
    }

    @Test func ipv6Host() throws {
        let parsed = try ConnectionConfig.parse(url: "sftp://me@[2001:db8::1]:2200/home/me")
        #expect(parsed.config.host == "2001:db8::1")
        #expect(parsed.config.port == 2200)
        #expect(parsed.path == "/home/me")
    }

    @Test func percentEncodedPath() throws {
        let parsed = try ConnectionConfig.parse(url: "sftp://u@h/my%20folder/a")
        #expect(parsed.path == "/my folder/a")
    }

    @Test func errors() {
        #expect(throws: ConnectionURLError.missingScheme) { try ConnectionConfig.parse(url: "example.com") }
        #expect(throws: ConnectionURLError.unsupportedScheme("http")) { try ConnectionConfig.parse(url: "http://example.com") }
        #expect(throws: ConnectionURLError.missingHost) { try ConnectionConfig.parse(url: "sftp://user@/path") }
        #expect(throws: ConnectionURLError.invalidPort("99999")) { try ConnectionConfig.parse(url: "sftp://h:99999") }
        #expect(throws: ConnectionURLError.invalidPort("abc")) { try ConnectionConfig.parse(url: "sftp://h:abc") }
    }

    @Test func configRoundTripsThroughCodable() throws {
        let config = ConnectionConfig(protocol: .sftp, host: "h", username: "u", authMethods: .both, keyPath: "~/.ssh/id_ed25519", elevation: .sudo)
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
        #expect(decoded.authMethods == [.key, .password])
    }
}
