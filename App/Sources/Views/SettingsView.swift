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
                    LabeledContent("Maximum connections across all sites", value: "\(maxConnections)")
                }
            }
            TransferSettingsSections()
            MacSettingsSections()
            Section("Logging") {
                Toggle("Write a log file for each connection", isOn: $writeLogFiles)
                Text("Kept in ~/Library/Logs/Dockyard. Applies to connections opened from now on.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Section("Local folder") {
                HStack {
                    TextField("Default folder", text: $localFolder, prompt: Text("Your home folder"))
                        .help("Used when a connection has no local folder and no session to restore")
                    Button("Choose\u{2026}") { chooseFolder() }
                    if !localFolder.isEmpty { Button("Clear") { localFolder = "" } }
                }
            }
            Section("Finder") {
                Stepper(value: $pollSeconds, in: 5...3600, step: 5) {
                    LabeledContent("Check for server changes every", value: "\(Int(pollSeconds)) seconds")
                }
                Text("SFTP and FTP cannot push changes, so the extension re-lists the open folders.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Section("WHM") {
                Stepper(value: $whmHours, in: AppSettings.whmHoursRange) {
                    LabeledContent("Sync accounts every", value: "\(whmHours) hour\(whmHours == 1 ? "" : "s")")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 680)
        .background(WindowAccessor { window in DemoWindows.register("settings", window) })
    }

    private func chooseFolder() {
        if let url = Dialogs.chooseFile(canChooseDirectories: true) { localFolder = url.path }
    }
}
