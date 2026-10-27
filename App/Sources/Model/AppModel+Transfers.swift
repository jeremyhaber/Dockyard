import AppKit
import ConnectionKit
import DockyardCore
import Foundation
import Observation

enum TransferTab: String, CaseIterable, Identifiable {
    case active = "Active", queued = "Queued", failed = "Failed", done = "Done"
    var id: String { rawValue }

    /// Active, queued and failed list files; Done lists top-level jobs so folders can be opened.
    var filter: TransferJobFilter {
        switch self {
        case .active: TransferJobFilter(scope: .files, states: [.running])
        case .queued: TransferJobFilter(scope: .files, states: [.queued])
        case .failed: TransferJobFilter(scope: .files, states: [.failed])
        case .done: TransferJobFilter(scope: .topLevel, states: [.completed, .skipped, .cancelled])
        }
    }

    func count(in s: TransferSnapshot) -> Int {
        switch self {
        case .active: s.activeCount
        case .queued: s.queuedCount
        case .failed: s.failedCount
        case .done: s.completedCount + s.skippedCount + s.cancelledCount
        }
    }
}

/// UI state of the Transfers tab.
@MainActor @Observable
final class TransferCenter {
    var tab: TransferTab = .active
    /// The folder job whose files the table shows, if one is open.
    var folder: TransferJobInfo?
    @ObservationIgnored var lastFailed: Int?
    @ObservationIgnored var appliedFilters: String?
}

extension AppModel {
    func showTransfers(tab: TransferTab? = nil) {
        if let tab { transferUI.tab = tab }
        drawerTab = .transfers
        drawerVisible = true
    }

    /// Opens the Transfers tab on its Failed list. Notifications deep-link here.
    func showFailedTransfers() { showTransfers(tab: .failed) }

    var transferRate: Double { DemoMode.isEnabled ? 24_800_000 : transfers.rate }

    /// Dock badge and the "N transfers failed" toast when the failed count grows.
    func trackTransferFailures(_ snapshot: TransferSnapshot) {
        let failed = snapshot.failedCount
        NSApplication.shared.dockTile.badgeLabel = failed > 0 ? "\(failed)" : nil
        let previous = transferUI.lastFailed
        transferUI.lastFailed = failed
        guard !DemoMode.isEnabled, let previous, failed > previous else { return }
        showFailureToast(failed)
    }

    func showFailureToast(_ failed: Int) {
        toasts.removeAll { $0.link == .failedTransfers }
        showToast("\(failed) transfer\(failed == 1 ? "" : "s") failed", symbol: "exclamationmark.triangle", isError: true, link: .failedTransfers)
    }

    /// Shows where a transfer put its file: Finder for downloads, a new tab in the connection for uploads.
    func revealTransfer(_ job: TransferJobInfo) {
        let parts = job.route.components(separatedBy: " \u{2192} ")
        guard parts.count == 2 else { return }
        if parts[1] == "This Mac" {
            let url = URL(fileURLWithPath: job.destinationPath)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url.deletingLastPathComponent())
            }
        } else if let session = sessions.first(where: { $0.connection.name == parts[1] }) {
            activate(session)
            session.server?.openTab(at: RemotePath.parent(of: job.destinationPath))
        } else {
            showToast("Open \(parts[1]) to reveal this item", symbol: "exclamationmark.circle", isError: true)
        }
    }

    func copyTransferErrors(_ jobs: [TransferJobInfo]) {
        let text = jobs.compactMap { job in job.error.map { "\(job.name): \($0)" } }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func applyLeftoverChoice(_ choice: LeftoverChoice) async {
        switch choice {
        case .ask, .keep: break
        case .resume: await queue.resume()
        case .retryFailed:
            await queue.retryFailed()
            await queue.resume()
        case .clear:
            await queue.cancelAll()
            await queue.removeFinished(includingCancelled: true)
            await queue.removeFailed()
        }
    }

    func clearFailedTransfers() { let q = queue; Task { await q.removeFailed() } }
}
