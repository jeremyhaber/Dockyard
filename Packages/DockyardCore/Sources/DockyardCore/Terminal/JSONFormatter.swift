import Foundation

/// A token-level JSON pretty printer. It never builds values, so key order, string escapes and number text come out
/// exactly as they went in; only the whitespace between tokens changes. Strict JSON: comments and trailing commas are errors.
public enum JSONFormatter {
    public struct ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        public var line: Int
        public var column: Int
        public var message: String
        public var description: String { "line \(line), column \(column): \(message)" }
    }

    /// The indent unit the text already uses: a tab, or 2 or 4 spaces (2 when it cannot tell).
    public static func detectIndent(in text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first, first == " " || first == "\t" else { continue }
            if first == "\t" { return "\t" }
            let spaces = line.prefix(while: { $0 == " " }).count
            if line.dropFirst(spaces).allSatisfy({ $0 == " " || $0 == "\r" }) { continue }
            return spaces % 4 == 0 ? "    " : "  "
        }
        return "  "
    }

    /// Validates `text` as one JSON value. Nil when it is valid.
    public static func validate(_ text: String) -> ParseError? {
        do { _ = try format(text, indent: "  ") } catch let error as ParseError { return error } catch { return nil }
        return nil
    }

    public static func format(_ text: String) throws -> String {
        try format(text, indent: detectIndent(in: text))
    }

    public static func format(_ text: String, indent: String) throws -> String {
        let bytes = Array(text.utf8)
        var parser = Printer(bytes: bytes, indent: Array(indent.utf8))
        try parser.run()
        var out = parser.out
        if text.hasSuffix("\n") { out.append(10) }
        return String(decoding: out, as: UTF8.self)
    }

    private struct Printer {
        enum State { case value, arrayValue, key, colon, commaOrClose, end }
        let bytes: [UInt8]
        let indent: [UInt8]
        var out: [UInt8] = []
        var i = 0
        var stack: [UInt8] = []   // `{` or `[`
        var state = State.value

        init(bytes: [UInt8], indent: [UInt8]) {
            self.bytes = bytes
            self.indent = indent
        }

        func fail(_ message: String, at offset: Int) -> ParseError {
            let prefix = String(decoding: bytes[0..<min(offset, bytes.count)], as: UTF8.self)
            let line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let lastLine = prefix.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
            return ParseError(line: line, column: lastLine.count + 1, message: message)
        }

        func describe(_ byte: UInt8) -> String {
            byte < 0x20 || byte >= 0x7F ? "this character" : "\u{201C}\(String(UnicodeScalar(byte)))\u{201D}"
        }

        mutating func newline(_ depth: Int) {
            out.append(10)
            for _ in 0..<depth { out.append(contentsOf: indent) }
        }

        mutating func skipSpace() {
            while i < bytes.count, [32, 9, 10, 13].contains(bytes[i]) { i += 1 }
        }

        mutating func run() throws {
            while true {
                skipSpace()
                guard i < bytes.count else {
                    if state == .end { return }
                    throw fail("Unexpected end of the text", at: i)
                }
                let c = bytes[i]
                switch state {
                case .end:
                    throw fail("Unexpected data after the JSON value", at: i)
                case .value, .arrayValue:
                    if state == .arrayValue { newline(stack.count) }
                    try value(c)
                case .key:
                    guard c == 0x22 else { throw fail("Expected a string key, found \(describe(c))", at: i) }
                    newline(stack.count)
                    try string()
                    state = .colon
                case .colon:
                    guard c == 0x3A else { throw fail("Expected \u{201C}:\u{201D} after the key, found \(describe(c))", at: i) }
                    out.append(contentsOf: [0x3A, 0x20])
                    i += 1
                    state = .value
                case .commaOrClose:
                    let open = stack.last!
                    if c == 0x2C {
                        out.append(0x2C)
                        i += 1
                        state = open == 0x7B ? .key : .arrayValue
                    } else if c == (open == 0x7B ? 0x7D : 0x5D) {
                        stack.removeLast()
                        newline(stack.count)
                        out.append(c)
                        i += 1
                        state = stack.isEmpty ? .end : .commaOrClose
                    } else {
                        let want = open == 0x7B ? "\u{201C},\u{201D} or \u{201C}}\u{201D}" : "\u{201C},\u{201D} or \u{201C}]\u{201D}"
                        throw fail("Expected \(want), found \(describe(c))", at: i)
                    }
                }
            }
        }

        mutating func value(_ c: UInt8) throws {
            switch c {
            case 0x7B, 0x5B:
                let close: UInt8 = c == 0x7B ? 0x7D : 0x5D
                var peek = i + 1
                while peek < bytes.count, [32, 9, 10, 13].contains(bytes[peek]) { peek += 1 }
                if peek < bytes.count, bytes[peek] == close {
                    out.append(contentsOf: [c, close])
                    i = peek + 1
                    state = stack.isEmpty ? .end : .commaOrClose
                } else {
                    out.append(c)
                    i += 1
                    stack.append(c)
                    state = c == 0x7B ? .key : .arrayValue
                }
            case 0x22:
                try string()
                state = stack.isEmpty ? .end : .commaOrClose
            case 0x2D, 0x30...0x39:
                try number()
                state = stack.isEmpty ? .end : .commaOrClose
            case 0x74: try literal("true")
            case 0x66: try literal("false")
            case 0x6E: try literal("null")
            default:
                throw fail("Unexpected \(describe(c)) where a value should be", at: i)
            }
        }

        mutating func literal(_ word: String) throws {
            let letters = Array(word.utf8)
            guard i + letters.count <= bytes.count, Array(bytes[i..<(i + letters.count)]) == letters else {
                throw fail("Invalid value; expected \u{201C}\(word)\u{201D}", at: i)
            }
            out.append(contentsOf: letters)
            i += letters.count
            state = stack.isEmpty ? .end : .commaOrClose
        }

        /// Copies a string token verbatim, checking its escapes.
        mutating func string() throws {
            let begin = i
            i += 1
            while i < bytes.count {
                let c = bytes[i]
                if c == 0x22 {
                    i += 1
                    out.append(contentsOf: bytes[begin..<i])
                    return
                }
                if c < 0x20 { throw fail("Control characters in a string must be escaped", at: i) }
                if c == 0x5C {
                    guard i + 1 < bytes.count else { break }
                    switch bytes[i + 1] {
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: i += 2
                    case 0x75:
                        guard i + 5 < bytes.count, bytes[(i + 2)...(i + 5)].allSatisfy(Self.isHex) else {
                            throw fail("Invalid \\u escape", at: i)
                        }
                        i += 6
                    default: throw fail("Invalid escape in a string", at: i)
                    }
                } else {
                    i += 1
                }
            }
            throw fail("The string is not closed", at: begin)
        }

        static func isHex(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) || (0x41...0x46).contains(b) || (0x61...0x66).contains(b) }

        /// Copies a number token verbatim, checking the JSON grammar.
        mutating func number() throws {
            let begin = i
            func digits() -> Int {
                var n = 0
                while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1; n += 1 }
                return n
            }
            if bytes[i] == 0x2D { i += 1 }
            guard i < bytes.count else { throw fail("Invalid number", at: begin) }
            if bytes[i] == 0x30 {
                i += 1
            } else if digits() == 0 {
                throw fail("Invalid number", at: begin)
            }
            if i < bytes.count, bytes[i] == 0x2E {
                i += 1
                if digits() == 0 { throw fail("Invalid number: digits expected after the decimal point", at: begin) }
            }
            if i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 {
                i += 1
                if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
                if digits() == 0 { throw fail("Invalid number: digits expected in the exponent", at: begin) }
            }
            out.append(contentsOf: bytes[begin..<i])
        }
    }
}
