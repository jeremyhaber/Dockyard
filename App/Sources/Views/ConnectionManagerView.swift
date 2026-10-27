import AppKit
import ConnectionKit
import DockyardCore
import SwiftUI
import UniformTypeIdentifiers

struct ConnectionManagerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var model = ConnectionManagerModel()
    @State private var showWHM = false

    var body: some View {
        HStack(spacing: 0) {
            scopeList
                .frame(width: 200)
            Divider()
            VStack(spacing: 0) {
                header
                if let notice = model.notice {
                    HStack {
                        Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
                        Text(notice).font(.system(size: 12))
                        Spacer()
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Dismiss")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Palette.selection)
                }
                Divider()
                ManagerTable(
                    connections: model.results,
                    statuses: statuses,
                    clientNames: app.clientNames,
                    sourceLabels: Dictionary(uniqueKeysWithValues: model.whmSources.map { ($0.id, $0.label) }),
                    selection: $model.selection,
                    actions: actions)
                Divider()
                HStack {
                    Text("\(model.results.count) of \(app.allConnections.count) connections")
                        .font(.caption)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Text("\u{21A9} connect   \u{2318}\u{21A9} new tab   \u{2325}\u{21A9} side by side (coming soon)")
                        .font(.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 26)
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .background(Palette.ground)
        .navigationTitle("Connections")
        .task(id: model.key(app: app)) { await model.reload(app: app) }
        .sheet(item: editorBinding) { request in SiteEditorSheet(request: request) }
        .sheet(isPresented: $showWHM) { WHMSheet(model: model) }
    }

    private var editorBinding: Binding<SiteEditorRequest?> {
        Binding(
            get: { app.siteEditor?.origin == .manager ? app.siteEditor : nil },
            set: { if $0 == nil, app.siteEditor?.origin == .manager { app.siteEditor = nil } })
    }

    private var statuses: [UUID: SessionStatus] {
        var out: [UUID: SessionStatus] = [:]
        for s in app.sessions where out[s.connection.id] == nil || s.status.isConnected { out[s.connection.id] = s.status }
        return out
    }

    private var actions: ManagerActions {
        ManagerActions(
            connect: { c, newTab in
                app.open(c, newTab: newTab)
                openWindow(id: "main")
            },
            edit: { app.editConnection($0, origin: .manager) },
            duplicate: { c in
                Task {
                    let copy = await app.duplicate(c)
                    app.editConnection(copy, origin: .manager)
                }
            },
            delete: { c in Task { await app.delete(c) } },
            toggleFavorite: { app.toggleFavorite($0) })
    }

    // MARK: Left list

    private var scopeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                scopeRow("All", icon: "tray.full", scope: .all, count: app.allConnections.count)
                scopeRow("Favorites", icon: "star", scope: .favorites, count: app.favorites.count)
                scopeRow("Open now", icon: "bolt.horizontal", scope: .openNow, count: Set(app.sessions.map(\.connection.id)).count)
                scopeRow("Recently added", icon: "sparkles", scope: .recentlyAdded, count: nil)
                Text("SOURCES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.top, 14)
                    .padding(.horizontal, 8)
                ForEach(model.whmSources) { source in
                    scopeRow(source.label, icon: "server.rack", scope: .whm(source.id), count: model.count(for: .whm(source.id)))
                }
                scopeRow("FileZilla import", icon: "square.and.arrow.down", scope: .filezilla, count: model.count(for: .filezillaImport))
                scopeRow("Added by hand", icon: "hand.point.up.left", scope: .manual, count: model.count(for: .manual))
                scopeRow("Quick connect", icon: "bolt", scope: .quickConnect, count: model.count(for: .quickConnect))
            }
            .padding(8)
        }
        .background(Palette.chromeAlt)
    }

    private func scopeRow(_ title: String, icon: String, scope: ManagerScope, count: Int?) -> some View {
        Button {
            model.scope = scope
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(title).lineLimit(1)
                Spacer()
                if let count {
                    Text("\(count)").font(.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(model.scope == scope ? Palette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.scope == scope ? .isSelected : [])
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
                    TextField("Search name, client, host, tag", text: $model.search)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search connections")
                }
                .padding(6)
                .background(Palette.chrome, in: RoundedRectangle(cornerRadius: 6))
                Menu {
                    Button("FileZilla sitemanager.xml\u{2026}") { importFileZilla() }
                    Button("WHM server\u{2026}") { showWHM = true }
                } label: {
                    Text("Import\u{2026}")
                }
                .menuStyle(.button)
                .fixedSize()
                Button("New Connection") { app.editConnection(nil, origin: .manager) }
                    .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 6) {
                protocolChip
                serverChip
                tagChip
                lastUsedChip
                if model.hasActiveFilters {
                    Button("Clear filters") { model.clearFilters() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Spacer()
            }
        }
        .padding(12)
    }

    private func chip(_ title: String, active: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .font(.system(size: 11))
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .foregroundStyle(active ? Color.accentColor : Palette.textPrimary)
        .background(active ? Palette.selection : Palette.chrome, in: Capsule())
        .overlay(Capsule().stroke(Palette.border))
    }

    private var protocolChip: some View {
        Menu {
            ForEach(ConnectionProtocol.allCases, id: \.self) { p in
                Toggle(p == .rclone ? "Cloud" : p.rawValue.uppercased(), isOn: Binding(
                    get: { model.protocols.contains(p) },
                    set: { if $0 { model.protocols.insert(p) } else { model.protocols.remove(p) } }))
            }
        } label: {
            chip(model.protocols.isEmpty ? "Protocol" : "Protocol: \(model.protocols.count)", active: !model.protocols.isEmpty)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var serverChip: some View {
        Menu {
            Button("Any server") { model.whmServer = nil }
            Divider()
            ForEach(model.whmSources) { source in
                Button(source.label) { model.whmServer = source.id }
            }
        } label: {
            chip(model.whmSources.first { $0.id == model.whmServer }?.label ?? "Server", active: model.whmServer != nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var tagChip: some View {
        Menu {
            Button("Any tag") { model.tag = nil }
            Divider()
            ForEach(model.tags, id: \.self) { tag in
                Button(tag) { model.tag = tag }
            }
        } label: {
            chip(model.tag.map { "Tag: \($0)" } ?? "Tag", active: model.tag != nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var lastUsedChip: some View {
        Menu {
            Button("Any time") { model.lastUsed = nil }
            Divider()
            ForEach(LastUsedChoice.allCases) { choice in
                Button(choice.rawValue) { model.lastUsed = choice }
            }
        } label: {
            chip(model.lastUsed?.rawValue ?? "Last used", active: model.lastUsed != nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Import

    private func importFileZilla() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let defaultFile = URL(fileURLWithPath: FileZillaParser.defaultPath(home: home.path))
        guard let url = Dialogs.chooseFile(
            directory: defaultFile.deletingLastPathComponent(), showHidden: true, types: [.xml]) else { return }
        Task { model.notice = await app.importFileZilla(from: url) }
    }
}

struct WHMSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: ConnectionManagerModel
    @State private var label = ""
    @State private var host = ""
    @State private var port = "2087"
    @State private var apiUser = "root"
    @State private var token = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("WHM servers").font(.headline)
            if !model.whmSources.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.whmSources) { source in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(source.label)
                                Text(syncText(source)).font(.caption).foregroundStyle(Palette.textSecondary)
                            }
                            Spacer()
                            Button("Sync now") { sync(source) }.disabled(busy)
                            Button(role: .destructive) {
                                Task { try? await app.whmSources.delete(source.id); await model.reload(app: app) }
                            } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Remove \(source.label)")
                        }
                        .padding(8)
                        Divider()
                    }
                }
                .background(Palette.chrome, in: RoundedRectangle(cornerRadius: 6))
            }
            Text("Add a server").font(.subheadline).foregroundStyle(Palette.textSecondary)
            Form {
                TextField("Label", text: $label, prompt: Text("Optional"))
                TextField("Host", text: $host, prompt: Text("whm.example.com"))
                TextField("API port", text: $port)
                TextField("API user", text: $apiUser)
                SecureField("API token", text: $token)
            }
            .formStyle(.columns)
            if let message { Text(message).font(.callout).foregroundStyle(Palette.textSecondary) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add and Sync") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || token.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func syncText(_ s: WHMSource) -> String {
        if let error = s.lastSyncError { return "Last sync failed: \(error)" }
        guard let date = s.lastSyncAt else { return "\(s.host) \u{00B7} never synced" }
        return "\(s.host) \u{00B7} last sync \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func add() {
        busy = true
        let h = host.trimmingCharacters(in: .whitespaces)
        let p = Int(port) ?? 2087
        Task {
            message = await app.addWHMSource(label: label, host: h, port: p, apiUser: apiUser, token: token)
            token = ""
            busy = false
            await model.reload(app: app)
        }
    }

    private func sync(_ source: WHMSource) {
        busy = true
        Task {
            message = await app.syncWHM(source)
            busy = false
            await model.reload(app: app)
        }
    }
}
