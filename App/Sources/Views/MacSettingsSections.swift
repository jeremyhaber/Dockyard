import SwiftUI

/// Settings sections for notifications, Touch ID and updates.
struct MacSettingsSections: View {
    @AppStorage(AppSettings.notificationMode) private var notifications = AppSettings.NotificationMode.failedOnly.rawValue
    @AppStorage(AppSettings.requireTouchID) private var requireTouchID = false
    @AppStorage(AppSettings.touchIDGraceMinutes) private var graceMinutes = AppSettings.defaultTouchIDGraceMinutes
    @AppStorage(AppSettings.terminalSuggestions) private var terminalSuggestions = true
    @AppStorage(AppSettings.checkFilesBeforeSaving) private var checkBeforeSaving = true
    @AppStorage(AppSettings.terminalEditorChoiceKey) private var editorChoiceRaw = ""
    @AppStorage(AppSettings.editorApp) private var editorApp = ""
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
        Section("Terminal") {
            Toggle("Suggest commands from history", isOn: $terminalSuggestions)
            Text("Shows the rest of a command you have run before in grey as you type. → or End accepts it, ⌥→ takes one word. Tab still completes on the server. Commands are remembered per connection on this Mac.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
            Picker("When you type nano, vim or another editor", selection: Binding(
                get: { _ = editorChoiceRaw; return AppSettings.terminalEditorChoice },
                set: { editorChoiceRaw = $0.rawValue })) {
                Text("Open in Dockyard\u{2019}s editor").tag(AppSettings.TerminalEditorChoice.dockyard)
                Text("Open in \(editorName)").tag(AppSettings.TerminalEditorChoice.macEditor)
                Text("Run it in the terminal").tag(AppSettings.TerminalEditorChoice.terminal)
            }
            Text("Type command vim to run the real editor.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
            Toggle("Check files before saving", isOn: $checkBeforeSaving)
            Text("Dockyard\u{2019}s editor runs the server\u{2019}s own checker on PHP, Python, JavaScript, shell, JSON, YAML and crontab files, and asks before saving one with errors. The file is sent to the checker over SSH and never written to a temporary file on the server, except for JavaScript. After saving an nginx, Apache or PHP-FPM config it also tests it.")
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

    private var editorName: String {
        guard let url = AppSettings.editorURL, editorApp == url.path else { return "the default app" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
