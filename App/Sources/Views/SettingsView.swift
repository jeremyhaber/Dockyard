import DockyardCore
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
    @AppStorage(ScratchSettings.folderKey) private var scratchFolder = ""
    @AppStorage(ScratchSettings.hoursKey) private var scratchHours = ScratchSettings.defaultHours
    @AppStorage(ScratchSettings.trashKey) private var scratchTrash = true
    @AppStorage(ScratchSettings.keepKey) private var scratchKeep = ScratchKeepDestination.downloads.rawValue
    @Environment(AppModel.self) private var app

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
            scratchSection
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

    private var scratchSection: some View {
        Section("Scratch") {
            HStack {
                TextField("Location", text: $scratchFolder, prompt: Text(ScratchSettings.defaultFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
                Button("Choose\u{2026}") {
                    if let url = Dialogs.chooseFile(canChooseDirectories: true) { scratchFolder = url.path }
                }
                if !scratchFolder.isEmpty { Button("Reset") { scratchFolder = "" } }
            }
            Picker("Remove files after", selection: $scratchHours) {
                ForEach(ScratchSettings.lifetimes, id: \.self) { Text(ScratchSettings.title(hours: $0)).tag($0) }
            }
            Toggle("Move expired files to the Trash", isOn: $scratchTrash)
            Picker("Keep moves files to", selection: $scratchKeep) {
                ForEach(ScratchKeepDestination.allCases) { Text($0.title).tag($0.rawValue) }
            }
            HStack {
                let count = app.scratch.items.count
                Text(count == 0 ? "Empty" : "\(count == 1 ? "1 item" : "\(count) items"), \(FileDisplay.size(app.scratch.totalSize))")
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button("Empty Scratch Now\u{2026}") { app.scratch.emptyAll() }
                    .disabled(count == 0)
            }
            Text("The clock starts when a file arrives in Scratch. Files that run out while Dockyard is closed are removed at the next launch.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
        }
        .onChange(of: scratchFolder) { app.scratch.refresh() }
        .onChange(of: scratchHours) { app.scratch.refresh() }
    }

    private func chooseFolder() {
        if let url = Dialogs.chooseFile(canChooseDirectories: true) { localFolder = url.path }
    }
}
