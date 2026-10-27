import AppKit
import ConnectionKit
import DockyardCore
import SwiftUI

struct SiteEditorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    let request: SiteEditorRequest
    @State private var draft: SiteDraft
    @State private var clientFolders: [ClientFolder] = []
    @State private var newFolderName = ""
    @State private var testing = false
    @State private var testResult: ConnectionTestResult?
    @State private var errorText: String?
    @State private var hasStoredPassword = false

    init(request: SiteEditorRequest) {
        self.request = request
        _draft = State(initialValue: request.connection.map(SiteDraft.init(connection:)) ?? SiteDraft())
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            Form {
                generalSection
                if draft.protocolChoice == .cloud {
                    cloudSection
                } else if draft.protocolChoice == .sftp {
                    authSection
                    elevationSection
                } else {
                    Section("Authentication") {
                        SecureField("Password", text: $draft.password, prompt: Text(hasStoredPassword ? "Saved in Keychain" : "Optional, asked on connect"))
                    }
                }
                finderSection
                SiteEditorSafetySection(draft: $draft)
                otherSection
            }
            .formStyle(.grouped)
            .onAppear {
                if DemoMode.screen == "siteEditorSafety" { proxy.scrollTo(SiteEditorSafetySection.anchor, anchor: .top) }
            }
            }
            Divider()
            buttons
        }
        .frame(width: 600, height: 620)
        .task {
            clientFolders = (try? await app.folders.all()) ?? []
            if let id = request.connection?.id {
                hasStoredPassword = ((try? await app.secrets.secret(for: id, purpose: .password)) ?? nil) != nil
            }
        }
    }

    // MARK: Sections

    private var generalSection: some View {
        Section(draft.isNew ? "New connection" : "Connection") {
            TextField("Name", text: $draft.name, prompt: Text("Defaults to the host"))
            Picker("Client folder", selection: $draft.clientFolderId) {
                Text("None").tag(UUID?.none)
                ForEach(clientFolders) { folder in Text(folder.name).tag(Optional(folder.id)) }
            }
            HStack {
                TextField("New client folder", text: $newFolderName)
                Button("Add") { addFolder() }
                    .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Picker("Protocol", selection: $draft.protocolChoice) {
                ForEach(DraftProtocol.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if draft.protocolChoice != .cloud {
                TextField("Host", text: $draft.host)
                TextField("Port", text: $draft.port, prompt: Text(String(draft.protocolChoice.connectionProtocol.defaultPort)))
                TextField("User", text: $draft.username)
            }
        }
    }

    private var authSection: some View {
        Section("Authentication") {
            Toggle("SSH agent", isOn: $draft.useAgent)
            Toggle("SSH key", isOn: $draft.useKey)
            if draft.useKey {
                HStack {
                    TextField("Key file", text: $draft.keyPath, prompt: Text("~/.ssh/id_ed25519"))
                    Button("Choose\u{2026}") { chooseKey() }
                }
                SecureField("Key passphrase", text: $draft.keyPassphrase, prompt: Text("Only if the key is encrypted"))
            }
            Toggle(draft.useKey ? "Password too" : "Password", isOn: $draft.usePassword)
            if draft.usePassword {
                SecureField("Password", text: $draft.password, prompt: Text(hasStoredPassword ? "Saved in Keychain" : "Asked on first connect if empty"))
            }
            if draft.useKey && draft.usePassword {
                Text("The key is tried first, then the password answers the server's prompt.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var elevationSection: some View {
        Section("After login") {
            Picker("Elevate with", selection: $draft.elevation) {
                Text("None").tag(Elevation.none)
                Text("su -").tag(Elevation.su)
                Text("sudo -i").tag(Elevation.sudo)
            }
            if draft.elevation != .none {
                SecureField("Elevation password", text: $draft.elevationPassword, prompt: Text("Stored in Keychain"))
                Toggle("Also browse files as root", isOn: $draft.elevateFileBrowsing)
                Toggle("Ask before elevating on PROD sites", isOn: $draft.askBeforeElevatingOnProd)
            }
        }
    }

    private var cloudSection: some View {
        let preset = draft.cloudPreset
        return Section("Cloud storage") {
            Picker("Provider", selection: $draft.cloudPresetID) {
                ForEach(CloudPreset.all) { Text($0.title).tag($0.id) }
            }
            if let label = preset.hostLabel {
                TextField(label, text: $draft.host)
            }
            if let label = preset.userLabel {
                TextField(label, text: $draft.username)
            }
            if let label = preset.secretLabel {
                SecureField(label, text: $draft.cloudSecret, prompt: Text("Stored in Keychain"))
            }
            if preset.usesOAuth {
                HStack {
                    Button("Authorise in Browser\u{2026}") { authorise() }
                    Text(draft.cloudSecret.isEmpty ? "Not authorised yet" : "Authorised, save to keep it")
                        .font(.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            if preset.backend == "s3" {
                TextField("Region", text: $draft.cloudRegion, prompt: Text("Optional"))
            }
            if !preset.usesOAuth {
                TextField("Bucket or path", text: $draft.cloudRoot, prompt: Text("Empty lists all buckets"))
            }
        }
    }

    private var finderSection: some View {
        Section("Finder") {
            Toggle("Mount in Finder", isOn: $draft.mountInFinder)
            Toggle("Mount when Dockyard opens", isOn: $draft.mountOnLaunch)
            Toggle("Read-only mount", isOn: $draft.mountReadOnly)
            Text("Saving mounts the connection under Locations in Finder. PROD sites mount read-only by default, and mounts never use su or sudo.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
        }
    }

    private var otherSection: some View {
        Section("Other") {
            Toggle("Read-only site", isOn: $draft.readOnly)
            Text("Blocks uploads, deletes, renames and permission changes, and shows a lock on the connection tab.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
            Toggle("Production site (PROD)", isOn: Binding(
                get: { draft.isProd },
                set: { value in
                    draft.isProd = value
                    if draft.isNew { draft.mountReadOnly = value }
                }))
            HStack {
                TextField("Local folder", text: $draft.localFolder, prompt: Text("Default: your home folder"))
                Button("Choose\u{2026}") { chooseLocalFolder() }
            }
            Stepper(value: $draft.maxConnections, in: Connection.maxConnectionsRange) {
                LabeledContent("Max connections", value: "\(draft.maxConnections)")
            }
            Stepper(value: $draft.connectDelayMs, in: 0...10_000, step: 100) {
                LabeledContent("Delay between new connections", value: "\(draft.connectDelayMs) ms")
            }
            Toggle("On connect: restore last session", isOn: $draft.restoreSession)
            Toggle("Favorite", isOn: $draft.favorite)
            TextField("Tags", text: $draft.tags, prompt: Text("Comma separated"))
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                TextEditor(text: $draft.notes)
                    .font(.system(size: 12))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.border))
            }
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        VStack(spacing: 6) {
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let testResult {
                Label(testResult.message, systemImage: testResult.success ? "checkmark.circle" : "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(testResult.success ? Palette.statusGreen : Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if !draft.isNew {
                    Button("Duplicate") { duplicate() }
                }
                Button("Test Connection") { test() }
                    .disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { app.siteEditor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(connect: false) }
                Button("Save & Connect") { save(connect: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    // MARK: Actions

    private func addFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        Task {
            if let folder = try? await app.folders.findOrCreate(name: name) {
                clientFolders = (try? await app.folders.all()) ?? clientFolders
                draft.clientFolderId = folder.id
                newFolderName = ""
            }
        }
    }

    private func chooseKey() {
        let ssh = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if let url = Dialogs.chooseFile(directory: ssh) { draft.keyPath = url.path }
    }

    private func chooseLocalFolder() {
        if let url = Dialogs.chooseFile(canChooseDirectories: true) { draft.localFolder = url.path }
    }

    private func authorise() {
        let snapshot = draft
        Task {
            switch await app.authorizeCloud(snapshot) {
            case .success(let token):
                draft.cloudSecret = token
                errorText = nil
            case .failure(let error):
                errorText = error.errorDescription
            }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        let snapshot = draft
        Task {
            testResult = await app.testConnection(snapshot)
            testing = false
        }
    }

    private func duplicate() {
        guard let original = request.connection else { return }
        Task {
            let copy = await app.duplicate(original)
            draft = SiteDraft(connection: copy)
            testResult = nil
        }
    }

    private func save(connect: Bool) {
        let snapshot = draft
        Task {
            do {
                if connect {
                    try await app.saveAndConnect(snapshot)
                } else {
                    _ = try await app.save(snapshot)
                }
                app.siteEditor = nil
                if connect { openWindow(id: "main") }
            } catch let error as SiteDraftError {
                errorText = error.description
            } catch {
                errorText = error.userMessage
            }
        }
    }
}
