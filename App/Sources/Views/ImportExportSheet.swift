import AppKit
import DockyardCore
import SwiftUI

/// File > Import Connections: asks for the passphrase, merges the file and lists what changed.
struct ImportExportSheet: View {
    @Environment(AppModel.self) private var app
    let file: URL
    let data: Data
    let dismiss: () -> Void
    private let autoStart: Bool
    @State private var passphrase: String
    @State private var busy = false
    @State private var errorText: String?
    @State private var report: ExportImportReport?
    @FocusState private var focused: Bool

    init(file: URL, data: Data, dismiss: @escaping () -> Void, prefill: String = "", autoStart: Bool = false) {
        self.file = file
        self.data = data
        self.dismiss = dismiss
        self.autoStart = autoStart
        _passphrase = State(initialValue: prefill)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import Connections").font(.headline)
                    Text(file.lastPathComponent).font(.monoSmall).foregroundStyle(Palette.textSecondary)
                }
            }
            if let report {
                summary(report)
            } else {
                passphraseForm
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            focused = true
            if autoStart { start() }
        }
    }

    private var passphraseForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter the passphrase that was used to export this file. Connections you already have are kept as they are; only new ones are added.")
                .font(.callout).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Passphrase", text: $passphrase)
                .focused($focused)
                .onSubmit { if !passphrase.isEmpty { start() } }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Color.red)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty || busy)
            }
        }
    }

    private func summary(_ report: ExportImportReport) -> some View {
        let merge = report.merge
        let restored = merge.secretsRestored + report.whmTokensRestored
        return VStack(alignment: .leading, spacing: 12) {
            Label("Import finished", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.statusGreen)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Connections added", merge.connectionsCreated)
                row("Already saved, skipped", merge.connectionsSkipped)
                row("Client folders added", merge.foldersCreated)
                row("WHM servers added", merge.whmSourcesCreated)
                row("Passwords and tokens restored", restored)
            }
            if !report.settingsApplied.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings applied").font(.subheadline)
                    ForEach(report.settingsApplied, id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            if merge.connectionsCreated > 0 && restored == 0 {
                Text("This file has no passwords, so the new connections ask for them on first connect.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func row(_ title: String, _ value: Int) -> some View {
        GridRow {
            Text(title)
            Text("\(value)").monospacedDigit().gridColumnAlignment(.trailing)
        }
        .font(.callout)
    }

    private func start() {
        busy = true
        errorText = nil
        let secret = passphrase
        Task {
            do {
                let contents = try await app.openExport(data, passphrase: secret)
                report = try await app.mergeExport(contents)
            } catch {
                errorText = error.userMessage
            }
            busy = false
        }
    }
}

extension AppModel {
    /// File > Export Connections.
    func presentExport() {
        SheetPresenter.present { dismiss in ExportSheet(dismiss: dismiss) }
    }

    /// File > Import Connections. Asks for the file when `url` is nil.
    func presentImportExport(url: URL? = nil) {
        let file = url ?? Dialogs.chooseFile(types: [.dockyardExport])
        guard let file else { return }
        guard let data = try? Data(contentsOf: file), EncryptedExport.inspect(data) != nil else {
            alertMessage = "\"\(file.lastPathComponent)\" is not a Dockyard export file."
            return
        }
        SheetPresenter.present { dismiss in ImportExportSheet(file: file, data: data, dismiss: dismiss) }
    }
}
