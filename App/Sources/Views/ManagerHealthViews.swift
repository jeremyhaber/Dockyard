import DockyardCore
import SwiftUI

enum TestTarget {
    case selected, list, all
}

@MainActor
extension ConnectionManagerModel {
    /// Starts a test for the chosen set. `visible` is what the list shows now.
    func test(_ target: TestTarget, visible: [Connection], app: AppModel) {
        let list: [Connection]
        switch target {
        case .selected: list = visible.filter { selection.contains($0.id) }
        case .list: list = visible
        case .all: list = app.allConnections
        }
        app.testConnections(list)
    }

    /// Asks first, naming the connections, then hides them for 30 days.
    func requestRemove(_ list: [Connection], app: AppModel) {
        guard !list.isEmpty else { return }
        let shown = list.prefix(10).map { "\u{2022} \($0.name)" }.joined(separator: "\n")
        let more = list.count > 10 ? "\nand \(list.count - 10) more" : ""
        let title = list.count == 1 ? "Remove \u{201C}\(list[0].name)\u{201D}?" : "Remove \(list.count) connections?"
        let message = shown + more
            + "\n\nThey move to Recently removed and can be restored for 30 days. Saved passwords stay in your Keychain until then."
        guard Dialogs.confirm(title: title, message: message, confirm: "Remove") else { return }
        Task { await app.removeConnections(list) }
    }

    func requestRestore(_ list: [Connection], app: AppModel) {
        Task { await app.restoreConnections(list) }
    }

    /// Deletes removed connections for good: the selection, or everything in the list when `list` is the whole list.
    func requestDelete(_ list: [Connection], all: Bool, app: AppModel) {
        guard !list.isEmpty else { return }
        let what = list.count == 1 ? "\u{201C}\(list[0].name)\u{201D}" : "\(list.count) connections"
        guard Dialogs.confirm(
            title: all ? "Empty Recently removed?" : "Delete \(what) now?",
            message: "\(all ? "All \(list.count) removed connections are" : "It is") deleted for good, together with their saved passwords in the Keychain. This cannot be undone.",
            confirm: all ? "Empty" : "Delete") else { return }
        Task { await app.deleteRemovedConnections(ids: all ? nil : list.map(\.id)) }
    }

    /// Demo screens open straight on the Recently removed list.
    func applyDemoScreen() {
        if DemoMode.isEnabled, DemoMode.screen == "recentlyRemoved" { scope = .recentlyRemoved }
    }
}

/// The Test menu and Remove button in the manager's toolbar.
struct ManagerHealthControls: View {
    @Environment(AppModel.self) private var app
    let model: ConnectionManagerModel
    let visible: [Connection]

    var body: some View {
        Menu {
            Button("Test Selected") { model.test(.selected, visible: visible, app: app) }
                .disabled(model.selection.isEmpty)
            Button("Test All in This List") { model.test(.list, visible: visible, app: app) }
                .disabled(visible.isEmpty)
            Divider()
            Button("Test All Connections") { model.test(.all, visible: visible, app: app) }
                .disabled(app.allConnections.isEmpty)
        } label: {
            Label("Test", systemImage: "waveform.path.ecg")
        } primaryAction: {
            model.test(model.selection.isEmpty ? .list : .selected, visible: visible, app: app)
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(app.health.isRunning)
        .help("Check that connections log in and list their folder. Nothing is changed on the servers.")

        Button {
            model.requestRemove(model.selectedConnections(), app: app)
        } label: {
            Label("Remove\u{2026}", systemImage: "trash")
        }
        .disabled(model.selection.isEmpty)
        .help("Remove the selected connections (Delete key)")
    }
}

/// Progress while a test runs, then the outcome with a shortcut to the failing connections.
struct ManagerHealthBar: View {
    @Environment(AppModel.self) private var app
    let model: ConnectionManagerModel

    var body: some View {
        if let run = app.health.run {
            bar {
                ProgressView(value: Double(run.completed), total: Double(max(run.total, 1)))
                    .frame(width: 220)
                    .accessibilityLabel("Test progress")
                Text(run.cancelling ? "Stopping\u{2026}" : "Testing \(run.completed) / \(run.total)\u{2026}")
                    .font(.system(size: 12)).monospacedDigit()
                Spacer()
                Button("Cancel") { app.health.cancel() }
                    .disabled(run.cancelling)
            }
        } else if let summary = app.health.summary {
            bar {
                Image(systemName: summary.failing == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.failing == 0 ? Palette.statusGreen : Palette.statusAmber)
                    .accessibilityHidden(true)
                Text(summary.text).font(.system(size: 12))
                Spacer()
                if summary.failing > 0 {
                    Button("Show Failing") { model.health = .failing }
                        .buttonStyle(.link).font(.system(size: 12))
                }
                Button { app.health.dismissSummary() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
        }
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) { content() }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Palette.selection)
        }
    }
}

/// Above the Recently removed list: what it is, and Restore / Empty.
struct ManagerRemovedBar: View {
    @Environment(AppModel.self) private var app
    let model: ConnectionManagerModel
    let visible: [Connection]

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "trash").foregroundStyle(Palette.textSecondary).accessibilityHidden(true)
                Text("Removed connections are deleted for good after 30 days.").font(.system(size: 12))
                Spacer()
                Button("Restore") { model.requestRestore(model.selectedConnections(in: visible), app: app) }
                    .disabled(model.selection.isEmpty)
                Button("Empty\u{2026}") { model.requestDelete(visible, all: true, app: app) }
                    .disabled(visible.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Palette.selection)
        }
    }
}

extension ConnectionManagerModel {
    func selectedConnections(in list: [Connection]) -> [Connection] { list.filter { selection.contains($0.id) } }
}
