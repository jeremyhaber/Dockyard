import ConnectionKit
import DockyardCore
import SwiftUI

struct JumpPalette: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var hits: [JumpHit] = []
    @State private var folders: [JumpFolder] = []
    @State private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
                    TextField("Jump to a site or recent folder", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($focused)
                        .onSubmit {
                            if hits.isEmpty, showsRecentChanges { showRecentChanges() } else { activate(hits.indices.contains(selected) ? hits[selected] : nil) }
                        }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .accessibilityLabel("Jump search")
                }
                .padding(14)
                Divider()
                if showsRecentChanges {
                    Button { showRecentChanges() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(Color.accentColor)
                            Text("Recent changes").font(.system(size: 13, weight: .medium))
                            Text("Undo moves, renames and copies").font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                if hits.isEmpty {
                    Text(query.isEmpty ? "Type to search connections and recent folders" : "No matches")
                        .foregroundStyle(Palette.textSecondary)
                        .padding(20)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                                    row(hit, selected: index == selected)
                                        .id(hit.id)
                                        .onTapGesture { activate(hit) }
                                }
                            }
                        }
                        .frame(maxHeight: 340)
                        .onChange(of: selected) {
                            if hits.indices.contains(selected) { proxy.scrollTo(hits[selected].id) }
                        }
                    }
                }
            }
            .frame(width: 560)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            .padding(.top, 70)
        }
        .onAppear { focused = true }
        .task {
            let recent = (try? await app.history.recentAcrossConnections()) ?? []
            folders = recent.map { JumpFolder(connectionId: $0.connectionId, path: $0.path, visitedAt: $0.visitedAt) }
            refresh()
        }
        .onChange(of: query) { selected = 0; refresh() }
    }

    private func row(_ hit: JumpHit, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch hit.target {
            case .connection(let c):
                StatusDot(status: app.status(of: c.id))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(c.name).font(.system(size: 13, weight: .medium))
                        if c.isProd { Badge(text: "PROD", style: .prod) }
                        if c.protocol == .rclone { Badge(text: "CLOUD", style: .cloud) }
                    }
                    Text(subtitle(c)).font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                }
            case .folder(let f, let c):
                Image(systemName: "folder").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Text(c.name).font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(selected ? Palette.selection : Color.clear)
        .contentShape(Rectangle())
    }

    private func subtitle(_ c: Connection) -> String {
        let client = c.clientFolderId.flatMap { app.clientNames[$0] }
        let base = c.protocol == .rclone ? "Cloud" : "\(c.username.isEmpty ? "" : c.username + "@")\(c.host)"
        return client.map { "\($0) \u{00B7} \(base)" } ?? base
    }

    private func refresh() {
        hits = JumpSearch.search(
            query, connections: app.allConnections, folders: folders, clientNames: app.clientNames,
            openNow: Set(app.sessions.map(\.connection.id)), limit: 12)
    }

    private func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        selected = min(max(0, selected + delta), hits.count - 1)
    }

    private var showsRecentChanges: Bool {
        let q = query.lowercased()
        return app.activeSession?.server != nil && ["recent", "undo", "changes", "history of changes"].contains { $0.hasPrefix(q) && !q.isEmpty || q.hasPrefix($0) }
    }

    private func showRecentChanges() {
        let pane = app.activeSession.flatMap { $0.pane(app.focusedSide) ?? $0.server }
        close()
        pane?.requestRecentChanges()
    }

    private func close() { app.jumpVisible = false }

    private func activate(_ hit: JumpHit?) {
        guard let hit else { return }
        switch hit.target {
        case .connection(let c): app.open(c)
        case .folder(let f, let c): app.open(c, initialPath: f.path)
        }
        close()
    }
}
