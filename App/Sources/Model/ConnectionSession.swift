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
        self.log = LogBuffer(fileWriter: DemoMode.isEnabled ? nil : writer)
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
        let current = fs
        fs = nil
        await current?.disconnect()
        attachTask?.cancel()
    }

    func markDisconnected() { status = .disconnected }

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
        await run("New folder", side: side) { pane in
            let path = RemotePath.join(pane.currentPath, name)
            try await pane.fs.mkdir(path)
            if side == .local { self.log.append(.status, "Created local folder \(path)") }
        }
    }

    func rename(_ item: RemoteItem, to newName: String, in side: PaneSide) async {
        guard newName != item.name, !newName.isEmpty else { return }
        await run("Rename", side: side) { pane in
            let target = RemotePath.join(RemotePath.parent(of: item.path), newName)
            try await pane.fs.rename(item.path, target)
            if side == .local { self.log.append(.status, "Renamed \(item.path) to \(target)") }
        }
    }

    func delete(_ items: [RemoteItem], in side: PaneSide) async {
        await run("Delete", side: side) { pane in
            for item in items {
                try await pane.fs.delete(item.path, recursive: item.isDirectory)
                if side == .local { self.log.append(.status, "Deleted \(item.path)") }
            }
        }
    }

    func chmod(_ items: [RemoteItem], mode: UInt16, in side: PaneSide) async {
        await run("Change permissions", side: side) { pane in
            for item in items { try await pane.fs.chmod(item.path, mode: mode) }
        }
    }

    /// Moves items to another folder on the same file system.
    func move(_ items: [RemoteItem], to directory: String, in side: PaneSide) async {
        await run("Move", side: side) { pane in
            for item in items {
                try await pane.fs.rename(item.path, RemotePath.join(directory, item.name))
            }
        }
    }

    /// Downloads one file to a temporary folder so the caller can open it.
    func fetchForOpening(_ item: RemoteItem) async throws -> URL {
        guard let fs else { throw RemoteError.notConnected }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockyard-open", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(item.name)
        let progress = Progress(totalUnitCount: Int64(item.size ?? 0))
        try await fs.download(item.path, to: url, progress: progress)
        return url
    }

    func queueTransfer(
        _ items: [RemoteItem], from source: PaneSide, to destination: PaneSide, directory: String,
        move: Bool, queue: TransferQueue
    ) {
        guard !items.isEmpty else { return }
        let src = endpoint(source), dst = endpoint(destination)
        Task {
            _ = await queue.enqueue(items: items, from: src, to: dst, into: directory, move: move)
        }
    }
}
