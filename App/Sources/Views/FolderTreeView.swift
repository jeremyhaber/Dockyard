import AppKit
import ConnectionKit
import DockyardCore
import SwiftUI

final class TreeItem: NSObject {
    let path: String
    init(path: String) { self.path = path }
}

final class TreeOutlineView: NSOutlineView {
    var onCommandClickRow: ((Int) -> Bool)?
    var onFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let row = self.row(at: convert(event.locationInWindow, from: nil))
            if row >= 0, onCommandClickRow?(row) == true { return }
        }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return super.becomeFirstResponder()
    }
}

final class TreeCellView: NSTableCellView {
    let pill = NSButton(title: "tab", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.bezelStyle = .inline
        pill.controlSize = .mini
        pill.font = .systemFont(ofSize: 9, weight: .semibold)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(icon)
        addSubview(label)
        addSubview(pill)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -4),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

struct FolderTreeView: NSViewRepresentable {
    let pane: PaneModel
    let session: ConnectionSession
    /// Changes whenever the tree, current folder or tabs change.
    let version: Int

    func makeCoordinator() -> FolderTreeCoordinator {
        FolderTreeCoordinator(app: AppModel.shared, pane: pane, session: session)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = TreeOutlineView()
        context.coordinator.configure(outline)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Palette.ns("ChromeAlt")
        scroll.setAccessibilityLabel(pane.side == .local ? "Local folders" : "Server folders")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(version: version)
    }
}

@MainActor
final class FolderTreeCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let app: AppModel
    private let pane: PaneModel
    private let session: ConnectionSession
    private weak var outline: TreeOutlineView?
    private var items: [String: TreeItem] = [:]
    private var rowInfo: [String: TreeRow] = [:]
    private var lastVersion = -1
    private var syncing = false

    private static let cellID = NSUserInterfaceItemIdentifier("folder")

    init(app: AppModel, pane: PaneModel, session: ConnectionSession) {
        self.app = app
        self.pane = pane
        self.session = session
    }

    func configure(_ outline: TreeOutlineView) {
        self.outline = outline
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folders"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 20
        outline.style = .sourceList
        outline.selectionHighlightStyle = .regular
        outline.backgroundColor = Palette.ns("ChromeAlt")
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([.dockyardItems, .fileURL])
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outline.onCommandClickRow = { [weak self] row in self?.commandClick(row) ?? false }
        outline.onFocus = { [weak self] in
            guard let self else { return }
            self.app.focusedSide = self.pane.side
        }
    }

    private func item(for path: String) -> TreeItem {
        if let existing = items[path] { return existing }
        let created = TreeItem(path: path)
        items[path] = created
        return created
    }

    func update(version: Int) {
        guard let outline, version != lastVersion else { return }
        lastVersion = version
        rowInfo = Dictionary(pane.treeRows.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let scroll = outline.enclosingScrollView?.contentView.bounds.origin
        syncing = true
        outline.reloadData()
        expandExpanded(from: item(for: pane.tree.root.path))
        selectCurrent()
        syncing = false
        if let scroll { outline.enclosingScrollView?.contentView.scroll(to: scroll) }
    }

    private func expandExpanded(from item: TreeItem) {
        guard let outline, let node = pane.tree.node(at: item.path), node.isExpanded else { return }
        outline.expandItem(item)
        for child in node.children ?? [] { expandExpanded(from: self.item(for: child.path)) }
    }

    private func selectCurrent() {
        guard let outline, let current = items[pane.currentPath] else {
            outline?.deselectAll(nil)
            return
        }
        let row = outline.row(forItem: current)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        } else {
            outline.deselectAll(nil)
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? TreeItem else { return 1 }
        return pane.tree.node(at: item.path)?.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let parent = item as? TreeItem else { return self.item(for: pane.tree.root.path) }
        let children = pane.tree.node(at: parent.path)?.children ?? []
        return self.item(for: children[index].path)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? TreeItem, let node = pane.tree.node(at: item.path) else { return false }
        if let children = node.children { return !children.isEmpty }
        return true
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? TreeItem, let info = rowInfo[item.path] else { return nil }
        let cell = (outlineView.makeView(withIdentifier: Self.cellID, owner: self) as? TreeCellView) ?? {
            let c = TreeCellView()
            c.identifier = Self.cellID
            c.pill.target = self
            c.pill.action = #selector(pillClicked(_:))
            return c
        }()
        cell.textField?.stringValue = info.name
        cell.imageView?.image = NSImage(systemSymbolName: info.isCurrent ? "folder.fill" : "folder", accessibilityDescription: nil)
        cell.imageView?.contentTintColor = .controlAccentColor
        if let tab = info.openInTabIndex {
            cell.pill.isHidden = false
            cell.pill.tag = tab
            cell.pill.setAccessibilityLabel("Switch to the tab showing \(info.name)")
        } else {
            cell.pill.isHidden = true
        }
        return cell
    }

    @objc private func pillClicked(_ sender: NSButton) {
        pane.activateTab(sender.tag)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if syncing { return true }
        if let item = item as? TreeItem { pane.toggleTree(item.path) }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        if syncing { return true }
        if let item = item as? TreeItem { pane.toggleTree(item.path) }
        return false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let outline, outline.selectedRow >= 0,
              let item = outline.item(atRow: outline.selectedRow) as? TreeItem else { return }
        pane.navigate(to: item.path)
    }

    private func commandClick(_ row: Int) -> Bool {
        guard let outline, let item = outline.item(atRow: row) as? TreeItem else { return false }
        pane.openTab(at: item.path, activate: false)
        return true
    }

    // MARK: Drop target

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let target = item as? TreeItem else { return [] }
        outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return DropHandler.operation(info, pane: pane, session: session, directory: target.path)
    }

    func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int
    ) -> Bool {
        guard let target = item as? TreeItem else { return false }
        return DropHandler.perform(info, app: app, pane: pane, session: session, directory: target.path)
    }
}
