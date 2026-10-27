import Citadel
import Foundation
import NIOCore

/// SFTP over SSH using Citadel.
public actor SFTPFileSystem: RemoteFileSystem {
    public nonisolated let config: ConnectionConfig
    private let secrets: SecretStore
    private let hostKeyValidator: SSHHostKeyValidator
    private let hub = LogHub()

    private var ssh: Boxed<SSHClient>?
    private var sftp: Boxed<SFTPClient>?

    private static let chunkSize = 64 * 1024

    public nonisolated var logStream: AsyncStream<LogLine> { hub.stream() }
    public nonisolated var supportsShell: Bool { true }

    public init(
        config: ConnectionConfig,
        secrets: SecretStore,
        hostKeyValidator: SSHHostKeyValidator = .acceptAnything()
    ) {
        self.config = config
        self.secrets = secrets
        self.hostKeyValidator = hostKeyValidator
    }

    // MARK: Connection

    public func connect() async throws {
        await disconnectQuietly()
        hub.emit(.status, "Connecting to \(config.host):\(config.port)...")
        do {
            let attempts = try await loadAttempts()
            var lastError: Error = RemoteError.authenticationFailed("No authentication method available")
            for (index, attempt) in attempts.enumerated() {
                hub.emit(.status, "Authenticating as \(config.username) using \(attempt.label)")
                let username = config.username
                let method = attempt.method
                let settings = SSHClientSettings(
                    host: config.host,
                    port: config.port,
                    authenticationMethod: { method(username) },
                    hostKeyValidator: hostKeyValidator
                )
                do {
                    ssh = Boxed(try await SSHClient.connect(to: settings))
                    hub.emit(.status, "Authenticated with \(attempt.label)")
                    lastError = RemoteError.notConnected
                    break
                } catch where SSHAuthAttempt.isRejection(error) {
                    lastError = RemoteError.authenticationFailed("The server rejected \(attempt.label) authentication")
                    let next = index + 1 < attempts.count ? "; trying \(attempts[index + 1].label)" : ""
                    hub.emit(.warning, "\(attempt.label.prefix(1).uppercased() + attempt.label.dropFirst()) authentication rejected\(next)")
                }
            }
            guard ssh != nil else { throw lastError }
            try await openChannel()
            hub.emit(.status, "SFTP subsystem ready")
        } catch {
            hub.emit(.error, "Connection failed: \(error)")
            await disconnectQuietly()
            throw error
        }
    }

    public func disconnect() async {
        await disconnectQuietly()
        hub.emit(.status, "Disconnected")
    }

    private func disconnectQuietly() async {
        try? await sftp?.value.close()
        try? await ssh?.value.close()
        sftp = nil
        ssh = nil
    }

    private func loadAttempts() async throws -> [SSHAuthAttempt] {
        var attempts: [SSHAuthAttempt] = []
        if config.authMethods.contains(.key) {
            guard let keyPath = config.keyPath else { throw RemoteError.invalidConfiguration("Key authentication needs a key path") }
            let passphrase = try await secrets.secret(for: config.id, purpose: .keyPassphrase)
            attempts.append(try .key(path: keyPath, passphrase: passphrase))
        }
        if config.authMethods.contains(.password) {
            if let password = try await secrets.secret(for: config.id, purpose: .password) {
                attempts.append(.password(password))
            } else if attempts.isEmpty {
                throw RemoteError.authenticationFailed("No password stored for this connection")
            }
        }
        guard !attempts.isEmpty else { throw RemoteError.invalidConfiguration("No authentication method selected") }
        return attempts
    }

    private func openChannel() async throws {
        guard let ssh else { throw RemoteError.notConnected }
        try? await sftp?.value.close()
        sftp = Boxed(try await ssh.value.openSFTP())
    }

    private func client() throws -> Boxed<SFTPClient> {
        guard let sftp, sftp.value.isActive else { throw RemoteError.notConnected }
        return sftp
    }

    private func withFile<R>(_ file: Boxed<SFTPFile>, _ body: () async throws -> R) async throws -> R {
        do {
            let result = try await body()
            try await file.value.close()
            return result
        } catch {
            try? await file.value.close()
            throw error
        }
    }

    // MARK: Listing

    public func homeDirectory() async throws -> String {
        try await client().value.getRealPath(atPath: ".")
    }

    public func list(_ path: String) async throws -> [RemoteItem] {
        let sftp = try client().value
        hub.emit(.status, "Listing directory \(path)")
        let dir = path.isEmpty ? "." : path

        let names: [SFTPMessage.Name]
        do {
            names = try await sftp.listDirectory(atPath: dir)
        } catch {
            throw map(error, path: dir)
        }

        var items: [RemoteItem] = []
        for component in names.flatMap(\.components) where component.filename != "." && component.filename != ".." {
            var item = Self.item(from: component, parent: dir)
            if item.isSymlink, let target = try? await sftp.getAttributes(at: item.path) {
                item.isDirectory = Self.isDirectory(target.permissions)
            }
            items.append(item)
        }
        hub.emit(.status, "Directory listing of \(dir) successful (\(items.count) items)")
        return items
    }

    public func stat(_ path: String) async throws -> RemoteItem? {
        let sftp = try client().value
        do {
            let attributes = try await sftp.getAttributes(at: path)
            return Self.item(name: RemotePath.lastComponent(of: path), path: path, attributes: attributes, symlinkTarget: nil)
        } catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile {
            return nil
        } catch {
            throw map(error, path: path)
        }
    }

    private static let fileTypeMask: UInt32 = 0o170000

    private static func isDirectory(_ permissions: UInt32?) -> Bool {
        permissions.map { $0 & fileTypeMask == 0o040000 } ?? false
    }

    private static func item(from component: SFTPPathComponent, parent: String) -> RemoteItem {
        var target: String?
        if component.attributes.permissions.map({ $0 & fileTypeMask == 0o120000 }) == true {
            target = component.longname.range(of: " -> ", options: .backwards).map { String(component.longname[$0.upperBound...]) } ?? ""
        }
        return item(name: component.filename, path: RemotePath.join(parent, component.filename), attributes: component.attributes, symlinkTarget: target)
    }

    private static func item(name: String, path: String, attributes: SFTPFileAttributes, symlinkTarget: String?) -> RemoteItem {
        RemoteItem(
            name: name,
            path: path,
            isDirectory: isDirectory(attributes.permissions),
            size: attributes.size,
            modified: attributes.accessModificationTime?.modificationTime,
            permissions: attributes.permissions.map { UInt16($0 & 0o7777) },
            symlinkTarget: symlinkTarget
        )
    }

    // MARK: Transfers

    public func download(_ remote: String, to local: URL, progress: Progress, resume: Bool) async throws {
        let sftp = try client().value
        do {
            let file = Boxed(try await sftp.openFile(filePath: remote, flags: .read))
            try await withFile(file) {
                let total = try await file.value.readAttributes().size
                var offset: UInt64 = 0
                if resume, let existing = LocalFile.size(of: local), existing > 0, total == nil || existing < total! {
                    offset = existing
                }
                if let total, total > 0, LocalFile.size(of: local) == total, resume {
                    progress.totalUnitCount = Int64(total)
                    progress.completedUnitCount = Int64(total)
                    return
                }
                if offset == 0 { _ = FileManager.default.createFile(atPath: local.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: local)
                defer { try? handle.close() }
                try handle.truncate(atOffset: offset)
                try handle.seek(toOffset: offset)

                progress.totalUnitCount = Int64(total ?? 0)
                progress.completedUnitCount = Int64(offset)
                hub.emit(.status, "get \(remote)\(offset > 0 ? " (resuming at \(offset))" : "")")

                while true {
                    try Task.checkCancellation()
                    if progress.isCancelled { throw CancellationError() }
                    var chunk = try await file.value.read(from: offset, length: UInt32(Self.chunkSize))
                    guard chunk.readableBytes > 0 else { break }
                    let bytes = chunk.readBytes(length: chunk.readableBytes) ?? []
                    try handle.write(contentsOf: bytes)
                    offset += UInt64(bytes.count)
                    progress.completedUnitCount = Int64(offset)
                }
                hub.emit(.status, "get \(remote) finished (\(offset) bytes)")
            }
        } catch {
            hub.emit(.error, "Download of \(remote) failed: \(error)")
            throw map(error, path: remote)
        }
    }

    public func upload(_ local: URL, to remote: String, progress: Progress, resume: Bool) async throws {
        let sftp = try client().value
        guard let total = LocalFile.size(of: local) else { throw RemoteError.notFound(local.path) }
        do {
            var offset: UInt64 = 0
            if resume, let existing = try await stat(remote)?.size, existing > 0, existing <= total {
                offset = existing
            }
            progress.totalUnitCount = Int64(total)
            progress.completedUnitCount = Int64(offset)
            hub.emit(.status, "put \(remote)\(offset > 0 ? " (resuming at \(offset))" : "")")

            let flags: SFTPOpenFileFlags = offset > 0 ? [.write] : [.write, .create, .truncate]
            let file = Boxed(try await sftp.openFile(filePath: remote, flags: flags))
            try await withFile(file) {
                let handle = try FileHandle(forReadingFrom: local)
                defer { try? handle.close() }
                try handle.seek(toOffset: offset)

                while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                    try Task.checkCancellation()
                    if progress.isCancelled { throw CancellationError() }
                    try await file.value.write(ByteBuffer(bytes: chunk), at: offset)
                    offset += UInt64(chunk.count)
                    progress.completedUnitCount = Int64(offset)
                }
                hub.emit(.status, "put \(remote) finished (\(offset) bytes)")
            }
        } catch {
            hub.emit(.error, "Upload of \(remote) failed: \(error)")
            throw map(error, path: remote)
        }
    }

    // MARK: Namespace operations

    public func mkdir(_ path: String) async throws {
        hub.emit(.status, "mkdir \(path)")
        do { try await client().value.createDirectory(atPath: path) } catch { throw map(error, path: path) }
    }

    public func rename(_ from: String, _ to: String) async throws {
        hub.emit(.status, "rename \(from) -> \(to)")
        do { try await client().value.rename(at: from, to: to) } catch { throw map(error, path: from) }
    }

    public func delete(_ path: String, recursive: Bool) async throws {
        let sftp = try client().value
        hub.emit(.status, "rm\(recursive ? " -r" : "") \(path)")
        do {
            try await remove(path, recursive: recursive, on: sftp)
        } catch {
            throw map(error, path: path)
        }
    }

    /// Uses the directory listing (lstat semantics) so symlinks are removed, never followed.
    private func remove(_ path: String, recursive: Bool, on sftp: SFTPClient) async throws {
        let parent = RemotePath.parent(of: path)
        let name = RemotePath.lastComponent(of: path)
        let entry = try await sftp.listDirectory(atPath: parent).flatMap(\.components).first { $0.filename == name }
        guard let entry else { throw RemoteError.notFound(path) }

        if Self.isDirectory(entry.attributes.permissions) {
            if recursive {
                for child in try await sftp.listDirectory(atPath: path).flatMap(\.components) where child.filename != "." && child.filename != ".." {
                    try await remove(RemotePath.join(path, child.filename), recursive: true, on: sftp)
                }
            }
            try await client().value.rmdir(at: path)
        } else {
            try await sftp.remove(at: path)
        }
    }

    public func chmod(_ path: String, mode: UInt16) async throws {
        hub.emit(.status, "chmod \(String(mode & 0o7777, radix: 8)) \(path)")
        var attributes = SFTPFileAttributes()
        attributes.permissions = UInt32(mode & 0o7777)
        do { try await client().value.setAttributes(at: path, to: attributes) } catch { throw map(error, path: path) }
    }

    private func map(_ error: Error, path: String) -> Error {
        if let status = error as? SFTPMessage.Status {
            switch status.errorCode {
            case .noSuchFile: return RemoteError.notFound(path)
            case .permissionDenied: return RemoteError.permissionDenied(path)
            default: return RemoteError.protocolError(status.message)
            }
        }
        return error
    }
}
