import ConnectionKit
import DockyardCore
import Observation
import SwiftUI

@MainActor @Observable
final class CompareModel {
    private(set) var entries: [DiffEntry] = []
    private(set) var loading = false
    private(set) var error: String?
    var selection: Set<String> = []
    var recursive = false { didSet { if recursive != oldValue { reload() } } }
    var showIdentical = false

    let session: ConnectionSession
    let localPath: String
    let serverPath: String
    @ObservationIgnored private var task: Task<Void, Never>?

    init(session: ConnectionSession) {
        self.session = session
        localPath = session.local?.currentPath ?? "/"
        serverPath = session.server?.currentPath ?? "/"
    }

    var visible: [DiffEntry] { showIdentical ? entries : entries.filter { $0.status != .same } }

    func reload() {
        task?.cancel()
        loading = true
        error = nil
        let left = session.endpoint(.local), right = session.endpoint(.server)
        let (lp, rp, deep) = (localPath, serverPath, recursive)
        // FTP servers report times to the minute, so equal means within a minute there.
        let tolerance: TimeInterval = session.connection.protocol == .ftp || session.connection.protocol == .ftps ? 61 : 2
        task = Task {
            do {
                let result = try await FolderComparator(timeTolerance: tolerance)
                    .compare(left: left, leftPath: lp, right: right, rightPath: rp, recursive: deep)
                try Task.checkCancellation()
                self.entries = result
                self.selection = self.selection.intersection(Set(result.map(\.id)))
                self.loading = false
            } catch is CancellationError {
                return
            } catch {
                self.error = error.userMessage
                self.loading = false
            }
        }
    }

    enum Pick { case none, differences, local, server }

    func select(_ pick: Pick) {
        let files = entries.filter { !$0.isDirectory || $0.status == .onlyLeft || $0.status == .onlyRight }
        switch pick {
        case .none: selection = []
        case .differences: selection = Set(files.filter { $0.status != .same }.map(\.id))
        case .local: selection = Set(files.filter { $0.status == .onlyLeft || $0.status == .newerLeft }.map(\.id))
        case .server: selection = Set(files.filter { $0.status == .onlyRight || $0.status == .newerRight }.map(\.id))
        }
    }

    func sync(_ direction: SyncDirection, app: AppModel) -> String {
        let chosen = entries.filter { selection.contains($0.id) }
        let plan = SyncPlan.make(
            selection: chosen, direction: direction,
            left: session.endpoint(.local), leftRoot: localPath, right: session.endpoint(.server), rightRoot: serverPath)
        let queue = app.queue
        Task { _ = await plan.execute(on: queue) }
        let verb = direction == .push ? "to the server" : "to this Mac"
        var text = "Queued \(plan.requests.count) transfer\(plan.requests.count == 1 ? "" : "s") \(verb)"
        if !plan.skipped.isEmpty { text += ", skipped \(plan.skipped.count) that cannot go that way" }
        return text
    }
}

extension DiffStatus {
    var label: String {
        switch self {
        case .onlyLeft: "Only on this Mac"
        case .onlyRight: "Only on server"
        case .newerLeft: "Newer on this Mac"
        case .newerRight: "Newer on server"
        case .same: "Identical"
        case .differs: "Different"
        }
    }

    var symbol: String {
        switch self {
        case .onlyLeft: "plus.circle"
        case .onlyRight: "plus.circle"
        case .newerLeft: "arrow.up.circle.fill"
        case .newerRight: "arrow.down.circle.fill"
        case .same: "checkmark.circle"
        case .differs: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .onlyLeft, .newerLeft: Color.accentColor
        case .onlyRight, .newerRight: Palette.statusAmber
        case .same: Palette.statusGrey
        case .differs: Color.red
        }
    }
}

/// Compare / Sync (HANDOFF 10): the local and server folder of the active tabs, side by side.
struct CompareSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: CompareModel

    init(session: ConnectionSession) {
        _model = State(initialValue: CompareModel(session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            columnTitles
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 900, height: 540)
        .background(Palette.ground)
        .task { model.reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Compare and sync").font(.headline)
                Spacer()
                Toggle("Include subfolders", isOn: $model.recursive).toggleStyle(.checkbox)
                Toggle("Show identical", isOn: $model.showIdentical).toggleStyle(.checkbox)
            }
            HStack(spacing: 16) {
                pathLabel("desktopcomputer", "This Mac", model.localPath)
                pathLabel("server.rack", model.session.connection.name, model.serverPath)
            }
            summary
        }
        .padding(14)
    }

    private func pathLabel(_ symbol: String, _ title: String, _ path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Palette.textSecondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(path).font(.monoSmall).foregroundStyle(Palette.textSecondary).lineLimit(1).truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: some View {
        let entries = model.entries
        let kinds: [(DiffStatus, String)] = [
            (.onlyLeft, "only here"), (.newerLeft, "newer here"), (.onlyRight, "only on server"),
            (.newerRight, "newer on server"), (.differs, "different"),
        ]
        let parts = kinds.compactMap { kind -> String? in
            let n = entries.count(of: kind.0)
            return n > 0 ? "\(n) \(kind.1)" : nil
        }
        return Text(model.loading ? "Comparing\u{2026}" : (parts.isEmpty ? "The folders match." : parts.joined(separator: "  \u{00B7}  ")))
            .font(.system(size: 12))
            .foregroundStyle(Palette.textSecondary)
    }

    private var columnTitles: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 44)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("This Mac").frame(width: 176, alignment: .leading)
            Text("Server").frame(width: 176, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(Palette.chrome)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.error {
            message("exclamationmark.triangle", error)
        } else if model.loading && model.entries.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visible.isEmpty {
            message("checkmark.circle", "Nothing to sync. Both folders have the same files.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visible) { entry in
                        CompareRow(entry: entry, selected: model.selection.contains(entry.id)) { on in
                            if on { model.selection.insert(entry.id) } else { model.selection.remove(entry.id) }
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private func message(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Palette.textSecondary)
            Text(text).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu("Select") {
                Button("All differences") { model.select(.differences) }
                Button("New and newer on this Mac") { model.select(.local) }
                Button("New and newer on the server") { model.select(.server) }
                Divider()
                Button("None") { model.select(.none) }
            }
            .menuStyle(.button)
            .fixedSize()
            Text("\(model.selection.count) selected")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Button {
                push(.pull)
            } label: {
                Label("Pull to This Mac", systemImage: "arrow.down")
            }
            .disabled(model.selection.isEmpty)
            Button {
                push(.push)
            } label: {
                Label("Push to Server", systemImage: "arrow.up")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.selection.isEmpty)
        }
        .padding(12)
    }

    private func push(_ direction: SyncDirection) {
        let text = model.sync(direction, app: app)
        app.showToast(text, symbol: "arrow.triangle.2.circlepath")
        dismiss()
    }
}

struct CompareRow: View {
    let entry: DiffEntry
    let selected: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Select \(entry.name)", isOn: Binding(get: { selected }, set: { onToggle($0) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 20)
            Image(systemName: entry.status.symbol)
                .foregroundStyle(entry.status.tint)
                .frame(width: 18)
                .help(entry.status.label)
                .accessibilityLabel(entry.status.label)
            HStack(spacing: 5) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : Palette.textSecondary)
                    .font(.system(size: 11))
                Text(entry.relativePath).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            side(entry.left, newer: entry.status == .newerLeft)
            side(entry.right, newer: entry.status == .newerRight)
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(selected ? Palette.selection : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onToggle(!selected) }
    }

    private func side(_ item: RemoteItem?, newer: Bool) -> some View {
        HStack(spacing: 4) {
            if let item {
                Text(item.isDirectory ? "Folder" : FileDisplay.size(item.size))
                    .frame(width: 54, alignment: .trailing)
                Text(FileDisplay.modifiedCompact(item.modified))
                    .lineLimit(1)
                    .frame(width: 100, alignment: .leading)
                if newer { Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.accentColor) }
            } else {
                Text("\u{2013}").foregroundStyle(Palette.textSecondary)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(width: 176, alignment: .leading)
    }
}
