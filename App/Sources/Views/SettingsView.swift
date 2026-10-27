import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
    @AppStorage(AppSettings.globalMaxConnections) private var maxConnections = AppSettings.defaultGlobalMaxConnections
    @AppStorage(AppSettings.writeLogFiles) private var writeLogFiles = true
    @AppStorage(AppSettings.defaultLocalFolder) private var localFolder = ""
    @AppStorage(AppSettings.finderPollSeconds, store: AppGroup.sharedDefaults) private var pollSeconds = 30.0
    @AppStorage(AppSettings.whmSyncHours) private var whmHours = 6

    var body: some View {
        Form {
            Section("Transfers") {
                Stepper(value: $maxConnections, in: AppSettings.globalMaxRange) {
                    LabeledContent("Maximum connections", value: "\(maxConnections)")
                }
                Text("The most transfers running at once across all sites. Each site also has its own limit.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Section("Logging") {
                Toggle("Write a log file for each connection", isOn: $writeLogFiles)
                Text("Files are kept in ~/Library/Logs/Dockyard and rotate automatically. Applies to connections opened from now on.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Section("Local folder") {
                HStack {
                    TextField("Default folder", text: $localFolder, prompt: Text("Your home folder"))
                    Button("Choose\u{2026}") { chooseFolder() }
                    if !localFolder.isEmpty { Button("Clear") { localFolder = "" } }
                }
                Text("Where the local pane starts when a connection has no folder of its own and no session to restore.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Section("Finder") {
                Stepper(value: $pollSeconds, in: 5...3600, step: 5) {
                    LabeledContent("Check for server changes every", value: "\(Int(pollSeconds)) seconds")
                }
                Text("Mounted connections have no change notifications, so the Finder extension re-lists the folders Finder is showing.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Section("WHM") {
                Stepper(value: $whmHours, in: AppSettings.whmHoursRange) {
                    LabeledContent("Sync accounts every", value: "\(whmHours) hour\(whmHours == 1 ? "" : "s")")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .background(WindowAccessor { window in DemoWindows.register("settings", window) })
    }

    private func chooseFolder() {
        if let url = Dialogs.chooseFile(canChooseDirectories: true) { localFolder = url.path }
    }
}
