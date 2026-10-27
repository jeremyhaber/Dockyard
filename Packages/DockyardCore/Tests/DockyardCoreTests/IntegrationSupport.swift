import Foundation
import ConnectionKit

/// Real servers from `Packages/ConnectionKit/scripts/integration-servers.sh`. Skipped unless DOCKYARD_INTEGRATION=1.
enum IT {
    static let enabled = ProcessInfo.processInfo.environment["DOCKYARD_INTEGRATION"] == "1"
    static let host = ProcessInfo.processInfo.environment["DOCKYARD_HOST"] ?? "127.0.0.1"
    static let user = "dockyard"
    static let password = "dockyard-test-pw"

    static func sftp() async throws -> SFTPFileSystem {
        let config = ConnectionConfig(protocol: .sftp, host: host, port: 2222, username: user, authMethods: .password)
        let secrets = InMemorySecretStore()
        await secrets.setSecret(password, for: config.id, purpose: .password)
        let fs = SFTPFileSystem(config: config, secrets: secrets)
        try await fs.connect()
        return fs
    }

    static func ftp(port: Int = 2121) async throws -> FTPFileSystem {
        let config = ConnectionConfig(protocol: .ftp, host: host, port: port, username: user, authMethods: .password)
        let secrets = InMemorySecretStore()
        await secrets.setSecret(password, for: config.id, purpose: .password)
        let fs = FTPFileSystem(config: config, secrets: secrets)
        try await fs.connect()
        return fs
    }

    /// A unique scratch folder under the account's home.
    static func scratch(_ fs: any RemoteFileSystem, _ label: String) async throws -> String {
        let home = try await fs.homeDirectory()
        let path = RemotePath.join(home, "it-\(label)-\(UUID().uuidString.prefix(8))")
        try await fs.mkdir(path)
        return path
    }

    static func upload(_ fs: any RemoteFileSystem, _ text: String, to remote: String) async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("it-\(UUID().uuidString)")
        try text.write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }
        try await fs.upload(temp, to: remote, progress: Progress(totalUnitCount: 0))
    }

    static func download(_ fs: any RemoteFileSystem, _ remote: String) async throws -> String {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await fs.download(remote, to: temp, progress: Progress(totalUnitCount: 0))
        return try String(contentsOf: temp, encoding: .utf8)
    }
}

/// Forwards everything to `inner` but makes `rename` fail, so the safety net has to copy.
struct RenameFailingFileSystem: RemoteFileSystem, RemoteCommandRunner {
    let inner: SFTPFileSystem
    var logStream: AsyncStream<LogLine> { inner.logStream }
    var supportsShell: Bool { true }
    func connect() async throws { try await inner.connect() }
    func disconnect() async { await inner.disconnect() }
    func homeDirectory() async throws -> String { try await inner.homeDirectory() }
    func list(_ path: String) async throws -> [RemoteItem] { try await inner.list(path) }
    func stat(_ path: String) async throws -> RemoteItem? { try await inner.stat(path) }
    func download(_ remote: String, to local: URL, progress: Progress, resume: Bool) async throws {
        try await inner.download(remote, to: local, progress: progress, resume: resume)
    }
    func upload(_ local: URL, to remote: String, progress: Progress, resume: Bool) async throws {
        try await inner.upload(local, to: remote, progress: progress, resume: resume)
    }
    func mkdir(_ path: String) async throws { try await inner.mkdir(path) }
    func rename(_ from: String, _ to: String) async throws { throw RemoteError.protocolError("cross-device link") }
    func delete(_ path: String, recursive: Bool) async throws { try await inner.delete(path, recursive: recursive) }
    func chmod(_ path: String, mode: UInt16) async throws { try await inner.chmod(path, mode: mode) }
    func exec(_ command: String) async throws -> SSHExecResult { try await inner.exec(command) }
    func execStream(_ command: String) async throws -> AsyncThrowingStream<SSHExecEvent, Error> { try await inner.execStream(command) }
}
