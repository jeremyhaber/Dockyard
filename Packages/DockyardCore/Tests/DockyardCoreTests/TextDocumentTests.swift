import Foundation
import Testing
@testable import DockyardCore

@Suite struct TextDocumentTests {
    private func roundTrip(_ bytes: [UInt8]) throws {
        let data = Data(bytes)
        let doc = try #require(TextDocument.decode(data))
        #expect(doc.encode(doc.text).data == data)
    }

    @Test func utf8RoundTripsWithAndWithoutTrailingNewline() throws {
        try roundTrip(Array("hello\nwörld\n".utf8))
        try roundTrip(Array("no newline".utf8))
        try roundTrip([])
    }

    @Test func bomIsKeptAndReported() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("a\nb\n".utf8)
        let doc = try #require(TextDocument.decode(data))
        #expect(doc.format.hasBOM && doc.text == "a\nb\n")
        #expect(doc.format.label == "UTF-8 BOM \u{00B7} LF")
        #expect(doc.encode(doc.text).data == data)
        #expect(doc.encode("a\nb\nc\n").data == Data([0xEF, 0xBB, 0xBF]) + Data("a\nb\nc\n".utf8))
    }

    @Test func crlfAndCRAreNormalisedAndRestored() throws {
        let crlf = Data("one\r\ntwo\r\n".utf8)
        let doc = try #require(TextDocument.decode(crlf))
        #expect(doc.text == "one\ntwo\n" && doc.format.lineEnding == .crlf)
        #expect(doc.encode("one\ntwo\nthree\n").data == Data("one\r\ntwo\r\nthree\r\n".utf8))
        try roundTrip(Array(crlf))
        let cr = Data("a\rb\r".utf8)
        let old = try #require(TextDocument.decode(cr))
        #expect(old.text == "a\nb\n" && old.format.lineEnding == .cr)
        try roundTrip(Array(cr))
    }

    @Test func mixedEndingsRoundTripWhenUntouched() throws {
        let data = Data("a\r\nb\nc\n".utf8)
        let doc = try #require(TextDocument.decode(data))
        #expect(doc.hadMixedLineEndings && doc.format.lineEnding == .lf)
        #expect(doc.encode(doc.text).data == data)
    }

    @Test func nonUTF8FallsBackToLatin1AndRoundTrips() throws {
        let bytes: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x0A, 0xFF, 0xFE, 0x0A]
        let doc = try #require(TextDocument.decode(Data(bytes)))
        #expect(doc.format.encoding == .latin1)
        #expect(doc.encode(doc.text).data == Data(bytes))
        #expect(doc.encode(doc.text + "x").data == Data(bytes + [0x78]))
    }

    @Test func latin1SwitchesToUTF8WhenTextCannotBeHeld() throws {
        let doc = try #require(TextDocument.decode(Data([0x63, 0xE9])))
        let saved = doc.encode(doc.text + "\u{20AC}")
        #expect(saved.format.encoding == .utf8)
        #expect(saved.data == Data("c\u{E9}\u{20AC}".utf8))
    }

    @Test func binaryIsRefused() {
        #expect(TextDocument.decode(Data([0x00, 0x01, 0x02])) == nil)
        #expect(TextDocument.decode(Data("text\0more".utf8)) == nil)
        #expect(TextDocument.decode(Data((0..<200).map { _ in UInt8(0x01) } + [0xFF])) == nil)
    }

    @Test func emptyBufferForMissingFile() {
        let doc = TextDocument.empty()
        #expect(doc.text.isEmpty && doc.encode("").data.isEmpty)
        #expect(doc.encode("x\n").data == Data("x\n".utf8))
    }
}

@Suite struct SyntaxHighlighterTests {
    private func kinds(_ line: String, _ language: SyntaxLanguage) -> [(String, SyntaxKind)] {
        let units = Array(line.utf16)
        return SyntaxHighlighter.spans(in: line, language: language).map {
            (String(utf16CodeUnits: Array(units[$0.start..<$0.start + $0.length]), count: $0.length), $0.kind)
        }
    }

    @Test func detectsLanguages() {
        #expect(SyntaxLanguage.detect(fileName: "wp-config.php") == .php)
        #expect(SyntaxLanguage.detect(fileName: ".env.production") == .ini)
        #expect(SyntaxLanguage.detect(fileName: "deploy.sh") == .shell)
        #expect(SyntaxLanguage.detect(fileName: "default.conf", path: "/etc/nginx/sites-enabled/default.conf") == .nginx)
        #expect(SyntaxLanguage.detect(fileName: "my.cnf") == .ini)
        #expect(SyntaxLanguage.detect(fileName: "notes.txt") == .plain)
        #expect(SyntaxLanguage.detect(fileName: "root", path: "/var/spool/cron/crontabs/root") == .crontab)
    }

    @Test func shellComments() {
        let spans = kinds("echo hi # note", .shell)
        #expect(spans.contains { $0.0 == "# note" && $0.1 == .comment })
        #expect(!kinds("echo $#", .shell).contains { $0.1 == .comment })
    }

    @Test func phpStringsVariablesKeywords() {
        let spans = kinds("define('DB_NAME', $name); // done", .php)
        #expect(spans.contains { $0.0 == "'DB_NAME'" && $0.1 == .string })
        #expect(spans.contains { $0.0 == "$name" && $0.1 == .variable })
        #expect(spans.contains { $0.0 == "define" && $0.1 == .keyword })
        #expect(spans.contains { $0.0 == "// done" && $0.1 == .comment })
    }

    @Test func jsonKeysAndValues() {
        let spans = kinds("  \"port\": 8080, \"on\": true", .json)
        #expect(spans.contains { $0.0 == "\"port\"" && $0.1 == .key })
        #expect(spans.contains { $0.0 == "8080" && $0.1 == .number })
        #expect(spans.contains { $0.0 == "true" && $0.1 == .keyword })
    }

    @Test func yamlAndIni() {
        #expect(kinds("  - name: web # c", .yaml).contains { $0.0 == "name" && $0.1 == .key })
        #expect(kinds("[mysqld]", .ini).first?.1 == .tag)
        #expect(kinds("max_connections = 100", .ini).contains { $0.0 == "max_connections" && $0.1 == .key })
        #expect(kinds("; off", .ini).first?.1 == .comment)
    }

    @Test func cronAndNginx() {
        #expect(kinds("*/5 * * * * /usr/bin/php run.php", .crontab).contains { $0.0 == "5" && $0.1 == .number })
        #expect(kinds("  listen 443 ssl;", .nginx).first.map { $0.0 == "listen" && $0.1 == .keyword } == true)
    }

    @Test func spansUseUTF16Offsets() {
        let spans = SyntaxHighlighter.spans(in: "\u{1F600} 'x'", language: .javascript)
        #expect(spans.first { $0.kind == .string }?.start == 3)
    }

    @Test func plainAndEmptyHaveNoSpans() {
        #expect(SyntaxHighlighter.spans(in: "anything", language: .plain).isEmpty)
        #expect(SyntaxHighlighter.spans(in: "", language: .php).isEmpty)
    }
}
