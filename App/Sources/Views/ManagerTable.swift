import AppKit
import ConnectionKit
import DockyardCore
import SwiftUI

final class ManagerNSTableView: NSTableView {
    var onReturn: ((NSEvent.ModifierFlags) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?(event.modifierFlags)
        } else {
            super.keyDown(with: event)
        }
    }
}

final class FavoriteCellView: NSTableCellView {
    let button = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class TwoLineCellView: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        for field in [title, subtitle] {
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

struct ManagerActions {
    var connect: (Connection, Bool) -> Void
    var edit: (Connection) -> Void
    var duplicate: (Connection) -> Void
    var delete: (Connection) -> Void
    var toggleFavorite: (Connection) -> Void
}

struct ManagerTable: NSViewRepresentable {
    let connections: [Connection]
    let statuses: [UUID: SessionStatus]
    let clientNames: [UUID: String]
    let sourceLabels: [UUID: String]
    @Binding var selection: Set<UUID>
    let actions: ManagerActions

    func makeCoordinator() -> ManagerTableCoordinator { ManagerTableCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ManagerNSTableView()
        context.coordinator.configure(table)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.setAccessibilityLabel("Connections")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }
}

@MainActor
final class ManagerTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private var parent: ManagerTable?
    private weak var table: ManagerNSTableView?
    private var rows: [Connection] = []
    private var sortKey = "name"
    private var ascending = true
    private var suppressSelection = false

    func configure(_ table: ManagerNSTableView) {
        self.table = table
        table.style = .inset
        table.rowHeight = 38
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        func column(_ id: String, _ title: String, width: CGFloat, sortable: Bool = true) {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = min(width, 40)
            if sortable { c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true) }
            table.addTableColumn(c)
        }
        column("star", "\u{2605}", width: 34)
        column("name", "Name", width: 260)
        column("host", "Host", width: 190)
        column("protocol", "Protocol", width: 70)
        column("source", "Source", width: 140)
        column("last", "Last used", width: 110)
        column("status", "Status", width: 100)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.tableColumns[1].resizingMask = .autoresizingMask
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onReturn = { [weak self] flags in self?.returnPressed(flags) }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
    }

    func update(_ parent: ManagerTable) {
        self.parent = parent
        guard let table else { return }
        let selected = parent.selection
        rows = sorted(parent.connections)
        suppressSelection = true
        table.reloadData()
        var indexes = IndexSet()
        for (i, c) in rows.enumerated() where selected.contains(c.id) { indexes.insert(i) }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        suppressSelection = false
    }

    private func sorted(_ list: [Connection]) -> [Connection] {
        let result = list.sorted { a, b in
            switch sortKey {
            case "host": return a.host.localizedCaseInsensitiveCompare(b.host) == .orderedAscending
            case "protocol": return a.protocol.rawValue < b.protocol.rawValue
            case "source": return a.source.rawValue < b.source.rawValue
            case "last": return (a.lastConnectedAt ?? .distantPast) < (b.lastConnectedAt ?? .distantPast)
            case "status": return statusRank(a) < statusRank(b)
            case "star": return a.favorite && !b.favorite
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        return ascending ? result : result.reversed()
    }

    private func statusRank(_ c: Connection) -> Int {
        switch parent?.statuses[c.id] {
        case .connected?: 0
        case .connecting?, .reconnecting?: 1
        default: 2
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < rows.count, let parent else { return nil }
        let c = rows[row]
        let id = column.identifier
        switch id.rawValue {
        case "star":
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? FavoriteCellView) ?? {
                let v = FavoriteCellView()
                v.identifier = id
                v.button.target = self
                v.button.action = #selector(starClicked(_:))
                return v
            }()
            cell.button.image = NSImage(
                systemSymbolName: c.favorite ? "star.fill" : "star",
                accessibilityDescription: c.favorite ? "Favorite" : "Not a favorite")
            cell.button.contentTintColor = c.favorite ? NSColor(Palette.statusAmber) : .tertiaryLabelColor
            cell.button.tag = row
            return cell
        case "name":
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? TwoLineCellView) ?? {
                let v = TwoLineCellView()
                v.identifier = id
                return v
            }()
            var title = c.name
            if c.isProd { title += "  PROD" }
            if c.protocol == .rclone { title += "  CLOUD" }
            cell.title.stringValue = title
            var sub: [String] = []
            if let folder = c.clientFolderId, let name = parent.clientNames[folder] { sub.append(name) }
            if !c.username.isEmpty { sub.append(c.username) }
            if c.removedFromSource { sub.append("removed from WHM") }
            cell.subtitle.stringValue = sub.joined(separator: " \u{00B7} ")
            return cell
        default:
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? TextCellView) ?? {
                let v = TextCellView()
                v.identifier = id
                return v
            }()
            var text = ""
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.textColor = .labelColor
            switch id.rawValue {
            case "host":
                text = c.protocol == .rclone ? (c.cloud?.backend ?? "rclone") : (c.port == c.protocol.defaultPort ? c.host : "\(c.host):\(c.port)")
                cell.textField?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            case "protocol": text = c.protocol == .rclone ? "Cloud" : c.protocol.rawValue.uppercased()
            case "source": text = sourceText(c.source, parent)
            case "last":
                if let date = c.lastConnectedAt {
                    text = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
                } else {
                    text = "Never"
                    cell.textField?.textColor = .secondaryLabelColor
                }
            case "status":
                let status = parent.statuses[c.id]
                text = status?.label ?? "Saved"
                cell.textField?.textColor = status == nil ? .secondaryLabelColor : .labelColor
            default: break
            }
            cell.textField?.stringValue = text
            return cell
        }
    }

    private func sourceText(_ source: ConnectionSource, _ parent: ManagerTable) -> String {
        switch source {
        case .manual: "Added by hand"
        case .quickConnect: "Quick connect"
        case .filezillaImport: "FileZilla import"
        case .transmitImport: "Transmit import"
        case .cyberduckImport: "Cyberduck import"
        case .sshConfigImport: "SSH config"
        case .whm(let id): "WHM: \(parent.sourceLabels[id] ?? "server")"
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let table, let parent else { return }
        let ids = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
        if ids != parent.selection { parent.selection = ids }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        sortKey = key
        ascending = d.ascending
        if let parent { update(parent) }
    }

    // MARK: Actions

    private func selectedConnections() -> [Connection] {
        guard let table else { return [] }
        return table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
    }

    @objc private func starClicked(_ sender: NSButton) {
        guard sender.tag < rows.count else { return }
        parent?.actions.toggleFavorite(rows[sender.tag])
    }

    @objc private func doubleClicked() {
        guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
        parent?.actions.connect(rows[table.clickedRow], NSEvent.modifierFlags.contains(.command))
    }

    private func returnPressed(_ flags: NSEvent.ModifierFlags) {
        // Option-Return (side by side) arrives with the side-by-side layout.
        if flags.contains(.option) { return }
        for c in selectedConnections() { parent?.actions.connect(c, flags.contains(.command)) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table else { return }
        if table.clickedRow >= 0, !table.selectedRowIndexes.contains(table.clickedRow) {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        }
        let has = !selectedConnections().isEmpty
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = has
            menu.addItem(item)
        }
        add("Connect", #selector(menuConnect))
        add("Open in New Tab", #selector(menuConnectNewTab))
        menu.addItem(.separator())
        add("Edit\u{2026}", #selector(menuEdit))
        add("Duplicate", #selector(menuDuplicate))
        add("Toggle Favorite", #selector(menuFavorite))
        menu.addItem(.separator())
        add("Delete\u{2026}", #selector(menuDelete))
    }

    @objc private func menuConnect() { for c in selectedConnections() { parent?.actions.connect(c, false) } }
    @objc private func menuConnectNewTab() { for c in selectedConnections() { parent?.actions.connect(c, true) } }
    @objc private func menuEdit() { if let c = selectedConnections().first { parent?.actions.edit(c) } }
    @objc private func menuDuplicate() { if let c = selectedConnections().first { parent?.actions.duplicate(c) } }
    @objc private func menuFavorite() { for c in selectedConnections() { parent?.actions.toggleFavorite(c) } }

    @objc private func menuDelete() {
        let list = selectedConnections()
        guard !list.isEmpty else { return }
        let what = list.count == 1 ? "\"\(list[0].name)\"" : "\(list.count) connections"
        guard Dialogs.confirm(
            title: "Delete \(what)?", message: "Saved passwords for \(list.count == 1 ? "it" : "them") are removed from your Keychain.",
            confirm: "Delete") else { return }
        for c in list { parent?.actions.delete(c) }
    }
}
