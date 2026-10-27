import AppKit
import DockyardCore
import SwiftUI

/// The Transfers tab of the bottom drawer: Active, Queued, Failed and Done lists over the whole queue.
struct TransfersView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let center = app.transferUI
        let snapshot = app.transfers
        TransferTableView(
            queue: app.queue, version: version(snapshot), tab: center.tab, folder: center.folder,
            openFolder: { center.folder = $0 })
            .overlay { if snapshot.isIdle && TransferTab.done.count(in: snapshot) + snapshot.failedCount == 0 { emptyHint } }
    }

    private var emptyHint: some View {
        Text("No transfers yet. Drag files between the panes to start one.")
            .font(.system(size: 12))
            .foregroundStyle(Palette.textSecondary)
    }

    private func version(_ s: TransferSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(s.activeCount)
        hasher.combine(s.queuedCount)
        hasher.combine(s.completedCount)
        hasher.combine(s.failedCount)
        hasher.combine(s.cancelledCount)
        hasher.combine(s.skippedCount)
        hasher.combine(s.bytesDone / 131_072)
        return hasher.finalize()
    }
}

/// The Transfers controls in the drawer's single header row: sub-tabs after the main tabs, actions on the right.
struct TransfersHeader: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(iconOnly: false)
            row(iconOnly: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(iconOnly: Bool) -> some View {
        @Bindable var center = app.transferUI
        let snapshot = app.transfers
        return HStack(spacing: 8) {
            Picker("List", selection: $center.tab) {
                ForEach(TransferTab.allCases) { tab in
                    Text("\(tab.rawValue) \(tab.count(in: snapshot).formatted())").tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
            .onChange(of: center.tab) { center.folder = nil }
            if let folder = center.folder {
                Button {
                    center.folder = nil
                } label: {
                    Label(folder.name, systemImage: "chevron.left")
                }
                .accessibilityLabel("Back to all transfers, leaving \(folder.name)")
            }
            Spacer(minLength: 0)
            if !iconOnly, let skips = skipSummary(snapshot) {
                Label(skips, systemImage: "line.3.horizontal.decrease")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .help("Existing files left alone by your rules, and items left out by transfer filters (.DS_Store, node_modules/ and your own)")
            }
            Group {
                Button { app.retryFailedTransfers() } label: {
                    Label("Retry all failed", systemImage: "arrow.clockwise")
                }
                .disabled(snapshot.failedCount == 0)
                .help("Retry all failed transfers")
                if center.tab == .failed {
                    Button { app.clearFailedTransfers() } label: {
                        Label("Clear failed", systemImage: "xmark.circle")
                    }
                    .disabled(snapshot.failedCount == 0)
                    .help("Remove failed transfers from the list")
                } else {
                    Button { app.clearFinishedTransfers() } label: {
                        Label("Clear done", systemImage: "xmark.circle")
                    }
                    .disabled(TransferTab.done.count(in: snapshot) == 0)
                    .help("Remove finished transfers from the list")
                }
                Button {
                    app.setTransfersPaused(!snapshot.isPaused)
                } label: {
                    Label(snapshot.isPaused ? "Resume" : "Pause", systemImage: snapshot.isPaused ? "play.fill" : "pause.fill")
                }
                .disabled(snapshot.isIdle && !snapshot.isPaused)
                .help(snapshot.isPaused ? "Resume the queue" : "Pause the queue")
            }
            .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
        }
    }

    /// "312 skipped: unchanged \u{00B7} 4 skipped: kept existing \u{00B7} 9 skipped: filters"
    private func skipSummary(_ s: TransferSnapshot) -> String? {
        var parts = SkipReason.allCases.compactMap { reason in
            s.skipReasons[reason].map { "\($0.formatted()) skipped: \(reason.title)" }
        }
        if s.filteredCount > 0 { parts.append("\(s.filteredCount.formatted()) skipped: filters") }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}

struct TransferTableView: NSViewRepresentable {
    let queue: TransferQueue
    let version: Int
    let tab: TransferTab
    let folder: TransferJobInfo?
    let openFolder: (TransferJobInfo) -> Void

    func makeCoordinator() -> TransferTableCoordinator { TransferTableCoordinator(queue: queue) }

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
        context.coordinator.openFolder = openFolder
        context.coordinator.update(version: version, tab: tab, folder: folder)
    }
}

private enum Column: String, CaseIterable {
    case name, route, size, progress, speed, status

    var title: String {
        switch self {
        case .name: "Name"
        case .route: "Route"
        case .size: "Size"
        case .progress: "Progress"
        case .speed: "Speed"
        case .status: "Status"
        }
    }

    var width: CGFloat {
        switch self {
        case .name: 300
        case .route: 190
        case .size: 80
        case .progress: 140
        case .speed: 84
        case .status: 84
        }
    }
}

/// Name with a status icon and a second line (the error text for failed rows).
private final class NameCell: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 12)
        detail.font = .systemFont(ofSize: 10)
        for label in [title, detail] { label.lineBreakMode = .byTruncatingMiddle }
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [icon, text])
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class ProgressCell: NSTableCellView {
    let bar = NSProgressIndicator()
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        label.alignment = .right
        let row = NSStackView(views: [bar, label])
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 34),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class TextCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
final class TransferTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private static let pageSize = 100
    private let queue: TransferQueue
    private weak var table: NSTableView?
    private var total = 0
    private var pages: [Int: [TransferJobInfo]] = [:]
    private var loading: Set<Int> = []
    private var lastVersion = -1
    private var tab = TransferTab.active
    private var folder: TransferJobInfo?
    private var generation = 0
    private var speeds: [UUID: (done: UInt64, time: Date, rate: Double)] = [:]
    var openFolder: (TransferJobInfo) -> Void = { _ in }

    init(queue: TransferQueue) { self.queue = queue }

    func configure(_ table: NSTableView) {
        self.table = table
        table.style = .plain
        table.rowHeight = 36
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = .separatorColor.withAlphaComponent(0.4)
        for column in Column.allCases {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            c.title = column.title
            c.width = column.width
            c.minWidth = 50
            c.resizingMask = column == .name ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(c)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(doubleClicked)
        table.target = self
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
    }

    private var jobFilter: TransferJobFilter {
        if let folder { return TransferJobFilter(scope: .children(of: folder.id)) }
        return tab.filter
    }

    func update(version: Int, tab newTab: TransferTab, folder newFolder: TransferJobInfo?) {
        let changed = newTab != tab || newFolder?.id != folder?.id
        guard version != lastVersion || changed else { return }
        lastVersion = version
        if changed {
            tab = newTab
            folder = newFolder
            pages.removeAll()
            speeds.removeAll()
            table?.scrollRowToVisible(0)
        }
        generation += 1
        let current = generation
        let queue = self.queue
        let filter = jobFilter
        let visible = visiblePages()
        let selected = selectedIDs()
        Task {
            let count = await queue.count(filter)
            var fresh: [Int: [TransferJobInfo]] = [:]
            for page in visible where page * Self.pageSize < count {
                fresh[page] = await queue.page(offset: page * Self.pageSize, limit: Self.pageSize, filter: filter)
            }
            guard current == self.generation else { return }
            self.total = count
            self.pages = fresh
            self.loading.removeAll()
            self.sampleSpeeds()
            self.table?.reloadData()
            self.restoreSelection(selected)
        }
    }

    private func sampleSpeeds() {
        let now = Date()
        var live: Set<UUID> = []
        for job in pages.values.joined() where job.state == .running && !job.isDirectory {
            live.insert(job.id)
            if let last = speeds[job.id], now.timeIntervalSince(last.time) > 0.3 {
                let delta = job.bytesDone >= last.done ? Double(job.bytesDone - last.done) / now.timeIntervalSince(last.time) : 0
                speeds[job.id] = (job.bytesDone, now, last.rate == 0 ? delta : last.rate * 0.5 + delta * 0.5)
            } else if speeds[job.id] == nil {
                speeds[job.id] = (job.bytesDone, now, 0)
            }
        }
        speeds = speeds.filter { live.contains($0.key) }
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
        let filter = jobFilter
        Task {
            let rows = await queue.page(offset: page * Self.pageSize, limit: Self.pageSize, filter: filter)
            guard current == self.generation else { return }
            self.pages[page] = rows
            self.loading.remove(page)
            let start = page * Self.pageSize
            self.table?.reloadData(forRowIndexes: IndexSet(integersIn: start..<min(self.total, start + Self.pageSize)),
                                   columnIndexes: IndexSet(integersIn: 0..<Column.allCases.count))
        }
    }

    // MARK: Selection

    private func selectedIDs() -> Set<UUID> {
        guard let table else { return [] }
        return Set(table.selectedRowIndexes.compactMap { job(at: $0)?.id })
    }

    private func restoreSelection(_ ids: Set<UUID>) {
        guard let table, !ids.isEmpty else { return }
        var rows = IndexSet()
        for (page, jobs) in pages {
            for (i, job) in jobs.enumerated() where ids.contains(job.id) { rows.insert(page * Self.pageSize + i) }
        }
        table.selectRowIndexes(rows, byExtendingSelection: false)
    }

    private func targetJobs() -> [TransferJobInfo] {
        guard let table else { return [] }
        var rows = table.selectedRowIndexes
        if table.clickedRow >= 0, !rows.contains(table.clickedRow) { rows = IndexSet(integer: table.clickedRow) }
        return rows.compactMap { job(at: $0) }
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { total }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let column = Column(rawValue: id) else { return nil }
        let job = self.job(at: row)
        switch column {
        case .name:
            let cell = reuse(tableView, id) { NameCell() }
            guard let job else {
                cell.title.stringValue = "Loading\u{2026}"
                cell.detail.stringValue = ""
                cell.icon.image = nil
                return cell
            }
            cell.title.stringValue = job.name
            if let error = job.error {
                cell.detail.stringValue = error.replacingOccurrences(of: "Server replied ", with: "")
                cell.detail.textColor = .systemRed
            } else {
                var detail = RemotePathText.destination(of: job)
                if job.isDirectory, job.childCount > 0 { detail = "\(job.finishedChildCount.formatted()) of \(job.childCount.formatted()) items" }
                cell.detail.stringValue = detail
                cell.detail.textColor = .secondaryLabelColor
            }
            cell.icon.image = NSImage(systemSymbolName: Self.symbol(job), accessibilityDescription: Self.status(job))
            cell.icon.contentTintColor = Self.tint(job.state)
            return cell
        case .progress:
            let cell = reuse(tableView, id) { ProgressCell() }
            let running = job?.state == .running || job?.state == .completed
            cell.bar.isHidden = !running
            cell.label.isHidden = !running
            if let job, running, let fraction = job.fraction {
                cell.bar.doubleValue = fraction
                cell.label.stringValue = "\(Int(fraction * 100))%"
                cell.label.textColor = .secondaryLabelColor
            } else {
                cell.bar.isHidden = true
                cell.label.isHidden = true
            }
            return cell
        default:
            let cell = reuse(tableView, id) { TextCell() }
            cell.label.textColor = .secondaryLabelColor
            guard let job else { cell.label.stringValue = ""; return cell }
            switch column {
            case .route:
                cell.label.stringValue = job.isRelay ? "\(job.route) (relayed)" : job.route
            case .size:
                cell.label.stringValue = job.bytesTotal > 0 ? FileDisplay.size(job.bytesTotal) : "\u{2014}"
            case .speed:
                let rate = DemoMode.isEnabled ? Double(4_000_000 + job.name.count * 310_000) : (speeds[job.id]?.rate ?? 0)
                cell.label.stringValue = job.state == .running && rate > 0 ? "\(FileDisplay.size(UInt64(rate)))/s" : ""
            default:
                cell.label.stringValue = Self.status(job)
                cell.label.textColor = job.state == .failed ? .systemRed : .secondaryLabelColor
            }
            return cell
        }
    }

    private func reuse<T: NSTableCellView>(_ table: NSTableView, _ id: String, make: () -> T) -> T {
        let identifier = NSUserInterfaceItemIdentifier("transfer-\(id)")
        if let cell = table.makeView(withIdentifier: identifier, owner: self) as? T { return cell }
        let cell = make()
        cell.identifier = identifier
        return cell
    }

    // MARK: Actions

    @objc private func doubleClicked() {
        guard let table, let job = self.job(at: table.clickedRow), job.isDirectory, job.childCount > 0 else { return }
        openFolder(job)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let jobs = targetJobs()
        guard !jobs.isEmpty else { return }
        func add(_ title: String, _ symbol: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        if jobs.contains(where: { $0.state == .failed || $0.state == .cancelled }) { add("Retry", "arrow.clockwise", #selector(retry)) }
        if jobs.contains(where: { $0.state == .queued || $0.state == .running }) { add("Cancel", "xmark.circle", #selector(cancel)) }
        if jobs.count == 1, jobs[0].isDirectory, jobs[0].childCount > 0 { add("Show Items", "folder", #selector(showItems)) }
        if jobs.count == 1 { add("Reveal", "arrow.right.circle", #selector(reveal)) }
        if jobs.contains(where: { $0.error != nil }) { add("Copy Error", "doc.on.doc", #selector(copyError)) }
    }

    @objc private func retry() { for job in targetJobs() where job.state == .failed || job.state == .cancelled { AppModel.shared.retryTransfer(job.id) } }
    @objc private func cancel() { for job in targetJobs() where job.state == .queued || job.state == .running { AppModel.shared.cancelTransfer(job.id) } }
    @objc private func reveal() { if let job = targetJobs().first { AppModel.shared.revealTransfer(job) } }
    @objc private func copyError() { AppModel.shared.copyTransferErrors(targetJobs()) }
    @objc private func showItems() { if let job = targetJobs().first { openFolder(job) } }

    // MARK: Appearance

    private static func status(_ job: TransferJobInfo) -> String {
        switch job.state {
        case .queued: "Queued"
        case .running: job.willResume ? "Resuming" : (job.isDirectory ? "Listing" : "Running")
        case .completed: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        }
    }

    private static func symbol(_ job: TransferJobInfo) -> String {
        if job.isDirectory, job.state != .failed { return "folder" }
        switch job.state {
        case .queued: return "clock"
        case .running: return "arrow.up.arrow.down"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "slash.circle"
        case .skipped: return "arrow.uturn.right"
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

/// Where a job's file ends up, for the row subtitle.
private enum RemotePathText {
    /// The destination folder: on this Mac with the home folder shown as `~`, otherwise the remote path.
    static func destination(of job: TransferJobInfo) -> String {
        let folder = parent(job.destinationPath)
        guard job.route.hasSuffix("\u{2192} This Mac") else { return folder }
        return (folder as NSString).abbreviatingWithTildeInPath
    }

    static func parent(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }
}
