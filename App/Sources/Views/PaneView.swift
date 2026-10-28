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
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var legacyScrollers = NSScroller.preferredScrollerStyle == .legacy

    private static let rowHeight: CGFloat = 30

    /// Legacy (always-visible) scrollers take space below the tabs instead of drawing over them.
    private var scrollerRoom: CGFloat {
        guard legacyScrollers, contentWidth > viewportWidth + 0.5 else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(Array(pane.state.tabs.enumerated()), id: \.element.id) { index, tab in
                            FolderTab(
                                pane: pane, index: index, path: tab.path,
                                active: index == pane.activeTabIndex,
                                closable: pane.state.tabs.count > 1
                            )
                            .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: Self.rowHeight)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                }
                .scrollIndicators(.automatic)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
                .onAppear { reveal(proxy) }
                .onChange(of: pane.activeTabIndex) { reveal(proxy) }
                .onChange(of: pane.state.tabs.count) { reveal(proxy) }
            }
            Divider()
                .frame(height: Self.rowHeight - 12)
                .padding(.top, 6)
            Button {
                pane.openTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New folder tab (\u{2318}T)")
            .accessibilityLabel("New folder tab")
            .padding(.horizontal, 4)
            .frame(height: Self.rowHeight)
        }
        .frame(height: Self.rowHeight + scrollerRoom)
        .background(Palette.chrome)
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            legacyScrollers = NSScroller.preferredScrollerStyle == .legacy
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard pane.state.tabs.indices.contains(pane.activeTabIndex) else { return }
        let id = pane.state.tabs[pane.activeTabIndex].id
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
    }
}

private struct FolderTab: View {
    let pane: PaneModel
    let index: Int
    let path: String
    let active: Bool
    let closable: Bool
    @State private var hovering = false

    private var title: String { path == "/" ? "/" : RemotePath.lastComponent(of: path) }

    /// Long names are cut in the middle: the scroll view gives tabs no width to truncate against.
    private var shortTitle: String {
        guard title.count > 24 else { return title }
        return "\(title.prefix(11))\u{2026}\(title.suffix(11))"
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: active ? "folder.fill" : "folder")
                .font(.system(size: 10))
                .foregroundStyle(active ? Color.accentColor : Palette.textSecondary)
            Text(shortTitle)
                .font(.system(size: 11, weight: active ? .medium : .regular))
                .foregroundStyle(active ? Palette.textPrimary : Palette.textSecondary)
                .lineLimit(1)
            if closable {
                Button {
                    pane.closeTab(at: index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(active || hovering ? 1 : 0)
                .accessibilityLabel("Close tab \(title)")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, closable ? 4 : 8)
        .frame(height: 22)
        .background(background, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(active ? Palette.border : Color.clear))
        .shadow(color: .black.opacity(active ? 0.06 : 0), radius: 1, y: 0.5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) { return }
            pane.activateTab(index)
        }
        .help(path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var background: Color {
        if active { return Palette.ground }
        return hovering ? Palette.textPrimary.opacity(0.06) : .clear
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
                if app.canOpenCPanel(session.connection) {
                    Button { app.openCPanel(for: session.connection) } label: {
                        Label("cPanel", systemImage: "safari").labelStyle(.titleAndIcon).font(.caption)
                    }
                    .help("Open \(session.connection.username)'s cPanel in your browser, already signed in")
                }
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
