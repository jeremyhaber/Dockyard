import AppKit
import ConnectionKit
import DockyardCore
import Foundation
import Observation

/// What the app knows about 1Password: whether the CLI is installed and unlocked, and where the SSH agent listens.
@MainActor @Observable
final class OnePasswordCenter {
    let cli: OnePasswordCLI
    private(set) var status: OnePasswordStatus?
    private(set) var checking = false
    /// Set when `op` could not even report a status (timeout, unexpected output).
    private(set) var failure: String?
    private(set) var agentSocketFound = false

    init(cli: OnePasswordCLI) { self.cli = cli }

    var isReady: Bool { status?.isReady ?? false }

    /// Shown in Settings; `~` stays unexpanded so the text matches 1Password's own documentation.
    var agentSocketDisplayPath: String { AgentSocket.onePasswordDefaultPath }

    var accounts: [OnePasswordAccount] {
        switch status {
        case .ready(let list), .signedOut(let list): list
        default: []
        }
    }

    func refresh() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        failure = nil
        do {
            status = try await cli.status()
        } catch {
            status = nil
            failure = error.userMessage
        }
        let socket = AgentSocket.onePassword.resolvedPath()
        agentSocketFound = DemoMode.isEnabled || socket.map { FileManager.default.fileExists(atPath: $0) } == true
    }
}

extension AppModel {
    /// Resolved 1Password secrets are only kept for seconds, and not across sleep or a locked screen.
    func installSecretCacheFlush() {
        let store = resolvingSecrets
        let flush: @Sendable (Notification) -> Void = { _ in Task { await store.flushCache() } }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main, using: flush)
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: flush)
    }

    func flushSecretCache() {
        let store = resolvingSecrets
        Task { await store.flushCache() }
    }
}
