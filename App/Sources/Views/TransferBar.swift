import ConnectionKit
import DockyardCore
import SwiftUI

struct TransferBar: View {
    @Environment(AppModel.self) private var app
    @State private var showQueue = false

    var body: some View {
        let snapshot = app.transfers
        HStack(spacing: 12) {
            if snapshot.isIdle {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundStyle(Palette.textSecondary)
                Text(summaryWhenIdle(snapshot))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
            } else {
                Image(systemName: snapshot.currentIsRelay ? "arrow.triangle.swap" : "arrow.up.arrow.down")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.currentName ?? "Preparing\u{2026}")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if let route = snapshot.currentRoute {
                        Text(snapshot.currentIsRelay ? "\(route), relayed through this Mac" : route)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 240, alignment: .leading)
                if let fraction = snapshot.fraction {
                    ProgressView(value: fraction).frame(width: 160)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(progressText(snapshot))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
                if snapshot.queuedCount > 0 {
                    Text("\(snapshot.queuedCount) queued")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Button {
                showQueue.toggle()
            } label: {
                Label("Queue", systemImage: "list.bullet")
                    .labelStyle(.titleAndIcon)
            }
            .controlSize(.small)
            .popover(isPresented: $showQueue, arrowEdge: .top) { QueuePopover() }
            .accessibilityLabel("Transfer queue")

            EditingIndicator()
            ArchiveIndicator()

            Spacer()

            logButton
            Button {
                app.toggleDrawer(tab: .terminal)
            } label: {
                Label("Terminal", systemImage: "terminal")
            }
            .controlSize(.small)
            .help("Toggle the terminal drawer (\u{2303}`)")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Palette.chrome)
        .overlay(alignment: .top) { Divider() }
    }

    private var logButton: some View {
        let counts = app.activeSession?.logCounts
        return Button {
            app.toggleDrawer(tab: .log)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "text.alignleft")
                Text("Log")
                if let counts, counts.errors > 0 {
                    countPill(counts.errors, color: .red)
                }
                if let counts, counts.warnings > 0 {
                    countPill(counts.warnings, color: Palette.statusAmber)
                }
            }
        }
        .controlSize(.small)
        .help("Toggle the log drawer")
        .accessibilityLabel("Log, \(counts?.errors ?? 0) errors, \(counts?.warnings ?? 0) warnings")
    }

    private func countPill(_ n: Int, color: Color) -> some View {
        Text("\(n)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .background(color, in: Capsule())
    }

    private func summaryWhenIdle(_ s: TransferSnapshot) -> String {
        if s.failedCount > 0 { return "No transfers running, \(s.failedCount) failed" }
        if s.completedCount > 0 { return "\(s.completedCount) transfer\(s.completedCount == 1 ? "" : "s") completed" }
        return "No transfers"
    }

    private func progressText(_ s: TransferSnapshot) -> String {
        guard s.bytesTotal > 0 else { return "" }
        return "\(FileDisplay.size(s.bytesDone)) / \(FileDisplay.size(s.bytesTotal))"
    }
}

/// "Editing 2 files": server files opened in an editor and uploaded on every save, with a Stop button each.
struct EditingIndicator: View {
    @Environment(AppModel.self) private var app
    @State private var showList = false

    var body: some View {
        let entries = app.edits.entries
        if !entries.isEmpty {
            Button {
                showList.toggle()
            } label: {
                Label("Editing \(entries.count) file\(entries.count == 1 ? "" : "s")", systemImage: "pencil.and.outline")
            }
            .controlSize(.small)
            .help("Files you are editing; saves upload automatically")
            .popover(isPresented: $showList, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Saved changes upload automatically")
                        .font(.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(10)
                    Divider()
                    ForEach(app.edits.entries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.fileName).font(.system(size: 12, weight: .medium))
                                Text("\(entry.connectionName) \u{00B7} \(entry.remotePath)")
                                    .font(.monoSmall)
                                    .foregroundStyle(Palette.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            Spacer(minLength: 12)
                            Button("Stop") { app.edits.stop(entry.id) }
                                .controlSize(.small)
                                .accessibilityLabel("Stop editing \(entry.fileName)")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
                .frame(width: 420)
            }
        }
    }
}

/// Running compress and extract jobs, with a cancel button each.
struct ArchiveIndicator: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ForEach(app.archives.running) { job in
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(job.title) \u{00B7} \(job.place)")
                    .font(.system(size: 11))
                    .lineLimit(1)
                Button {
                    app.archives.cancel(job.id)
                } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel \(job.title)")
            }
        }
    }
}
