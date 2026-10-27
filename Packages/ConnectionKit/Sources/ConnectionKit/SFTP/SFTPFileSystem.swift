import Foundation

/// SFTP over SSH using libssh2 for the transport and `SFTPClient` for the protocol.
public actor SFTPFileSystem: RemoteFileSystem, RemoteCommandRunner {
    public struct Options: Sendable {
        /// Start `sftp-server` as root through the configured `su`/`sudo` elevation. Falls back to the
        /// normal user (with a warning in the log) when elevation fails.
        public var browseAsRoot = false
        public var session = SSHSessionOptions()
        /// Hosts to tunnel through, outermost first. Each hop is an SSH connection of its own.
        public var jumpHosts: [SSHJumpHop] = []

        public init(browseAsRoot: Bool = false) { self.browseAsRoot = browseAsRoot }
    }

    public nonisolated let config: ConnectionConfig
    private let secrets: SecretStore
    private let hostKeyValidator: SSHHostKeyValidator
    private let options: Options
    private let hub = LogHub()

    private var ssh: SSHSession?
    private var sftp: SFTPClient?
    public private(set) var isBrowsingAsRoot = false

    public nonisolated var logStream: AsyncStream<LogLine> { hub.stream() }
    public nonisolated var supportsShell: Bool { true }

    public init(
        config: ConnectionConfig,
        secrets: SecretStore,
        hostKeyValidator: SSHHostKeyValidator = .acceptAnything(),
        options: Options = Options()
    ) {
        self.config = config
        self.secrets = secrets
        self.hostKeyValidator = hostKeyValidator
        self.options = options
    }

    // MARK: Connection

    public func connect() async throws {
        await disconnectQuietly()
        hub.emit(.status, "Connecting to \(config.host):\(config.port)...")
        do {
            let session = try await connectSession()
            ssh = session
            try await session.authenticate(username: config.username, steps: try await SSHAuth.steps(for: config, secrets: secrets))
            try await openSFTP(on: session)
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
        if let sftp { try? await sftp.run { $0.close() } }
        await ssh?.close()
        sftp = nil
        ssh = nil
        isBrowsingAsRoot = false
    }

    /// Connects the whole jump chain and returns the session for the final host (not yet authenticated).
    private func connectSession() async throws -> SSHSession {
        let hub = self.hub
        var upstream: SSHSession?
        do {
            for hop in options.jumpHosts {
                hub.emit(.status, "Connecting to jump host \(hop.config.host):\(hop.config.port)...")
                let session = try await SSHSession.connect(
                    host: hop.config.host, port: hop.config.port, via: upstream, options: options.session,
                    validator: hop.hostKeyValidator ?? hostKeyValidator
                ) { hub.emit($0, "[\(hop.config.host)] \($1)") }
                upstream = session
                try await session.authenticate(username: hop.config.username, steps: try await SSHAuth.steps(for: hop.config, secrets: hop.secrets))
            }
            if upstream != nil { hub.emit(.status, "Connecting to \(config.host):\(config.port) through the jump host...") }
            return try await SSHSession.connect(
                host: config.host, port: config.port, via: upstream, options: options.session, validator: hostKeyValidator
            ) { hub.emit($0, $1) }
        } catch {
            await upstream?.close()
            throw error
        }
    }

    private func openSFTP(on session: SSHSession) async throws {
        if options.browseAsRoot, config.elevation != .none {
            let method = config.elevation == .su ? "su" : "sudo"
            do {
                let password = try await secrets.secret(for: config.id, purpose: .elevationPassword)
                hub.emit(.status, "Starting sftp-server as root through \(method)")
                sftp = try await session.openElevatedSFTP(kind: config.elevation, password: password)
                isBrowsingAsRoot = true
                hub.emit(.status, "Browsing files as root")
                return
            } catch {
                hub.emit(.warning, "Could not browse as root through \(method) (\(error)); using the normal user")
            }
        }
        sftp = try await session.openSFTP()
    }

    private func client() throws -> SFTPClient {
        guard let sftp else { throw RemoteError.notConnected }
        return sftp
    }

    // MARK: Shell and exec on the same connection

    /// Opens a terminal on the existing SSH connection. Uses the configured elevation (`su -` / `sudo -i`).
    public func openShell(cols: Int, rows: Int) async throws -> ShellChannel {
        guard let ssh else { throw RemoteError.notConnected }
        var elevation: ShellElevation?
        if config.elevation != .none {
            elevation = ShellElevation(kind: config.elevation, password: try await secrets.secret(for: config.id, purpose: .elevationPassword))
        }
        hub.emit(.status, "Opening shell (\(cols)x\(rows))")
        return try await ssh.openShell(cols: cols, rows: rows, elevation: elevation)
    }

    public func exec(_ command: String) async throws -> SSHExecResult {
        guard let ssh else { throw RemoteError.notConnected }
        hub.emit(.command, command)
        return try await ssh.exec(command)
    }

    /// Runs a command and streams its output and exit status. With `elevated` and an `su`/`sudo` setting it
    /// runs as root (`canElevateCommands` says whether the file browser is root too). Cancelling the
    /// consuming task (or dropping the stream) kills the remote process group.
    public func execStream(_ command: String, elevated: Bool) async throws -> AsyncThrowingStream<SSHExecEvent, Error> {
        guard let ssh else { throw RemoteError.notConnected }
        var elevation: ShellElevation?
        if elevated, config.elevation != .none {
            elevation = ShellElevation(kind: config.elevation, password: try await secrets.secret(for: config.id, purpose: .elevationPassword))
        }
        hub.emit(.command, elevation == nil ? command : "[\(config.elevation == .su ? "su" : "sudo")] \(command)")
        return ssh.execStream(command, elevation: elevation)
    }

    public var canElevateCommands: Bool { isBrowsingAsRoot }

    // MARK: Listing

    public func homeDirectory() async throws -> String {
        let sftp = try client()
        do { return try await sftp.run { try $0.realpath(".") } } catch { throw map(error, path: ".") }
    }

    public func list(_ path: String) async throws -> [RemoteItem] {
        let sftp = try client()
        let dir = path.isEmpty ? "." : path
        hub.emit(.status, "Listing directory \(dir)")
        let entries: [SFTPEntry]
        do { entries = try await sftp.run { try $0.listDirectory(dir) } } catch { throw map(error, path: dir) }

        var items: [RemoteItem] = []
        items.reserveCapacity(entries.count)
        for entry in entries {
            let itemPath = RemotePath.join(dir, entry.name)
            var item = Self.item(name: entry.name, path: itemPath, attributes: entry.attributes)
            if entry.attributes.isSymlink {
                let resolved = try? await sftp.run { client -> (String, SFTPAttributes?) in
                    (try client.readlink(itemPath), try? client.stat(itemPath, followLinks: true))
                }
                item.symlinkTarget = resolved?.0 ?? ""
                item.isDirectory = resolved?.1?.isDirectory ?? false
            }
            items.append(item)
        }
        hub.emit(.status, "Directory listing of \(dir) successful (\(items.count) items)")
        return items
    }

    public func stat(_ path: String) async throws -> RemoteItem? {
        let sftp = try client()
        do {
            let attributes = try await sftp.run { try $0.stat(path, followLinks: false) }
            var item = Self.item(name: RemotePath.lastComponent(of: path), path: path, attributes: attributes)
            if attributes.isSymlink {
                let resolved = try? await sftp.run { client -> (String, SFTPAttributes?) in
                    (try client.readlink(path), try? client.stat(path, followLinks: true))
                }
                item.symlinkTarget = resolved?.0 ?? ""
                item.isDirectory = resolved?.1?.isDirectory ?? false
            }
            return item
        } catch let status as SFTPStatusError where status.known == .noSuchFile {
            return nil
        } catch {
            throw map(error, path: path)
        }
    }

    private static func item(name: String, path: String, attributes: SFTPAttributes) -> RemoteItem {
        RemoteItem(
            name: name,
            path: path,
            isDirectory: attributes.isDirectory,
            size: attributes.size,
            modified: attributes.modified,
            permissions: attributes.permissions.map { UInt16($0 & 0o7777) }
        )
    }

    // MARK: Transfers

    public func download(_ remote: String, to local: URL, progress: Progress, resume: Bool) async throws {
        let sftp = try client()
        let hub = self.hub
        do {
            let bytes = try await SFTPTransfer.download(sftp, remote: remote, to: local, resume: resume, progress: progress) { offset in
                hub.emit(.status, "get \(remote)\(offset > 0 ? " (resuming at \(offset))" : "")")
            }
            hub.emit(.status, "get \(remote) finished (\(bytes) bytes)")
        } catch {
            hub.emit(.error, "Download of \(remote) failed: \(error)")
            throw map(error, path: remote)
        }
    }

    public func upload(_ local: URL, to remote: String, progress: Progress, resume: Bool) async throws {
        let sftp = try client()
        let hub = self.hub
        guard let total = LocalFile.size(of: local) else { throw RemoteError.notFound(local.path) }
        do {
            let bytes = try await SFTPTransfer.upload(sftp, local: local, remote: remote, total: total, resume: resume, progress: progress) { offset in
                hub.emit(.status, "put \(remote)\(offset > 0 ? " (resuming at \(offset))" : "")")
            }
            hub.emit(.status, "put \(remote) finished (\(bytes) bytes)")
            await preserveModificationTime(of: local, on: remote)
        } catch {
            hub.emit(.error, "Upload of \(remote) failed: \(error)")
            throw map(error, path: remote)
        }
    }

    private func preserveModificationTime(of local: URL, on remote: String) async {
        guard let sftp, let date = (try? FileManager.default.attributesOfItem(atPath: local.path))?[.modificationDate] as? Date else { return }
        let seconds = UInt32(clamping: Int64(date.timeIntervalSince1970))
        let attributes = SFTPAttributes(accessTime: seconds, modifiedTime: seconds)
        do { try await sftp.run { try $0.setstat(remote, attributes) } } catch {
            hub.emit(.warning, "Could not set the modification time of \(remote): \(error)")
        }
    }

    // MARK: Namespace operations

    public func mkdir(_ path: String) async throws {
        let sftp = try client()
        hub.emit(.status, "mkdir \(path)")
        do { try await sftp.run { try $0.mkdir(path) } } catch { throw map(error, path: path) }
    }

    public func rename(_ from: String, _ to: String) async throws {
        let sftp = try client()
        hub.emit(.status, "rename \(from) -> \(to)")
        do { try await sftp.run { try $0.rename(from, to) } } catch { throw map(error, path: from) }
    }

    public func delete(_ path: String, recursive: Bool) async throws {
        let sftp = try client()
        hub.emit(.status, "rm\(recursive ? " -r" : "") \(path)")
        do { try await remove(path, recursive: recursive, on: sftp) } catch { throw map(error, path: path) }
    }

    /// Uses lstat semantics so symlinks are removed, never followed.
    private func remove(_ path: String, recursive: Bool, on sftp: SFTPClient) async throws {
        let attributes = try await sftp.run { try $0.stat(path, followLinks: false) }
        if attributes.isDirectory {
            if recursive {
                for child in try await sftp.run({ try $0.listDirectory(path) }) {
                    try await remove(RemotePath.join(path, child.name), recursive: true, on: sftp)
                }
            }
            try await sftp.run { try $0.rmdir(path) }
        } else {
            try await sftp.run { try $0.remove(path) }
        }
    }

    public func chmod(_ path: String, mode: UInt16) async throws {
        let sftp = try client()
        hub.emit(.status, "chmod \(String(mode & 0o7777, radix: 8)) \(path)")
        let attributes = SFTPAttributes(permissions: UInt32(mode & 0o7777))
        do { try await sftp.run { try $0.setstat(path, attributes) } } catch { throw map(error, path: path) }
    }

    private func map(_ error: Error, path: String) -> Error {
        guard let status = error as? SFTPStatusError else { return error }
        switch status.known {
        case .noSuchFile: return RemoteError.notFound(path)
        case .permissionDenied: return RemoteError.permissionDenied(path)
        default: return RemoteError.protocolError(status.message.isEmpty ? "SFTP error \(status.code) for \(path)" : status.message)
        }
    }
}
