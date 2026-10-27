import Foundation

public protocol RemoteFileSystem: Sendable {
    func connect() async throws
    func list(_ path: String) async throws -> [RemoteItem]
    /// Resumes from the size of an existing partial local file when `resume` is true.
    func download(_ remote: String, to local: URL, progress: Progress, resume: Bool) async throws
    /// Resumes from the size of an existing partial remote file when `resume` is true.
    func upload(_ local: URL, to remote: String, progress: Progress, resume: Bool) async throws
    func mkdir(_ path: String) async throws
    func rename(_ from: String, _ to: String) async throws
    func delete(_ path: String, recursive: Bool) async throws
    /// No-op where unsupported.
    func chmod(_ path: String, mode: UInt16) async throws
    func homeDirectory() async throws -> String
    func disconnect() async
    /// Each access returns a new subscription to this connection's log.
    var logStream: AsyncStream<LogLine> { get }
    var supportsShell: Bool { get }
}

extension RemoteFileSystem {
    public func download(_ remote: String, to local: URL, progress: Progress) async throws {
        try await download(remote, to: local, progress: progress, resume: false)
    }

    public func upload(_ local: URL, to remote: String, progress: Progress) async throws {
        try await upload(local, to: remote, progress: progress, resume: false)
    }

    public func stat(_ path: String) async throws -> RemoteItem? {
        guard path != "/" else { return RemoteItem(name: "/", path: "/", isDirectory: true) }
        let name = RemotePath.lastComponent(of: path)
        return try await list(RemotePath.parent(of: path)).first { $0.name == name }
    }

    public func exists(_ path: String) async throws -> Bool {
        try await stat(path) != nil
    }
}

public enum RemoteError: Error, Equatable, CustomStringConvertible {
    case notConnected
    case authenticationFailed(String)
    case notFound(String)
    case permissionDenied(String)
    case protocolError(String)
    case serverRejected(code: Int, message: String)
    case unsupported(String)
    case invalidConfiguration(String)
    case hostKeyRejected(String)
    /// The server would not take another connection right now: connection limit, rate limit or a
    /// disconnect while connecting or logging in. Retrying later, or with fewer connections, may work.
    case connectionRefused(String)

    public var description: String {
        switch self {
        case .notConnected: "Not connected"
        case .authenticationFailed(let m): "Authentication failed: \(m)"
        case .notFound(let m): "Not found: \(m)"
        case .permissionDenied(let m): "Permission denied: \(m)"
        case .protocolError(let m): "Protocol error: \(m)"
        case .serverRejected(let code, let m): "Server replied \(code) \(m)"
        case .unsupported(let m): "Unsupported: \(m)"
        case .invalidConfiguration(let m): "Invalid configuration: \(m)"
        case .hostKeyRejected(let fingerprint): "Host key rejected (\(fingerprint))"
        case .connectionRefused(let m): "Connection refused: \(m)"
        }
    }

    /// True when `message` reads like a server-side connection limit or rate limit.
    public static func looksLikeConnectionLimit(_ message: String) -> Bool {
        let text = message.lowercased()
        return connectionLimitPhrases.contains { text.contains($0) }
    }

    private static let connectionLimitPhrases = [
        "too many connections", "too many users", "too many clients", "too many sessions", "too many logins",
        "too many concurrent", "too many from", "maximum number of clients", "max clients", "maximum connections",
        "connection limit", "connections from your", "rate limit", "rate-limit", "throttl", "try again later",
        "maxstartups", "too many authentication failures", "server is full", "server busy",
    ]

    /// Maps an unsuccessful FTP reply during connect or login to a refusal when it is one.
    static func ftpRefusal(code: Int, message: String) -> RemoteError? {
        if code == 421 || looksLikeConnectionLimit(message) && [421, 425, 426, 430, 530, 550].contains(code) {
            return .connectionRefused("\(code) \(message)")
        }
        return nil
    }
}

/// Shared helpers for backends that move bytes between a remote file and a local `URL`.
enum LocalFile {
    static let chunkSize = 128 * 1024

    static func size(of url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.uint64Value
    }
}
