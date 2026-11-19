import Foundation

/// How a text file is stored on disk, so the in-terminal editor can save it back the way it found it.
public struct TextFormat: Equatable, Sendable {
    public enum Encoding: Equatable, Sendable {
        case utf8
        /// Fallback for bytes that are not UTF-8: every byte maps to one character, so nothing is lost.
        case latin1
    }

    public enum LineEnding: Equatable, Sendable {
        case lf, crlf, cr

        public var token: String {
            switch self {
            case .lf: "\n"
            case .crlf: "\r\n"
            case .cr: "\r"
            }
        }

        public var label: String {
            switch self {
            case .lf: "LF"
            case .crlf: "CRLF"
            case .cr: "CR"
            }
        }
    }

    public var encoding: Encoding
    public var hasBOM: Bool
    public var lineEnding: LineEnding

    public init(encoding: Encoding = .utf8, hasBOM: Bool = false, lineEnding: LineEnding = .lf) {
        self.encoding = encoding
        self.hasBOM = hasBOM
        self.lineEnding = lineEnding
    }

    /// "UTF-8 · LF", "UTF-8 BOM · CRLF", "Latin-1 · LF".
    public var label: String {
        let name = switch encoding {
        case .utf8: hasBOM ? "UTF-8 BOM" : "UTF-8"
        case .latin1: "Latin-1"
        }
        return "\(name) \u{00B7} \(lineEnding.label)"
    }
}

/// A file's bytes turned into editable text (always with `\n` line breaks) and back.
public struct TextDocument: Equatable, Sendable {
    /// Files above this are not opened inline.
    public static let maxBytes = 10 * 1024 * 1024
    /// Syntax highlighting is skipped above this many bytes.
    public static let highlightLimit = 1024 * 1024

    public var text: String
    public var format: TextFormat
    /// True when the file mixed several line-ending styles. Saving an edited buffer then uses the dominant one.
    public let hadMixedLineEndings: Bool
    private let original: Data

    /// Nil for binary data (a NUL byte, or mostly control characters when it is not UTF-8).
    public static func decode(_ data: Data) -> TextDocument? {
        var body = data
        var bom = false
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            bom = true
            body = data.dropFirst(3)
        }
        if body.contains(0) { return nil }
        let encoding: TextFormat.Encoding
        var decoded: String
        if let utf8 = String(data: body, encoding: .utf8) {
            decoded = utf8
            encoding = .utf8
        } else {
            guard !looksBinary(body), let latin = String(data: body, encoding: .isoLatin1) else { return nil }
            decoded = latin
            encoding = .latin1
            bom = false
        }
        let (ending, mixed) = dominantLineEnding(in: body)
        if ending != .lf || mixed {
            decoded = decoded.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        return TextDocument(
            text: decoded, format: TextFormat(encoding: encoding, hasBOM: bom, lineEnding: ending),
            hadMixedLineEndings: mixed, original: data)
    }

    /// An empty buffer for a file that does not exist yet.
    public static func empty() -> TextDocument {
        TextDocument(text: "", format: TextFormat(), hadMixedLineEndings: false, original: Data())
    }

    /// The bytes to write for `edited`. An untouched buffer returns the original bytes exactly (even for files with
    /// mixed line endings). Text Latin-1 cannot hold switches the file to UTF-8, and the returned format says so.
    public func encode(_ edited: String) -> (data: Data, format: TextFormat) {
        if edited == text { return (original, format) }
        var out = format
        var body = edited
        if format.lineEnding != .lf { body = body.replacingOccurrences(of: "\n", with: format.lineEnding.token) }
        var bytes: Data
        if format.encoding == .latin1, let latin = body.data(using: .isoLatin1) {
            bytes = latin
        } else {
            out.encoding = .utf8
            bytes = Data(body.utf8)
        }
        if out.encoding == .utf8, out.hasBOM { bytes = Data([0xEF, 0xBB, 0xBF]) + bytes }
        return (bytes, out)
    }

    /// The buffer saved as `data`, so the next save compares against what is now on disk.
    public func rebased(on edited: String, data: Data, format: TextFormat) -> TextDocument {
        TextDocument(text: edited, format: format, hadMixedLineEndings: false, original: data)
    }

    private init(text: String, format: TextFormat, hadMixedLineEndings: Bool, original: Data) {
        self.text = text
        self.format = format
        self.hadMixedLineEndings = hadMixedLineEndings
        self.original = original
    }

    /// Counts CRLF, bare LF and bare CR; the most common wins (LF when there are none).
    static func dominantLineEnding(in data: Data) -> (TextFormat.LineEnding, mixed: Bool) {
        var crlf = 0, lf = 0, cr = 0
        var previous: UInt8 = 0
        for byte in data {
            if byte == 0x0A {
                if previous == 0x0D { crlf += 1; cr -= 1 } else { lf += 1 }
            } else if byte == 0x0D {
                cr += 1
            }
            previous = byte
        }
        let kinds = [crlf, lf, cr].filter { $0 > 0 }.count
        if crlf == 0, lf == 0, cr == 0 { return (.lf, false) }
        let best = max(crlf, lf, cr)
        let ending: TextFormat.LineEnding = best == lf ? .lf : (best == crlf ? .crlf : .cr)
        return (ending, kinds > 1)
    }

    /// Non-UTF-8 data where over 10% of the first 8 KB are control characters other than tab, line breaks, form feed
    /// and escape is treated as binary.
    private static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        guard !sample.isEmpty else { return false }
        let controls = sample.filter { $0 < 0x20 && ![0x09, 0x0A, 0x0D, 0x0C, 0x1B].contains($0) || $0 == 0x7F }.count
        return controls * 10 > sample.count
    }
}
