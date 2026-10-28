import SwiftUI

/// Settings sections for notifications, Touch ID and updates.
struct MacSettingsSections: View {
    @AppStorage(AppSettings.notificationMode) private var notifications = AppSettings.NotificationMode.failedOnly.rawValue
    @AppStorage(AppSettings.requireTouchID) private var requireTouchID = false
    @AppStorage(AppSettings.touchIDGraceMinutes) private var graceMinutes = AppSettings.defaultTouchIDGraceMinutes
    @State private var automaticUpdates = UpdateModel.shared.automaticChecks

    var body: some View {
        Section("Notifications") {
            Picker("Notify when a batch of transfers ends", selection: $notifications) {
                ForEach(AppSettings.NotificationMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Text("One notification per batch, and only while Dockyard is in the background. macOS asks for permission the first time.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
        }
        Section("Security") {
            Toggle("Require Touch ID to use saved passwords", isOn: $requireTouchID)
            if requireTouchID {
                Stepper(value: $graceMinutes, in: AppSettings.touchIDGraceRange) {
                    LabeledContent(
                        "Ask again after",
                        value: graceMinutes == 0 ? "every connection" : "\(graceMinutes) minute\(graceMinutes == 1 ? "" : "s")")
                }
            }
            Text("Dockyard asks before it reads a password from the Keychain to connect. Macs without Touch ID use the account password. The approval ends when the Mac sleeps. Finder mounts read the Keychain on their own and are not covered.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
        }
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { automaticUpdates },
                set: { automaticUpdates = $0; UpdateModel.shared.automaticChecks = $0 }))
                .disabled(!UpdateModel.isConfigured)
            if !UpdateModel.isConfigured {
                Text(DemoMode.isEnabled ? "Updates are turned off in demo mode." : "This build has no update feed.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
        }
    }
}
