import Foundation

/// Strips the `DKYD-PID:<pid>:<pgid>` line that the supervising wrapper prints before the real command
/// runs, and passes everything else through.
struct ExecMarkerFilter {
    static let prefix = "DKYD-PID:"

    private(set) var pid: String?
    private(set) var pgid: String?
    private var pending = Data()
    private var finished = false
    private let dropPreamble: Bool

    /// With `dropPreamble`, bytes before the marker (su's password prompt) are discarded.
    init(dropPreamble: Bool) { self.dropPreamble = dropPreamble }

    mutating func feed(_ data: Data) -> Data {
        if finished { return data }
        pending.append(data)
        guard let range = pending.range(of: Data(Self.prefix.utf8)) else {
            if pending.count > 64 * 1024 { return flush() }
            return Data()
        }
        guard let newline = pending[range.upperBound...].firstIndex(of: UInt8(ascii: "\n")) else { return Data() }
        let line = String(decoding: pending[range.upperBound..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: ":").map(String.init)
        if parts.count == 2 { (pid, pgid) = (parts[0], parts[1]) }
        let before = dropPreamble ? Data() : Data(pending[..<range.lowerBound])
        let after = Data(pending[(newline + 1)...])
        finished = true
        pending = Data()
        return before + after
    }

    /// Releases buffered bytes when the stream ends without a marker.
    mutating func flush() -> Data {
        defer { pending = Data(); finished = true }
        return pending
    }
}

extension SSHSession {
    private static func supervised(_ command: String) -> String {
        let marker = "pg=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' '); printf '\(ExecMarkerFilter.prefix)%s:%s\\n' \"$$\" \"${pg:-$$}\""
        return "\(marker); exec sh -c \(ShellQuote.quote(command)) </dev/null"
    }

    /// Runs `command` under `sh -c` in a supervised process and streams its output, ending with the exit
    /// status. Cancelling the consuming task (or dropping the stream) sends TERM, then KILL, to the whole
    /// remote process group. With `elevation` the command runs as root through `su`/`sudo`.
    public func execStream(_ command: String, elevation: ShellElevation? = nil) -> AsyncThrowingStream<SSHExecEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<SSHExecEvent, Error>.makeStream()
        let task = Task { [self] in
            do {
                let status = try await runChannel(Self.supervised(command), elevation: elevation, supervise: true) { continuation.yield($0) }
                continuation.yield(.exit(status))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runChannel(
        _ script: String, elevation: ShellElevation?, supervise: Bool,
        onOutput: @escaping @Sendable (SSHExecEvent) -> Void
    ) async throws -> Int32 {
        let kind = elevation?.kind ?? .none
        let password = elevation?.password
        let channel = try await perform { session in
            let channel = try session.newChannel()
            do {
                let wrapped = "sh -c \(ShellQuote.quote(script))"
                switch kind {
                case .none:
                    try channel.exec(wrapped)
                case .sudo:
                    try channel.exec(password == nil ? "sudo -n \(wrapped)" : "sudo -S -p '' \(wrapped)")
                    if let password { try channel.write(Array((password + "\n").utf8)) }
                case .su:
                    try channel.requestPTY(cols: 200, rows: 24, term: "dumb")
                    try channel.exec("su root -c \(ShellQuote.quote("stty raw -echo; " + wrapped))")
                }
                if kind != .su { try channel.sendEOF() }
            } catch {
                channel.close()
                throw error
            }
            return channel
        }

        var filter = ExecMarkerFilter(dropPreamble: kind == .su)
        var promptAnswered = kind != .su
        do {
            while true {
                if supervise, Task.isCancelled {
                    await kill(filter, elevation: elevation)
                    try? await perform { _ in channel.close() }
                    throw CancellationError()
                }
                let chunk = try await perform { _ in try channel.readSome(wait: 0.2) }
                if !chunk.stdout.isEmpty {
                    if !promptAnswered, let password, String(decoding: chunk.stdout, as: UTF8.self).lowercased().contains("assword") {
                        promptAnswered = true
                        try await perform { _ in try channel.write(Array((password + "\n").utf8)) }
                    }
                    let data = supervise ? filter.feed(chunk.stdout) : chunk.stdout
                    if !data.isEmpty { onOutput(.stdout(data)) }
                }
                if !chunk.stderr.isEmpty { onOutput(.stderr(chunk.stderr)) }
                if chunk.isEOF { break }
            }
            if supervise {
                let rest = filter.flush()
                if !rest.isEmpty { onOutput(.stdout(rest)) }
            }
            return try await perform { _ in try channel.closeAndExitStatus() }
        } catch {
            try? await perform { _ in channel.close() }
            throw error
        }
    }

    /// Sends TERM, waits up to two seconds, then KILL, to the process group the wrapper reported.
    private func kill(_ filter: ExecMarkerFilter, elevation: ShellElevation?) async {
        guard let pid = filter.pid, let pgid = filter.pgid,
              pid.allSatisfy(\.isNumber), pgid.allSatisfy(\.isNumber) else { return }
        let script = """
        kill -s TERM -- -\(pgid) 2>/dev/null; kill -s TERM \(pid) 2>/dev/null; i=0
        while [ $i -lt 20 ] && kill -0 \(pid) 2>/dev/null; do sleep 0.1; i=$((i+1)); done
        if kill -0 \(pid) 2>/dev/null; then kill -s KILL -- -\(pgid) 2>/dev/null; kill -s KILL \(pid) 2>/dev/null; fi
        true
        """
        log(.status, "Cancelling remote process group \(pgid)")
        _ = try? await runChannel(script, elevation: elevation, supervise: false) { _ in }
    }
}
