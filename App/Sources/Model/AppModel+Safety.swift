import AppKit
import ConnectionKit
import DockyardCore
import Foundation

// MARK: - Versions, trash and checksums

extension AppModel {
    /// The safety net for one site: versions and trash per its switches, logging to the site's tab, asking before going unprotected.
    func safetyNet(for connection: Connection) -> SafetyNet {
        let id = connection.id
        let prompts = self.prompts
        return SafetyNet(
            policy: SafetyPolicy(connection),
            decision: { failure in
                let name = RemotePath.lastComponent(of: failure.path)
                let verb = failure.operation == .delete ? "delete" : "overwrite"
                return await prompts.askConfirm(ConfirmRequest(
                    title: "Could not keep a copy of \"\(name)\"",
                    message: "\(failure.reason)\n\nContinue and \(verb) it without a backup?",
                    confirmTitle: failure.operation == .delete ? "Delete" : "Overwrite", symbol: "exclamationmark.triangle"))
            },
            log: { kind, message in
                Task { @MainActor in AppModel.shared.session(for: id)?.log.append(kind, message) }
            })
    }

    /// Hook for edit in place and the queue: keeps the old version when the site asks for it.
    func overwriteHook(for connection: Connection) -> (@Sendable (String, any RemoteFileSystem) async throws -> Void)? {
        guard connection.keepVersionsOnOverwrite else { return nil }
        let net = safetyNet(for: connection)
        return { path, fs in _ = try await net.prepareOverwrite(path: path, on: fs) }
    }

    /// Deletes entries older than the retention setting from the trash when a connection opens.
    func purgeKeptVersions(_ session: ConnectionSession) {
        let c = session.connection
        guard !DemoMode.isEnabled, c.keepVersionsOnOverwrite || c.trashOnDelete, let fs = session.fs else { return }
        let log = session.log
        let days = AppSettings.trashRetention
        Task {
            let browser = TrashBrowser(fs: fs, log: { kind, message in log.append(kind, message) })
            guard let removed = try? await browser.purge(olderThanDays: days), !removed.isEmpty else { return }
            log.append(.status, "Purged \(removed.count) day\(removed.count == 1 ? "" : "s") of old versions (older than \(days) days)")
        }
    }

    func showVersions(for session: ConnectionSession) { safety.versionsSessionID = session.id }

    var versionsSession: ConnectionSession? {
        safety.versionsSessionID.flatMap { id in sessions.first { $0.id == id } }
    }

    /// An endpoint the queue can use for a saved connection that may not be open: its site is registered first.
    func transferEndpoint(for connection: Connection) async -> TransferEndpoint {
        let site = transferSite(for: connection)
        await queue.register(site: site)
        let fs: any RemoteFileSystem = session(for: connection.id)?.fs ?? ((try? makeQueueSession(for: connection)) ?? LocalFileSystem())
        return site.endpoint(fs: fs)
    }
}

// MARK: - Search

extension AppModel {
    /// ⌘F: opens the search bar of the active connection's server pane.
    func openSearch() {
        guard let session = activeSession, session.server != nil else { return }
        focusedSide = .server
        safety.search(for: session).open()
    }

    /// Shows a search hit in a new folder tab of the server pane.
    func reveal(_ hit: SearchHit, in session: ConnectionSession) {
        let folder = hit.isDirectory == true ? hit.path : RemotePath.parent(of: hit.path)
        session.server?.openTab(at: folder)
    }
}

// MARK: - One-click cPanel and WHM login

extension AppModel {
    func canOpenCPanel(_ connection: Connection) -> Bool { connection.source.whmServerId != nil }

    func openCPanel(for connection: Connection) {
        guard let serverID = connection.source.whmServerId else { return }
        Task { await openWHMSession(serverID: serverID, service: .cpanel, account: connection.username) }
    }

    func openWHM(_ source: WHMSource) {
        Task { await openWHMSession(serverID: source.id, service: .whm, account: source.apiUser) }
    }

    private func openWHMSession(serverID: UUID, service: WHMService, account: String) async {
        let target = service == .cpanel ? "cPanel" : "WHM"
        do {
            guard let source = try await whmSources.all().first(where: { $0.id == serverID }) else {
                throw WHMError.api("The WHM server is no longer in your list")
            }
            if DemoMode.isEnabled {
                showToast("Demo: would open \(target) for \(account) on \(source.label)", symbol: "safari")
                return
            }
            guard let token = try await ungatedSecrets.secret(for: source.id, purpose: .cloudToken), !token.isEmpty else {
                throw WHMError.api("No API token saved for \(source.label)")
            }
            let client = WHMClient(host: source.host, port: source.apiPort, apiUser: source.apiUser, token: token,
                                   transport: URLSessionTransport(trustSelfSignedFor: source.host))
            let login: WHMLoginSession
            if service == .cpanel { login = try await client.cpanelLogin(for: account) } else { login = try await client.whmLogin() }
            NSWorkspace.shared.open(login.url)
        } catch {
            showToast("Could not open \(target): \(error.userMessage)", symbol: "exclamationmark.circle", isError: true)
        }
    }
}
