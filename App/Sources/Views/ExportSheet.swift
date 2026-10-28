import AppKit
import DockyardCore
import SwiftUI

/// File > Export Connections: a passphrase, the "Include passwords" choice and a save panel.
struct ExportSheet: View {
    @Environment(AppModel.self) private var app
    let dismiss: () -> Void
    @State private var passphrase: String
    @State private var confirmation: String
    @State private var includePasswords = false
    @State private var counts: ExportPreviewCounts?
    @State private var busy = false
    @State private var result: Result<URL, Error>?
    @FocusState private var focus: Field?

    private enum Field { case passphrase, confirmation }

    init(dismiss: @escaping () -> Void, prefill: String = "") {
        self.dismiss = dismiss
        _passphrase = State(initialValue: prefill)
        _confirmation = State(initialValue: prefill)
    }

    private var mismatch: Bool { !confirmation.isEmpty && confirmation != passphrase }
    private var weak: Bool { !passphrase.isEmpty && passphrase.count < 8 }
    private var canExport: Bool { !passphrase.isEmpty && passphrase == confirmation && !busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Export Connections").font(.headline)
                    Text(summary)
                        .font(.callout).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if case .success(let url) = result {
                done(url)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { counts = await app.exportCounts() }
        .onAppear { focus = .passphrase }
    }

    private var summary: String {
        guard let counts else { return "Saves your connections, client folders, WHM servers and settings in one encrypted file." }
        return "\(counts.connections) connection\(counts.connections == 1 ? "" : "s"), \(counts.folders) client folder\(counts.folders == 1 ? "" : "s"), "
            + "\(counts.whmSources) WHM server\(counts.whmSources == 1 ? "" : "s") and your settings, in one encrypted file."
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                SecureField("Passphrase", text: $passphrase)
                    .focused($focus, equals: .passphrase)
                    .onSubmit { focus = .confirmation }
                SecureField("Confirm passphrase", text: $confirmation)
                    .focused($focus, equals: .confirmation)
                    .onSubmit { if canExport { export() } }
            }
            .formStyle(.columns)
            if mismatch {
                Label("The passphrases do not match.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Color.red)
            } else if weak {
                Label("Use at least 8 characters. Anyone with the file can try to guess the passphrase.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Palette.statusAmber)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Include passwords", isOn: $includePasswords).toggleStyle(.checkbox)
                Text(includePasswords
                    ? "Saved passwords, key passphrases and tokens are read from your Keychain and encrypted with the passphrase. Keep the file and passphrase apart."
                    : "Connections will ask for their passwords on first connect after an import.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .failure(let error) = result {
                Text(error.userMessage).font(.caption).foregroundStyle(Color.red)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export\u{2026}") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
        }
    }

    private func done(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.statusGreen)
            Text(includePasswords ? "Passwords are included. Move the file with care." : "Passwords are not included.")
                .font(.callout).foregroundStyle(Palette.textSecondary)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export Connections"
        panel.nameFieldStringValue = "Dockyard Connections.dockyardexport"
        panel.allowedContentTypes = [.dockyardExport]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        result = nil
        let secret = passphrase
        let withPasswords = includePasswords
        Task {
            do {
                _ = try await app.exportConnections(to: url, passphrase: secret, includePasswords: withPasswords)
                result = .success(url)
                passphrase = ""
                confirmation = ""
            } catch {
                result = .failure(error)
            }
            busy = false
        }
    }
}
