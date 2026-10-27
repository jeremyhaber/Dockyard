import ConnectionKit
import DockyardCore
import SwiftUI

struct TransferBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = app.transfers
        HStack(spacing: 12) {
            Image(systemName: s.isPaused ? "pause.circle" : "arrow.up.arrow.down")
                .foregroundStyle(s.isIdle ? Palette.textSecondary : Color.accentColor)
                .accessibilityHidden(true)
            Text(summary(s))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(s.isIdle ? Palette.textSecondary : Palette.textPrimary)
                .lineLimit(1)
            if s.failedCount > 0 { failedBadge(s.failedCount) }
            if !s.isIdle {
                if let fraction = s.fraction {
                    ProgressView(value: fraction).frame(width: 150)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(progressText(s))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            skippedLabel(s)
            EditingIndicator()
            ArchiveIndicator()

            Spacer(minLength: 8)

            transfersButton
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
        .contentShape(Rectangle())
        .onTapGesture { app.showTransfers() }
        .help("Show all transfers")
    }

    private func failedBadge(_ count: Int) -> some View {
        Button {
            app.showFailedTransfers()
        } label: {
            Text("\(count.formatted()) failed")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.red, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Show the failed transfers")
        .accessibilityLabel("\(count) failed transfers. Show them")
    }

    @ViewBuilder
    private func skippedLabel(_ s: TransferSnapshot) -> some View {
        let skipped = s.filteredCount + s.skipReasons.values.reduce(0, +)
        if skipped > 0 {
            Text("\(skipped.formatted()) skipped")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .help(skipHelp(s))
        }
    }

    private func skipHelp(_ s: TransferSnapshot) -> String {
        var parts = SkipReason.allCases.compactMap { reason in s.skipReasons[reason].map { "\($0.formatted()) \(reason.title)" } }
        if s.filteredCount > 0 { parts.append("\(s.filteredCount.formatted()) left out by filters") }
        return parts.joined(separator: ", ")
    }

    private var transfersButton: some View {
        Button {
            app.toggleDrawer(tab: .transfers)
        } label: {
            Label("Transfers", systemImage: "list.bullet.rectangle")
        }
        .controlSize(.small)
        .help("Toggle the transfers drawer")
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

    /// "3 active · 1,204 queued", or what is left when nothing runs.
    private func summary(_ s: TransferSnapshot) -> String {
        if s.isIdle {
            if s.isPaused { return "Transfers paused" }
            if s.completedCount > 0 { return "\(s.completedCount.formatted()) transfer\(s.completedCount == 1 ? "" : "s") done" }
            return "No transfers"
        }
        var parts = ["\(s.activeCount.formatted()) active", "\(s.queuedCount.formatted()) queued"]
        if s.isPaused { parts.insert("paused", at: 0) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "1.2 GB of 3.4 GB \u{00B7} 24.8 MB/s \u{00B7} 2 min left"
    private func progressText(_ s: TransferSnapshot) -> String {
        guard s.bytesTotal > 0 else { return "" }
        var parts = ["\(FileDisplay.size(s.bytesDone)) of \(FileDisplay.size(s.bytesTotal))"]
        let rate = app.transferRate
        if rate > 0 {
            parts.append("\(FileDisplay.size(UInt64(rate)))/s")
            parts.append(Self.timeLeft(Double(s.bytesTotal - min(s.bytesDone, s.bytesTotal)) / rate))
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func timeLeft(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.up))
        if s < 60 { return "\(max(s, 1)) sec left" }
        if s < 3600 { return "\(s / 60) min left" }
        return "\(s / 3600) h \((s % 3600) / 60) min left"
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
