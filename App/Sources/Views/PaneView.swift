import AppKit
import ConnectionKit
import DockyardCore
import SwiftUI

struct PaneView: View {
    @Environment(AppModel.self) private var app
    let pane: PaneModel
    let session: ConnectionSession
    @AppStorage private var treeHeight: Double

    init(pane: PaneModel, session: ConnectionSession) {
        self.pane = pane
        self.session = session
        _treeHeight = AppStorage(wrappedValue: TreeLayout.defaultHeight, TreeLayout.key(for: pane.side))
    }

    var body: some View {
        GeometryReader { proxy in
            content(treeHeight: TreeLayout.clamp(treeHeight, available: proxy.size.height))
        }
        .background(Palette.ground)
    }

    private func content(treeHeight shown: Double) -> some View {
        VStack(spacing: 0) {
            PathBar(pane: pane, session: session)
            Divider()
            if pane.side == .server { PinsBar(pane: pane, session: session) }
            FolderTreeView(pane: pane, session: session, version: pane.treeSignature)
                .frame(height: shown)
            TreeResizeHandle(height: shown) { treeHeight = $0 }
            FolderTabsBar(pane: pane)
            Divider()
            if pane.side == .server { SearchBar(pane: pane, session: session) }
            ZStack {
                FileTableView(pane: pane, session: session, version: pane.rowsVersion, sort: pane.sort)
                    .frame(minHeight: TreeLayout.minListHeight)
                if pane.side == .server { SearchResults(session: session) }
                if let message = pane.errorMessage {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(Palette.statusAmber)
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                        Button("Try Again") { pane.reload() }
                    }
                    .padding(20)
                    .background(Palette.ground.opacity(0.95), in: RoundedRectangle(cornerRadius: 8))
                } else if pane.isLoading && pane.rows.isEmpty {
                    ProgressView().controlSize(.small)
                }
                if let hint = app.dropHint, hint.paneID == pane.id {
                    DropHintView(text: hint.text)
                }
            }
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack {
            Text(pane.footer)
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            if pane.isLoading { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Palette.chromeAlt)
    }
}

struct FolderTabsBar: View {
    let pane: PaneModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(Array(pane.state.tabs.enumerated()), id: \.element.id) { index, tab in
                        tabButton(index: index, path: tab.path)
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.hidden)
            Button {
                pane.openTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New folder tab (\u{2318}T)")
            .accessibilityLabel("New folder tab")
            .padding(.horizontal, 8)
        }
        .frame(height: 26)
        .background(Palette.chrome)
    }

    private func tabButton(index: Int, path: String) -> some View {
        let active = index == pane.activeTabIndex
        let title = path == "/" ? "/" : RemotePath.lastComponent(of: path)
        return HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .lineLimit(1)
            if pane.state.tabs.count > 1 {
                Button {
                    pane.closeTab(at: index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tab \(title)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(active ? Palette.ground : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(active ? Palette.border : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) { return }
            pane.activateTab(index)
        }
        .help(path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct PathBar: View {
    let pane: PaneModel
    let session: ConnectionSession
    @Environment(AppModel.self) private var app
    @State private var editing = false
    @State private var text = ""
    @State private var showHistory = false
    @State private var showRecent = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button { pane.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!pane.state.canGoBack)
                .help("Back (\u{2318}[)")
                .accessibilityLabel("Back")
            Button { pane.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!pane.state.canGoForward)
                .help("Forward (\u{2318}])")
                .accessibilityLabel("Forward")
            Button { pane.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!pane.state.canGoUp)
                .help("Up one folder (\u{2318}\u{2191})")
                .accessibilityLabel("Up one folder")
            pathArea
            if pane.side == .server, session.browsingAsRoot {
                Badge(text: "ROOT", style: .root)
                    .help("Browsing files as root")
            }
            if pane.side == .server {
                Button { showHistory.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help("Folder history (\u{2318}Y)")
                    .accessibilityLabel("Folder history")
                    .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                        HistoryPopover(pane: pane, session: session) { showHistory = false }
                    }
                PinButton(pane: pane, session: session)
                WebURLButton(pane: pane, session: session)
            }
            Button { showRecent.toggle() } label: { Image(systemName: "arrow.uturn.backward.circle") }
                .help("Recent changes and Undo")
                .accessibilityLabel("Recent changes")
                .popover(isPresented: $showRecent, arrowEdge: .bottom) {
                    RecentChangesPopover(pane: pane, session: session) { showRecent = false }
                }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background {
            if pane.side == .server, let color = session.connection.color {
                Palette.chrome.overlay(color.color.opacity(0.10))
            } else {
                Palette.chrome
            }
        }
        .onChange(of: pane.pathEditToken) { beginEditing() }
        .onChange(of: pane.historyToken) { if pane.side == .server { showHistory = true } }
        .onChange(of: pane.recentToken) { showRecent = true }
    }

    @ViewBuilder
    private var pathArea: some View {
        if editing {
            HStack(spacing: 4) {
                TextField("Path", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.monoSmall)
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
                    .accessibilityLabel("Folder path")
                Button("Go") { commit() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            BreadcrumbBar(pane: pane, onEmptyTap: beginEditing)
                .frame(height: 22)
            .accessibilityLabel("Path: \(pane.currentPath)")
        }
    }

    private func beginEditing() {
        text = pane.currentPath
        editing = true
        app.focusedSide = pane.side
        Task { fieldFocused = true }
    }

    private func commit() {
        pane.navigate(toTyped: text)
        editing = false
    }
}

struct HistoryPopover: View {
    let pane: PaneModel
    let session: ConnectionSession
    let dismiss: () -> Void
    @Environment(AppModel.self) private var app
    @State private var entries: [FolderHistoryEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Folders visited on \(session.connection.name)")
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
                .padding(10)
            Divider()
            PinnedSection(pane: pane, session: session, dismiss: dismiss)
            if entries.isEmpty {
                Text("No history yet")
                    .foregroundStyle(Palette.textSecondary)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            Button {
                                if NSEvent.modifierFlags.contains(.command) {
                                    pane.openTab(at: entry.path)
                                } else {
                                    pane.navigate(to: entry.path)
                                }
                                dismiss()
                            } label: {
                                HStack {
                                    Text(entry.path).font(.monoSmall).lineLimit(1).truncationMode(.head)
                                    Spacer(minLength: 12)
                                    Text(entry.visitedAt, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(Palette.textSecondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            Divider()
            Text("Click to open here, \u{2318}-click to open in a new tab")
                .font(.caption2)
                .foregroundStyle(Palette.textSecondary)
                .padding(8)
        }
        .frame(width: 380)
        .task {
            entries = (try? await app.history.entries(connectionId: session.connection.id)) ?? []
        }
    }
}
