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

struct QueuePopover: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let snapshot = app.transfers
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Retry failed") { app.retryFailedTransfers() }
                    .disabled(snapshot.failedCount == 0)
                Button("Clear finished") { app.clearFinishedTransfers() }
                Button("Cancel all") { app.cancelAllTransfers() }
                    .disabled(snapshot.isIdle)
            }
            .controlSize(.small)
            .padding(10)
            Divider()
            if snapshot.jobs.isEmpty {
                Text("The queue is empty")
                    .foregroundStyle(Palette.textSecondary)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(snapshot.jobs) { job in
                            JobRow(job: job)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
        .frame(width: 480)
    }
}

struct JobRow: View {
    @Environment(AppModel.self) private var app
    let job: TransferJobInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).font(.system(size: 12)).lineLimit(1)
                Text(job.isRelay ? "\(job.route), relayed through this Mac" : job.route)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                if let error = job.error {
                    Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
                } else if job.state == .running, let fraction = job.fraction {
                    ProgressView(value: fraction)
                }
                if job.isDirectory, job.childCount > 0 {
                    Text("\(job.finishedChildCount) of \(job.childCount) items")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer()
            Text(stateText)
                .font(.system(size: 10))
                .foregroundStyle(Palette.textSecondary)
            if job.state == .queued || job.state == .running {
                Button {
                    app.cancelTransfer(job.id)
                } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel \(job.name)")
            } else if job.state == .failed || job.state == .cancelled {
                Button {
                    app.retryTransfer(job.id)
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Retry \(job.name)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var stateText: String {
        switch job.state {
        case .queued: "Queued"
        case .running: job.willResume ? "Resuming" : "Running"
        case .completed: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        }
    }

    private var icon: String {
        switch job.state {
        case .queued: "clock"
        case .running: "arrow.up.arrow.down"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "slash.circle"
        case .skipped: "arrow.uturn.right"
        }
    }

    private var color: Color {
        switch job.state {
        case .completed: Palette.statusGreen
        case .failed: .red
        case .running: Color.accentColor
        default: Palette.textSecondary
        }
    }
}
