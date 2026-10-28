import SwiftUI
import UniformTypeIdentifiers

/// The Settings window (⌘,).
struct SettingsView: View {
    @AppStorage(AppSettings.globalMaxConnections) private var maxConnections = AppSettings.defaultGlobalMaxConnections
    @AppStorage(AppSettings.writeLogFiles) private var writeLogFiles = true
    @AppStorage(AppSettings.defaultLocalFolder) private var localFolder = ""
    @AppStorage(AppSettings.finderPollSeconds, store: AppGroup.sharedDefaults) private var pollSeconds = 30.0
    @AppStorage(AppSettings.whmSyncHours) private var whmHours = 6
    @AppStorage(AppSettings.editorApp) private var editorApp = ""

    var body: some View {
        Form {
            Section("Transfers") {
                Stepper(value: $maxConnections, in: AppSettings.globalMaxRange) {
                    LabeledContent("Maximum connections across all sites", value: "\(maxConnections)")
                }
            }
            Section("Editing") {
                HStack {
                    LabeledContent("Edit files in", value: editorName)
                    Button("Choose\u{2026}") { chooseEditor() }
                    if !editorApp.isEmpty { Button("Use Default") { editorApp = "" } }
                }
                Text("Double-click or Edit opens files here. Saving uploads the file back to the server.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            OnePasswordSettingsSection()
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

    private var editorName: String {
        guard let url = AppSettings.editorURL, editorApp == url.path else { return "Default app for each file" }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func chooseEditor() {
        if let url = Dialogs.chooseFile(directory: URL(fileURLWithPath: "/Applications"), types: [.application]) {
            editorApp = url.path
        }
    }

    private func chooseFolder() {
        if let url = Dialogs.chooseFile(canChooseDirectories: true) { localFolder = url.path }
    }
}
