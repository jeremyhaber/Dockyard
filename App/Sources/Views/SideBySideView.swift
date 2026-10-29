import ConnectionKit
import DockyardCore
import SwiftUI

/// "Servers side by side" (HANDOFF 8), shown for a tab group: Local collapses to a rail, every column is one of the
/// group's connections.
struct SideBySideView: View {
    @Environment(AppModel.self) private var app
    static let minColumnWidth: CGFloat = 300
    static let addWidth: CGFloat = 44
    @State private var localWidthAtDragStart = LocalPaneLayout.defaultWidth

    var body: some View {
        let columns = app.columnSessions
        let weights = columns.map { app.columnWeight($0.id) }
        HStack(spacing: 0) {
            LocalRail()
            if app.localRailExpanded, app.activeSession?.local != nil {
                ColumnResizeHandle(
                    label: "Resize the local pane",
                    onBegin: { localWidthAtDragStart = app.localPaneWidth },
                    onDrag: { app.localPaneWidth = LocalPaneLayout.clamp(localWidthAtDragStart + $0) },
                    onReset: { app.localPaneWidth = LocalPaneLayout.defaultWidth }
                )
            } else {
                Divider()
            }
            // Columns share the width down to their minimum, then scroll sideways (HorizontalColumns)
            // instead of pushing the window wider than the screen.
            HorizontalColumns(
                minimumWidth: Self.minimumContentWidth(weights),
                columnFractions: weights.map { CGFloat($0 / weights.reduce(0, +)) },
                activeIndex: columns.firstIndex { $0.id == app.activeSessionID },
                app: app
            ) {
                ServerColumnsRow(columns: columns)
            }
            Divider()
            VStack {
                AddColumnMenu()
                Spacer()
            }
            .padding(8)
            .frame(width: Self.addWidth)
        }
    }

    /// The width at which the narrowest column is `minColumnWidth`; below it the columns scroll.
    static func minimumContentWidth(_ weights: [Double]) -> CGFloat {
        guard let narrowest = weights.min(), narrowest > 0 else { return 0 }
        return minColumnWidth * weights.reduce(0, +) / narrowest + CGFloat(weights.count - 1)
    }
}

/// The columns with draggable dividers between them. Each column's width is its weight's share of the row.
private struct ServerColumnsRow: View {
    @Environment(AppModel.self) private var app
    let columns: [ConnectionSession]
    @State private var dragStart: (weights: [Double], usable: Double)?

    var body: some View {
        GeometryReader { proxy in
            let weights = columns.map { app.columnWeight($0.id) }
            let total = weights.reduce(0, +)
            let usable = max(0, proxy.size.width - CGFloat(columns.count - 1))
            HStack(spacing: 0) {
                ForEach(Array(columns.enumerated()), id: \.element.id) { index, session in
                    if index > 0 {
                        ColumnResizeHandle(
                            label: "Resize \(columns[index - 1].connection.name) and \(session.connection.name)",
                            onBegin: { dragStart = (weights, Double(usable)) },
                            onDrag: { resize(divider: index, by: $0) },
                            onReset: { app.resetColumnWidths() }
                        )
                    }
                    ServerColumn(session: session, canRemove: columns.count > 1)
                        .frame(width: usable * weights[index] / total)
                }
            }
        }
    }

    /// Moves width between the columns either side of divider `index`; both keep the minimum width.
    private func resize(divider index: Int, by offset: Double) {
        guard let start = dragStart, start.weights.count == columns.count, start.usable > 0 else { return }
        let total = start.weights.reduce(0, +)
        let pair = start.weights[index - 1] + start.weights[index]
        let floor = SideBySideView.minColumnWidth * total / start.usable
        guard pair >= 2 * floor else { return }
        let left = min(max(start.weights[index - 1] + offset * total / start.usable, floor), pair - floor)
        app.columnWeights[columns[index - 1].id] = left
        app.columnWeights[columns[index].id] = pair - left
    }
}

/// The slim rail that stands in for the local pane; it expands to the active connection's local pane.
struct LocalRail: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.localRailExpanded, let session = app.activeSession, let local = session.local {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "desktopcomputer").accessibilityHidden(true)
                    Text("This Mac").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button { app.localRailExpanded = false } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless)
                        .help("Collapse the local pane")
                        .accessibilityLabel("Collapse the local pane")
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Palette.chrome)
                Divider()
                PaneView(pane: local, session: session)
            }
            .frame(width: app.localPaneWidth)
        } else {
            VStack(spacing: 10) {
                Button { app.localRailExpanded = true } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .help("Expand the local pane")
                    .accessibilityLabel("Expand the local pane")
                Image(systemName: "desktopcomputer").foregroundStyle(Palette.textSecondary).accessibilityHidden(true)
                Text("This Mac")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 16, height: 70)
                Spacer()
            }
            .padding(.top, 10)
            .frame(width: 32)
            .background(Palette.chromeAlt)
            .contentShape(Rectangle())
            .onTapGesture { app.localRailExpanded = true }
            .accessibilityElement(children: .contain)
        }
    }
}

/// One connection with its own folder tabs, path bar and file list.
struct ServerColumn: View {
    @Environment(AppModel.self) private var app
    let session: ConnectionSession
    let canRemove: Bool

    var body: some View {
        let active = app.activeSessionID == session.id
        VStack(spacing: 0) {
            header(active: active)
                .overlay(alignment: .top) { ConnectionColorStripe(color: session.connection.color) }
            Divider()
            if session.status.isConnected, let server = session.server {
                PaneView(pane: server, session: session)
            } else {
                ConnectionStateView(session: session)
            }
        }
        .background(Palette.ground)
    }

    private func header(active: Bool) -> some View {
        HStack(spacing: 6) {
            StatusDot(status: session.status)
            ConnectionNameField(session: session, place: .column, font: .system(size: 12, weight: .semibold))
            if session.connection.isProd { Badge(text: "PROD", style: .prod) }
            if session.connection.protocol == .rclone { Badge(text: "CLOUD", style: .cloud) }
            if session.browsingAsRoot { Badge(text: "ROOT", style: .root) }
            if session.connection.readOnly { Image(systemName: "lock.fill").font(.system(size: 9)).accessibilityLabel("Read-only") }
            Spacer()
            if canRemove {
                Button { app.removeColumn(session.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain)
                    .help("Take this tab out of the group")
                    .accessibilityLabel("Remove \(session.connection.name) from the group")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(session.connection.color?.fill(active: active) ?? (active ? Palette.selection : Palette.chrome))
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { app.renaming = RenameTarget(sessionID: session.id, place: .column) })
        .simultaneousGesture(TapGesture().onEnded { app.activeSessionID = session.id })
        .reordersSession(session.id)
        .contextMenu {
            ConnectionColorMenu(connection: session.connection)
            Button("Rename\u{2026}") { app.renaming = RenameTarget(sessionID: session.id, place: .column) }
            Button("Edit Connection\u{2026}") { app.editConnection(session.connection, origin: .main) }
            Divider()
            TabGroupMenuItems(session: session)
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("Drag onto the edge of another tab to move it, or onto its middle to group them")
    }
}

/// "+" at the right of the columns: add an open connection, or open a saved one.
struct AddColumnMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let shown = Set(app.columnSessions.map(\.id))
        let openOthers = app.sessions.filter { !shown.contains($0.id) }
        Menu {
            if !openOthers.isEmpty {
                Section("Open connections") {
                    ForEach(openOthers) { session in
                        Button(session.connection.name) { app.addColumn(session) }
                    }
                }
            }
            Section("Saved connections") {
                ForEach(recentOthers(excluding: Set(openOthers.map(\.connection.id)).union(app.sessions.map(\.connection.id)))) { connection in
                    Button(connection.name) { app.addColumn(connection) }
                }
            }
            Divider()
            Button("More\u{2026}") { openWindow(id: "manager") }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a server column")
        .accessibilityLabel("Add a server column")
    }

    private func recentOthers(excluding: Set<UUID>) -> [Connection] {
        var seen = excluding
        return Array((app.favorites + app.recents).filter { seen.insert($0.id).inserted }.prefix(8))
    }
}
