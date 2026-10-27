import DockyardCore
import SwiftUI

/// Lists what an import would do before it writes anything: new connections, duplicates that are skipped, warnings.
struct ImportPreviewSheet: View {
    @Environment(AppModel.self) private var app
    let preview: ImportPreview
    let finished: (String) -> Void
    let dismiss: () -> Void
    @State private var readKeychain = true
    @State private var busy = false
    @State private var showWarnings = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)
            Divider()
            List {
                ForEach(preview.rows) { row in
                    ImportRowView(row: row)
                }
                if !preview.warnings.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showWarnings) {
                            ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning).font(.caption).foregroundStyle(Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } label: {
                            Label("\(preview.warnings.count) warning\(preview.warnings.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Palette.statusAmber)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .frame(height: 280)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Import from \(preview.kind.title)").font(.headline)
                Text(summaryLine).font(.callout).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var summaryLine: String {
        var parts: [String] = ["\(preview.newCount) new"]
        if preview.updateCount > 0 { parts.append("\(preview.updateCount) updated") }
        parts.append("\(preview.duplicateCount) already saved and skipped")
        if !preview.warnings.isEmpty { parts.append("\(preview.warnings.count) warning\(preview.warnings.count == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if preview.kind.readsKeychain {
                Toggle("Read saved passwords from the \(preview.kind.title) Keychain items", isOn: $readKeychain)
                    .toggleStyle(.checkbox)
                Text(readKeychain
                    ? "macOS may ask you to allow Dockyard to use each item. Passwords it cannot read are asked for on first connect."
                    : "Every imported connection asks for its password on first connect.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Importing again updates the connections created by an earlier import and keeps the host and port you edited.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(preview.changeCount == 0 ? "Nothing to Import" : "Import \(preview.changeCount) Connection\(preview.changeCount == 1 ? "" : "s")") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.changeCount == 0 || busy)
            }
        }
    }

    private func apply() {
        busy = true
        let keychain = readKeychain
        Task {
            let message = await app.applyImport(preview, readKeychain: keychain)
            finished(message)
            dismiss()
        }
    }
}

private struct ImportRowView: View {
    let row: ImportRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
                .accessibilityLabel(label)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.name).lineLimit(1)
                    if let folder = row.folder {
                        Text(folder).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                }
                Text(row.detail).font(.monoSmall).foregroundStyle(Palette.textSecondary).lineLimit(1)
                if let note = row.note {
                    Text(note).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(label).font(.caption).foregroundStyle(color)
        }
        .padding(.vertical, 2)
        .opacity(row.outcome == .duplicate ? 0.6 : 1)
    }

    private var symbol: String {
        switch row.outcome {
        case .new: "plus.circle.fill"
        case .update: "arrow.triangle.2.circlepath.circle.fill"
        case .duplicate: "equal.circle"
        }
    }

    private var color: Color {
        switch row.outcome {
        case .new: Palette.statusGreen
        case .update: Color.accentColor
        case .duplicate: Palette.textSecondary
        }
    }

    private var label: String {
        switch row.outcome {
        case .new: "New"
        case .update: "Update"
        case .duplicate: "Already saved"
        }
    }
}

extension AppModel {
    /// Opens the preview sheet for a parsed import. `finished` gets the sentence to show once it is applied.
    func presentImportPreview(_ preview: ImportPreview, finished: @escaping (String) -> Void) {
        SheetPresenter.present { dismiss in ImportPreviewSheet(preview: preview, finished: finished, dismiss: dismiss) }
    }

    /// Picks the source file where needed, parses, and shows the preview or explains why nothing can be imported.
    func startImport(_ kind: ImportKind, finished: @escaping (String) -> Void) {
        var url: URL?
        switch kind {
        case .transmit:
            let prefs = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Preferences")
            url = Dialogs.chooseFile(directory: prefs, showHidden: true)
            if url == nil { return }
        case .cyberduck:
            if CyberduckParser.bookmarkDirectories(home: NSHomeDirectory()).contains(where: { FileManager.default.fileExists(atPath: $0) }) { break }
            url = Dialogs.chooseFile(canChooseDirectories: true)
            if url == nil { return }
        case .sshConfig:
            break
        }
        let source = url
        Task {
            do {
                presentImportPreview(try await prepareImport(kind, from: source), finished: finished)
            } catch let failure as ImportFailure {
                SheetPresenter.present { dismiss in ImportFailureSheet(failure: failure, dismiss: dismiss) }
            } catch {
                alertMessage = error.userMessage
            }
        }
    }
}

struct ImportFailureSheet: View {
    let failure: ImportFailure
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26))
                    .foregroundStyle(Palette.statusAmber)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(failure.title).font(.headline)
                    Text(failure.message)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
