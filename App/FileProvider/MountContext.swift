import ConnectionKit
import DockyardCore
import FileProvider
import Foundation
import RcloneKit

/// The state behind one mounted domain: the connection record, its file system and the change poller.
/// Mounts always use the normal user (`MountPolicy.config`), never su or sudo.
actor MountContext {
    enum MountError: Error {
        case unavailable(String)
        case readOnly
    }

    let domainIdentifier: String
    let displayName: String
    let connectionID: UUID
    private(set) var rootPath = "/"
    private(set) var readOnly = true

    private var connection: Connection?
    private var jumpChain: [Connection] = []
    private var fs: (any RemoteFileSystem)?
    private var connected = false
    private let poller = MountPoller()

    init(identifier: String, displayName: String) {
        self.domainIdentifier = identifier
        self.displayName = displayName
        self.connectionID = MountNaming.connectionId(fromDomainIdentifier: identifier) ?? UUID()
    }

    private func manager() -> NSFileProviderManager? {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: domainIdentifier), displayName: displayName)
        return NSFileProviderManager(for: domain)
    }

    func temporaryDirectory() -> URL {
        (try? manager()?.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
    }

    // MARK: Log

    nonisolated func log(_ kind: LogLine.Kind, _ message: String) {
        FinderLogFile.append(kind: kind.rawValue, message: FinderLog.message(message), connection: connectionID)
    }

    // MARK: Connection

    private func loadConnection() async throws -> Connection {
        if let connection { return connection }
        let db = try DockyardDatabase.openReadOnly(path: AppGroup.databaseURL.path)
        guard let record = try await ConnectionRepository(database: db).connection(id: connectionID) else {
            throw MountError.unavailable("This connection no longer exists in Dockyard.")
        }
        let repository = ConnectionRepository(database: db)
        var chain: [Connection] = []
        var next = record.jumpHost
        while let id = next, chain.count < JumpChain.maxHops, let hop = try await repository.connection(id: id) {
            chain.insert(hop, at: 0)
            next = hop.jumpHost
        }
        jumpChain = chain
        connection = record
        readOnly = record.mountReadOnly
        return record
    }

    private func makeFileSystem(_ c: Connection) throws -> any RemoteFileSystem {
        let secrets = KeychainSecretStore(accessGroup: AppGroup.keychainAccessGroup, useDataProtectionKeychain: true)
        let config = MountPolicy.config(for: c)
        switch c.protocol {
        case .sftp:
            func trustedOnly(host: String, port: Int) -> SSHHostKeyValidator {
                SSHHostKeyValidator { key in
                    guard let db = try? DockyardDatabase.openReadOnly(path: AppGroup.databaseURL.path) else { return false }
                    let verdict = try? await KnownHostRepository(database: db).verdict(
                        host: host, port: port, keyType: key.algorithm, fingerprint: key.fingerprint)
                    return verdict == .trusted
                }
            }
            var options = SFTPFileSystem.Options()
            options.jumpHosts = jumpChain.map {
                SSHJumpHop(config: $0.config, secrets: secrets, hostKeyValidator: trustedOnly(host: $0.host, port: $0.port))
            }
            return SFTPFileSystem(
                config: config, secrets: secrets, hostKeyValidator: trustedOnly(host: c.host, port: c.port), options: options)
        case .ftp, .ftps:
            return FTPFileSystem(config: config, secrets: secrets)
        case .rclone:
            guard let cloud = c.cloud, let backend = RcloneBackend(rawValue: cloud.backend) else {
                throw MountError.unavailable("This cloud connection has no storage provider configured.")
            }
            let spec = RcloneRemoteSpec(backend: backend, options: cloud.options, root: cloud.root)
            return try RcloneFileSystem(config: config, spec: spec, secrets: secrets, library: RcloneLibrary.load())
        }
    }

    /// The connected file system. Connects (and resolves the mount root) on first use.
    func filesystem() async throws -> any RemoteFileSystem {
        if let fs, connected { return fs }
        let c = try await loadConnection()
        let created = try fs ?? makeFileSystem(c)
        fs = created
        log(.status, "Connecting \(c.name) for Finder")
        try await created.connect()
        connected = true
        rootPath = c.protocol == .rclone ? "/" : ((try? await created.homeDirectory()) ?? "/")
        return created
    }

    /// Runs an operation, reconnecting once when the connection dropped.
    func perform<T: Sendable>(_ body: @Sendable (any RemoteFileSystem) async throws -> T) async throws -> T {
        let current = try await filesystem()
        do {
            return try await body(current)
        } catch RemoteError.notConnected {
            connected = false
            return try await body(try await filesystem())
        }
    }

    func isReadOnly() async -> Bool {
        _ = try? await loadConnection()
        return readOnly
    }

    // MARK: Paths

    func path(for identifier: NSFileProviderItemIdentifier) -> String? {
        if identifier == .rootContainer { return rootPath }
        guard identifier.rawValue.hasPrefix("p:") else { return nil }
        return String(identifier.rawValue.dropFirst(2))
    }

    func identifier(forPath path: String) -> NSFileProviderItemIdentifier {
        path == rootPath ? .rootContainer : NSFileProviderItemIdentifier("p:" + path)
    }

    func parentIdentifier(ofPath path: String) -> NSFileProviderItemIdentifier {
        identifier(forPath: RemotePath.parent(of: path))
    }

    // MARK: Items

    func item(_ remote: RemoteItem) async -> ProviderItem {
        ProviderItem(
            remote: remote, identifier: identifier(forPath: remote.path), parent: parentIdentifier(ofPath: remote.path),
            readOnly: await isReadOnly())
    }

    func rootItem() async -> ProviderItem {
        ProviderItem(
            remote: RemoteItem(name: displayName, path: rootPath, isDirectory: true), identifier: .rootContainer,
            parent: .rootContainer, readOnly: await isReadOnly())
    }

    // MARK: Change polling

    func watch(_ path: String, snapshot: [RemoteItem]) async {
        await poller.watch(path, snapshot: snapshot)
        await poller.start(context: self)
    }

    func pollOnce(folder path: String, previous: [RemoteItem]) async -> ([RemoteItem], DirectoryChange)? {
        guard let fresh = try? await perform({ try await $0.list(path) }) else { return nil }
        return (fresh, DirectoryChangeDetector.diff(old: previous, new: fresh))
    }

    func changes(since anchor: Int) async -> (changes: [PolledChange], anchor: Int) {
        await poller.changes(since: anchor)
    }

    func currentAnchor() async -> Int { await poller.anchor }

    func signalWorkingSet() {
        guard let manager = manager() else { return }
        manager.signalEnumerator(for: .workingSet) { _ in }
    }

    func shutdown() async {
        await poller.stop()
        await fs?.disconnect()
        connected = false
    }
}

/// One folder's change as the working set reports it.
struct PolledChange: Sendable {
    var folder: String
    var change: DirectoryChange
}

/// Re-lists the folders Finder has enumerated every polling interval and remembers what changed.
/// SFTP and FTP offer no change notifications, so this is how Finder learns about server-side edits.
actor MountPoller {
    private var snapshots: [String: [RemoteItem]] = [:]
    private var log: [(anchor: Int, change: PolledChange)] = []
    private var task: Task<Void, Never>?
    private(set) var anchor = 0
    private var failures = 0

    func watch(_ path: String, snapshot: [RemoteItem]) {
        snapshots[path] = snapshot
        // Keep the working set small: the most recently enumerated folders only.
        if snapshots.count > 40, let drop = snapshots.keys.first(where: { $0 != path }) { snapshots.removeValue(forKey: drop) }
    }

    func start(context: MountContext) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.delay()
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
                await self.tick(context)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func delay() -> TimeInterval {
        let stored = AppGroup.sharedDefaults.double(forKey: AppGroup.pollIntervalKey)
        let settings = MountPollingSettings(interval: stored > 0 ? stored : MountPollingSettings.defaultInterval)
        return settings.delay(afterConsecutiveFailures: failures)
    }

    private func tick(_ context: MountContext) async {
        var found = false
        var failed = false
        for (path, previous) in snapshots {
            guard let (fresh, change) = await context.pollOnce(folder: path, previous: previous) else {
                failed = true
                continue
            }
            snapshots[path] = fresh
            if !change.isEmpty {
                anchor += 1
                log.append((anchor, PolledChange(folder: path, change: change)))
                found = true
            }
        }
        failures = failed ? failures + 1 : 0
        if log.count > 200 { log.removeFirst(log.count - 200) }
        if found { await context.signalWorkingSet() }
    }

    func changes(since anchor: Int) -> (changes: [PolledChange], anchor: Int) {
        (log.filter { $0.anchor > anchor }.map(\.change), self.anchor)
    }
}
