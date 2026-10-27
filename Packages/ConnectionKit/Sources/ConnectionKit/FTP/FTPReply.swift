import Foundation

struct FTPReply: Sendable, Equatable {
    var code: Int
    var lines: [String]

    /// Text of the first line with the code stripped.
    var message: String { lines.first ?? "" }
    var isPreliminary: Bool { (100..<200).contains(code) }
    var isCompletion: Bool { (200..<300).contains(code) }
    var isIntermediate: Bool { (300..<400).contains(code) }
    var isTransientFailure: Bool { (400..<500).contains(code) }
    var isPermanentFailure: Bool { (500..<600).contains(code) }
    var isFailure: Bool { code >= 400 }
}

/// Assembles single and multi-line replies (RFC 959 section 4.2) from lines without line endings.
struct FTPReplyParser {
    private var pendingCode: Int?
    private var pendingLines: [String] = []

    /// Feeds one line; returns a reply when the final line of one arrives.
    mutating func feed(_ line: String) -> FTPReply? {
        if let code = pendingCode {
            if let (lineCode, isLast, text) = Self.split(line), lineCode == code, isLast {
                defer { pendingCode = nil; pendingLines = [] }
                pendingLines.append(text)
                return FTPReply(code: code, lines: pendingLines)
            }
            pendingLines.append(line.hasPrefix("\(code)-") ? String(line.dropFirst(4)) : line)
            return nil
        }

        guard let (code, isLast, text) = Self.split(line) else { return nil }
        if isLast { return FTPReply(code: code, lines: [text]) }
        pendingCode = code
        pendingLines = [text]
        return nil
    }

    /// Splits `"123 text"` / `"123-text"` into code, whether it is the final line, and text.
    private static func split(_ line: String) -> (Int, Bool, String)? {
        let utf8 = Array(line.utf8)
        guard utf8.count >= 3, utf8[0...2].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let code = Int(line.prefix(3)) else { return nil }
        if utf8.count == 3 { return (code, true, "") }
        switch utf8[3] {
        case UInt8(ascii: " "): return (code, true, String(line.dropFirst(4)))
        case UInt8(ascii: "-"): return (code, false, String(line.dropFirst(4)))
        default: return nil
        }
    }
}

enum FTPPassive {
    struct Endpoint: Equatable {
        var host: String?
        var port: Int
    }

    /// Parses `227 Entering Passive Mode (192,168,1,2,19,137).`
    static func parsePASV(_ message: String) -> Endpoint? {
        let numbers: [Int]
        if let open = message.firstIndex(of: "("), let close = message[open...].firstIndex(of: ")") {
            numbers = message[message.index(after: open)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        } else {
            // Some servers omit the parentheses: take the first run of six comma-separated numbers.
            let digits = message.split(whereSeparator: { !$0.isNumber && $0 != "," })
            guard let run = digits.first(where: { $0.split(separator: ",").count == 6 }) else { return nil }
            numbers = run.split(separator: ",").compactMap { Int($0) }
        }
        guard numbers.count == 6, numbers.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return Endpoint(host: numbers[0...3].map(String.init).joined(separator: "."), port: numbers[4] * 256 + numbers[5])
    }

    /// Parses `229 Entering Extended Passive Mode (|||6446|)`; the delimiter may be any character.
    static func parseEPSV(_ message: String) -> Endpoint? {
        guard let open = message.firstIndex(of: "("), let close = message[open...].firstIndex(of: ")") else { return nil }
        let inner = message[message.index(after: open)..<close]
        guard let delimiter = inner.first else { return nil }
        let fields = inner.split(separator: delimiter, omittingEmptySubsequences: false)
        // "|||port|" -> ["", "", "", "port", ""]
        guard fields.count >= 5, let port = Int(fields[3]), (1...65535).contains(port) else { return nil }
        return Endpoint(host: nil, port: port)
    }

    /// True for addresses a server behind NAT commonly reports in PASV replies.
    static func isNonRoutable(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
