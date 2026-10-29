import AppKit
import DockyardCore
import SwiftUI
import UniformTypeIdentifiers

/// The drawer's Scratch tab: downloads that expire (HANDOFF 7).
struct ScratchView: View {
    @Environment(AppModel.self) private var app
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var center = app.scratch
        Group {
            if center.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 24))
                    Text("Scratch is empty. Right-click a server file and choose Download to Scratch, or drop server files here. They are removed after \(ScratchSettings.lifetimeTitle).")
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table(center)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).padding(4)
            }
        }
        .onDrop(of: [UTType(exportedAs: "app.dockyard.items")], isTargeted: $dropTargeted) { _ in
            guard let origin = DragState.origin, origin.side == .server, !DragState.items.isEmpty,
                  let session = app.sessions.first(where: { $0.id == origin.session }) else { return false }
            app.downloadToScratch(DragState.items, from: session)
            return true
        }
    }

    private func table(_ center: ScratchCenter) -> some View {
        @Bindable var center = center
        return Table(of: ScratchItem.self, selection: $center.selection) {
            TableColumn("Name") { item in
                Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
                    .lineLimit(1).truncationMode(.middle)
            }
            TableColumn("From") { item in
                Text(item.origin ?? "Added in Finder")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            TableColumn("Size") { item in
                Text(item.isDirectory ? "--" : FileDisplay.size(item.size)).foregroundStyle(.secondary)
            }
            .width(70)
            TableColumn("Expires") { item in
                let left = center.remaining(item)
                let urgent = item.expires.timeIntervalSince(center.now) < 3600
                VStack(alignment: .leading, spacing: 3) {
                    Text(center.timeLeft(item))
                        .foregroundStyle(urgent ? Palette.statusAmber : .primary)
                    ProgressView(value: left)
                        .progressViewStyle(.linear)
                        .tint(urgent ? Palette.statusAmber : Palette.statusGreen)
                        .controlSize(.mini)
                }
            }
            .width(min: 120, ideal: 150)
        } rows: {
            ForEach(center.items) { item in
                TableRow(item).itemProvider { NSItemProvider(contentsOf: item.url) }
            }
        }
        .contextMenu(forSelectionType: URL.self) { ids in
            let picked = center.items.filter { ids.contains($0.url) }
            if !picked.isEmpty {
                Button("Open") { picked.forEach(center.open) }
                Button("Quick Look") { center.quickLook(picked) }
                Button("Show in Finder") { center.reveal(picked) }
                Divider()
                Button("Keep") { center.keep(picked, app: app) }
                Button("Move to Trash") { center.moveToTrash(picked) }
            }
        } primaryAction: { ids in
            center.items.filter { ids.contains($0.url) }.forEach(center.open)
        }
        .onKeyPress(.space) {
            center.quickLook(center.selectedItems)
            return .handled
        }
        .scrollContentBackground(.hidden)
    }
}

/// The controls to the right of the drawer's tabs when Scratch is shown.
struct ScratchHeader: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let center = app.scratch
        let selected = center.selectedItems
        HStack(spacing: 8) {
            Text(summary(center))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Keep") { center.keep(selected, app: app) }
                .disabled(selected.isEmpty)
                .help("Move the selected items out of Scratch so they are not removed")
            Button("Show in Finder") { center.reveal(selected) }
            Button("Empty Scratch\u{2026}") { center.emptyAll() }
                .disabled(center.items.isEmpty)
        }
    }

    private func summary(_ center: ScratchCenter) -> String {
        let folder = center.folderURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        guard !center.items.isEmpty else { return folder }
        let count = center.items.count == 1 ? "1 item" : "\(center.items.count) items"
        return "\(count), \(FileDisplay.size(center.totalSize)) · \(folder)"
    }
}
