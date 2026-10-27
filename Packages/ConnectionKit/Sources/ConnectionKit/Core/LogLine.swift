import Foundation

public struct LogLine: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case status, command, response, warning, error
    }

    public var time: Date
    public var kind: Kind
    public var message: String

    public init(time: Date = Date(), kind: Kind, message: String) {
        self.time = time
        self.kind = kind
        self.message = message
    }
}

/// Fan-out for log lines. Every `stream()` call returns an independent subscription.
public final class LogHub: Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<LogLine>.Continuation] = [:]
    }

    private let state = LockedBox(State())

    public init() {}

    public func stream() -> AsyncStream<LogLine> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LogLine>.makeStream(bufferingPolicy: .unbounded)
        state.withLock { $0.continuations[id] = continuation }
        continuation.onTermination = { [state] _ in
            state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    public func emit(_ kind: LogLine.Kind, _ message: String) {
        let line = LogLine(kind: kind, message: message)
        let targets = state.withLock { Array($0.continuations.values) }
        for continuation in targets { continuation.yield(line) }
    }

    public func finish() {
        let targets = state.withLock { state -> [AsyncStream<LogLine>.Continuation] in
            defer { state.continuations.removeAll() }
            return Array(state.continuations.values)
        }
        for continuation in targets { continuation.finish() }
    }
}

/// Minimal lock-protected value (avoids requiring the macOS 15 `Mutex`).
public final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

public enum LogRedactor {
    /// Replaces secrets in an FTP command line (`PASS`, `ACCT`, `ADAT`) with `****`.
    public static func redactFTPCommand(_ line: String) -> String {
        let verb = line.prefix(while: { $0 != " " }).uppercased()
        guard ["PASS", "ACCT", "ADAT"].contains(verb), line.contains(" ") else { return line }
        return line.prefix(while: { $0 != " " }) + " ****"
    }
}
