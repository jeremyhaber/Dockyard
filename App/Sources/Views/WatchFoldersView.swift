import AppKit
import ConnectionKit
import DockyardCore
import SwiftUI

/// The Watch Folders window: local folders that upload to a server folder whenever something changes.
struct WatchFoldersView: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false

    var body: some View {
        let watches = app.watches
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watch Folders").font(.headline)
                    Text("Changes in a linked folder upload automatically, skipping what your filters leave out.")
                        .font(.caption).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Button {
                    adding = true
                } label: { Label("Add Watch\u{2026}", systemImage: "plus") }
            }
            .padding(14)
            Divider()
            if watches.links.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "eye").font(.system(size: 32)).foregroundStyle(Palette.textSecondary)
                    Text("No watched folders").font(.title3)
                    Text("Link a folder on this Mac to a folder on a server, then save in your editor and the change is live.")
                        .foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    Button("Add Watch\u{2026}") { adding = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(watches.links) { link in
                        WatchRow(link: link, status: watches.status[link.id] ?? WatchStatus())
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 680, minHeight: 380)
        .background(Palette.ground)
        .sheet(isPresented: $adding) { AddWatchSheet() }
        .background(WindowAccessor { window in DemoWindows.register("watch", window) })
    }
}

private struct WatchRow: View {
    @Environment(AppModel.self) private var app
    let link: WatchLink
    let status: WatchStatus

    var body: some View {
        let connection = app.allConnections.first { $0.id == link.connectionId }
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .padding(.top, 5)
                .accessibilityLabel(link.paused ? "Paused" : "Watching")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(Palette.textSecondary)
                    Text(link.localRoot).font(.monoSmall).lineLimit(1).truncationMode(.head)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(Palette.textSecondary)
                    Text("\(connection?.name ?? "Missing connection"): \(link.remoteRoot)")
                        .font(.monoSmall).lineLimit(1).truncationMode(.middle)
                }
                Text(statusText).font(.caption).foregroundStyle(status.message == nil ? Palette.textSecondary : Palette.statusAmber)
                Toggle("Mirror deletes", isOn: Binding(
                    get: { link.mirrorDeletes },
                    set: { app.watches.setMirrorDeletes($0, for: link.id) }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Also delete or rename on the server when you delete or rename here. Off: nothing is ever removed from the server.")
            }
            Spacer(minLength: 12)
            Button(link.paused ? "Resume" : "Pause") { app.watches.setPaused(!link.paused, for: link.id) }
                .controlSize(.small)
            Button(role: .destructive) {
                app.watches.remove(link.id)
            } label: { Image(systemName: "trash") }
                .controlSize(.small)
                .help("Stop watching this folder")
                .accessibilityLabel("Remove watch of \(link.localRoot)")
        }
        .padding(.vertical, 6)
    }

    private var dotColor: Color { link.paused ? Palette.statusAmber : Palette.statusGreen }

    private var statusText: String {
        if let message = status.message { return message }
        if link.paused { return "Paused. Changes made meanwhile upload when you resume." }
        var parts = ["Watching"]
        if status.uploaded > 0 { parts.append("\(status.uploaded.formatted()) uploaded") }
        if status.deleted > 0 { parts.append("\(status.deleted.formatted()) mirrored") }
        if status.skipped > 0 { parts.append("\(status.skipped.formatted()) skipped by filters") }
        if let last = status.lastActivity { parts.append("last change \(last.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

private struct AddWatchSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var localRoot = ""
    @State private var connectionID: UUID?
    @State private var remoteRoot = "/"
    @State private var mirrorDeletes = false

    private var candidates: [Connection] {
        app.allConnections.filter { $0.protocol != .rclone }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Watch a folder").font(.headline)
            Form {
                HStack {
                    TextField("Local folder", text: $localRoot, prompt: Text("A folder on this Mac"))
                    Button("Choose\u{2026}") {
                        if let url = Dialogs.chooseFile(canChooseDirectories: true) { localRoot = url.path }
                    }
                }
                Picker("Connection", selection: $connectionID) {
                    Text("Choose\u{2026}").tag(UUID?.none)
                    ForEach(candidates) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField("Server folder", text: $remoteRoot, prompt: Text("/home/user/public_html"))
                Toggle("Mirror deletes", isOn: $mirrorDeletes)
                Text("Off, a file you delete here stays on the server. On, deletes and renames follow, with the same checks as deleting by hand.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Watching") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(localRoot.isEmpty || connectionID == nil || remoteRoot.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onChange(of: connectionID) {
            if let c = candidates.first(where: { $0.id == connectionID }), remoteRoot == "/" { remoteRoot = c.initialRemotePath ?? "/" }
        }
    }

    private func add() {
        guard let connectionID else { return }
        app.watches.add(WatchLink(connectionId: connectionID, localRoot: localRoot, remoteRoot: remoteRoot, mirrorDeletes: mirrorDeletes))
        dismiss()
    }
}

/// "Watching 2 folders" in the transfer bar; opens the Watch Folders window.
struct WatchIndicator: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let count = app.watches.activeCount
        if count > 0 {
            Button {
                openWindow(id: "watch")
            } label: {
                Label("Watching \(count) folder\(count == 1 ? "" : "s")", systemImage: "eye")
            }
            .controlSize(.small)
            .help("Open Watch Folders")
        }
    }
}
