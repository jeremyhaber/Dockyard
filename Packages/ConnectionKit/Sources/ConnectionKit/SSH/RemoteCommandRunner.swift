import Foundation

public enum SSHExecEvent: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
    case exit(Int32)
}

/// A backend that can run shell commands on the server (SFTP over SSH). FTP and cloud backends do not conform.
public protocol RemoteCommandRunner: Sendable {
    func exec(_ command: String) async throws -> SSHExecResult
    func execStream(_ command: String) async throws -> AsyncThrowingStream<SSHExecEvent, Error>
}

public enum ShellQuote {
    /// Quotes `text` for a POSIX shell: wrapped in single quotes, with embedded quotes escaped.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func quote(_ words: [String]) -> String { words.map(quote).joined(separator: " ") }
}
