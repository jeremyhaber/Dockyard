import Foundation
import Testing
@testable import ConnectionKit

@Suite struct RunAsTests {
    @Test func acceptsAccountNames() {
        for name in ["acmeshop", "user_1", "a.b", "x-y", "Z9"] { #expect(SSHSession.isValidAccountName(name)) }
    }

    @Test func rejectsAnythingAShellCouldMisread() {
        for name in ["", "-root", "a b", "a;b", "a'b", "$(id)", "a/b", "\u{e9}", String(repeating: "a", count: 65)] {
            #expect(!SSHSession.isValidAccountName(name))
        }
    }

    @Test func commandRunsAsTheUserFromTheirHome() throws {
        let command = try SSHSession.asUser("acmeshop", "ls")
        #expect(command == "su -s /bin/sh acmeshop -c 'cd && ls'")
        let quoted = try SSHSession.asUser("acmeshop", "echo 'x'")
        #expect(quoted == "su -s /bin/sh acmeshop -c " + ShellQuote.quote("cd && echo 'x'"))
        #expect(throws: RemoteError.self) { try SSHSession.asUser("a;b", "ls") }
    }

    @Test func configCarriesRunAsThroughCoding() throws {
        let config = ConnectionConfig(protocol: .sftp, host: "h", username: "root", runAs: "acmeshop")
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: try JSONEncoder().encode(config))
        #expect(decoded.runAs == "acmeshop")
    }
}
