import AppKit
import DockyardCore
import UserNotifications

/// Posts one summary notification when a batch of transfers ends while Dockyard is in the background.
/// Permission is requested the first time one is due.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    nonisolated private static let failedCategory = "transfersFailed"

    /// Called when the user clicks a "transfers failed" notification. `AppModel.showFailedTransfers()` replaces
    /// the default once the Transfers tab is merged.
    var onShowFailedTransfers: @MainActor () -> Void = {
        let app = AppModel.shared
        app.drawerTab = .log
        app.drawerVisible = true
    }

    private var wasIdle = true
    private var baseline = (completed: 0, failed: 0)
    private var configured = false

    /// Feeds every queue snapshot; posts when a busy queue turns idle.
    func observe(_ snapshot: TransferSnapshot) {
        if !snapshot.isIdle {
            if wasIdle { baseline = (snapshot.completedCount, snapshot.failedCount) }
            wasIdle = false
            return
        }
        guard !wasIdle else { return }
        wasIdle = true
        let completed = max(0, snapshot.completedCount - baseline.completed)
        let failed = max(0, snapshot.failedCount - baseline.failed)
        guard completed + failed > 0, !DemoMode.isEnabled, !NSApp.isActive else { return }
        switch AppSettings.notifications {
        case .off: return
        case .failedOnly where failed == 0: return
        default: break
        }
        post(completed: completed, failed: failed)
    }

    /// One summary per batch. A later batch within moments replaces the earlier notification (same identifier).
    private func post(completed: Int, failed: Int) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        if !configured {
            center.delegate = self
            configured = true
        }
        let content = UNMutableNotificationContent()
        content.title = "Transfers finished: \(completed.formatted()) done, \(failed.formatted()) failed"
        content.body = failed > 0 ? "Open Dockyard to see what failed and retry." : "Everything in the queue went through."
        if failed > 0 { content.categoryIdentifier = Self.failedCategory }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "transfers.summary", content: content, trigger: nil)
        Task {
            // The first call shows the system permission prompt; a refusal simply means nothing is posted.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let failed = response.notification.request.content.categoryIdentifier == Self.failedCategory
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if failed { onShowFailedTransfers() }
        }
    }
}
