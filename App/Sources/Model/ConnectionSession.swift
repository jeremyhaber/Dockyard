import ConnectionKit
import DockyardCore
import Foundation
import Observation

enum SessionStatus: Equatable {
    case connecting
    case connected
    case reconnecting
    case failed(String)
    case disconnected

    var isConnected: Bool { self == .connected }

    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .failed: "Failed"
        case .disconnected: "Disconnected"
        }
    }
}

/// One open connection tab: its file system, both panes and its log.
@MainActor @Observable
final class ConnectionSession: Identifiable {
    let id = UUID()
    private(set) var connection: Connection
    let log: LogBuffer
    let localFS: any RemoteFileSystem = DemoMode.isEnabled ? DemoFileSystem(kind: .local) : LocalFileSystem()

    private(set) var status: SessionStatus = .connecting
    private(set) var fs: (any RemoteFileSystem)?
    private(set) var local: PaneModel?
    private(set) var server: PaneModel?
    var restoreNotice: String?
    private(set) var logCounts: LogCounts
    private(set) var logVersion = 0
    /// Last failure from a file operation, shown in an alert.
    var operationError: String?
    /// True while the SFTP subsystem runs as root (HANDOFF 6).
    private(set) var browsingAsRoot = false
    /// Set by "Browse files as root" in the terminal bar: the next connect elevates even if the site did not ask for it.
    var rootBrowsingOverride = false

    /// Bumped when shells are added, closed or selected, so views reading `terminals` update. The lazy first shell does not bump it.
    private var terminalRevision = 0
    @ObservationIgnored private var shells: [TerminalController] = []
    /// Which checkers and web servers the server has, found once by the inline editor.
    @ObservationIgnored var editorTools: ServerTools?
    @ObservationIgnored private var activeShellID: UUID?
    @ObservationIgnored private var shellCounter = 0
    @ObservationIgnored private var suppressedKinds: Set<OperationKind> = []
    @ObservationIgnored var onSessionChange: ((ConnectionSession) -> Void)?
    @ObservationIgnored var connectTask: Task<Void, Never>?
    @ObservationIgnored private var logTask: Task<Void, Never>?
    @ObservationIgnored private var attachTask: Task<Void, Never>?

    init(connection: Connection) {
        self.connection = connection
        let name = connection.name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let writer = RollingLogFileWriter(
            directory: AppPaths.logsDirectory,
            name: "\(name.isEmpty ? "connection" : name)-\(connection.id.uuidString.prefix(8))")
        self.log = LogBuffer(fileWriter: DemoMode.isEnabled || !AppSettings.logFilesEnabled ? nil : writer)
        self.logCounts = log.counts
        followLog()
    }

    private func followLog() {
        let log = self.log
        logTask = Task { [weak self] in
            for await counts in log.updates() {
                guard let self else { return }
                self.logCounts = counts
                self.logVersion += 1
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    // MARK: Lifecycle

    func updateConnection(_ connection: Connection) { self.connection = connection }

    func setStatus(_ status: SessionStatus) { self.status = status }

    func attach(_ fs: any RemoteFileSystem) {
        attachTask?.cancel()
        self.fs = fs
        attachTask = log.attach(to: fs.logStream)
    }

    func fail(_ error: Error) {
        let message = error.userMessage
        log.append(.error, message)
        status = .failed(message)
    }

    func install(local: PaneModel, server: PaneModel, notice: String?) {
        self.local = local
        self.server = server
        restoreNotice = notice
        let log = self.log
        for pane in [local, server] {
            pane.onLog = { kind, message in log.append(kind, message) }
            pane.onStateChange = { [weak self] in
                guard let self else { return }
                self.onSessionChange?(self)
            }
        }
        status = .connected
    }

    func teardown() async {
        local = nil
        server = nil
        browsingAsRoot = false
        for shell in shells { await shell.stop() }
        shells = []
        activeShellID = nil
        shellCounter = 0
        terminalRevision += 1
        let current = fs
        fs = nil
        await current?.disconnect()
        attachTask?.cancel()
    }

    func markDisconnected() { status = .disconnected }

    func setBrowsingAsRoot(_ value: Bool) { browsingAsRoot = value }

    // MARK: Terminal

    var shellAvailable: Bool { fs?.supportsShell ?? false }

    /// Shell tabs in creation order (the first is created on demand).
    var terminals: [TerminalController] {
        _ = terminalRevision
        _ = activeTerminal
        return shells
    }

    /// The selected shell; creates "Shell 1" when there is none yet.
    var activeTerminal: TerminalController {
        _ = terminalRevision
        if let id = activeShellID, let found = shells.first(where: { $0.id == id }) { return found }
        if let first = shells.first {
            activeShellID = first.id
            return first
        }
        return makeShell()
    }

    /// The active shell (kept for callers that just want "the terminal").
    func terminal() -> TerminalController { activeTerminal }

    @discardableResult
    func newTerminal() -> TerminalController {
        _ = activeTerminal
        let created = makeShell()
        terminalRevision += 1
        return created
    }

    func selectTerminal(_ controller: TerminalController) {
        guard shells.contains(where: { $0.id == controller.id }), activeShellID != controller.id else { return }
        activeShellID = controller.id
        terminalRevision += 1
    }

    /// Stops and removes a shell. Closing the last one leaves a fresh idle "Shell 1".
    func closeTerminal(_ controller: TerminalController) {
        guard let index = shells.firstIndex(where: { $0.id == controller.id }) else { return }
        shells.remove(at: index)
        if shells.isEmpty { shellCounter = 0 }
        if activeShellID == controller.id {
            activeShellID = shells.isEmpty ? nil : shells[min(index, shells.count - 1)].id
        }
        terminalRevision += 1
        Task { await controller.stop() }
        if shells.isEmpty { _ = activeTerminal }
    }

    private func makeShell() -> TerminalController {
        shellCounter += 1
        let created = TerminalController(session: self, title: "Shell \(shellCounter)")
        // `crontab -e` typed in this shell opens the visual cron editor instead.
        created.onEditCrontab = { [weak self] in
            guard let self else { return }
            AppModel.shared.openCronEditor(for: self)
        }
        shells.append(created)
        activeShellID = created.id
        return created
    }

    /// Opens a shell on the existing connection (no second login).
    func openShell(cols: Int, rows: Int) async throws -> any ShellBackend {
        guard let fs else { throw RemoteError.notConnected }
        if let sftp = fs as? SFTPFileSystem { return try await sftp.openShell(cols: cols, rows: rows) }
        if let demo = fs as? DemoFileSystem, demo.supportsShell {
            return DemoShell(host: connection.host, user: connection.username, elevated: connection.elevation != .none)
        }
        throw RemoteError.unsupported("This connection has no shell")
    }

    // MARK: Panes

    func pane(_ side: PaneSide) -> PaneModel? { side == .local ? local : server }

    func otherSide(_ side: PaneSide) -> PaneSide { side == .local ? .server : .local }

    func endpoint(_ side: PaneSide) -> TransferEndpoint {
        switch side {
        case .local: TransferEndpoint(fs: localFS, label: "This Mac")
        case .server: TransferEndpoint(fs: fs ?? localFS, label: connection.name, siteId: connection.id)
        }
    }

    func sessionState() -> SessionState? {
        guard let local, let server else { return nil }
        return SessionState(
            connectionId: connection.id,
            localTabs: local.sessionTabs, remoteTabs: server.sessionTabs,
            activeLocalTab: local.activeTabIndex, activeRemoteTab: server.activeTabIndex,
            localTreeExpanded: local.expandedPaths, remoteTreeExpanded: server.expandedPaths)
    }

    func refreshPanes() {
        local?.invalidate(); local?.reload()
        server?.invalidate(); server?.reload()
    }

    // MARK: File operations

    private func run(_ title: String, side: PaneSide, _ body: (PaneModel) async throws -> Void) async {
        guard let pane = pane(side) else { return }
        do {
            try await body(pane)
        } catch {
            log.append(.error, "\(title): \(error.userMessage)")
            operationError = "\(title): \(error.userMessage)"
        }
        pane.invalidate()
        pane.reload()
    }

    func createFolder(named name: String, in side: PaneSide) async {
        guard await authorize(.mkdir, paths: [name], side: side) else { return }
        await run("New folder", side: side) { pane in
            let path = RemotePath.join(pane.currentPath, name)
            try await pane.fs.mkdir(path)
            if side == .local { self.log.append(.status, "Created local folder \(path)") }
            self.record(ChangeEntry(scope: self.scope(side), kind: .newFolder, toPath: path, isDirectory: true), side: side)
        }
    }

    func rename(_ item: RemoteItem, to newName: String, in side: PaneSide) async {
        guard newName != item.name, !newName.isEmpty else { return }
        guard await authorize(.rename, paths: [item.path], side: side) else { return }
        await run("Rename", side: side) { pane in
            let target = RemotePath.join(RemotePath.parent(of: item.path), newName)
            try await pane.fs.rename(item.path, target)
            if side == .local { self.log.append(.status, "Renamed \(item.path) to \(target)") }
            self.record(
                ChangeEntry(scope: self.scope(side), kind: .rename, fromPath: item.path, toPath: target, isDirectory: item.isDirectory),
                side: side)
        }
    }

    /// Server deletes are real deletes. Local deletes go to the macOS Trash.
    func delete(_ items: [RemoteItem], in side: PaneSide) async {
        guard await authorize(.delete, paths: items.map(\.path), side: side) else { return }
        await run("Delete", side: side) { pane in
            for item in items {
                if side == .local, !DemoMode.isEnabled {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                    self.log.append(.status, "Moved \(item.path) to the Trash")
                } else {
                    if side == .server, self.connection.trashOnDelete {
                        let outcome = try await AppModel.shared.safetyNet(for: self.connection).prepareDelete(path: item.path, on: pane.fs)
                        if !outcome.originalStillInPlace { continue }
                    }
                    try await pane.fs.delete(item.path, recursive: item.isDirectory)
                    if side == .local { self.log.append(.status, "Deleted \(item.path)") }
                }
            }
        }
    }

    func chmod(_ items: [RemoteItem], mode: UInt16, in side: PaneSide) async {
        guard await authorize(.chmod, paths: items.map(\.path), side: side) else { return }
        await run("Change permissions", side: side) { pane in
            for item in items {
                try await pane.fs.chmod(item.path, mode: mode)
                guard let previous = item.permissions else { continue }
                self.record(
                    ChangeEntry(scope: self.scope(side), kind: .chmod, toPath: item.path, isDirectory: item.isDirectory, previousMode: previous, newMode: mode),
                    side: side, toast: false)
            }
        }
    }

    /// Moves items to another folder on the same file system.
    func move(_ items: [RemoteItem], to directory: String, in side: PaneSide) async {
        guard await authorize(.move, paths: items.map(\.path), side: side) else { return }
        await run("Move", side: side) { pane in
            for item in items {
                let target = RemotePath.join(directory, item.name)
                try await pane.fs.rename(item.path, target)
                self.record(
                    ChangeEntry(scope: self.scope(side), kind: .move, fromPath: item.path, toPath: target, isDirectory: item.isDirectory),
                    side: side)
            }
        }
    }

    // MARK: Guardrails

    /// Read-only refusals and PROD confirmations for server writes. Local operations are never guarded.
    /// True when `authorize` will show the PROD confirmation, so callers skip their own and the user sees one dialog.
    func asksBeforeRunning(_ kind: OperationKind, paths: [String], side: PaneSide) -> Bool {
        guard side == .server else { return false }
        if case .confirm = Guardrails.decide(GuardedOperation(kind, paths: paths), for: connection, suppressed: suppressedKinds) { return true }
        return false
    }

    func authorize(_ kind: OperationKind, paths: [String], side: PaneSide = .server) async -> Bool {
        guard side == .server else { return true }
        switch Guardrails.decide(GuardedOperation(kind, paths: paths), for: connection, suppressed: suppressedKinds) {
        case .allow:
            return true
        case .deny(let reason):
            log.append(.warning, reason)
            operationError = reason
            return false
        case .confirm(let summary):
            var message = "\(connection.name) is a PROD site."
            if summary.hiddenCount > 0 { message += " \(summary.hiddenCount) more are not listed." }
            if kind == .delete, !connection.trashOnDelete { message += " The items are deleted from the server and cannot be recovered." }
            let request = ConfirmRequest(
                title: summary.title, message: message, confirmTitle: kind == .delete ? "Delete" : "Overwrite",
                items: summary.items, suppressTitle: summary.canSuppressForSession ? "Don\u{2019}t ask again for this session" : nil)
            let answer = await AppModel.shared.prompts.askConfirmDetailed(request)
            if answer.confirmed, answer.suppress { suppressedKinds.insert(kind) }
            return answer.confirmed
        }
    }

    // MARK: Journal

    /// The change journal scope of one of this session's panes.
    func scope(_ side: PaneSide) -> UUID { side == .local ? ChangeEntry.localScope : connection.id }

    private func record(_ entry: ChangeEntry, side: PaneSide, toast: Bool = true) {
        AppModel.shared.recordChange(entry, session: self, side: side, toast: toast)
    }
}
