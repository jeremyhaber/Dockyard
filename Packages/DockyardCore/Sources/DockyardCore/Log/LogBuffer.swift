import Foundation
import ConnectionKit

/// Last line of defence against secrets in logs. Backends already avoid logging passwords; this catches mistakes.
public enum LogSanitizer {
    public static let mask = "****"

    private static let rulesBox = LockedBox<[(NSRegularExpression, String)]>({
        func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
        return [
            // ftp://user:secret@host
            (rx(#"(://[^/\s:@]+:)[^@\s/]+(@)"#), "$1\(mask)$2"),
            // Authorization: whm root:TOKEN / Bearer abc / Basic abc  (rest of line)
            (rx(#"(authorization\s*[:=]\s*).*"#), "$1\(mask)"),
            (rx(#"\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#), "$1 \(mask)"),
            // PASS secret / ACCT secret at the start of an FTP command
            (rx(#"^(\s*(?:command:\s*)?(?:PASS|ACCT|ADAT)\s+).+$"#), "$1\(mask)"),
            // password=..., "password": "...", passphrase: ..., token=..., secret, api_key
            (rx(#"("?\b(?:password|passwd|pwd|passphrase|pass|token|secret|api[_-]?key|access[_-]?key)"?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s&,;"']+)"#), "$1\(mask)"),
        ]
    }())

    public static func redact(_ message: String, secrets: [String] = []) -> String {
        var out = message
        for s in secrets where s.count >= 3 { out = out.replacingOccurrences(of: s, with: mask) }
        let rules = rulesBox.withLock { $0 }
        for (regex, template) in rules {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: template)
        }
        return out
    }
}

public struct LogCounts: Sendable, Equatable {
    public var total = 0
    public var errors = 0
    public var warnings = 0
}

public enum LogFormat {
    public static func kindTitle(_ kind: LogLine.Kind) -> String { kind.rawValue.prefix(1).uppercased() + kind.rawValue.dropFirst() }

    private static func formatter(_ pattern: String, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = pattern
        return f
    }

    /// `14:03:11  Command: PASV`
    public static func line(_ l: LogLine, timeZone: TimeZone = .current) -> String {
        "\(formatter("HH:mm:ss", timeZone).string(from: l.time))  \(kindTitle(l.kind)): \(l.message)"
    }

    /// `2026-10-27 14:03:11  Command: PASV` for files.
    public static func fileLine(_ l: LogLine, timeZone: TimeZone = .current) -> String {
        "\(formatter("yyyy-MM-dd HH:mm:ss", timeZone).string(from: l.time))  \(kindTitle(l.kind)): \(l.message)"
    }
}

/// Per-connection log: bounded ring buffer, counts, copy-as-text and an optional rolling file.
public final class LogBuffer: Sendable {
    public static let defaultCapacity = 5_000

    private struct State {
        var ring: [LogLine?]
        var head = 0       // index of oldest
        var count = 0
        var counts = LogCounts()
        var secrets: [String] = []
        var continuations: [UUID: AsyncStream<LogCounts>.Continuation] = [:]
    }

    public let capacity: Int
    private let state: LockedBox<State>
    private let fileWriter: RollingLogFileWriter?

    public init(capacity: Int = LogBuffer.defaultCapacity, fileWriter: RollingLogFileWriter? = nil) {
        self.capacity = max(1, capacity)
        self.state = LockedBox(State(ring: Array(repeating: nil, count: max(1, capacity))))
        self.fileWriter = fileWriter
    }

    /// Anything registered here is masked wherever it shows up in later lines.
    public func registerSecret(_ secret: String) {
        state.withLock { if !secret.isEmpty { $0.secrets.append(secret) } }
    }

    public func append(_ kind: LogLine.Kind, _ message: String, time: Date = Date()) {
        append(LogLine(time: time, kind: kind, message: message))
    }

    public func append(_ line: LogLine) {
        let (counts, targets, clean): (LogCounts, [AsyncStream<LogCounts>.Continuation], LogLine) = state.withLock { s in
            var clean = line
            clean.message = LogSanitizer.redact(line.message, secrets: s.secrets)
            if s.count == s.ring.count {
                if let old = s.ring[s.head] { Self.adjust(&s.counts, old, -1) }
                s.ring[s.head] = clean
                s.head = (s.head + 1) % s.ring.count
            } else {
                s.ring[(s.head + s.count) % s.ring.count] = clean
                s.count += 1
            }
            Self.adjust(&s.counts, clean, +1)
            return (s.counts, Array(s.continuations.values), clean)
        }
        fileWriter?.write(clean)
        for c in targets { c.yield(counts) }
    }

    private static func adjust(_ c: inout LogCounts, _ line: LogLine, _ d: Int) {
        c.total += d
        if line.kind == .error { c.errors += d }
        if line.kind == .warning { c.warnings += d }
    }

    public func lines(errorsOnly: Bool = false) -> [LogLine] {
        state.withLock { s in
            let all = (0..<s.count).compactMap { s.ring[(s.head + $0) % s.ring.count] }
            return errorsOnly ? all.filter { $0.kind == .error } : all
        }
    }

    public var counts: LogCounts { state.withLock { $0.counts } }

    public func clear() {
        let targets = state.withLock { s -> [AsyncStream<LogCounts>.Continuation] in
            s.ring = Array(repeating: nil, count: s.ring.count)
            s.head = 0; s.count = 0; s.counts = LogCounts()
            return Array(s.continuations.values)
        }
        for c in targets { c.yield(LogCounts()) }
    }

    /// The text the Copy button puts on the pasteboard.
    public func copyText(errorsOnly: Bool = false, timeZone: TimeZone = .current) -> String {
        lines(errorsOnly: errorsOnly).map { LogFormat.line($0, timeZone: timeZone) }.joined(separator: "\n")
    }

    /// Emits updated counts (for the transfer bar's Log button) after every line.
    public func updates() -> AsyncStream<LogCounts> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<LogCounts>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { s in
            s.continuations[key] = continuation
            continuation.yield(s.counts)
        }
        continuation.onTermination = { [state] _ in state.withLock { _ = $0.continuations.removeValue(forKey: key) } }
        return stream
    }

    /// Feeds the buffer from a backend's `logStream` until the stream ends or the task is cancelled.
    @discardableResult
    public func attach(to stream: AsyncStream<LogLine>) -> Task<Void, Never> {
        Task { [self] in for await line in stream { append(line) } }
    }
}

/// Writes log lines to `<directory>/<name>.log`, rotating at `maxBytes` and keeping `maxFiles` files.
public final class RollingLogFileWriter: Sendable {
    private struct State {
        var handle: FileHandle?
        var size: Int = 0
        var lastError: String?
    }
    public let directory: URL
    public let baseName: String
    public let maxBytes: Int
    public let maxFiles: Int
    private let timeZone: TimeZone
    private let state = LockedBox(State())

    public init(directory: URL, name: String, maxBytes: Int = 1_000_000, maxFiles: Int = 5, timeZone: TimeZone = .current) {
        self.directory = directory
        self.baseName = Self.safeName(name)
        self.maxBytes = max(256, maxBytes)
        self.maxFiles = max(1, maxFiles)
        self.timeZone = timeZone
    }

    deinit { state.withLock { try? $0.handle?.close() } }

    public var currentFile: URL { directory.appendingPathComponent("\(baseName).log") }
    public var lastError: String? { state.withLock { $0.lastError } }

    /// Files from newest to oldest.
    public var allFiles: [URL] {
        (0..<maxFiles).map { $0 == 0 ? currentFile : directory.appendingPathComponent("\(baseName).\($0).log") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func write(_ line: LogLine) {
        let data = Data((LogFormat.fileLine(line, timeZone: timeZone) + "\n").utf8)
        state.withLock { s in
            do {
                if s.handle == nil { try open(&s) }
                if s.size + data.count > maxBytes, s.size > 0 { try rotate(&s) }
                try s.handle?.write(contentsOf: data)
                s.size += data.count
            } catch {
                s.lastError = error.localizedDescription
                try? s.handle?.close()
                s.handle = nil
            }
        }
    }

    private func open(_ s: inout State) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: currentFile.path) { _ = fm.createFile(atPath: currentFile.path, contents: nil) }
        let h = try FileHandle(forWritingTo: currentFile)
        s.size = Int(try h.seekToEnd())
        s.handle = h
    }

    private func rotate(_ s: inout State) throws {
        try s.handle?.close()
        s.handle = nil
        let fm = FileManager.default
        func file(_ i: Int) -> URL { i == 0 ? currentFile : directory.appendingPathComponent("\(baseName).\(i).log") }
        try? fm.removeItem(at: file(maxFiles - 1))
        for i in stride(from: maxFiles - 2, through: 0, by: -1) where fm.fileExists(atPath: file(i).path) {
            try fm.moveItem(at: file(i), to: file(i + 1))
        }
        if maxFiles == 1 { try? fm.removeItem(at: currentFile) }
        try open(&s)
    }

    static func safeName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\0").union(.controlCharacters)
        let cleaned = name.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) }
        let s = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return s.isEmpty ? "connection" : s
    }
}
