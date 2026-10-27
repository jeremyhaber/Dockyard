import AppKit
import DockyardCore
import SwiftUI

enum QueueFilterChoice: String, CaseIterable, Identifiable {
    case all = "All", running = "Running", failed = "Failed", finished = "Finished"
    var id: String { rawValue }

    var filter: TransferJobFilter {
        switch self {
        case .all: TransferJobFilter(scope: .topLevel)
        case .running: TransferJobFilter(scope: .topLevel, states: [.queued, .running])
        case .failed: TransferJobFilter(scope: .topLevel, states: [.failed, .cancelled])
        case .finished: TransferJobFilter(scope: .topLevel, states: [.completed, .skipped])
        }
    }
}

/// The full transfer list. Rows are fetched a page at a time from the queue's store, so 100,000 jobs cost no more than 100.
struct QueuePopover: View {
    @Environment(AppModel.self) private var app
    @State private var choice = QueueFilterChoice.all

    var body: some View {
        let snapshot = app.transfers
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button(snapshot.isPaused ? "Resume" : "Pause") { app.setTransfersPaused(!snapshot.isPaused) }
                Button("Retry failed") { app.retryFailedTransfers() }
                    .disabled(snapshot.failedCount == 0)
                Button("Clear finished") { app.clearFinishedTransfers() }
                Button("Cancel all") { app.cancelAllTransfers() }
                    .disabled(snapshot.isIdle)
            }
            .controlSize(.small)
            .padding(10)
            Picker("Show", selection: $choice) {
                ForEach(QueueFilterChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            Divider()
            QueueTableView(queue: app.queue, version: version(snapshot), filter: choice)
                .frame(height: 340)
            Divider()
            HStack {
                Text(summary(snapshot)).font(.caption).foregroundStyle(Palette.textSecondary)
                Spacer()
            }
            .padding(8)
        }
        .frame(width: 520)
    }

    private func version(_ s: TransferSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(s.activeCount)
        hasher.combine(s.queuedCount)
        hasher.combine(s.completedCount)
        hasher.combine(s.failedCount)
        hasher.combine(s.cancelledCount)
        hasher.combine(s.bytesDone / 262_144)
        return hasher.finalize()
    }

    private func summary(_ s: TransferSnapshot) -> String {
        "\(s.activeCount) running, \(s.queuedCount) queued, \(s.completedCount) done, \(s.failedCount) failed"
    }
}

struct QueueTableView: NSViewRepresentable {
    let queue: TransferQueue
    let version: Int
    let filter: QueueFilterChoice

    func makeCoordinator() -> QueueTableCoordinator { QueueTableCoordinator(queue: queue) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        context.coordinator.configure(table)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.setAccessibilityLabel("Transfers")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(version: version, filter: filter)
    }
}

final class QueueRowView: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    let state = NSTextField(labelWithString: "")
    let button = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 12)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        state.font = .systemFont(ofSize: 10)
        state.textColor = .secondaryLabelColor
        state.alignment = .right
        for label in [title, detail] { label.lineBreakMode = .byTruncatingMiddle }
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        button.isBordered = false
        button.imagePosition = .imageOnly
        let text = NSStackView(views: [title, detail, progress])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [icon, text, state, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            state.widthAnchor.constraint(equalToConstant: 64),
            button.widthAnchor.constraint(equalToConstant: 20),
            progress.widthAnchor.constraint(equalTo: text.widthAnchor),
        ])
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
final class QueueTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let pageSize = 100
    private let queue: TransferQueue
    private weak var table: NSTableView?
    private var total = 0
    private var pages: [Int: [TransferJobInfo]] = [:]
    private var loading: Set<Int> = []
    private var lastVersion = -1
    private var filter = QueueFilterChoice.all
    private var generation = 0
    private static let rowID = NSUserInterfaceItemIdentifier("queueRow")

    init(queue: TransferQueue) { self.queue = queue }

    func configure(_ table: NSTableView) {
        self.table = table
        table.style = .plain
        table.rowHeight = 42
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 0)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("job"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
    }

    func update(version: Int, filter newFilter: QueueFilterChoice) {
        guard version != lastVersion || newFilter != filter else { return }
        lastVersion = version
        if newFilter != filter {
            filter = newFilter
            pages.removeAll()
        }
        generation += 1
        let current = generation
        let queue = self.queue
        let jobFilter = filter.filter
        let visible = visiblePages()
        Task {
            let count = await queue.count(jobFilter)
            var fresh: [Int: [TransferJobInfo]] = [:]
            for page in visible where page * Self.pageSize < count {
                fresh[page] = await queue.page(offset: page * Self.pageSize, limit: Self.pageSize, filter: jobFilter)
            }
            guard current == self.generation else { return }
            self.total = count
            self.pages = fresh
            self.loading.removeAll()
            self.table?.reloadData()
        }
    }

    private func visiblePages() -> [Int] {
        guard let table else { return [0] }
        let range = table.rows(in: table.visibleRect)
        let first = max(0, range.location) / Self.pageSize
        let last = max(0, range.location + max(range.length, 1) - 1) / Self.pageSize
        return Array(first...max(first, last))
    }

    private func job(at row: Int) -> TransferJobInfo? {
        let page = row / Self.pageSize
        guard let rows = pages[page] else {
            load(page)
            return nil
        }
        let index = row % Self.pageSize
        return index < rows.count ? rows[index] : nil
    }

    private func load(_ page: Int) {
        guard !loading.contains(page) else { return }
        loading.insert(page)
        let current = generation
        let queue = self.queue
        let jobFilter = filter.filter
        Task {
            let rows = await queue.page(offset: page * Self.pageSize, limit: Self.pageSize, filter: jobFilter)
            guard current == self.generation else { return }
            self.pages[page] = rows
            self.loading.remove(page)
            let start = page * Self.pageSize
            self.table?.reloadData(forRowIndexes: IndexSet(integersIn: start..<min(self.total, start + Self.pageSize)), columnIndexes: IndexSet(integer: 0))
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { total }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Self.rowID, owner: self) as? QueueRowView) ?? {
            let c = QueueRowView()
            c.identifier = Self.rowID
            c.button.target = self
            c.button.action = #selector(rowAction(_:))
            return c
        }()
        guard let job = job(at: row) else {
            cell.title.stringValue = "Loading\u{2026}"
            cell.detail.stringValue = ""
            cell.state.stringValue = ""
            cell.progress.isHidden = true
            cell.button.isHidden = true
            cell.icon.image = nil
            return cell
        }
        cell.title.stringValue = job.name
        var detail = job.isRelay ? "\(job.route), relayed through this Mac" : job.route
        if job.isDirectory, job.childCount > 0 { detail += " \u{00B7} \(job.finishedChildCount) of \(job.childCount) items" }
        if let error = job.error { detail = error }
        cell.detail.stringValue = detail
        cell.detail.textColor = job.error == nil ? .secondaryLabelColor : .systemRed
        cell.state.stringValue = Self.stateText(job)
        cell.icon.image = NSImage(systemSymbolName: Self.symbol(job.state), accessibilityDescription: Self.stateText(job))
        cell.icon.contentTintColor = Self.tint(job.state)
        let showProgress = job.state == .running && job.fraction != nil
        cell.progress.isHidden = !showProgress
        cell.progress.doubleValue = job.fraction ?? 0
        switch job.state {
        case .queued, .running:
            cell.button.isHidden = false
            cell.button.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Cancel \(job.name)")
        case .failed, .cancelled:
            cell.button.isHidden = false
            cell.button.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Retry \(job.name)")
        default:
            cell.button.isHidden = true
        }
        cell.button.tag = row
        return cell
    }

    @objc private func rowAction(_ sender: NSButton) {
        guard let job = job(at: sender.tag) else { return }
        let app = AppModel.shared
        switch job.state {
        case .queued, .running: app.cancelTransfer(job.id)
        case .failed, .cancelled: app.retryTransfer(job.id)
        default: break
        }
    }

    private static func stateText(_ job: TransferJobInfo) -> String {
        switch job.state {
        case .queued: "Queued"
        case .running: job.willResume ? "Resuming" : "Running"
        case .completed: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        }
    }

    private static func symbol(_ state: TransferState) -> String {
        switch state {
        case .queued: "clock"
        case .running: "arrow.up.arrow.down"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "slash.circle"
        case .skipped: "arrow.uturn.right"
        }
    }

    private static func tint(_ state: TransferState) -> NSColor {
        switch state {
        case .completed: Palette.ns("StatusGreen")
        case .failed: .systemRed
        case .running: .controlAccentColor
        default: .secondaryLabelColor
        }
    }
}
