import Foundation
import Testing
@testable import ConnectionKit

@Suite struct FTPReplyParserTests {
    private func parse(_ lines: [String]) -> [FTPReply] {
        var parser = FTPReplyParser()
        return lines.compactMap { parser.feed($0) }
    }

    @Test func singleLine() {
        let replies = parse(["220 Welcome"])
        #expect(replies == [FTPReply(code: 220, lines: ["Welcome"])])
    }

    @Test func multiLineReply() {
        let replies = parse([
            "211-Features:",
            " MDTM",
            " MLST type*;size*;modify*;",
            " UTF8",
            "211 End",
        ])
        #expect(replies.count == 1)
        #expect(replies[0].code == 211)
        #expect(replies[0].lines == ["Features:", " MDTM", " MLST type*;size*;modify*;", " UTF8", "End"])
    }

    @Test func interiorLinesWithDigitsDoNotTerminate() {
        let replies = parse(["214-Help", "214x not a terminator", "500 also not", "214 done"])
        #expect(replies.map(\.code) == [214])
        #expect(replies[0].lines.count == 4)
    }

    @Test func consecutiveRepliesAndGarbageBetween() {
        let replies = parse(["150 Opening", "garbage", "226 Done"])
        #expect(replies.map(\.code) == [150, 226])
    }

    @Test func bareCodeLine() {
        #expect(parse(["200"]) == [FTPReply(code: 200, lines: [""])])
    }

    @Test func classification() {
        #expect(FTPReply(code: 150, lines: []).isPreliminary)
        #expect(FTPReply(code: 226, lines: []).isCompletion)
        #expect(FTPReply(code: 350, lines: []).isIntermediate)
        #expect(FTPReply(code: 450, lines: []).isFailure)
        #expect(FTPReply(code: 550, lines: []).isPermanentFailure)
    }
}

@Suite struct FTPPassiveParsingTests {
    @Test func pasvWithParentheses() {
        let endpoint = FTPPassive.parsePASV("Entering Passive Mode (192,168,1,20,19,137).")
        #expect(endpoint == .init(host: "192.168.1.20", port: 19 * 256 + 137))
    }

    @Test func pasvWithoutParentheses() {
        let endpoint = FTPPassive.parsePASV("Entering Passive Mode 10,0,0,5,4,1")
        #expect(endpoint == .init(host: "10.0.0.5", port: 1025))
    }

    @Test func pasvRejectsGarbage() {
        #expect(FTPPassive.parsePASV("Entering Passive Mode (1,2,3,4,5)") == nil)
        #expect(FTPPassive.parsePASV("Entering Passive Mode (1,2,3,4,5,300)") == nil)
        #expect(FTPPassive.parsePASV("nope") == nil)
    }

    @Test func epsv() {
        #expect(FTPPassive.parseEPSV("Entering Extended Passive Mode (|||6446|)") == .init(host: nil, port: 6446))
        #expect(FTPPassive.parseEPSV("Extended Passive mode OK (!!!2121!)") == .init(host: nil, port: 2121))
        #expect(FTPPassive.parseEPSV("Entering Extended Passive Mode (|||abc|)") == nil)
        #expect(FTPPassive.parseEPSV("no parens") == nil)
        #expect(FTPPassive.parseEPSV("(|||0|)") == nil)
    }

    @Test func nonRoutableAddresses() {
        #expect(FTPPassive.isNonRoutable("192.168.0.4"))
        #expect(FTPPassive.isNonRoutable("10.1.2.3"))
        #expect(FTPPassive.isNonRoutable("172.20.0.1"))
        #expect(FTPPassive.isNonRoutable("0.0.0.0"))
        #expect(!FTPPassive.isNonRoutable("172.32.0.1"))
        #expect(!FTPPassive.isNonRoutable("93.184.216.34"))
    }
}

@Suite struct FTPListParserTests {
    @Test func mlsdFile() throws {
        let item = try #require(FTPListParser.parseMLSD(
            "type=file;size=1234;modify=20240115123045;perm=adfrw;UNIX.mode=0644; my file.txt", parent: "/data"))
        #expect(item.name == "my file.txt")
        #expect(item.path == "/data/my file.txt")
        #expect(!item.isDirectory)
        #expect(item.size == 1234)
        #expect(item.permissions == 0o644)
        #expect(item.modified == Date(timeIntervalSince1970: 1_705_321_845))
    }

    @Test func mlsdDirectoryAndSkippedEntries() throws {
        let dir = try #require(FTPListParser.parseMLSD("Type=dir;Modify=20240101000000.123; sub", parent: "/"))
        #expect(dir.isDirectory)
        #expect(dir.path == "/sub")
        #expect(FTPListParser.parseMLSD("type=cdir;modify=20240101000000; .", parent: "/") == nil)
        #expect(FTPListParser.parseMLSD("type=pdir;modify=20240101000000; ..", parent: "/") == nil)
        #expect(FTPListParser.parseMLSD("garbage-without-space", parent: "/") == nil)
    }

    @Test func mlsdSymlink() throws {
        let item = try #require(FTPListParser.parseMLSD("type=OS.unix=slink:/etc/real;size=9; link", parent: "/x"))
        #expect(item.symlinkTarget == "/etc/real")
    }

    private let now = Date(timeIntervalSince1970: 1_718_000_000) // 2024-06-10

    @Test func listFileWithTime() throws {
        let item = try #require(FTPListParser.parseUnixList(
            "-rw-r--r--    1 ftp      ftp          4096 Jan 15 12:30 notes.txt", parent: "/home", now: now))
        #expect(item.name == "notes.txt")
        #expect(item.path == "/home/notes.txt")
        #expect(item.size == 4096)
        #expect(item.permissions == 0o644)
        #expect(!item.isDirectory)
        #expect(item.modified == Date(timeIntervalSince1970: 1_705_321_800))
    }

    @Test func listDirectoryWithYear() throws {
        let item = try #require(FTPListParser.parseUnixList(
            "drwxr-xr-x   2 user group  4096 Dec  5  2021 old stuff", parent: "/", now: now))
        #expect(item.isDirectory)
        #expect(item.name == "old stuff")
        #expect(item.permissions == 0o755)
        #expect(item.modified == Date(timeIntervalSince1970: 1_638_662_400))
    }

    @Test func listFutureDateBelongsToPreviousYear() throws {
        let item = try #require(FTPListParser.parseUnixList(
            "-rw-r--r-- 1 u g 1 Dec 25 10:00 a", parent: "/", now: now))
        #expect(item.modified == Date(timeIntervalSince1970: 1_703_498_400))
    }

    @Test func listSymlinkAndSpecialBits() throws {
        let link = try #require(FTPListParser.parseUnixList(
            "lrwxrwxrwx 1 root root 11 Jan  1 00:00 www -> /var/www/x", parent: "/", now: now))
        #expect(link.name == "www")
        #expect(link.symlinkTarget == "/var/www/x")
        let sticky = try #require(FTPListParser.parseUnixList(
            "drwxrwxrwt 9 root root 4096 Jun  1 08:00 tmp", parent: "/", now: now))
        #expect(sticky.permissions == 0o1777)
        let suid = try #require(FTPListParser.parseUnixList(
            "-rwsr-xr-x 1 root root 100 Jun  1 08:00 su", parent: "/", now: now))
        #expect(suid.permissions == 0o4755)
    }

    @Test func listIgnoresNonEntries() {
        #expect(FTPListParser.parseUnixList("total 48", parent: "/", now: now) == nil)
        #expect(FTPListParser.parseUnixList("", parent: "/", now: now) == nil)
        #expect(FTPListParser.parseUnixList("01-15-24  12:30PM       <DIR>          docs", parent: "/", now: now) == nil)
    }
}

@Suite struct LogRedactionTests {
    @Test func passwordIsRedacted() {
        #expect(LogRedactor.redactFTPCommand("PASS hunter2") == "PASS ****")
        #expect(LogRedactor.redactFTPCommand("pass hunter2 with spaces") == "pass ****")
        #expect(LogRedactor.redactFTPCommand("ACCT secret") == "ACCT ****")
    }

    @Test func otherCommandsAreUntouched() {
        #expect(LogRedactor.redactFTPCommand("USER bob") == "USER bob")
        #expect(LogRedactor.redactFTPCommand("PASV") == "PASV")
        #expect(LogRedactor.redactFTPCommand("RETR PASSWORDS.txt") == "RETR PASSWORDS.txt")
    }

    @Test func hubDeliversToEverySubscriber() async {
        let hub = LogHub()
        let a = hub.stream(), b = hub.stream()
        hub.emit(.command, "USER x")
        hub.finish()
        var seenA: [String] = [], seenB: [String] = []
        for await line in a { seenA.append(line.message) }
        for await line in b { seenB.append(line.message) }
        #expect(seenA == ["USER x"] && seenB == ["USER x"])
    }

    @Test func inMemorySecretStoreRoundTrip() async {
        let store = InMemorySecretStore()
        let id = UUID()
        #expect(await store.secret(for: id, purpose: .password) == nil)
        await store.setSecret("a", for: id, purpose: .password)
        await store.setSecret("b", for: id, purpose: .keyPassphrase)
        #expect(await store.secret(for: id, purpose: .password) == "a")
        await store.setSecret("c", for: id, purpose: .password)
        #expect(await store.secret(for: id, purpose: .password) == "c")
        await store.removeSecret(for: id, purpose: .password)
        #expect(await store.secret(for: id, purpose: .password) == nil)
        #expect(await store.secret(for: id, purpose: .keyPassphrase) == "b")
    }
}
