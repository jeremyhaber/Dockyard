import DockyardCore
import SwiftUI

/// Settings sections for transfers: existing files, leftovers at launch, default filters and kept versions.
struct TransferSettingsSections: View {
    @AppStorage(AppSettings.defaultConflict) private var conflict = ConflictPolicy.ask.rawValue
    @AppStorage(AppSettings.launchLeftovers) private var leftovers = LeftoverChoice.ask.rawValue
    @AppStorage(AppSettings.trashRetentionDays) private var retention = TrashBrowser.defaultRetentionDays
    @AppStorage(AppSettings.globalFilters) private var filters = TransferFilter.globalDefaults.joined(separator: "\n")

    var body: some View {
        Section("Existing files") {
            Picker("When a file already exists", selection: $conflict) {
                ForEach(ConflictPolicy.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            Text("Sites can set their own default in the site editor. A batch can pick a rule from the Upload with and Download with menus.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
            Picker("On launch with leftover transfers", selection: $leftovers) {
                ForEach(LeftoverChoice.allCases) { Text($0.title).tag($0.rawValue) }
            }
        }
        Section("Transfer filters") {
            TextEditor(text: $filters)
                .font(.monoSmall)
                .frame(height: 76)
                .accessibilityLabel("Default transfer filters, one pattern per line")
            HStack {
                Text("One pattern per line, in .gitignore style. Applied to folder transfers, compare and sync, and watch folders.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
                Spacer()
                Button("Reset") { filters = TransferFilter.globalDefaults.joined(separator: "\n") }
                    .controlSize(.small)
            }
        }
        Section("Versions and trash") {
            Stepper(value: $retention, in: 1...365) {
                LabeledContent("Purge kept versions after", value: "\(retention) day\(retention == 1 ? "" : "s")")
            }
            Text("Applies to sites that keep old versions or move deleted files to the trash. Purged when you connect.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
        }
    }
}
