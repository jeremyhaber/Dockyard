import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

@Suite struct LogTests {
    @Test func ringBufferKeepsNewestLines() {
        let log = LogBuffer(capacity: 5)
        for i in 0..<12 { log.append(.status, "line \(i)") }
        #expect(log.lines().map(\.message) == (7..<12).map { "line \($0)" })
        #expect(log.counts.total == 5)
    }

    @Test func fiveThousandLineDefault() {
        let log = LogBuffer()
        for i in 0..<5_500 { log.append(.response, "r\(i)") }
        #expect(log.lines().count == 5_000)
        #expect(log.lines().first?.message == "r500")
        #expect(log.lines().last?.message == "r5499")
    }

    @Test func countsFollowEvictions() {
        let log = LogBuffer(capacity: 3)
        log.append(.error, "e1"); log.append(.warning, "w1"); log.append(.status, "s")
        #expect(log.counts == LogCounts(total: 3, errors: 1, warnings: 1))
        log.append(.status, "s2")  // evicts e1
        #expect(log.counts == LogCounts(total: 3, errors: 0, warnings: 1))
        log.append(.error, "e2")
        #expect(log.counts.errors == 1)
        log.clear()
        #expect(log.counts == LogCounts() && log.lines().isEmpty)
    }

    @Test func errorsOnlyFilterAndCopyText() {
        let log = LogBuffer()
        let t = Date(timeIntervalSince1970: 1_700_000_000)  // 22:13:20 UTC
        log.append(.command, "PASV", time: t)
        log.append(.response, "227 Entering Passive Mode", time: t)
        log.append(.error, "550 No such file", time: t.addingTimeInterval(1))
        let utc = TimeZone(identifier: "UTC")!
        #expect(log.lines(errorsOnly: true).map(\.message) == ["550 No such file"])
        #expect(log.copyText(timeZone: utc) == "22:13:20  Command: PASV\n22:13:20  Response: 227 Entering Passive Mode\n22:13:21  Error: 550 No such file")
        #expect(log.copyText(errorsOnly: true, timeZone: utc) == "22:13:21  Error: 550 No such file")
        #expect(LogBuffer().copyText() == "")
    }

    @Test func redactsKnownPatterns() {
        let cases: [(String, String)] = [
            ("PASS hunter2", "PASS ****"),
            ("pass hunter2", "pass ****"),
            ("Command: PASS hunter2", "Command: PASS ****"),
            ("connecting to ftp://bob:s3cret@host.com/dir", "connecting to ftp://bob:****@host.com/dir"),
            ("password=abc123&user=bob", "password=****&user=bob"),
            (#"{"password": "abc 123", "user": "bob"}"#, #"{"password": ****, "user": "bob"}"#),
            ("passphrase: hunter2", "passphrase: ****"),
            ("Authorization: whm root:ABCDEF123456", "Authorization: ****"),
            ("Authorization: Bearer abc.def", "Authorization: ****"),
            ("sent header Bearer tok_123 ok", "sent header Bearer **** ok"),
            ("api_key=XYZ", "api_key=****"),
            ("USER bob", "USER bob"),
            ("227 Entering Passive Mode (1,2,3,4,5,6)", "227 Entering Passive Mode (1,2,3,4,5,6)"),
            ("Passed 3 files", "Passed 3 files"),
        ]
        for (input, expected) in cases {
            let out = LogSanitizer.redact(input)
            #expect(out == expected, "input: \(input)")
        }
    }

    @Test func masksRegisteredSecretsAnywhere() {
        let log = LogBuffer()
        log.registerSecret("Zx9!qLongSecret")
        log.append(.status, "typed Zx9!qLongSecret into prompt; again Zx9!qLongSecret")
        #expect(log.lines().first?.message == "typed **** into prompt; again ****")
        // Short secrets would shred ordinary words, so they are ignored.
        log.registerSecret("ab")
        log.append(.status, "about")
        #expect(log.lines().last?.message == "about")
    }

    @Test func bufferNeverHoldsPasswordFromBackendLines() {
        let log = LogBuffer()
        log.append(.command, "PASS Sup3rSecret")
        log.append(.status, "Login to ftp://u:Sup3rSecret@h failed")
        #expect(!log.copyText().contains("Sup3rSecret"))
    }

    @Test func attachConsumesBackendStream() async {
        let hub = LogHub()
        let log = LogBuffer()
        let task = log.attach(to: hub.stream())
        hub.emit(.status, "Connecting")
        hub.emit(.error, "Timeout")
        #expect(await waitUntil { log.counts.total == 2 })
        hub.finish()
        await task.value
        #expect(log.counts.errors == 1)
    }

    @Test func countUpdatesStream() async {
        let log = LogBuffer()
        let stream = log.updates()
        let watcher = Task { await firstValue(stream) { $0.errors == 2 && $0.warnings == 1 } }
        log.append(.error, "a"); log.append(.warning, "w"); log.append(.error, "b")
        #expect(await watcher.value != nil)
    }

    // MARK: File writer

    @Test func writesAndRotatesFiles() throws {
        let dir = try makeTempDir("logs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RollingLogFileWriter(directory: dir.appendingPathComponent("Dockyard"), name: "Client/Prod: 1", maxBytes: 300, maxFiles: 3,
                                          timeZone: TimeZone(identifier: "UTC")!)
        let log = LogBuffer(fileWriter: writer)
        for i in 0..<30 { log.append(.status, "message number \(i) with some padding", time: Date(timeIntervalSince1970: 1_700_000_000)) }
        #expect(writer.baseName == "Client_Prod_ 1")
        let files = writer.allFiles
        #expect(files.count == 3)
        #expect(files.map(\.lastPathComponent) == ["Client_Prod_ 1.log", "Client_Prod_ 1.1.log", "Client_Prod_ 1.2.log"])
        for f in files { #expect((try Data(contentsOf: f)).count <= 300 + 80) }
        let newest = try String(contentsOf: files[0], encoding: .utf8)
        #expect(newest.contains("message number 29"))
        #expect(newest.contains("2023-11-14 22:13:20  Status: message number"))
        let all = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(!all.contains("message number 0 "))  // oldest lines were rotated out
        #expect(writer.lastError == nil)
    }

    @Test func fileReceivesRedactedLinesOnly() throws {
        let dir = try makeTempDir("logs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RollingLogFileWriter(directory: dir, name: "c")
        let log = LogBuffer(fileWriter: writer)
        log.append(.command, "PASS topsecret")
        let text = try String(contentsOf: writer.currentFile, encoding: .utf8)
        #expect(text.contains("PASS ****") && !text.contains("topsecret"))
    }

    @Test func appendsToExistingFileAcrossInstances() throws {
        let dir = try makeTempDir("logs")
        defer { try? FileManager.default.removeItem(at: dir) }
        RollingLogFileWriter(directory: dir, name: "c").write(LogLine(kind: .status, message: "first"))
        RollingLogFileWriter(directory: dir, name: "c").write(LogLine(kind: .status, message: "second"))
        let text = try String(contentsOf: dir.appendingPathComponent("c.log"), encoding: .utf8)
        #expect(text.contains("first") && text.contains("second"))
    }

    @Test func unwritableDirectoryRecordsErrorWithoutCrashing() throws {
        let file = try makeTempDir("logs").appendingPathComponent("afile")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        // The "directory" is a file, so creating it fails.
        let writer = RollingLogFileWriter(directory: file, name: "c")
        writer.write(LogLine(kind: .status, message: "x"))
        #expect(writer.lastError != nil)
    }

    @Test func safeNames() {
        #expect(RollingLogFileWriter.safeName("") == "connection")
        #expect(RollingLogFileWriter.safeName("..") == "connection")
        #expect(RollingLogFileWriter.safeName("a/b\\c") == "a_b_c")
    }
}
