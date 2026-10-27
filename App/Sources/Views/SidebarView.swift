import AppKit
import ConnectionKit
import DockyardCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Open now", connections: openConnections, empty: "Nothing open")
                    section("Favorites", connections: app.favorites, empty: "Star a connection to pin it here")
                    section("Recent", connections: app.recents, empty: "Connections you use appear here")
                }
                .padding(10)
            }
            Divider()
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
            Divider()
            legend
        }
        .background(Palette.chromeAlt)
    }

    private var openConnections: [Connection] {
        var seen = Set<UUID>()
        return app.sessions.map(\.connection).filter { seen.insert($0.id).inserted }
    }

    private func section(_ title: String, connections: [Connection], empty: String) -> some View {
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
        .padding(.horizontal, 10)
        .frame(height: 28)
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

    var body: some View {
        let status = app.status(of: connection.id)
        let active = app.activeSession?.connection.id == connection.id
        HStack(spacing: 6) {
            StatusDot(status: status)
            Text(connection.name)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 2)
            if connection.mountInFinder {
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
        .contentShape(Rectangle())
        .onTapGesture {
            app.open(connection, newTab: NSEvent.modifierFlags.contains(.command))
        }
        .contextMenu {
            Button("Open") { app.open(connection) }
            Button("Open in New Tab") { app.open(connection, newTab: true) }
            Divider()
            Button(connection.favorite ? "Remove from Favorites" : "Add to Favorites") { app.toggleFavorite(connection) }
            Button(connection.mountInFinder ? "Unmount from Finder" : "Mount in Finder") {
                app.setMounted(connection, !connection.mountInFinder)
            }
            .disabled(!MountPolicy.canMount(connection))
            Button("Open Side by Side") { app.openSideBySide(connection) }
            Button("Edit\u{2026}") { app.editConnection(connection, origin: .main) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(connection.name), \(status?.label ?? "saved")")
        .accessibilityAddTraits(.isButton)
    }
}
