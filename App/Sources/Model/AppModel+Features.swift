import ConnectionKit
import DockyardCore
import Foundation

enum LayoutMode: String, Hashable, CaseIterable {
    case localServer, sideBySide
}

/// The "Drop to copy 2 files here" text shown over the column a drag is hovering.
struct DropHint: Equatable {
    var paneID: UUID
    var text: String
}

/// The change an "Undo" button on a toast reverses.
struct UndoTarget: Equatable {
    var entry: ChangeEntry
    var sessionID: UUID
    var side: PaneSide
}

/// A button on a toast that is not a journal undo, such as restoring removed connections.
struct ToastAction: Equatable {
    let id = UUID()
    var title: String
    var perform: @MainActor () -> Void

    static func == (lhs: ToastAction, rhs: ToastAction) -> Bool { lhs.id == rhs.id }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var symbol = "checkmark.circle"
    var isError = false
    var undo: UndoTarget?
    var action: ToastAction?
    var link: ToastLink?
}

/// Where a toast's "View" button leads.
enum ToastLink: Equatable { case failedTransfers }

// MARK: - Root browsing

extension AppModel {
    /// Decides whether this connect starts the SFTP subsystem as root, asking first on PROD sites.
    func shouldBrowseAsRoot(_ session: ConnectionSession) async -> Bool {
        let c = session.connection
        guard c.protocol == .sftp, c.elevation != .none, c.elevateFileBrowsing || session.rootBrowsingOverride else { return false }
        if DemoMode.isEnabled || !(c.isProd && c.askBeforeElevatingOnProd) { return true }
        return await prompts.askConfirm(ConfirmRequest(
            title: "Browse \(c.name) as root?",
            message: "This is a PROD site. Changes made as root bypass the account's permissions and can leave files owned by root. "
                + "Dockyard asks because \"Ask before elevating on PROD sites\" is on for this connection.",
            confirmTitle: "Browse as Root", cancelTitle: "Use Normal User"))
    }

    static func isBrowsingAsRoot(_ fs: any RemoteFileSystem) async -> Bool {
        if let sftp = fs as? SFTPFileSystem { return await sftp.isBrowsingAsRoot }
        if let demo = fs as? DemoFileSystem { return demo.browsesAsRoot }
        return false
    }
}

// MARK: - Settings

extension AppModel {
    /// Pushes the Settings window's values to the running transfer queue and the WHM timer.
    func applySettings() {
        let filters = AppSettings.globalFilterPatterns.joined(separator: "\n")
        if filters != transferUI.appliedFilters {
            transferUI.appliedFilters = filters
            for session in sessions { registerTransferSite(session.connection) }
        }
        let policy = AppSettings.conflictPolicy
        let queue = self.queue
        Task { await queue.setConflictPolicy(policy) }
        let limit = AppSettings.maxConnections
        if limit != lastAppliedMaxConnections {
            lastAppliedMaxConnections = limit
            Task { await queue.setMaxConcurrent(limit) }
        }
        let interval = AppSettings.whmSyncInterval
        if interval != lastAppliedWHMInterval {
            lastAppliedWHMInterval = interval
            if let scheduler = whmScheduler { Task { await scheduler.setInterval(interval) } }
        }
    }

    /// Items saved by an earlier build in the file-based keychain are copied once into the shared keychain group.
    func migrateSecretsIfNeeded() {
        let flag = "secretsMigratedToKeychainGroup"
        guard AppGroup.keychainAccessGroup != nil, !UserDefaults.standard.bool(forKey: flag) else { return }
        let legacy = FileSystemFactory.legacySecretStore()
        let target = keychainSecrets
        let repository = connections
        Task {
            guard let all = try? await repository.fetch(.all) else { return }
            for connection in all {
                for purpose in SecretPurpose.allCases {
                    guard let value = try? await legacy.secret(for: connection.id, purpose: purpose),
                          (try? await target.secret(for: connection.id, purpose: purpose)) == nil else { continue }
                    try? await target.setSecret(value, for: connection.id, purpose: purpose)
                }
            }
            UserDefaults.standard.set(true, forKey: flag)
        }
    }
}

// MARK: - Finder mounts

extension AppModel {
    func reconcileMounts(_ list: [Connection]) {
        guard !DemoMode.isEnabled else { return }
        let folderRepository = folders
        let service = mounts
        Task {
            let names = Dictionary(
                ((try? await folderRepository.all()) ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            service.reconcile(connections: list, clientNames: names)
        }
    }

    /// Turns "Mount in Finder" on or off for a connection. The domain follows through `reconcileMounts`.
    func setMounted(_ connection: Connection, _ mounted: Bool) {
        guard connection.mountInFinder != mounted, MountPolicy.canMount(connection) else { return }
        var updated = connection
        updated.mountInFinder = mounted
        let repository = connections
        Task {
            do {
                try await repository.save(updated)
            } catch {
                alertMessage = "Could not update \(connection.name): \(error.userMessage)"
                return
            }
            if !AppGroup.isSigned {
                alertMessage = "The setting is saved, but this build is not signed with Dockyard's App Group, so the Finder extension cannot load. "
                    + "See docs/app.md for the signing setup."
            } else {
                showToast(mounted ? "\(connection.name) will appear in Finder under Locations" : "\(connection.name) removed from Finder")
            }
        }
    }
}

extension AppModel {
    /// Shows what the Finder extension did (it writes to a file in the App Group container) in each connection's Log.
    func startFinderLogRelay() {
        guard AppGroup.isSigned, !DemoMode.isEnabled else { return }
        Task {
            var offsets: [UUID: UInt64] = [:]
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                for session in sessions {
                    let id = session.connection.id
                    let from = offsets[id] ?? FinderLogFile.currentSize(connection: id)
                    let result = FinderLogFile.read(connection: id, from: from)
                    offsets[id] = result.next
                    for line in result.lines {
                        session.log.append(LogLine.Kind(rawValue: line.kind) ?? .status, line.message)
                    }
                }
            }
        }
    }
}

// MARK: - Toasts

extension AppModel {
    func showToast(
        _ text: String, symbol: String = "checkmark.circle", isError: Bool = false, undo: UndoTarget? = nil,
        link: ToastLink? = nil, action: ToastAction? = nil
    ) {
        let toast = Toast(text: text, symbol: symbol, isError: isError, undo: undo, action: action, link: link)
        toasts.append(toast)
        Task {
            let seconds: UInt64 = DemoMode.isEnabled ? 120 : (undo == nil && link == nil && action == nil ? 4 : 9)
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            toasts.removeAll { $0.id == toast.id }
        }
    }

    func handleEdit(_ event: EditEvent) {
        if let line = event.logLine, let session = sessions.first(where: { $0.connection.id == event.connectionId }) {
            session.log.append(line.kind, line.message)
        }
        guard let text = event.toast else { return }
        switch event.kind {
        case .uploaded: showToast(text, symbol: "arrow.up.doc")
        case .uploadFailed: showToast(text, symbol: "exclamationmark.triangle", isError: true)
        default: showToast(text, symbol: "exclamationmark.circle", isError: true)
        }
    }
}

// MARK: - Layout and side by side

extension AppModel {
    var columnSessions: [ConnectionSession] {
        columnIDs.compactMap { id in sessions.first { $0.id == id } }
    }

    func setLayout(_ mode: LayoutMode) {
        layoutMode = mode
        if mode == .sideBySide { seedColumns() }
    }

    /// Fills the columns with the active connection and the next open one when none are chosen yet.
    func seedColumns() {
        columnIDs = columnIDs.filter { id in sessions.contains { $0.id == id } }
        guard columnIDs.isEmpty else { return }
        let ordered = (activeSession.map { [$0] } ?? []) + sessions.filter { $0.id != activeSessionID }
        columnIDs = ordered.prefix(2).map(\.id)
    }

    func addColumn(_ session: ConnectionSession) {
        guard !columnIDs.contains(session.id) else { return }
        columnIDs.append(session.id)
        activeSessionID = session.id
    }

    func addColumn(_ connection: Connection) {
        open(connection)
        if let session = session(for: connection.id) { addColumn(session) }
    }

    func removeColumn(_ id: UUID) {
        columnIDs.removeAll { $0 == id }
    }

    /// ⌥↩ in the connection manager.
    func openSideBySide(_ connection: Connection) {
        open(connection)
        layoutMode = .sideBySide
        seedColumns()
        if let session = session(for: connection.id) { addColumn(session) }
    }

    /// Queues a server-to-server copy (or move) relayed through this Mac.
    func queueRelay(
        _ items: [RemoteItem], from source: ConnectionSession, to destination: ConnectionSession, directory: String, move: Bool
    ) {
        guard !items.isEmpty else { return }
        let from = source.endpoint(.server), to = destination.endpoint(.server)
        let queue = self.queue
        Task { _ = await queue.enqueue(items: items, from: from, to: to, into: directory, move: move) }
    }
}
