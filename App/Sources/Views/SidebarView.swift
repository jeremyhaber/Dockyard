import AppKit
import ConnectionKit
import DockyardCore
import SwiftUI

/// Full width, or collapsed to an icon rail that expands over the content while the pointer is on it.
struct SidebarHost: View {
    @Environment(AppModel.self) private var app
    @State private var hoverExpanded = false
    @State private var hoverTask: Task<Void, Never>?

    static let width: CGFloat = 210
    static let railWidth: CGFloat = 52

    var body: some View {
        if app.sidebarCollapsed {
            Color.clear
                .frame(width: Self.railWidth)
                .overlay(alignment: .topLeading) {
                    SidebarView(compact: !hoverExpanded)
                        .frame(width: hoverExpanded ? Self.width : Self.railWidth)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .trailing) { if hoverExpanded { Divider() } }
                        .shadow(color: .black.opacity(hoverExpanded ? 0.18 : 0), radius: 10, x: 2)
                        .onHover(perform: hover)
                }
                .zIndex(1)
                .onChange(of: app.sidebarCollapsed) { hoverExpanded = false }
        } else {
            SidebarView(compact: false)
                .frame(width: Self.width)
        }
    }

    /// Opens after a short pause so passing over the rail does not flash it open; closes a little later for the same reason.
    private func hover(_ inside: Bool) {
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(nanoseconds: inside ? 250_000_000 : 200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { hoverExpanded = inside }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: compact ? .center : .leading, spacing: compact ? 8 : 14) {
                    let open = openConnections
                    let openIDs = Set(open.map(\.id))
                    let favorites = app.favorites.filter { !openIDs.contains($0.id) }
                    section("Open now", connections: open, empty: "Nothing open")
                    section("Favorites", connections: favorites, empty: app.favorites.isEmpty ? "Star a connection to pin it here" : "All open")
                    section("Recent", connections: app.recents(excluding: openIDs.union(favorites.map(\.id))), empty: "Connections you use appear here")
                }
                .padding(compact ? 6 : 10)
            }
            .scrollIndicators(compact ? .never : .automatic)
            Divider()
            if compact {
                Button {
                    openWindow(id: "manager")
                } label: {
                    Image(systemName: "server.rack")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Connections (\u{2318}O)")
                .accessibilityLabel("Connections, \(app.allConnections.count) saved")
            } else {
                Button {
                    openWindow(id: "manager")
                } label: {
                    HStack {
                        Image(systemName: "server.rack")
                        Text("Connections")
                        Spacer()
                        Text("\(app.allConnections.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 6)
                            .background(Palette.border.opacity(0.6), in: Capsule())
                        Text("\u{2318}O")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Connections, \(app.allConnections.count) saved")
            }
            Divider()
            HStack(spacing: 0) {
                if !compact { legend }
                Spacer(minLength: 0)
                collapseButton
            }
            .frame(height: 28)
        }
        .background(Palette.chromeAlt)
    }

    private var collapseButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { app.sidebarCollapsed.toggle() }
        } label: {
            Image(systemName: app.sidebarCollapsed ? "sidebar.squares.left" : "sidebar.left")
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Palette.textSecondary)
        .frame(maxWidth: compact ? .infinity : nil)
        .padding(.trailing, compact ? 0 : 4)
        .help(app.sidebarCollapsed ? "Keep the sidebar open (\u{2303}\u{2318}S)" : "Collapse the sidebar to icons (\u{2303}\u{2318}S)")
        .accessibilityLabel(app.sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
    }

    /// Connections with a connected (or connecting) tab. Each connection appears in one section only:
    /// open first, then favorites, then recent.
    private var openConnections: [Connection] {
        var seen = Set<UUID>()
        return app.sessions
            .filter { $0.status.isConnected || $0.status == .connecting || $0.status == .reconnecting }
            .map(\.connection)
            .filter { seen.insert($0.id).inserted }
    }

    @ViewBuilder
    private func section(_ title: String, connections: [Connection], empty: String) -> some View {
        if compact {
            if !connections.isEmpty {
                VStack(spacing: 4) {
                    ForEach(connections) { connection in
                        SidebarRow(connection: connection, compact: true)
                    }
                    Divider().padding(.horizontal, 6)
                }
            }
        } else {
            fullSection(title, connections: connections, empty: empty)
        }
    }

    private func fullSection(_ title: String, connections: [Connection], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .padding(.bottom, 2)
            if connections.isEmpty {
                Text(empty)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
            } else {
                ForEach(connections) { connection in
                    SidebarRow(connection: connection)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem(Palette.statusGreen, "Connected")
            legendItem(Palette.statusAmber, "Idle")
            legendItem(Palette.statusGrey, "Saved")
        }
        .padding(.leading, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Green connected, amber reconnecting or idle, grey saved")
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 10)).foregroundStyle(Palette.textSecondary)
        }
    }
}

struct SidebarRow: View {
    @Environment(AppModel.self) private var app
    let connection: Connection
    var compact = false

    var body: some View {
        let status = app.status(of: connection.id)
        let active = app.activeSession?.connection.id == connection.id
        Group {
            if compact {
                SiteIcon(connection: connection, size: 26)
                    .overlay(alignment: .bottomTrailing) {
                        StatusDot(status: status, size: 8)
                            .overlay(Circle().stroke(Palette.chromeAlt, lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }
                    .padding(5)
                    .background(active ? Palette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    .help(connection.name)
            } else {
                HStack(spacing: 6) {
                    SiteIcon(connection: connection, size: 16)
                        .overlay(alignment: .bottomTrailing) {
                            StatusDot(status: status, size: 6)
                                .overlay(Circle().stroke(Palette.chromeAlt, lineWidth: 1))
                                .offset(x: 2, y: 2)
                        }
                    Text(connection.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if connection.mountInFinder && AppGroup.mountingAvailable {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.textSecondary)
                            .help("Mounted in Finder")
                            .accessibilityLabel("Mounted in Finder")
                    }
                    if connection.isNew { Badge(text: "NEW", style: .new) }
                    if connection.isProd { Badge(text: "PROD", style: .prod) }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(active ? Palette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            app.open(connection, newTab: NSEvent.modifierFlags.contains(.command))
        }
        .contextMenu {
            Button("Open") { app.open(connection) }
            Button("Open in New Tab") { app.open(connection, newTab: true) }
            Divider()
            Button(connection.favorite ? "Remove from Favorites" : "Add to Favorites") { app.toggleFavorite(connection) }
            if AppGroup.mountingAvailable {
                Button(connection.mountInFinder ? "Unmount from Finder" : "Mount in Finder") {
                    app.setMounted(connection, !connection.mountInFinder)
                }
                .disabled(!MountPolicy.canMount(connection))
            }
            Button("Open Side by Side") { app.openSideBySide(connection) }
            if app.canOpenCPanel(connection) {
                Button("Open cPanel") { app.openCPanel(for: connection) }
            }
            ConnectionColorMenu(connection: connection)
            Button("Edit\u{2026}") { app.editConnection(connection, origin: .main) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(connection.name), \(status?.label ?? "saved")")
        .accessibilityAddTraits(.isButton)
    }
}
