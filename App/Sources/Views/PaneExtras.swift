import ConnectionKit
import DockyardCore
import SwiftUI

/// The clickable path. When it does not fit, the leading segments collapse into a "…" menu and the last ones stay visible.
struct BreadcrumbBar: View {
    let pane: PaneModel
    let onEmptyTap: () -> Void

    var body: some View {
        let segments = pane.state.breadcrumbs
        ViewThatFits(in: .horizontal) {
            ForEach(0..<max(segments.count, 1), id: \.self) { hidden in
                row(segments, hidden: hidden)
            }
        }
    }

    private func row(_ segments: [BreadcrumbSegment], hidden: Int) -> some View {
        let shown = Array(segments.dropFirst(hidden))
        let collapsed = Array(segments.prefix(hidden))
        return HStack(spacing: 0) {
            if !collapsed.isEmpty {
                Menu {
                    ForEach(collapsed) { segment in
                        Button(segment.path == "/" ? "/ (root)" : segment.title) { pane.navigate(to: segment.path) }
                    }
                } label: {
                    Text("\u{2026}")
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 3)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Earlier folders in the path")
                .accessibilityLabel("Earlier folders in the path")
                chevron
            }
            ForEach(shown) { segment in
                Button(segment.title) { pane.navigate(to: segment.path) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .accessibilityLabel(segment.path)
                if segment.path != pane.currentPath { chevron }
            }
            Color.clear
                .frame(minWidth: 12, maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onEmptyTap)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Palette.textSecondary)
            .accessibilityHidden(true)
    }
}

/// "Drop to copy 2 files here · Prod → Staging", shown over the pane a drag is hovering.
struct DropHintView: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down.on.square").accessibilityHidden(true)
                Text(text).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.accentColor, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.accentColor.opacity(0.08))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// The change journal of this pane: what changed, when, with Undo and Reveal per entry.
struct RecentChangesPopover: View {
    @Environment(AppModel.self) private var app
    let pane: PaneModel
    let session: ConnectionSession
    let dismiss: () -> Void
    @State private var entries: [ChangeEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(pane.side == .local ? "Recent changes on this Mac" : "Recent changes on \(session.connection.name)")
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
                .padding(10)
            Divider()
            if entries.isEmpty {
                Text("No changes yet. Moves, renames, new folders and copies show up here.")
                    .foregroundStyle(Palette.textSecondary)
                    .padding(16)
                    .frame(width: 420)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            row(entry)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            Divider()
            HStack {
                Text("\u{2318}Z undoes the latest change, \u{21E7}\u{2318}Z redoes it")
                    .font(.caption2)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
            }
            .padding(8)
        }
        .frame(width: 440)
        .task { await reload() }
    }

    private func row(_ entry: ChangeEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title).font(.system(size: 12, weight: .medium)).strikethrough(entry.undone)
                    Text(entry.time, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(Palette.textSecondary)
                }
                Text(detail(entry))
                    .font(.monoSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button("Reveal") {
                pane.openTab(at: entry.isDirectory && entry.kind != .move ? entry.toPath : RemotePath.parent(of: entry.toPath))
                dismiss()
            }
            .controlSize(.small)
            Button(entry.undone ? "Redo" : "Undo") {
                Task {
                    await app.apply(entry, redo: entry.undone, session: session, side: pane.side)
                    await reload()
                }
            }
            .controlSize(.small)
            .disabled(entry.undone && (entry.kind == .upload || entry.kind == .overwrite))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ e: ChangeEntry) -> String {
        switch e.kind {
        case .move, .rename, .overwrite: "\(e.fromPath ?? "") \u{2192} \(e.toPath)"
        case .chmod: "\(e.toPath): \(FileDisplay.octal(e.previousMode)) \u{2192} \(FileDisplay.octal(e.newMode))"
        case .newFolder, .upload: e.toPath
        }
    }

    private func reload() async {
        entries = (try? await app.journal.entries(scope: session.scope(pane.side))) ?? []
    }
}
