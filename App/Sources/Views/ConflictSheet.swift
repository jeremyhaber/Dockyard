import DockyardCore
import SwiftUI

/// "File exists": both files side by side, the seven rules and an "Apply to" scope.
struct ConflictSheet: View {
    @Environment(AppModel.self) private var app
    let request: ConflictRequest
    @State private var scope = ConflictScope.thisFile

    var body: some View {
        let info = request.info
        let sides = info.route.components(separatedBy: " \u{2192} ")
        let incomingNewer = Self.newer(info.sourceModified, than: info.destinationModified)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\"\(info.name)\" already exists").font(.headline)
                    Text(info.route).font(.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                card(title: "Incoming", place: sides.first ?? "", path: info.sourcePath, size: info.sourceSize,
                     modified: info.sourceModified, newer: incomingNewer == true)
                Image(systemName: "arrow.right")
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.top, 40)
                    .accessibilityHidden(true)
                card(title: "Existing", place: sides.last ?? "", path: info.destinationPath, size: info.destinationSize,
                     modified: info.destinationModified, newer: incomingNewer == false)
            }
            LabeledContent("Apply to") {
                Picker("Apply to", selection: $scope) {
                    ForEach(ConflictScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 250)
            }
            Divider()
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ruleButton(.overwrite, isDefault: true)
                    ruleButton(.overwriteIfNewer)
                    ruleButton(.overwriteIfDifferent)
                    ruleButton(.overwriteIfSizeDiffers)
                }
                HStack(spacing: 8) {
                    ruleButton(.resume)
                        .disabled(!canResume)
                        .help(canResume ? "Append the rest of the file to the partial copy" : "Only for a smaller, partial copy")
                    ruleButton(.rename)
                        .help("Keep both: the incoming file gets a numbered name")
                    ruleButton(.skip)
                    Button { resolve(.cancel) } label: { Text("Cancel Transfer").frame(maxWidth: .infinity) }
                        .help("Stop this transfer\(scope == .thisFile ? "" : " and everything queued")")
                }
            }
            .controlSize(.regular)
        }
        .padding(20)
        .frame(width: 640)
        .interactiveDismissDisabled()
    }

    private var canResume: Bool {
        guard let incoming = request.info.sourceSize, let existing = request.info.destinationSize else { return false }
        return existing < incoming
    }

    private func ruleButton(_ action: ConflictAction, isDefault: Bool = false) -> some View {
        Button { resolve(action) } label: { Text(action.title).frame(maxWidth: .infinity) }
            .keyboardShortcut(isDefault ? .defaultAction : nil)
    }

    private func card(title: String, place: String, path: String, size: UInt64?, modified: Date?, newer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                Spacer()
                if newer {
                    Text("Newer")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .foregroundStyle(Palette.statusGreen)
                        .background(Palette.statusGreen.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(place).font(.system(size: 12, weight: .medium))
                    Text(path).font(.monoSmall).foregroundStyle(Palette.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Divider()
            LabeledContent("Size", value: size.map { FileDisplay.size($0) } ?? "\u{2014}")
            LabeledContent("Modified", value: modified.map { FileDisplay.modified($0) } ?? "\u{2014}")
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.chrome, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(newer ? Palette.statusGreen.opacity(0.6) : Palette.border))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) file on \(place), \(size.map { FileDisplay.size($0) } ?? "unknown size"), modified \(modified.map { FileDisplay.modified($0) } ?? "unknown")\(newer ? ", newer" : "")")
    }

    /// True when `a` is newer than `b` by more than a second, false when older, nil when equal or unknown.
    private static func newer(_ a: Date?, than b: Date?) -> Bool? {
        guard let a, let b else { return nil }
        let delta = a.timeIntervalSince(b)
        return abs(delta) <= 1 ? nil : delta > 0
    }

    private func resolve(_ action: ConflictAction) {
        app.prompts.resolveConflict(request.id, ConflictDecision(action, scope: scope))
    }
}
