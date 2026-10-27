import ConnectionKit
import DockyardCore
import SwiftUI

/// "Servers side by side" (HANDOFF 8): Local collapses to a rail, every column is a connection.
struct SideBySideView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let columns = app.columnSessions
        HStack(spacing: 0) {
            LocalRail()
            Divider()
            if columns.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.split.3x1").font(.system(size: 30)).foregroundStyle(Palette.textSecondary)
                    Text("Add a server to start").font(.title3)
                    AddColumnMenu()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(columns) { session in
                    ServerColumn(session: session, canRemove: columns.count > 1)
                        .frame(minWidth: 300, maxWidth: .infinity)
                    Divider()
                }
                VStack {
                    AddColumnMenu()
                    Spacer()
                }
                .padding(8)
                .frame(width: 44)
            }
        }
        .onAppear { app.seedColumns() }
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
            .frame(width: 320)
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
            Text(session.connection.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if session.connection.isProd { Badge(text: "PROD", style: .prod) }
            if session.connection.protocol == .rclone { Badge(text: "CLOUD", style: .cloud) }
            if session.browsingAsRoot { Badge(text: "ROOT", style: .root) }
            if session.connection.readOnly { Image(systemName: "lock.fill").font(.system(size: 9)).accessibilityLabel("Read-only") }
            Spacer()
            if canRemove {
                Button { app.removeColumn(session.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain)
                    .help("Remove this column")
                    .accessibilityLabel("Remove column \(session.connection.name)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(active ? Palette.selection : Palette.chrome)
        .contentShape(Rectangle())
        .onTapGesture { app.activeSessionID = session.id }
        .accessibilityElement(children: .contain)
    }
}

/// "+" at the right of the columns: add an open connection, or open a saved one.
struct AddColumnMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let shown = Set(app.columnIDs)
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
