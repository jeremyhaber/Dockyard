import Foundation

public enum SSHExecEvent: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
    case exit(Int32)
}

/// A backend that can run shell commands on the server (SFTP over SSH). FTP and cloud backends do not conform.
public protocol RemoteCommandRunner: Sendable {
    /// Runs a command to completion and collects its output.
    func exec(_ command: String) async throws -> SSHExecResult

    /// Runs a command and streams stdout, stderr and finally the exit status. Cancelling the consuming
    /// task (or dropping the stream) kills the remote process group. With `elevated` the command runs as
    /// root through the connection's `su`/`sudo` setting, when one is configured.
    func execStream(_ command: String, elevated: Bool) async throws -> AsyncThrowingStream<SSHExecEvent, Error>

    /// True when an `elevated` command would really run as root (browsing as root with a configured `su`/`sudo`).
    var canElevateCommands: Bool { get async }
}

public extension RemoteCommandRunner {
    var canElevateCommands: Bool { get async { false } }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<SSHExecEvent, Error> {
        try await execStream(command, elevated: false)
    }

    /// Runs a command, passing output chunks to `onOutput` as they arrive, and returns the exit status.
    /// Cancelling the calling task kills the remote process group and throws `CancellationError`.
    func runCommand(
        _ command: String, elevated: Bool = false,
        onOutput: @escaping @Sendable (_ isStderr: Bool, Data) -> Void
    ) async throws -> Int32 {
        var status: Int32?
        for try await event in try await execStream(command, elevated: elevated) {
            switch event {
            case .stdout(let data): onOutput(false, data)
            case .stderr(let data): onOutput(true, data)
            case .exit(let code): status = code
            }
        }
        try Task.checkCancellation()
        guard let status else { throw RemoteError.protocolError("The command ended without an exit status") }
        return status
    }
}
