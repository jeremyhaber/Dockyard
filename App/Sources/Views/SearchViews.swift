import ConnectionKit
import DockyardCore
import SwiftUI

/// ⌘F bar above the server file list: name or content search under the current folder.
struct SearchBar: View {
    @Environment(AppModel.self) private var app
    let pane: PaneModel
    let session: ConnectionSession
    @FocusState private var focused: Bool

    var body: some View {
        let model = app.safety.search(for: session)
        if model.isOpen {
            SearchBarContent(model: model, pane: pane, session: session, focused: $focused)
        }
    }
}

private struct SearchBarContent: View {
    @Bindable var model: SearchModel
    let pane: PaneModel
    let session: ConnectionSession
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
                TextField(model.byContent ? "Text inside files" : "File name or pattern, e.g. *.php", text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .focused(focused)
                    .onSubmit(start)
                    .accessibilityLabel("Search text")
                Picker("Search by", selection: $model.byContent) {
                    Text("Name").tag(false)
                    Text("Contents").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .disabled(!session.shellAvailable)
                .help(session.shellAvailable ? "Search file names or what is inside files" : "Searching inside files needs an SSH connection")
                Toggle("Aa", isOn: $model.caseSensitive)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Match case")
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.cancel() }
                        .controlSize(.small)
                } else {
                    Button("Search", action: start)
                        .controlSize(.small)
                        .disabled(model.text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button {
                    model.close()
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Close search")
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            Divider()
            if model.hasResults { statusLine }
        }
        .background(Palette.chrome)
        .onAppear { focused.wrappedValue = true }
        .onChange(of: model.focusToken) { focused.wrappedValue = true }
        .onExitCommand { model.close() }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Text(statusText).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 20)
        .background(Palette.chromeAlt)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var statusText: String {
        let count = model.hits.count.formatted()
        if model.isRunning {
            if let progress = model.progress { return "\(count) found \u{00B7} \(progress.foldersScanned.formatted()) folders searched, now in \(progress.currentFolder)" }
            return "\(count) found, searching under \(model.searchedRoot)\u{2026}"
        }
        guard let summary = model.summary else { return "" }
        if let error = summary.error { return "\(count) found. \(error)" }
        if summary.cancelled { return "Stopped after \(count) found" }
        if summary.truncated { return "Showing the first \(count) matches. Narrow the search to see the rest." }
        return "\(count) match\(model.hits.count == 1 ? "" : "es") under \(model.searchedRoot)"
    }

    private func start() {
        guard let fs = session.fs else { return }
        if !session.shellAvailable { model.byContent = false }
        model.run(root: pane.currentPath, on: fs)
    }
}

/// The result list drawn over the file list while a search is open.
struct SearchResults: View {
    @Environment(AppModel.self) private var app
    let session: ConnectionSession
    @State private var selection: Set<SearchHit.ID> = []

    var body: some View {
        let model = app.safety.search(for: session)
        if model.isOpen, model.hasResults {
            Group {
                if model.hits.isEmpty {
                    VStack(spacing: 6) {
                        if model.isRunning { ProgressView().controlSize(.small) }
                        Text(model.isRunning ? "Searching\u{2026}" : "No matches")
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(model.hits, selection: $selection) {
                        TableColumn("Path") { hit in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(hit.name).font(.system(size: 12))
                                Text(RemotePath.parent(of: hit.path)).font(.system(size: 10)).foregroundStyle(Palette.textSecondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                        TableColumn("Size") { hit in
                            Text(hit.isDirectory == true ? "\u{2014}" : FileDisplay.size(hit.size))
                                .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                        }
                        .width(70)
                        TableColumn("Modified") { hit in
                            Text(hit.modified.map { FileDisplay.modifiedCompact($0) } ?? "")
                                .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                        }
                        .width(110)
                    }
                    .contextMenu(forSelectionType: SearchHit.ID.self) { ids in
                        if let hit = model.hits.first(where: { ids.contains($0.id) }) {
                            Button("Show in Folder Tab") { app.reveal(hit, in: session) }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(hit.path, forType: .string)
                            }
                        }
                    } primaryAction: { ids in
                        if let hit = model.hits.first(where: { ids.contains($0.id) }) { app.reveal(hit, in: session) }
                    }
                    .accessibilityLabel("Search results")
                }
            }
            .background(Palette.ground)
        }
    }
}
