import Foundation
import Testing
@testable import ConnectionKit

struct MemoryConfigFiles: SSHConfigFiles {
    var files: [String: String]

    func contents(of path: String) -> String? { files[path] }

    func expand(_ pattern: String) -> [String] {
        files.keys.filter { Glob.matches(pattern, $0, pathAware: true) }.sorted()
    }
}

private func parse(_ files: [String: String], main: String = "/home/me/.ssh/config") -> SSHConfigResult {
    SSHConfigParser(home: "/home/me", files: MemoryConfigFiles(files: files)).parse(path: main)
}

private func parse(_ config: String) -> SSHConfigResult { parse(["/home/me/.ssh/config": config]) }

@Suite struct GlobTests {
    @Test func basics() {
        #expect(Glob.matches("*.log", "a.log"))
        #expect(!Glob.matches("*.log", "a.logx"))
        #expect(Glob.matches("a?c", "abc"))
        #expect(Glob.matches("[a-c]x", "bx"))
        #expect(!Glob.matches("[!a-c]x", "bx"))
        #expect(Glob.matches("a\\*b", "a*b"))
        #expect(!Glob.matches("a\\*b", "axb"))
        #expect(Glob.matches("[", "["))
        #expect(Glob.matches("web*", "WEB1", caseInsensitive: true))
    }

    @Test func pathAware() {
        #expect(!Glob.matches("*.log", "a/b.log", pathAware: true))
        #expect(Glob.matches("**/*.log", "a/b/c.log", pathAware: true))
        #expect(Glob.matches("**/*.log", "c.log", pathAware: true))
        #expect(Glob.matches("a/**", "a/b/c", pathAware: true))
        #expect(Glob.matches("a/**/z", "a/z", pathAware: true))
        #expect(Glob.matches("a/**/z", "a/b/c/z", pathAware: true))
        #expect(!Glob.matches("a?b", "a/b", pathAware: true))
    }
}

@Suite struct SSHConfigParserTests {
    @Test func resolvesBasicHost() {
        let r = parse("""
        # comment
        Host web
            HostName web.example.com
            User deploy
            Port 2200
            IdentityFile ~/.ssh/web_ed25519
        """)
        #expect(r.entries == [SSHConfigEntry(alias: "web", hostName: "web.example.com", user: "deploy", port: 2200,
                                             identityFiles: ["/home/me/.ssh/web_ed25519"])])
        #expect(r.warnings.isEmpty)
    }

    @Test func multipleNamesAndWildcardDefaults() {
        let r = parse("""
        Host prod1 prod2 prod-*
            User ops
        Host prod1
            HostName 10.0.0.1
        Host prod2
            HostName 10.0.0.2
            User override
        Host *
            User fallback
            Port 2222
            IdentityFile ~/.ssh/default
        """)
        #expect(r.entries.map(\.alias) == ["prod1", "prod2"])
        let p1 = r.entries[0], p2 = r.entries[1]
        #expect(p1.hostName == "10.0.0.1" && p1.user == "ops" && p1.port == 2222)
        // First value wins: `Host prod1 prod2 prod-*` came before the override.
        #expect(p2.user == "ops")
        #expect(p1.identityFiles == ["/home/me/.ssh/default"])
    }

    @Test func identityFilesAccumulate() {
        let r = parse("""
        Host a
            IdentityFile ~/.ssh/one
            IdentityFile "/keys/two key"
        Host *
            IdentityFile ~/.ssh/one
            IdentityFile %d/.ssh/three
        """)
        #expect(r.entries[0].identityFiles == ["/home/me/.ssh/one", "/keys/two key", "/home/me/.ssh/three"])
    }

    @Test func negatedPatternsAndHostNameToken() {
        let r = parse("""
        Host *.example.com !secret.example.com
            User team
        Host db.example.com secret.example.com
            HostName %h.internal
        """)
        let byAlias = Dictionary(uniqueKeysWithValues: r.entries.map { ($0.alias, $0) })
        #expect(byAlias["db.example.com"]?.user == "team")
        #expect(byAlias["secret.example.com"]?.user == nil)
        #expect(byAlias["db.example.com"]?.hostName == "db.example.com.internal")
    }

    @Test func proxyJumpChains() {
        let r = parse("""
        Host target
            HostName 10.1.1.5
            ProxyJump bastion, ops@jump2.example.com:2022,[::1]:2200
        Host direct
            ProxyJump none
        Host *
            ProxyJump ignored@elsewhere
        """)
        #expect(r.entries[0].proxyJump == [
            SSHJumpSpec(host: "bastion"),
            SSHJumpSpec(user: "ops", host: "jump2.example.com", port: 2022),
            SSHJumpSpec(host: "::1", port: 2200),
        ])
        #expect(r.entries[1].proxyJump.isEmpty)
    }

    @Test func jumpSpecParsing() {
        #expect(SSHJumpSpec.parse("u@h") == SSHJumpSpec(user: "u", host: "h"))
        #expect(SSHJumpSpec.parse("ssh://u@h:22") == SSHJumpSpec(user: "u", host: "h", port: 22))
        #expect(SSHJumpSpec.parse("h:notaport") == nil)
        #expect(SSHJumpSpec.parse("") == nil)
        #expect(SSHJumpSpec.parse("fe80::1")?.host == "fe80::1")
    }

    @Test func includesAreRelativeToSSHDirectory() {
        let r = parse([
            "/home/me/.ssh/config": """
            Include config.d/*
            Include ~/extra/more.conf
            Host main
                HostName main.example.com
            """,
            "/home/me/.ssh/config.d/a": "Host a\n  HostName a.example.com\n",
            "/home/me/.ssh/config.d/b": "Host b\n  HostName b.example.com\n",
            "/home/me/extra/more.conf": "Host c\n  HostName c.example.com\n",
        ])
        #expect(r.entries.map(\.alias) == ["a", "b", "c", "main"])
    }

    @Test func includeInsideHostBlockContinuesTheBlock() {
        let r = parse([
            "/home/me/.ssh/config": "Host x\n  Include shared\n  HostName x.example.com\n",
            "/home/me/.ssh/shared": "User shared-user\n",
        ])
        #expect(r.entries[0].user == "shared-user" && r.entries[0].hostName == "x.example.com")
    }

    @Test func recursiveIncludeIsBounded() {
        let r = parse([
            "/home/me/.ssh/config": "Include config\nHost a\n",
        ])
        #expect(r.entries.map(\.alias) == ["a"])
        #expect(r.warnings.contains { $0.contains("too deep") })
    }

    @Test func matchBlocksAreSkippedWithWarning() {
        let r = parse("""
        Host a
            User one
        Match host b exec "true"
            User hidden
            HostName hidden.example.com
        Host b
            HostName b.example.com
        """)
        #expect(r.warnings.count == 1 && r.warnings[0].contains(":3:") && r.warnings[0].contains("Match"))
        #expect(r.entries.map(\.user) == ["one", nil])
        #expect(r.entries[1].hostName == "b.example.com")
    }

    @Test func syntaxVariants() {
        let r = parse("""
        host=eq
            HostName=eq.example.com
            port = 2022
        Host   spaced   # trailing comment
        \tUser   "quoted user"
        """)
        #expect(r.entries[0].hostName == "eq.example.com" && r.entries[0].port == 2022)
        #expect(r.entries[1].alias == "spaced" && r.entries[1].user == "quoted user")
    }

    @Test func invalidPortAndProxyCommand() {
        let r = parse("""
        Host a
            Port 99999
            ProxyCommand ssh -W %h:%p bastion
        """)
        #expect(r.entries[0].port == nil && r.entries[0].hasProxyCommand)
    }

    @Test func missingFileWarns() {
        let r = parse([:])
        #expect(r.entries.isEmpty && r.warnings.count == 1)
    }

    @Test func readsRealFilesFromDisk() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sshcfg-\(UUID().uuidString)")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh.appendingPathComponent("conf.d"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "Include conf.d/*.conf\nHost real\n  HostName r.example.com\n".write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host inc\n  User u\n".write(to: ssh.appendingPathComponent("conf.d/x.conf"), atomically: true, encoding: .utf8)
        let r = SSHConfigParser(home: home.path).parseDefault()
        #expect(r.entries.map(\.alias) == ["inc", "real"])
    }
}
