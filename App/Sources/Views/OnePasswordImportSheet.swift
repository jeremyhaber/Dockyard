import ConnectionKit
import DockyardCore
import SwiftUI

/// Import from 1Password: pick vaults, read the items, review what would change, then write it.
struct OnePasswordImportSheet: View {
    @Environment(AppModel.self) private var app
    @State private var model = OnePasswordImportModel()
    let finished: (String) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            content
        }
        .frame(width: 600)
        .task {
            await model.start(app: app)
            if DemoMode.isEnabled, DemoMode.screen == "onePasswordImport", model.phase == .chooseVaults {
                model.selectAllVaults()
                model.scan()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .checking:
            VStack { ProgressView("Checking 1Password\u{2026}") }
                .frame(maxWidth: .infinity, minHeight: 160)
        case .needsSetup:
            VStack(alignment: .leading, spacing: 14) {
                OnePasswordGuidance(
                    status: app.onePassword.status, checking: app.onePassword.checking, failure: model.error ?? app.onePassword.failure,
                    retry: { Task { await model.start(app: app) } })
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
        case .chooseVaults:
            chooseVaults
        case .scanning:
            scanning
        case .preview, .applying:
            previewContent
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.viewfinder")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Import from 1Password").font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .chooseVaults: "Choose the vaults to scan for Server, Login and SSH Key items."
        case .scanning: "Reading items. 1Password may ask you to approve access."
        case .preview, .applying:
            guard let preview = model.preview else { return "" }
            var parts = ["\(preview.newCount) new"]
            if preview.updateCount > 0 { parts.append("\(preview.updateCount) updated") }
            parts.append("\(preview.duplicateCount) already saved and skipped")
            if !preview.warnings.isEmpty { parts.append("\(preview.warnings.count) warning\(preview.warnings.count == 1 ? "" : "s")") }
            return parts.joined(separator: ", ")
        default: "Sites, passwords and SSH keys stay in 1Password."
        }
    }

    // MARK: Vaults

    private var chooseVaults: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(model.vaults) { vault in
                    Toggle(isOn: Binding(
                        get: { model.selectedVaults.contains(vault.id) },
                        set: { if $0 { model.selectedVaults.insert(vault.id) } else { model.selectedVaults.remove(vault.id) } })
                    ) {
                        Label(vault.name, systemImage: "lock.rectangle.stack")
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.plain)
            .frame(height: 190)
            .overlay(alignment: .center) {
                if model.vaults.isEmpty { Text("No vaults found").foregroundStyle(Palette.textSecondary) }
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(Color.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Select All") { model.selectAllVaults() }.disabled(model.vaults.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Scan") { model.scan() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedVaults.isEmpty)
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 16)
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.progressTotal > 0 {
                ProgressView(value: Double(model.progress), total: Double(model.progressTotal))
                Text("Reading item \(min(model.progress + 1, model.progressTotal)) of \(model.progressTotal)")
                    .font(.callout).foregroundStyle(Palette.textSecondary).monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
                Text("Listing items\u{2026}").font(.callout).foregroundStyle(Palette.textSecondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelScan() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minHeight: 160, alignment: .top)
    }

    // MARK: Preview

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            options
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            if let preview = model.preview {
                List {
                    ForEach(preview.rows) { row in ImportRowView(row: row) }
                    if !preview.sshKeys.isEmpty { sshKeys(preview.sshKeys) }
                    if !preview.warnings.isEmpty { warnings(preview.warnings) }
                }
                .listStyle(.plain)
                .frame(height: 220)
            }
            Divider()
            footer.padding(16)
        }
    }

    private var options: some View {
        Form {
            Picker("Client folder", selection: $model.folder) {
                ForEach(OnePasswordFolderChoice.allCases) { Text($0.title).tag($0) }
            }
            Picker("Passwords", selection: $model.secrets) {
                Text("Keep passwords in 1Password (recommended)").tag(OnePasswordSecretChoice.reference)
                Text("Copy into Keychain").tag(OnePasswordSecretChoice.copy)
            }
            .pickerStyle(.radioGroup)
            Toggle("Use 1Password SSH agent for SFTP", isOn: $model.useAgent)
        }
        .formStyle(.columns)
        .onChange(of: model.folder) { model.optionsChanged() }
        .onChange(of: model.secrets) { model.optionsChanged() }
        .onChange(of: model.useAgent) { model.optionsChanged() }
        .disabled(model.phase == .applying)
    }

    private func sshKeys(_ keys: [OnePasswordSSHKey]) -> some View {
        Section {
            ForEach(keys) { key in
                HStack(spacing: 10) {
                    Image(systemName: "key.fill").foregroundStyle(Palette.textSecondary).frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key.title).lineLimit(1)
                        Text([key.keyType, key.vault].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                            .font(.caption).foregroundStyle(Palette.textSecondary)
                    }
                }
            }
        } header: {
            Text("SSH keys found, available through the 1Password agent").font(.caption)
        }
    }

    private func warnings(_ list: [String]) -> some View {
        Section {
            ForEach(Array(list.enumerated()), id: \.offset) { _, warning in
                Text(warning).font(.caption).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Label("\(list.count) warning\(list.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Palette.statusAmber)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.secrets == .reference
                ? "Only a reference such as op://Vault/Item/password is saved. Dockyard asks 1Password for the password each time it connects."
                : "Each password is read from 1Password once and saved in your Keychain. Later changes in 1Password are not picked up.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(Color.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.phase == .applying { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(importTitle) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((model.preview?.changeCount ?? 0) == 0 || model.phase == .applying)
            }
        }
    }

    private var importTitle: String {
        let count = model.preview?.changeCount ?? 0
        return count == 0 ? "Nothing to Import" : "Import \(count) Connection\(count == 1 ? "" : "s")"
    }

    private func apply() {
        Task {
            guard let message = await model.apply() else { return }
            finished(message)
            dismiss()
        }
    }
}

extension AppModel {
    /// The manager's Import, 1Password, and the re-import action on its source row.
    func presentOnePasswordImport(finished: @escaping (String) -> Void) {
        SheetPresenter.present { dismiss in OnePasswordImportSheet(finished: finished, dismiss: dismiss) }
    }
}
