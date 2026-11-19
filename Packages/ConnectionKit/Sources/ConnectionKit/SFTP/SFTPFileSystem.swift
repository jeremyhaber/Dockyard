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
        /// Deletes folders with one `rm -rf` over SSH instead of removing every file over SFTP. Falls back to
        /// SFTP when the server cannot run commands (SFTP-only accounts, Windows) or the folder is still there.
        public var shellFolderDelete = true
        /// Called once when shell folder deletes turn out not to work on this server (commands refused, without
        /// effect, or seeing other files), so the app can switch the setting off for the site.
        public var onShellFolderDeleteUnavailable: (@Sendable () -> Void)?

        public init(browseAsRoot: Bool = false, shellFolderDelete: Bool = true) {
            self.browseAsRoot = browseAsRoot
            self.shellFolderDelete = shellFolderDelete
        }
    }

    public nonisolated let config: ConnectionConfig
    private let secrets: SecretStore
    private let hostKeyValidator: SSHHostKeyValidator
    private let options: Options
    private let hub = LogHub()

    private var ssh: SSHSession?
    private var sftp: SFTPClient?
    /// Set by `connect()` and cleared by `disconnect()`: a dropped session is re-established on next use.
    private var shouldReconnect = false
    private var reconnecting: Task<Void, Error>?
    public private(set) var isBrowsingAsRoot = false
    /// Set when folder deletes cannot use a shell command on this connection: the server refuses commands
    /// (SFTP-only account), or a command could not see a file SFTP had just created (the two see different file
    /// systems). Folder deletes then stay on SFTP until the next connect.
    private var shellDeleteUnavailable = false

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
        try await establish()
        shouldReconnect = true
    }

    private func establish() async throws {
        await disconnectQuietly()
        shellDeleteUnavailable = false
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
        shouldReconnect = false
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
        if let user = config.runAs {
            hub.emit(.status, "Logged in as \(config.username); starting sftp-server as \(user)")
            sftp = try await session.openSFTP(asUser: user)
            return
        }
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

    /// Returns the live SFTP client, reconnecting if the server dropped us.
    private func client() async throws -> SFTPClient {
        if await isUsable(), let sftp { return sftp }
        guard shouldReconnect else { throw RemoteError.notConnected }
        if let reconnecting {
            try await reconnecting.value
        } else {
            let task = Task { try await self.restore() }
            reconnecting = task
            defer { reconnecting = nil }
            try await task.value
        }
        guard let sftp else { throw RemoteError.notConnected }
        return sftp
    }

    /// Whether the SSH transport is up and the SFTP channel on it still open.
    private func isUsable() async -> Bool {
        guard let sftp, let ssh else { return false }
        return (try? await ssh.perform { _ in sftp.isOpen }) ?? false
    }

    /// Reopens just the SFTP channel when the server closed it on a live connection (the terminal keeps running),
    /// otherwise logs in again.
    private func restore() async throws {
        if let ssh, await ssh.alive {
            hub.emit(.status, "SFTP channel closed, reopening...")
            if let sftp { try? await sftp.run { $0.close() } }
            sftp = nil
            isBrowsingAsRoot = false
            do {
                try await openSFTP(on: ssh)
                hub.emit(.status, "SFTP subsystem ready")
                return
            } catch {
                hub.emit(.warning, "Could not reopen SFTP (\(error)); reconnecting")
            }
        }
        hub.emit(.status, "Connection lost, reconnecting...")
        try await establish()
    }

    /// The live SSH session for shells and commands, reconnecting if needed.
    private func liveSSH() async throws -> SSHSession {
        _ = try await client()
        guard let ssh else { throw RemoteError.notConnected }
        return ssh
    }

    /// Runs a read that is safe to repeat, again on a fresh connection if it failed because the old one was dead.
    private func retryingOnDrop<T>(_ body: (SFTPClient) async throws -> T) async throws -> T {
        let sftp = try await client()
        do {
            return try await body(sftp)
        } catch {
            guard shouldReconnect, !(await isUsable()) else { throw error }
            return try await body(try await client())
        }
    }

    // MARK: Shell and exec on the same connection

    /// Opens a terminal on the existing SSH connection. Uses the configured elevation (`su -` / `sudo -i`).
    public func openShell(cols: Int, rows: Int) async throws -> ShellChannel {
        let ssh = try await liveSSH()
        var elevation: ShellElevation?
        if config.elevation != .none, config.runAs == nil {
            elevation = ShellElevation(kind: config.elevation, password: try await secrets.secret(for: config.id, purpose: .elevationPassword))
        }
        hub.emit(.status, "Opening shell (\(cols)x\(rows))")
        return try await ssh.openShell(cols: cols, rows: rows, elevation: elevation, runAs: config.runAs)
    }

    public func exec(_ command: String) async throws -> SSHExecResult {
        let ssh = try await liveSSH()
        hub.emit(.command, command)
        return try await ssh.exec(try asAccount(command))
    }

    /// `command` as the `runAs` user when the login is root on that user's behalf.
    private func asAccount(_ command: String) throws -> String {
        guard let user = config.runAs else { return command }
        return try SSHSession.asUser(user, command)
    }

    /// Runs a command and streams its output and exit status. With `elevated` and an `su`/`sudo` setting it
    /// runs as root (`canElevateCommands` says whether the file browser is root too). Cancelling the
    /// consuming task (or dropping the stream) kills the remote process group.
    public func execStream(_ command: String, elevated: Bool) async throws -> AsyncThrowingStream<SSHExecEvent, Error> {
        try await execStream(command, elevated: elevated, stdin: nil)
    }

    /// With `stdin` the bytes are sent on the channel and closed; the command is logged, never the input.
    public func execStream(_ command: String, elevated: Bool, stdin: Data?) async throws -> AsyncThrowingStream<SSHExecEvent, Error> {
        let ssh = try await liveSSH()
        var elevation: ShellElevation?
        if elevated, config.elevation != .none, config.runAs == nil {
            elevation = ShellElevation(kind: config.elevation, password: try await secrets.secret(for: config.id, purpose: .elevationPassword))
        }
        hub.emit(.command, elevation == nil ? command : "[\(config.elevation == .su ? "su" : "sudo")] \(command)")
        return ssh.execStream(elevation == nil ? try asAccount(command) : command, elevation: elevation, stdin: stdin)
    }

    public var canElevateCommands: Bool { isBrowsingAsRoot }

    // MARK: Listing

    public func homeDirectory() async throws -> String {
        do { return try await retryingOnDrop { try await $0.run { try $0.realpath(".") } } } catch { throw map(error, path: ".") }
    }

    public func list(_ path: String) async throws -> [RemoteItem] {
        try await collectListing(path)
    }

    /// Sends entries as each server reply arrives. Symlinks first show as links to files; once the folder is listed
    /// their targets are resolved in pipelined groups and sent as `.updated`.
    public nonisolated func listStream(_ path: String) -> AsyncThrowingStream<ListingUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamListing(path, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Links resolved per server round trip.
    private static let linkGroupSize = 64

    private func streamListing(_ path: String, into continuation: AsyncThrowingStream<ListingUpdate, Error>.Continuation) async throws {
        let dir = path.isEmpty ? "." : path
        hub.emit(.status, "Listing directory \(dir)")
        let entries: [SFTPEntry]
        do {
            entries = try await retryingOnDrop { sftp in
                try await sftp.run { client in
                    try client.listDirectory(dir) { batch in
                        continuation.yield(.added(batch.map { Self.listedItem($0, in: dir) }))
                    }
                }
            }
        } catch {
            throw map(error, path: dir)
        }
        hub.emit(.status, "Directory listing of \(dir) successful (\(entries.count) items)")

        let links = entries.filter(\.attributes.isSymlink).map { Self.listedItem($0, in: dir) }
        guard !links.isEmpty else { return }
        let sftp = try await client()
        var start = 0
        while start < links.count {
            try Task.checkCancellation()
            let group = Array(links[start..<min(start + Self.linkGroupSize, links.count)])
            start += group.count
            let paths = group.map(\.path)
            // A failure here leaves the remaining links unresolved rather than failing a listing already shown.
            guard let resolved = try? await sftp.run({ try $0.resolveLinks(paths) }) else { return }
            continuation.yield(.updated(zip(group, resolved).map { item, link in
                var item = item
                item.symlinkTarget = link.target ?? ""
                item.isDirectory = link.attributes?.isDirectory ?? false
                return item
            }))
        }
    }

    /// An entry as first listed. A symlink is marked as one, with its target filled in later.
    private static func listedItem(_ entry: SFTPEntry, in dir: String) -> RemoteItem {
        var item = item(name: entry.name, path: RemotePath.join(dir, entry.name), attributes: entry.attributes)
        if entry.attributes.isSymlink { item.symlinkTarget = "" }
        return item
    }

    public func stat(_ path: String) async throws -> RemoteItem? {
        do {
            let attributes = try await retryingOnDrop { try await $0.run { try $0.stat(path, followLinks: false) } }
            let sftp = try await client()
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
        let sftp = try await client()
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
        let sftp = try await client()
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
        let sftp = try await client()
        hub.emit(.status, "mkdir \(path)")
        do { try await sftp.run { try $0.mkdir(path) } } catch { throw map(error, path: path) }
    }

    /// Exclusive create, so an existing file is never truncated.
    public func createFile(_ path: String) async throws {
        let sftp = try await client()
        hub.emit(.status, "create \(path)")
        do {
            try await sftp.run { client in
                let handle = try client.open(path, [.write, .create, .exclusive])
                try client.closeHandle(handle)
            }
        } catch {
            // OpenSSH answers an exclusive create on a taken name with a bare SSH_FX_FAILURE ("Failure").
            if error is SFTPStatusError, (try? await stat(path)) != nil { throw RemoteError.alreadyExists(path) }
            throw map(error, path: path)
        }
    }

    public func rename(_ from: String, _ to: String) async throws {
        let sftp = try await client()
        hub.emit(.status, "rename \(from) -> \(to)")
        do { try await sftp.run { try $0.rename(from, to) } } catch { throw map(error, path: from) }
    }

    public func delete(_ path: String, recursive: Bool) async throws {
        let sftp = try await client()
        hub.emit(.status, "Deleting \(path)...")
        do {
            let removed = try await remove(path, recursive: recursive, on: sftp)
            hub.emit(.status, removed.viaShell ? "Deleted \(path) with rm -rf" : "Deleted \(path) (\(removed.count) \(removed.count == 1 ? "item" : "items"))")
        } catch { throw map(error, path: path) }
    }

    /// Uses lstat semantics so symlinks are removed, never followed. Each item removed over SFTP is logged.
    private func remove(_ path: String, recursive: Bool, on sftp: SFTPClient, topLevel: Bool = true) async throws -> (count: Int, viaShell: Bool) {
        let attributes = try await sftp.run { try $0.stat(path, followLinks: false) }
        if attributes.isDirectory, recursive, topLevel, options.shellFolderDelete, await removeWithShell(path, on: sftp) {
            return (0, true)
        }
        var count = 0
        if attributes.isDirectory {
            if recursive {
                for child in try await sftp.run({ try $0.listDirectory(path) }) {
                    count += try await remove(RemotePath.join(path, child.name), recursive: true, on: sftp, topLevel: false).count
                }
            }
            hub.emit(.command, "rmdir \(path)")
            try await sftp.run { try $0.rmdir(path) }
        } else {
            hub.emit(.command, "rm \(path)")
            try await sftp.run { try $0.remove(path) }
        }
        return (count + 1, false)
    }

    /// Stops shell folder deletes for this connection and tells the app, which turns the site setting off.
    private func giveUpShellDelete(_ level: LogLine.Kind, _ message: String) {
        shellDeleteUnavailable = true
        hub.emit(level, message + "; deleting folders over SFTP and turning off shell deletes for this site")
        options.onShellFolderDeleteUnavailable?()
    }

    /// Exit status of the delete command when the shell cannot see the canary file.
    static let canaryMissingStatus: Int32 = 97

    /// One `rm -rf` over SSH, as the same user the file browser works as. True only when the folder is gone
    /// afterwards; any failure (no shell, ForceCommand internal-sftp, permission denied partway) returns false
    /// so the caller removes what is left over SFTP and reports the precise error.
    ///
    /// A canary file created over SFTP inside the folder must be visible to the shell at the same path, or
    /// nothing is deleted: this catches a shell that sees a different file system than SFTP does.
    private func removeWithShell(_ path: String, on sftp: SFTPClient) async -> Bool {
        guard !shellDeleteUnavailable else { return false }
        // Relative paths could resolve differently in a shell, and "/" (or anything with "..") is never worth the risk.
        let components = path.split(separator: "/").filter { $0 != "." }
        guard path.hasPrefix("/"), !components.isEmpty, !components.contains("..") else { return false }
        let canary = RemotePath.join(path, ".dockyard-rm-\(UUID().uuidString)")
        do {
            try await sftp.run { client in try client.closeHandle(try client.open(canary, [.write, .create, .truncate])) }
        } catch {
            // Without write access to the folder, rm -rf could not empty it either.
            return false
        }
        let command = "test -f \(ShellQuote.quote(canary)) || exit \(Self.canaryMissingStatus); rm -rf -- \(ShellQuote.quote(path))"
        let status: Int32?
        let stderr: Data
        do {
            if isBrowsingAsRoot {
                // The SFTP server runs as root, so the command must too.
                var exit: Int32?, errors = Data()
                for try await event in try await execStream(command, elevated: true) {
                    switch event {
                    case .exit(let code): exit = code
                    case .stderr(let data): errors.append(data)
                    case .stdout: break
                    }
                }
                (status, stderr) = (exit, errors)
            } else {
                let result = try await exec(command)
                (status, stderr) = (result.exitStatus, result.stderr)
            }
        } catch {
            // Nothing ran: the server would not start the command. Not worth retrying on this connection.
            giveUpShellDelete(.warning, "This server does not run SSH commands for this account (\(error))")
            try? await sftp.run { try $0.remove(canary) }
            return false
        }
        if status == Self.canaryMissingStatus {
            giveUpShellDelete(.warning, "SSH commands see different files than SFTP on this server")
            try? await sftp.run { try $0.remove(canary) }
            return false
        }
        // rm -rf always takes the canary with it (it sits at the top, where we could write), even when something
        // deeper is protected. Still there means the command never ran, whatever its exit status: an SFTP-only
        // account (ForceCommand internal-sftp) starts sftp-server for any command.
        if (try? await sftp.run({ try $0.stat(canary, followLinks: false) })) != nil {
            giveUpShellDelete(.warning, "SSH commands have no effect for this account")
            try? await sftp.run { try $0.remove(canary) }
            return false
        }
        do {
            _ = try await sftp.run { try $0.stat(path, followLinks: false) }
            let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            hub.emit(.warning, "rm -rf left \(path) in place (exit \(status.map(String.init) ?? "unknown"))\(message.isEmpty ? "" : ": \(message)"); deleting the rest over SFTP")
            return false
        } catch let error as SFTPStatusError where error.known == .noSuchFile {
            return true
        } catch {
            return false
        }
    }

    public func chmod(_ path: String, mode: UInt16) async throws {
        let sftp = try await client()
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
