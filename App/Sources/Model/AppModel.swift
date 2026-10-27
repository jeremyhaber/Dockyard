import AppKit
import ConnectionKit
import DockyardCore
import Foundation
import Observation
import RcloneKit

enum DrawerTab: String, Hashable {
    case log, terminal
}

/// The Quick Connect bar's protocol menu.
enum QuickProtocol: Hashable {
    case sftp, ftp, ftps
    case cloud(String)

    var title: String {
        switch self {
        case .sftp: "SFTP"
        case .ftp: "FTP"
        case .ftps: "FTPS"
        case .cloud(let id): CloudPreset.preset(id: id)?.title ?? "Cloud"
        }
    }

    var connectionProtocol: ConnectionProtocol? {
        switch self {
        case .sftp: .sftp
        case .ftp: .ftp
        case .ftps: .ftps
        case .cloud: nil
        }
    }
}

struct SiteEditorRequest: Identifiable {
    enum Origin { case main, manager }
    let id = UUID()
    var connection: Connection?
    var origin: Origin
    var connectAfterSave = false
}

/// App-wide state. Everything here is a thin layer over DockyardCore.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let database: DockyardDatabase
    let connections: ConnectionRepository
    let folders: ClientFolderRepository
    let sessionRepository: SessionRepository
    let history: FolderHistoryRepository
    let whmSources: WHMSourceRepository
    let knownHosts: KnownHostRepository
    let secrets: any SecretStore
    let quickConnectService: QuickConnectService
    let sessionService: SessionService
    let whmSync: WHMSyncService
    let queue: TransferQueue
    let prompts: PromptCenter
    private(set) var startupError: String?

    private(set) var sessions: [ConnectionSession] = []
    var activeSessionID: UUID?
    private(set) var allConnections: [Connection] = []
    private(set) var connectionsRevision = 0
    private(set) var clientNames: [UUID: String] = [:]
    private(set) var transfers = TransferSnapshot.empty

    var drawerVisible = false
    var drawerTab: DrawerTab = .log
    var drawerHeight: Double = 220
    var jumpVisible = false
    var siteEditor: SiteEditorRequest?
    var alertMessage: String?
    var focusedSide: PaneSide = .server
    private(set) var quickConnectFocusToken = 0
    private(set) var quickHistory: [QuickConnectHistoryEntry] = []

    @ObservationIgnored private var whmScheduler: WHMSyncScheduler?
    @ObservationIgnored private var wasIdle = true

    private init() {
        var startup: String?
        let db: DockyardDatabase
        let demo = DemoMode.isEnabled
        do {
            if demo { throw AppError.cancelled }
            try FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
            db = try DockyardDatabase(path: AppPaths.databaseURL.path)
        } catch {
            if !demo {
                startup = "Could not open the Dockyard database (\(error.userMessage)). Changes will not be saved this session."
            }
            // An in-memory database cannot fail to open.
            db = (try? DockyardDatabase()) ?? { fatalError("in-memory database unavailable") }()
        }
        let secrets = FileSystemFactory.secretStore()
        let prompts = PromptCenter()
        let repo = ConnectionRepository(database: db)
        let sessionRepo = SessionRepository(database: db)
        self.database = db
        self.connections = repo
        self.folders = ClientFolderRepository(database: db)
        self.sessionRepository = sessionRepo
        self.history = FolderHistoryRepository(database: db)
        let sources = WHMSourceRepository(database: db)
        self.whmSources = sources
        self.knownHosts = KnownHostRepository(database: db)
        self.secrets = secrets
        self.quickConnectService = QuickConnectService(repository: repo, secrets: secrets)
        self.sessionService = SessionService(repository: sessionRepo, saver: SessionSaver(repository: sessionRepo))
        self.whmSync = WHMSyncService(repository: repo, sources: sources, secrets: secrets)
        self.prompts = prompts
        // The queue keeps its jobs in the app database, opens its own pooled sessions per registered site and
        // starts restored jobs paused until `offerToResumeTransfers` has asked.
        let siteHost = QueueSiteHost()
        self.queueSiteHost = siteHost
        let siteProvider: (@Sendable (UUID) async -> TransferSite?)? = demo ? nil : { id in
            guard let connection = try? await repo.connection(id: id) else { return nil }
            return await siteHost.model?.transferSite(for: connection)
        }
        self.queue = TransferQueue(
            maxConcurrent: demo ? 1 : 10, conflictPolicy: .ask, resolver: { info in await prompts.askConflict(info) },
            database: db, siteProvider: siteProvider)
        self.startupError = startup
        siteHost.model = self
        startObserving()
        if demo {
            Task { await DemoSeeder.run(self) }
        } else {
            startWHMScheduler()
            Task { await offerToResumeTransfers() }
        }
    }

    /// Lets the queue's `siteProvider` reach the model, which does not exist yet while the queue is created.
    @ObservationIgnored private let queueSiteHost: QueueSiteHost

    private final class QueueSiteHost: @unchecked Sendable {
        @MainActor weak var model: AppModel?
    }

    // MARK: Transfer queue sites

    /// What the queue needs to open extra pooled connections to `connection` (limits, back-off and
    /// persistence across restarts all hang off this registration).
    func transferSite(for connection: Connection) -> TransferSite {
        TransferSite(connection: connection) { [weak self] in
            guard let self else { throw AppError.cancelled }
            return try await self.makeQueueSession(for: connection)
        }
    }

    private func makeQueueSession(for connection: Connection) throws -> any RemoteFileSystem {
        let log = session(for: connection.id)?.log ?? LogBuffer()
        let validator = hostKeyValidator(host: connection.host, port: connection.port, log: log)
        return try FileSystemFactory.make(for: connection, secrets: secrets, hostKeyValidator: validator)
    }

    private func registerTransferSite(_ connection: Connection) {
        let site = transferSite(for: connection)
        let queue = queue
        Task { await queue.register(site: site) }
    }

    /// Restored unfinished jobs start paused; ask before they hit the network.
    private func offerToResumeTransfers() async {
        let count = await queue.restoredJobCount
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Resume \(count) unfinished transfer\(count == 1 ? "" : "s")?"
        alert.informativeText = "Dockyard was closed while transfers were still queued. They are paused until you resume them."
        alert.addButton(withTitle: "Resume")
        alert.addButton(withTitle: "Keep Paused")
        alert.addButton(withTitle: "Discard")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            await queue.resume()
        case .alertThirdButtonReturn:
            await queue.cancelAll()
            await queue.removeFinished()
        default:
            break
        }
    }

    // MARK: Derived

    var activeSession: ConnectionSession? { sessions.first { $0.id == activeSessionID } }

    func session(for connectionID: UUID) -> ConnectionSession? { sessions.first { $0.connection.id == connectionID } }

    var favorites: [Connection] { allConnections.filter(\.favorite) }

    var recents: [Connection] {
        allConnections
            .filter { $0.lastConnectedAt != nil || $0.isNew }
            .sorted { ($0.lastConnectedAt ?? $0.createdAt) > ($1.lastConnectedAt ?? $1.createdAt) }
            .prefix(6).map { $0 }
    }

    func status(of connectionID: UUID) -> SessionStatus? { session(for: connectionID)?.status }

    // MARK: Observation

    private func startObserving() {
        let repo = connections
        let folderRepo = folders
        let queue = self.queue
        Task { [weak self] in
            for await list in repo.observe(.all) {
                guard let self else { return }
                self.allConnections = list
                self.connectionsRevision += 1
                self.refreshOpenConnectionRecords(list)
            }
        }
        Task { [weak self] in
            for await list in folderRepo.observe() {
                self?.clientNames = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.name) })
            }
        }
        Task { [weak self] in
            for await snapshot in await queue.updates() {
                self?.handle(snapshot)
            }
        }
        Task { [weak self] in
            for await line in queue.log.stream() {
                self?.route(line)
            }
        }
        Task { [weak self] in await self?.reloadQuickHistory() }
    }

    private func refreshOpenConnectionRecords(_ list: [Connection]) {
        let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        for session in sessions {
            if let updated = byID[session.connection.id], updated != session.connection {
                session.updateConnection(updated)
                registerTransferSite(updated)
            }
        }
    }

    private func handle(_ snapshot: TransferSnapshot) {
        transfers = snapshot
        let idle = snapshot.isIdle
        if idle && !wasIdle {
            for session in sessions { session.refreshPanes() }
        }
        wasIdle = idle
    }

    /// Transfer log lines carry the route (`Server → This Mac`); file them under the matching connection.
    private func route(_ line: LogLine) {
        for session in sessions where line.message.contains(session.connection.name) {
            session.log.append(line)
        }
    }

    private func startWHMScheduler() {
        let sync = whmSync
        let scheduler = WHMSyncScheduler(action: { _ = await sync.syncAll() })
        whmScheduler = scheduler
        Task { await scheduler.start() }
    }

    func reloadQuickHistory() async {
        quickHistory = (try? await quickConnectService.history()) ?? []
    }

    // MARK: Opening connections

    func activate(_ session: ConnectionSession) { activeSessionID = session.id }

    /// Opens a tab for the connection, or switches to its existing tab unless `newTab` is set.
    func open(_ connection: Connection, newTab: Bool = false, initialPath: String? = nil) {
        if !newTab, let existing = session(for: connection.id) {
            activate(existing)
            if let initialPath { existing.server?.navigate(to: initialPath) }
            switch existing.status {
            case .failed, .disconnected: reconnect(existing)
            default: break
            }
            return
        }
        let session = ConnectionSession(connection: connection)
        registerTransferSite(connection)
        session.onSessionChange = { [weak self] in self?.persist($0) }
        sessions.append(session)
        activeSessionID = session.id
        connections.openConnections.open(connection.id)
        startConnect(session, initialPath: initialPath, skipRestore: false)
    }

    func open(connectionID: UUID, newTab: Bool = false) {
        if let connection = allConnections.first(where: { $0.id == connectionID }) { open(connection, newTab: newTab) }
    }

    func reconnect(_ session: ConnectionSession) {
        session.connectTask?.cancel()
        startConnect(session, initialPath: nil, skipRestore: false)
    }

    private func startConnect(_ session: ConnectionSession, initialPath: String?, skipRestore: Bool) {
        session.connectTask = Task { [weak self] in
            await self?.connect(session, initialPath: initialPath, skipRestore: skipRestore)
        }
    }

    func startFresh(_ session: ConnectionSession) {
        session.restoreNotice = nil
        let service = sessionService
        let id = session.connection.id
        session.connectTask?.cancel()
        session.connectTask = Task { [weak self] in
            try? await service.startFresh(connectionId: id)
            await session.teardown()
            await self?.connect(session, initialPath: nil, skipRestore: true)
        }
    }

    func disconnect(_ session: ConnectionSession) {
        session.connectTask?.cancel()
        Task {
            await flush(session)
            await session.teardown()
            session.markDisconnected()
            session.log.append(.status, "Disconnected")
        }
    }

    func close(_ session: ConnectionSession) {
        session.connectTask?.cancel()
        Task {
            await flush(session)
            await session.teardown()
            sessions.removeAll { $0.id == session.id }
            if !sessions.contains(where: { $0.connection.id == session.connection.id }) {
                connections.openConnections.close(session.connection.id)
            }
            if activeSessionID == session.id { activeSessionID = sessions.last?.id }
        }
    }

    private func flush(_ session: ConnectionSession) async {
        if let state = session.sessionState() { await sessionService.saver.update(state) }
        await sessionService.saver.flush(session.connection.id)
    }

    private func persist(_ session: ConnectionSession) {
        guard session.status.isConnected, let state = session.sessionState() else { return }
        let saver = sessionService.saver
        Task { await saver.update(state) }
    }

    func prepareForQuit() async {
        for session in sessions {
            if let state = session.sessionState() { await sessionService.saver.update(state) }
        }
        await sessionService.saver.flushAll()
        await queue.shutdown()
        for session in sessions { await session.fs?.disconnect() }
    }

    // MARK: Connecting

    private func connect(_ session: ConnectionSession, initialPath: String?, skipRestore: Bool) async {
        session.setStatus(.connecting)
        session.restoreNotice = nil
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await ensureCredentials(for: session, forcePrompt: attempt > 1)
                try Task.checkCancellation()
                let validator = hostKeyValidator(host: session.connection.host, port: session.connection.port, log: session.log)
                let fs = try FileSystemFactory.make(for: session.connection, secrets: secrets, hostKeyValidator: validator)
                session.attach(fs)
                try await fs.connect()
                try Task.checkCancellation()
                await finishConnect(session, fs: fs, initialPath: initialPath, skipRestore: skipRestore)
                return
            } catch is CancellationError {
                return
            } catch AppError.cancelled {
                session.log.append(.status, "Connection cancelled")
                session.setStatus(.disconnected)
                return
            } catch let error as RemoteError {
                if case .authenticationFailed = error, attempt < 3, usesStoredPassword(session.connection) {
                    session.log.append(.warning, "Authentication failed; asking for the password again")
                    continue
                }
                session.fail(error)
                return
            } catch {
                session.fail(error)
                return
            }
        }
    }

    private func usesStoredPassword(_ c: Connection) -> Bool {
        switch c.protocol {
        case .sftp: c.authMethods.contains(.password)
        case .ftp, .ftps: c.username.lowercased() != "anonymous"
        case .rclone: false
        }
    }

    private func finishConnect(_ session: ConnectionSession, fs: any RemoteFileSystem, initialPath: String?, skipRestore: Bool) async {
        let c = session.connection
        try? await connections.markConnected(c.id)
        let home = (try? await fs.homeDirectory()) ?? "/"
        var localHome = NSHomeDirectory()
        if let folder = c.localFolder, !folder.isEmpty, FileManager.default.fileExists(atPath: folder) { localHome = folder }
        let serverStart = initialPath ?? c.initialRemotePath ?? home
        let rules = FileSystemFactory.rules(for: c)

        var restored: RestoredSession?
        if initialPath == nil, !skipRestore, c.restoreSession {
            let log = session.log
            restored = try? await sessionService.prepareRestore(
                for: c, local: session.localFS, remote: fs, log: { kind, message in log.append(kind, message) })
        }
        guard !Task.isCancelled else { return }

        let serverState: PaneState
        let localState: PaneState
        var serverExpanded: [String] = []
        var localExpanded: [String] = []
        if let restored {
            let st = restored.state
            serverState = PaneState(restoring: st.remoteTabs, active: st.activeRemoteTab, fallbackPath: serverStart, rules: rules)
            localState = PaneState(restoring: st.localTabs, active: st.activeLocalTab, fallbackPath: localHome)
            serverExpanded = st.remoteTreeExpanded
            localExpanded = st.localTreeExpanded
        } else {
            serverState = PaneState(initialPath: serverStart, rules: rules)
            localState = PaneState(initialPath: localHome)
        }
        let server = PaneModel(side: .server, fs: fs, state: serverState, home: home)
        let local = PaneModel(side: .local, fs: session.localFS, state: localState, home: NSHomeDirectory())
        let history = self.history
        let id = c.id
        server.onVisit = { path in Task { try? await history.record(connectionId: id, path: path) } }
        session.install(local: local, server: server, notice: restored?.notice)
        server.start(expanded: serverExpanded)
        local.start(expanded: localExpanded)
        server.onVisit?(server.currentPath)
        Task { await reloadQuickHistory() }
    }

    // MARK: Credentials and host keys

    private func ensureCredentials(for session: ConnectionSession, forcePrompt: Bool) async throws {
        if DemoMode.isEnabled { return }
        let c = session.connection
        let log = session.log
        switch c.protocol {
        case .rclone:
            guard let cloud = c.cloud, let backend = RcloneBackend(rawValue: cloud.backend) else { return }
            let existing = try? await secrets.secret(for: c.id, purpose: .cloudToken)
            if let existing, !existing.isEmpty, !forcePrompt {
                log.registerSecret(existing)
                return
            }
            if backend.usesOAuth {
                try await authorizeOAuth(connection: c, backend: backend, log: log)
            } else {
                let label = CloudPreset.preset(for: cloud)?.secretLabel ?? "Secret"
                try await promptAndStore(
                    PasswordRequest(title: "Secret for \(c.name)", message: "Dockyard stores it in your Keychain.", fieldLabel: label),
                    connection: c, purpose: .cloudToken, log: log)
            }
        case .sftp, .ftp, .ftps:
            guard usesStoredPassword(c) else { return }
            let existing = try? await secrets.secret(for: c.id, purpose: .password)
            if let existing, !existing.isEmpty, !forcePrompt {
                log.registerSecret(existing)
                return
            }
            let message = forcePrompt
                ? "The server rejected the saved password. Enter the password for \(c.username)@\(c.host)."
                : "Enter the password for \(c.username)@\(c.host). Dockyard stores it in your Keychain."
            try await promptAndStore(
                PasswordRequest(title: "Password for \(c.name)", message: message, fieldLabel: "Password"),
                connection: c, purpose: .password, log: log)
        }
    }

    private func promptAndStore(_ request: PasswordRequest, connection: Connection, purpose: SecretPurpose, log: LogBuffer) async throws {
        guard let value = await prompts.askPassword(request), !value.isEmpty else { throw AppError.cancelled }
        try await secrets.setSecret(value, for: connection.id, purpose: purpose)
        log.registerSecret(value)
    }

    private func authorizeOAuth(connection: Connection, backend: RcloneBackend, log: LogBuffer) async throws {
        let library = try FileSystemFactory.loadRclone()
        log.append(.status, "Opening your browser to authorise \(backend.rawValue)")
        let client = RcloneClient(transport: library).withLogger { kind, message in log.append(kind, message) }
        let token = try await RcloneOAuth(client: client).authorize(backend: backend, options: connection.cloud?.options ?? [:])
        try await secrets.setSecret(token, for: connection.id, purpose: .cloudToken)
        log.registerSecret(token)
    }

    func hostKeyValidator(host: String, port: Int, log: LogBuffer) -> SSHHostKeyValidator {
        let hosts = knownHosts
        let prompts = self.prompts
        return SSHHostKeyValidator { key in
            let verdict = (try? await hosts.verdict(host: host, port: port, keyType: key.algorithm, fingerprint: key.fingerprint)) ?? .unknown
            var previous: String?
            switch verdict {
            case .trusted:
                return true
            case .unknown:
                log.append(.status, "New host key \(key.algorithm) \(key.fingerprint)")
            case .changed(let old):
                previous = old
                log.append(.warning, "The host key for \(host) changed (was \(old), now \(key.fingerprint))")
            }
            let request = HostKeyRequest(
                host: host, port: port, algorithm: key.algorithm, fingerprint: key.fingerprint, previousFingerprint: previous)
            let trusted = await prompts.askHostKey(request)
            if trusted {
                try? await hosts.trust(host: host, port: port, keyType: key.algorithm, fingerprint: key.fingerprint)
            } else {
                log.append(.error, "Host key rejected")
            }
            return trusted
        }
    }

    // MARK: Quick connect

    func requestQuickConnectFocus() { quickConnectFocusToken += 1 }

    func quickConnect(choice: QuickProtocol, host: String, port: String, user: String, password: String) async {
        let portNumber = port.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Int(port.trimmingCharacters(in: .whitespaces))
        if portNumber == nil, !port.trimmingCharacters(in: .whitespaces).isEmpty {
            alertMessage = "The port must be a number."
            return
        }
        do {
            switch choice {
            case .cloud(let presetID):
                guard let preset = CloudPreset.preset(id: presetID) else { return }
                let connection = try await cloudQuickConnection(preset: preset, host: host, user: user, secret: password)
                open(connection, newTab: true)
            case .sftp, .ftp, .ftps:
                let input = QuickConnectInput(
                    protocolChoice: choice.connectionProtocol ?? .sftp, host: host, port: portNumber,
                    username: user, password: password.isEmpty ? nil : password)
                let result = try await quickConnectService.connect(input)
                open(result.connection, newTab: true, initialPath: result.initialPath)
            }
            await reloadQuickHistory()
        } catch let error as QuickConnectError {
            alertMessage = Self.describe(error)
        } catch {
            alertMessage = error.userMessage
        }
    }

    static func describe(_ error: QuickConnectError) -> String {
        switch error {
        case .missingHost: "Enter a host name or paste a URL such as sftp://user@host."
        case .invalidPort(let text): "\"\(text)\" is not a valid port."
        case .badURL(let urlError):
            switch urlError {
            case .missingScheme: "The URL needs a scheme such as sftp://."
            case .unsupportedScheme(let scheme): "Dockyard does not support \(scheme):// URLs."
            case .missingHost: "The URL has no host."
            case .invalidPort(let text): "\"\(text)\" is not a valid port."
            }
        }
    }

    private func cloudQuickConnection(preset: CloudPreset, host: String, user: String, secret: String) async throws -> Connection {
        let spec = preset.spec()
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        let existing = try await connections.fetch(.source(.quickConnect)).first {
            $0.protocol == .rclone && $0.cloud?.backend == spec.backend
                && $0.cloud?.options["provider"] == spec.options["provider"]
                && $0.host == trimmedHost && $0.username == trimmedUser
        }
        var connection: Connection
        if var found = existing {
            found.isNew = false
            found.lastConnectedAt = Date()
            connection = found
        } else {
            let name = trimmedHost.isEmpty ? preset.title : "\(preset.title) (\(trimmedHost))"
            connection = Connection(
                name: name, protocol: .rclone, host: trimmedHost, username: trimmedUser,
                authMethods: .password, source: .quickConnect, lastConnectedAt: Date(), isNew: true, cloud: spec)
        }
        try await connections.save(connection)
        if !secret.isEmpty { try await secrets.setSecret(secret, for: connection.id, purpose: .cloudToken) }
        return connection
    }

    // MARK: Connection management

    func toggleFavorite(_ connection: Connection) {
        Task { try? await connections.setFavorite(connection.id, !connection.favorite) }
    }

    func delete(_ connection: Connection) async {
        for session in sessions.filter({ $0.connection.id == connection.id }) { close(session) }
        for purpose in SecretPurpose.allCases { try? await secrets.removeSecret(for: connection.id, purpose: purpose) }
        try? await connections.delete(connection.id)
    }

    func duplicate(_ connection: Connection) async -> Connection {
        var copy = connection
        copy.id = UUID()
        copy.name = "\(connection.name) copy"
        copy.favorite = false
        copy.isNew = false
        copy.lastConnectedAt = nil
        copy.createdAt = Date()
        copy.source = .manual
        copy.userEditedFields = []
        try? await connections.save(copy)
        for purpose in SecretPurpose.allCases {
            if let value = try? await secrets.secret(for: connection.id, purpose: purpose) {
                try? await secrets.setSecret(value, for: copy.id, purpose: purpose)
            }
        }
        return copy
    }

    func editConnection(_ connection: Connection?, origin: SiteEditorRequest.Origin, connectAfterSave: Bool = false) {
        siteEditor = SiteEditorRequest(connection: connection, origin: origin, connectAfterSave: connectAfterSave)
    }

    func importFileZilla(from url: URL) async -> String {
        do {
            let data = try Data(contentsOf: url)
            let parsed = try FileZillaParser.parse(data)
            let importer = FileZillaImporter(repository: connections, folders: folders, secrets: secrets)
            let summary = try await importer.apply(parsed)
            var text = "Imported \(summary.created) connection\(summary.created == 1 ? "" : "s")"
            if summary.skippedDuplicates > 0 { text += ", skipped \(summary.skippedDuplicates) already saved" }
            if summary.needingPassword > 0 { text += ". \(summary.needingPassword) will ask for a password on first connect" }
            if !summary.warnings.isEmpty { text += ".\n" + summary.warnings.prefix(5).joined(separator: "\n") }
            return text
        } catch {
            return "Import failed: \(error.userMessage)"
        }
    }

    func addWHMSource(label: String, host: String, port: Int, apiUser: String, token: String) async -> String {
        let source = WHMSource(label: label.isEmpty ? host : label, host: host, apiPort: port, apiUser: apiUser)
        do {
            try await whmSources.save(source)
            try await WHMSyncService.storeToken(token, for: source, in: secrets)
            let report = try await whmSync.sync(source)
            return "Synced \(report.accountCount) accounts: \(report.created) new, \(report.updated) updated, \(report.removed) removed."
        } catch {
            return "Saved the server, but the first sync failed: \(error.userMessage)"
        }
    }

    func syncWHM(_ source: WHMSource) async -> String {
        do {
            let report = try await whmSync.sync(source)
            return "Synced \(report.accountCount) accounts: \(report.created) new, \(report.updated) updated, \(report.removed) removed."
        } catch {
            return "Sync failed: \(error.userMessage)"
        }
    }

    // MARK: Drawer

    func toggleDrawer(tab: DrawerTab) {
        if drawerVisible && drawerTab == tab {
            drawerVisible = false
        } else {
            drawerTab = tab
            drawerVisible = true
        }
    }
}
