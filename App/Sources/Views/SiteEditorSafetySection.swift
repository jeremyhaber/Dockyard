import DockyardCore
import SwiftUI

/// Versions, trash, checksums, filters and the default for existing files, in the site editor.
struct SiteEditorSafetySection: View {
    static let anchor = "safety"
    @Binding var draft: SiteDraft

    var body: some View {
        Section("Safety and transfers") {
            Toggle("Keep old versions when overwriting", isOn: $draft.keepVersionsOnOverwrite)
            Text("Before an upload replaces a file, the old copy is moved into ~/.dockyard-trash on the server, outside the web root. Restore it from Versions.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
            Toggle("Move deleted files to trash", isOn: $draft.trashOnDelete)
            Text("Deleted files stay on the server and keep using disk space and quota until the trash is emptied or purged. Not recommended on quota-limited shared hosting.")
                .font(.caption).foregroundStyle(draft.trashOnDelete ? Palette.statusAmber : Palette.textSecondary)
            if draft.protocolChoice == .sftp {
                Toggle("Verify checksums after SFTP transfers", isOn: $draft.verifyChecksums)
                Text("Compares SHA-256 of each file with sha256sum on the server. A mismatch fails the item.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Picker("When a file already exists", selection: $draft.defaultConflict) {
                Text("Use the Settings default").tag(ConflictPolicy.ask)
                ForEach(ConflictPolicy.allCases.filter { $0 != .ask }, id: \.self) { Text($0.title).tag($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Skip patterns for this site")
                TextEditor(text: $draft.transferFilters)
                    .font(.monoSmall)
                    .frame(height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.border))
                    .accessibilityLabel("Skip patterns for this site, one per line")
                Text("One per line, .gitignore style, on top of the defaults in Settings. Start a line with ! to include something again.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
        }
        .id(Self.anchor)
    }
}
