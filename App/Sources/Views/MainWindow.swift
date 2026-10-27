import AppKit
import ConnectionKit
import DockyardCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            ConnectionTabsBar()
            if let session = app.activeSession, let notice = session.restoreNotice {
                RestoreNoticeBar(session: session, text: notice)
            }
            QuickConnectBar()
            Divider()
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 210)
                Divider()
                VStack(spacing: 0) {
                    WorkArea()
                    if app.drawerVisible {
                        DrawerView()
                    }
                }
            }
            TransferBar()
        }
        .background(Palette.ground)
        .navigationTitle(app.activeSession?.connection.name ?? "Dockyard")
        .navigationSubtitle(subtitle)
        .toolbar { MainToolbar() }
        .overlay {
            if app.jumpVisible { JumpPalette() }
        }
        .sheet(item: promptBinding) { prompt in
            PromptSheet(prompt: prompt)
        }
        .sheet(item: editorBinding) { request in
            SiteEditorSheet(request: request)
        }
        .alert("Dockyard", isPresented: alertBinding) {
            Button("OK") { app.alertMessage = nil }
        } message: {
            Text(app.alertMessage ?? "")
        }
        .alert("Something went wrong", isPresented: operationErrorBinding) {
            Button("OK") { app.activeSession?.operationError = nil }
        } message: {
            Text(app.activeSession?.operationError ?? "")
        }
        .overlay(alignment: .bottomTrailing) { ToastStack().padding(.bottom, 44).padding(.trailing, 14) }
        .sheet(isPresented: compareBinding) {
            if let session = app.activeSession { CompareSheet(session: session) }
        }
        .background(WindowAccessor { window in DemoWindows.register("main", window) })
        .frame(minWidth: 980, minHeight: 620)
        .task {
            guard DemoMode.isEnabled else { return }
            if DemoMode.screen == "connectionManager" { openWindow(id: "manager") }
            if DemoMode.screen == "settings" { openSettings() }
        }
    }

    private var compareBinding: Binding<Bool> {
        Binding(get: { app.compareVisible }, set: { app.compareVisible = $0 })
    }

    private var subtitle: String {
        guard let c = app.activeSession?.connection else { return "" }
        return c.protocol == .rclone ? "Cloud \u{00B7} \(c.cloud?.backend ?? "rclone")" : "\(c.protocol.rawValue.uppercased()) \u{00B7} \(c.host)"
    }

    private var promptBinding: Binding<ActivePrompt?> {
        Binding(get: { app.prompts.active }, set: { _ in })
    }

    private var editorBinding: Binding<SiteEditorRequest?> {
        Binding(
            get: { app.siteEditor?.origin == .main ? app.siteEditor : nil },
            set: { if $0 == nil, app.siteEditor?.origin == .main { app.siteEditor = nil } })
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { app.alertMessage != nil }, set: { if !$0 { app.alertMessage = nil } })
    }

    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { app.activeSession?.operationError != nil },
            set: { if !$0 { app.activeSession?.operationError = nil } })
    }
}

// MARK: - Toolbar

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var app

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                app.jumpVisible = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Jump to site or folder")
                    Text("\u{2318}K")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.textSecondary)
                }
                .frame(width: 210, alignment: .leading)
            }
            .help("Jump to a site or recent folder (\u{2318}K)")

            Picker("Layout", selection: layoutBinding) {
                Image(systemName: "rectangle.split.2x1")
                    .accessibilityLabel("Local and server")
                    .tag(LayoutMode.localServer)
                Image(systemName: "rectangle.split.3x1")
                    .accessibilityLabel("Servers side by side")
                    .tag(LayoutMode.sideBySide)
            }
            .pickerStyle(.segmented)
            .help("Switch between Local + server and Servers side by side")

            Button {
                app.compareVisible = true
            } label: {
                Label("Compare / Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!canCompare)
            .help("Compare the local and server folders of the active tabs")

            if let connection = app.activeSession?.connection {
                Button {
                    app.setMounted(connection, !connection.mountInFinder)
                } label: {
                    Label(
                        connection.mountInFinder ? "Unmount from Finder" : "Mount in Finder",
                        systemImage: connection.mountInFinder ? "externaldrive.badge.minus" : "externaldrive.badge.plus")
                }
                .disabled(!MountPolicy.canMount(connection))
                .help(connection.mountInFinder ? "Remove this connection from Finder" : "Show this connection as a drive in Finder")
            }

            Button {
                if let session = app.activeSession { app.disconnect(session) }
            } label: {
                Label("Disconnect", systemImage: "eject")
            }
            .disabled(!(app.activeSession?.status.isConnected ?? false))
            .help("Disconnect the active connection")
        }
    }

    private var layoutBinding: Binding<LayoutMode> {
        Binding(get: { app.layoutMode }, set: { app.setLayout($0) })
    }

    private var canCompare: Bool {
        guard let session = app.activeSession else { return false }
        return session.status.isConnected && session.local != nil && session.server != nil
    }
}

// MARK: - Connection tabs

struct ConnectionTabsBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(app.sessions) { session in
                        ConnectionTab(session: session, active: session.id == app.activeSessionID)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 0)
            Button {
                app.requestQuickConnectFocus()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New connection tab")
            .accessibilityLabel("New connection tab")
            .padding(.horizontal, 10)
        }
        .frame(height: 32)
        .background(Palette.chrome)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct ConnectionTab: View {
    @Environment(AppModel.self) private var app
    let session: ConnectionSession
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: session.status)
            Text(session.connection.name)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .lineLimit(1)
            if session.connection.isProd { Badge(text: "PROD", style: .prod) }
            if session.connection.protocol == .rclone { Badge(text: "CLOUD", style: .cloud) }
            if session.connection.readOnly {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.textSecondary)
                    .help("Read-only: uploads, deletes, renames and permission changes are blocked")
                    .accessibilityLabel("Read-only")
            }
            Button {
                app.close(session)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(session.connection.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(active ? Palette.ground : Color.clear, in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { app.activate(session) }
        .contextMenu {
            Button("Reconnect") { app.reconnect(session) }
            Button("Open in New Tab") { app.open(session.connection, newTab: true) }
            Divider()
            Button("Close Tab") { app.close(session) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.connection.name), \(session.status.label)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct RestoreNoticeBar: View {
    @Environment(AppModel.self) private var app
    let session: ConnectionSession
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.accentColor)
            Text(text).font(.system(size: 12))
            Spacer()
            Button("Start fresh") { app.startFresh(session) }
                .controlSize(.small)
            Button {
                session.restoreNotice = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Palette.selection)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Work area

struct WorkArea: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if app.layoutMode == .sideBySide, !app.sessions.isEmpty {
                SideBySideView()
            } else if let session = app.activeSession {
                SessionContent(session: session)
                    .id(session.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 34))
                        .foregroundStyle(Palette.textSecondary)
                    Text("No connection open")
                        .font(.title3)
                    Text("Use Quick Connect above, or open a saved connection.")
                        .foregroundStyle(Palette.textSecondary)
                    HStack {
                        Button("Connections\u{2026}") { openWindow(id: "manager") }
                        Button("New Connection\u{2026}") { app.editConnection(nil, origin: .main) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Palette.ground)
    }
}

struct SessionContent: View {
    let session: ConnectionSession

    var body: some View {
        if session.status.isConnected || session.status == .reconnecting, let local = session.local, let server = session.server {
            HSplitView {
                PaneView(pane: local, session: session)
                    .frame(minWidth: 320)
                PaneView(pane: server, session: session)
                    .frame(minWidth: 320)
            }
        } else {
            ConnectionStateView(session: session)
        }
    }
}

/// What a connection tab or column shows while it is connecting, failed or closed.
struct ConnectionStateView: View {
    @Environment(AppModel.self) private var app
    let session: ConnectionSession

    var body: some View {
        switch session.status {
        case .connecting:
            VStack(spacing: 10) {
                ProgressView()
                Text("Connecting to \(session.connection.host.isEmpty ? session.connection.name : session.connection.host)\u{2026}")
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            statusView(icon: "exclamationmark.triangle", title: "Could not connect", message: message)
        case .disconnected:
            statusView(icon: "bolt.slash", title: "Disconnected", message: "This connection is closed.")
        case .connected, .reconnecting:
            Color.clear
        }
    }

    private func statusView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(Palette.statusAmber)
            Text(title).font(.title3)
            Text(message)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .textSelection(.enabled)
            HStack {
                Button("Reconnect") { app.reconnect(session) }
                    .keyboardShortcut(.defaultAction)
                Button("Edit Connection\u{2026}") { app.editConnection(session.connection, origin: .main) }
                Button("Show Log") {
                    app.drawerTab = .log
                    app.drawerVisible = true
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
