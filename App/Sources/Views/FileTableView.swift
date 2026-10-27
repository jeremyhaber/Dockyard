import AppKit
import ConnectionKit
import DockyardCore
import SwiftUI

// MARK: - AppKit pieces

final class FileNSTableView: NSTableView {
    var onCommandClickRow: ((Int) -> Bool)?
    var onReturn: (() -> Void)?
    var onDeleteKey: (() -> Void)?
    var onFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let row = self.row(at: convert(event.locationInWindow, from: nil))
            if row >= 0, onCommandClickRow?(row) == true { return }
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 51, 117: onDeleteKey?()
        default: super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return super.becomeFirstResponder()
    }
}

/// Draws the selection with the design's light blue instead of the system accent.
final class SelectionRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        Palette.ns("Selection").setFill()
        bounds.fill()
    }
}

@MainActor
private enum Symbols {
    static func image(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
    static let folder = image("folder.fill")
    static let file = image("doc")
    static let link = image("link")
    static let parent = image("arrow.turn.left.up")
}

final class NameCellView: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 13)
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class TextCellView: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - SwiftUI wrapper

struct FileTableView: NSViewRepresentable {
    let pane: PaneModel
    let session: ConnectionSession
    /// Changes whenever the rows change; SwiftUI calls `updateNSView` when it does.
    let version: Int
    let sort: FileSort

    func makeCoordinator() -> FileTableCoordinator {
        FileTableCoordinator(app: AppModel.shared, pane: pane, session: session)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = FileNSTableView()
        coordinator.configure(table)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = Palette.ns("Ground")
        scroll.setAccessibilityLabel(pane.side == .local ? "Local files" : "Server files")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(version: version, sort: sort)
    }
}

// MARK: - Coordinator

@MainActor
final class FileTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let app: AppModel
    private let pane: PaneModel
    private let session: ConnectionSession
    private weak var table: FileNSTableView?
    private var rows: [FileRow] = []
    private var lastVersion = -1
    private var suppressSort = false

    private static let nameID = NSUserInterfaceItemIdentifier("name")
    private static let sizeID = NSUserInterfaceItemIdentifier("size")
    private static let modifiedID = NSUserInterfaceItemIdentifier("modified")
    private static let permsID = NSUserInterfaceItemIdentifier("permissions")
    private static let rowID = NSUserInterfaceItemIdentifier("row")

    init(app: AppModel, pane: PaneModel, session: ConnectionSession) {
        self.app = app
        self.pane = pane
        self.session = session
    }

    func configure(_ table: FileNSTableView) {
        self.table = table
        table.style = .plain
        table.rowHeight = 22
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = Palette.ns("Ground")
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.intercellSpacing = NSSize(width: 0, height: 0)

        func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, key: SortKey, width: CGFloat, min: CGFloat) -> NSTableColumn {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = min
            c.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            return c
        }
        let name = column(Self.nameID, "Name", key: .name, width: 280, min: 140)
        name.resizingMask = .autoresizingMask
        let size = column(Self.sizeID, "Size", key: .size, width: 80, min: 50)
        let modified = column(Self.modifiedID, "Modified", key: .modified, width: 130, min: 90)
        let perms = column(Self.permsID, "Perms", key: .permissions, width: 90, min: 60)
        perms.isHidden = pane.side == .local
        for c in [name, size, modified, perms] { table.addTableColumn(c) }

        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.registerForDraggedTypes([.dockyardItems, .fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        table.onCommandClickRow = { [weak self] row in self?.commandClick(row) ?? false }
        table.onReturn = { [weak self] in self?.openSelection() }
        table.onDeleteKey = { [weak self] in self?.deleteSelection() }
        table.onFocus = { [weak self] in
            guard let self else { return }
            self.app.focusedSide = self.pane.side
        }
    }

    func update(version: Int, sort: FileSort) {
        guard let table else { return }
        if let descriptor = table.sortDescriptors.first, descriptor.key == sort.key.rawValue, descriptor.ascending == sort.ascending {
            // in sync
        } else {
            suppressSort = true
            table.sortDescriptors = [NSSortDescriptor(key: sort.key.rawValue, ascending: sort.ascending)]
            suppressSort = false
        }
        guard version != lastVersion else { return }
        lastVersion = version
        let selected = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
        rows = pane.rows
        table.reloadData()
        if !selected.isEmpty {
            var indexes = IndexSet()
            for (i, row) in rows.enumerated() where selected.contains(row.id) { indexes.insert(i) }
            table.selectRowIndexes(indexes, byExtendingSelection: false)
        }
        pane.selection = selectedRows()
    }

    private func selectedRows() -> [FileRow] {
        guard let table else { return [] }
        return table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let reused = tableView.makeView(withIdentifier: Self.rowID, owner: self) as? SelectionRowView { return reused }
        let view = SelectionRowView()
        view.identifier = Self.rowID
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < rows.count else { return nil }
        let id = column.identifier
        let fileRow = rows[row]
        if id == Self.nameID {
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NameCellView) ?? {
                let c = NameCellView()
                c.identifier = id
                return c
            }()
            switch fileRow {
            case .parent:
                cell.textField?.stringValue = ".."
                cell.imageView?.image = Symbols.parent
                cell.imageView?.contentTintColor = .secondaryLabelColor
            case .item(let item):
                cell.textField?.stringValue = item.name
                if item.isDirectory {
                    cell.imageView?.image = Symbols.folder
                    cell.imageView?.contentTintColor = .controlAccentColor
                } else {
                    cell.imageView?.image = item.isSymlink ? Symbols.link : Symbols.file
                    cell.imageView?.contentTintColor = .secondaryLabelColor
                }
            }
            return cell
        }
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? TextCellView) ?? {
            let c = TextCellView()
            c.identifier = id
            return c
        }()
        var text = ""
        if case .item(let item) = fileRow {
            switch id {
            case Self.sizeID: text = item.isDirectory ? "" : FileDisplay.size(item.size)
            case Self.modifiedID: text = FileDisplay.modified(item.modified)
            case Self.permsID: text = FileDisplay.permissions(item.permissions)
            default: break
            }
        }
        cell.textField?.stringValue = text
        cell.textField?.textColor = .secondaryLabelColor
        if id == Self.permsID {
            cell.textField?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        } else {
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        cell.textField?.alignment = id == Self.sizeID ? .right : .left
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        pane.selection = selectedRows()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !suppressSort, let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key.flatMap(SortKey.init(rawValue:)) else { return }
        pane.setSort(FileSort(key: key, ascending: descriptor.ascending))
    }

    // MARK: Opening

    @objc private func doubleClicked(_ sender: Any?) {
        guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
        open(rows[table.clickedRow])
    }

    private func openSelection() {
        if let first = selectedRows().first { open(first) }
    }

    private func open(_ row: FileRow) {
        switch row {
        case .parent:
            pane.goUp()
        case .item(let item):
            if item.isDirectory {
                pane.navigate(to: item.path)
            } else {
                openFile(item)
            }
        }
    }

    private func openFile(_ item: RemoteItem) {
        if pane.side == .local {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            return
        }
        let session = self.session
        Task {
            do {
                let url = try await session.fetchForOpening(item)
                NSWorkspace.shared.open(url)
            } catch {
                session.operationError = "Open \(item.name): \(error.userMessage)"
            }
        }
    }

    private func commandClick(_ row: Int) -> Bool {
        guard row < rows.count, case .item(let item) = rows[row], item.isDirectory else { return false }
        pane.openTab(at: item.path, activate: false)
        return true
    }

    // MARK: Drag source

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < rows.count, case .item(let item) = rows[row] else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.path, forType: .dockyardItems)
        if pane.side == .local {
            pasteboardItem.setString(URL(fileURLWithPath: item.path).absoluteString, forType: .fileURL)
        }
        return pasteboardItem
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        var items: [RemoteItem] = []
        for index in rowIndexes where index < rows.count {
            if case .item(let item) = rows[index] { items.append(item) }
        }
        DragState.origin = (self.session.id, pane.side)
        DragState.items = items
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DragState.clear()
    }

    // MARK: Drop target

    private func dropDirectory(row: Int, operation: NSTableView.DropOperation) -> (String, Bool) {
        if operation == .on, row >= 0, row < rows.count, case .item(let item) = rows[row], item.isDirectory {
            return (item.path, true)
        }
        return (pane.currentPath, false)
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let (directory, onFolder) = dropDirectory(row: row, operation: dropOperation)
        if !onFolder { tableView.setDropRow(-1, dropOperation: .on) }
        return DropHandler.operation(info, pane: pane, session: session, directory: directory)
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let (directory, _) = dropDirectory(row: row, operation: dropOperation)
        return DropHandler.perform(info, app: app, pane: pane, session: session, directory: directory)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table else { return }
        let clicked = table.clickedRow
        if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
            table.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        let selection = selectedRows()
        let items = pane.selectedItems
        let hasSelection = !items.isEmpty

        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }

        add("Open", #selector(menuOpen), enabled: !selection.isEmpty)
        if items.count == 1, items[0].isDirectory { add("Open in New Tab", #selector(menuOpenInTab)) }
        menu.addItem(.separator())
        if pane.side == .local {
            add("Upload", #selector(menuTransfer), enabled: hasSelection && session.status.isConnected)
        } else {
            add("Download", #selector(menuTransfer), enabled: hasSelection)
        }
        menu.addItem(.separator())
        add("Rename…", #selector(menuRename), enabled: items.count == 1)
        add("Delete…", #selector(menuDelete), enabled: hasSelection)
        add("New Folder…", #selector(menuNewFolder))
        menu.addItem(.separator())
        // Archive actions arrive with the archive module.
        add("Compress\u{2026} (coming soon)", #selector(menuRefresh), enabled: false)
        add("Extract (coming soon)", #selector(menuRefresh), enabled: false)
        menu.addItem(.separator())
        add("Copy Path", #selector(menuCopyPath), enabled: hasSelection)
        if pane.side == .server { add("Permissions…", #selector(menuChmod), enabled: hasSelection) }
        add("Refresh", #selector(menuRefresh))
    }

    @objc private func menuOpen() { openSelection() }

    @objc private func menuOpenInTab() {
        if let item = pane.selectedItems.first { pane.openTab(at: item.path, activate: false) }
    }

    @objc private func menuTransfer() {
        let items = pane.selectedItems
        if pane.side == .local {
            guard let server = session.server else { return }
            session.queueTransfer(items, from: .local, to: .server, directory: server.currentPath, move: false, queue: app.queue)
        } else {
            guard let local = session.local else { return }
            session.queueTransfer(items, from: .server, to: .local, directory: local.currentPath, move: false, queue: app.queue)
        }
    }

    @objc private func menuRename() {
        guard let item = pane.selectedItems.first,
              let name = Dialogs.promptText(title: "Rename", message: "New name for \(item.name)", initial: item.name, confirm: "Rename")
        else { return }
        let session = self.session, side = pane.side
        Task { await session.rename(item, to: name, in: side) }
    }

    private func deleteSelection() { menuDelete() }

    @objc private func menuDelete() {
        let items = pane.selectedItems
        guard !items.isEmpty else { return }
        let what = items.count == 1 ? "\"\(items[0].name)\"" : "\(items.count) items"
        guard Dialogs.confirm(
            title: "Delete \(what)?",
            message: pane.side == .local ? "The items are deleted immediately." : "The items are deleted from the server and cannot be recovered.",
            confirm: "Delete") else { return }
        let session = self.session, side = pane.side
        Task { await session.delete(items, in: side) }
    }

    @objc private func menuNewFolder() {
        guard let name = Dialogs.promptText(title: "New Folder", message: "Name of the new folder in \(pane.currentPath)", confirm: "Create"),
              !name.isEmpty else { return }
        let session = self.session, side = pane.side
        Task { await session.createFolder(named: name, in: side) }
    }

    @objc private func menuCopyPath() {
        Dialogs.copyToPasteboard(pane.selectedItems.map(\.path).joined(separator: "\n"))
    }

    @objc private func menuChmod() {
        let items = pane.selectedItems
        guard !items.isEmpty else { return }
        let initial = FileDisplay.octal(items[0].permissions)
        guard let text = Dialogs.promptText(
            title: "Permissions", message: "Octal mode, for example 644 or 755", initial: initial, confirm: "Apply"),
            let mode = FileDisplay.parseOctal(text) else { return }
        let session = self.session, side = pane.side
        Task { await session.chmod(items, mode: mode, in: side) }
    }

    @objc private func