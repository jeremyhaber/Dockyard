import Foundation

/// An interactive PTY shell on an `SSHSession`, for the terminal drawer.
public final class ShellChannel: @unchecked Sendable {
    /// Raw terminal output (stdout and stderr merged by the PTY). Finishes when the shell exits.
    public let output: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private let session: SSHSession
    private let channel: SSHChannel
    private var assistant: ElevationAssistant?
    private var isFinished = false

    // Created on the session queue by `SSHSession.openShell`.
    init(session: SSHSession, channel: SSHChannel, elevation: ShellElevation?, runAs: String? = nil) {
        (output, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.session = session
        self.channel = channel
        if let runAs {
            // Logged in as root: root's su needs no password.
            try? channel.write(Array("exec su -s /bin/bash - \(runAs)\n".utf8))
            session.log(.status, "Switching the shell to \(runAs)")
        } else if let elevation, elevation.kind != .none {
            let command = elevation.kind == .su ? "su -" : "sudo -i"
            if let password = elevation.password, !password.isEmpty {
                assistant = ElevationAssistant(command: command, password: password)
            } else {
                session.log(.warning, "No elevation password stored; run \(command) manually")
            }
            if assistant != nil {
                try? channel.write(Array((command + "\n").utf8))
                session.log(.status, "Elevating shell with \(command)")
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await session.perform { [channel] _ in try channel.write(data) }
    }

    public func resize(cols: Int, rows: Int) async throws {
        try await session.perform { [channel] _ in try channel.resizePTY(cols: cols, rows: rows) }
    }

    public func close() async {
        try? await session.perform { [self] _ in finish() }
    }

    // MARK: Session queue

    /// Moves pending output into the stream. Returns true when data arrived.
    func pump() -> Bool {
        guard !isFinished else { return false }
        var active = false
        do {
            for stream: Int32 in [0, 1] {
                while let data = try channel.readNow(stream: stream) {
                    active = true
                    continuation.yield(data)
                    feedAssistant(data)
                }
            }
            tickAssistant()
            if channel.isEOF { finish() }
        } catch {
            finish()
        }
        return active
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        continuation.finish()
        channel.close()
    }

    private func feedAssistant(_ data: Data) {
        guard assistant != nil else { return }
        let action = assistant?.feed(String(decoding: data, as: UTF8.self))
        apply(action)
    }

    private func tickAssistant() {
        guard assistant != nil else { return }
        apply(assistant?.tick())
    }

    private func apply(_ action: ElevationAssistant.Action?) {
        switch action {
        case .sendPassword(let line):
            try? channel.write(Array(line.utf8))
            session.log(.status, "Sent elevation password")
        case .succeeded(let command):
            session.log(.status, "Shell elevated with \(command)")
            assistant = nil
        case .failed(let reason):
            session.log(.warning, "Shell elevation failed: \(reason)")
            assistant = nil
        case nil:
            break
        }
    }
}

/// Watches shell output for a password prompt after `su -` / `sudo -i` and answers it once.
/// The password is only ever written to the channel; it is never logged or echoed (the PTY has echo off).
struct ElevationAssistant {
    enum Action {
        case sendPassword(String)
        case succeeded(String)
        case failed(String)
    }

    let command: String
    private let password: String
    private var lastLine = ""
    private var sentAt: Date?
    private var recent = ""
    private let started = Date()

    init(command: String, password: String) {
        self.command = command
        self.password = password
    }

    mutating func feed(_ text: String) -> Action? {
        let lowered = text.lowercased()
        if sentAt == nil {
            for scalar in lowered {
                if scalar == "\n" || scalar == "\r" { lastLine = "" } else { lastLine.append(scalar) }
            }
            let line = lastLine.trimmingCharacters(in: .whitespaces)
            if line.contains("password"), line.hasSuffix(":") {
                sentAt = Date()
                lastLine = ""
                return .sendPassword(password + "\n")
            }
            return nil
        }
        recent = String((recent + lowered).suffix(300))
        for phrase in ["sorry, try again", "authentication failure", "incorrect password", "permission denied"] where recent.contains(phrase) {
            return .failed(phrase)
        }
        return nil
    }

    mutating func tick() -> Action? {
        if let sentAt {
            return Date().timeIntervalSince(sentAt) > 2 ? .succeeded(command) : nil
        }
        return Date().timeIntervalSince(started) > 10 ? .failed("no password prompt appeared") : nil
    }
}
