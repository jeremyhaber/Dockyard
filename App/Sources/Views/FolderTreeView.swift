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
    /// Typing a name starts a find in the tree; returns whether it took the key.
    var onTypeToFind: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if let text = typeToFindText(event), onTypeToFind?(text) == true { return }
        super.keyDown(with: event)
    }

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
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applySelectionInk(emphasized: backgroundStyle == .emphasized) }
    }

    let pill = NSButton(title: "tab", target: nil, action: nil)
    let spinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = InkImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = InkLabel(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.bezelStyle = .inline
        pill.controlSize = .mini
        pill.font = .systemFont(ofSize: 9, weight: .semibold)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Loading")
        // A stack drops hidden views, so the label keeps the full width when neither accessory shows.
        let accessories = NSStackView(views: [spinner, pill])
        accessories.orientation = .horizontal
        accessories.spacing = 4
        accessories.translatesAutoresizingMaskIntoConstraints = false
        accessories.setHuggingPriority(.required, for: .horizontal)
        addSubview(icon)
        addSubview(label)
        addSubview(accessories)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: accessories.leadingAnchor, constant: -4),
            accessories.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            accessories.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func setLoading(_ loading: Bool) {
        if loading {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

struct FolderTreeView: NSViewRepresentable {
    let pane: PaneModel
    let session: ConnectionSession
    /// Changes whenever the tree, current folder or tabs change.
    let version: Int
    /// Folders being listed; their rows show a spinner.
    let loading: Set<String>

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
        context.coordinator.update(version: version, loading: loading)
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
    private var loading: Set<String> = []
    /// The current folder once its row has been scrolled into view.
    private var lastRevealed: String?
    private var syncing = false
    /// The pane's `findMoveToken` last acted on, and a match still waiting for its row to appear.
    private var lastFindMove = 0
    private var pendingFindScroll: String?
    private var findWasActive = false

    private static let cellID = NSUserInterfaceItemIdentifier("folder")
    /// The `..` row above the tree's top folder; selecting it shows the folder above.
    private let parentItem = TreeItem(path: "..")

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
        outline.onTypeToFind = { [weak self] text in
            self?.pane.startFind(typing: text, scope: .folders)
            return self != nil
        }
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

    func update(version: Int, loading: Set<String>) {
        guard let outline else { return }
        let loadingChanged = loading.symmetricDifference(self.loading)
        self.loading = loading
        guard version != lastVersion else {
            // Only the spinners changed: refresh just those rows.
            let rows = IndexSet(loadingChanged.compactMap { items[$0].map { outline.row(forItem: $0) } }.filter { $0 >= 0 })
            if !rows.isEmpty { outline.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0)) }
            return
        }
        lastVersion = version
        rowInfo = Dictionary(pane.treeRows.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        // Keep the user's scroll position unless the current folder changed or was just revealed.
        let row = items[pane.currentPath].map { outline.row(forItem: $0) } ?? -1
        let keepScroll = pane.currentPath == lastRevealed && row >= 0
        let scroll = outline.enclosingScrollView?.contentView.bounds.origin
        syncing = true
        outline.reloadData()
        expandExpanded(from: item(for: pane.tree.root.path))
        selectCurrent()
        syncing = false
        if keepScroll, let scroll {
            outline.enclosingScrollView?.contentView.scroll(to: scroll)
        } else if outline.row(forItem: items[pane.currentPath]) >= 0 {
            lastRevealed = pane.currentPath
        }
        followFind(outline)
    }

    /// Scrolls to the find bar's current folder match (its parents may still be expanding), and takes focus back
    /// when the bar closes.
    private func followFind(_ outline: TreeOutlineView) {
        let active = pane.findOpen && pane.findScope == .folders
        if active, pane.findMoveToken != lastFindMove {
            lastFindMove = pane.findMoveToken
            pendingFindScroll = pane.findCurrent
        }
        if !active { pendingFindScroll = nil }
        if let path = pendingFindScroll, let item = items[path] {
            let row = outline.row(forItem: item)
            if row >= 0 {
                outline.scrollRowToVisible(row)
                pendingFindScroll = nil
            }
        }
        if findWasActive, !active, outline.window?.firstResponder === outline.window {
            outline.window?.makeFirstResponder(outline)
        }
        findWasActive = active
    }

    private func expandExpanded(from item: TreeItem) {
        guard let outline, let node = pane.tree.node(at: item.path), node.isExpanded else { return }
        outline.expandItem(item)
        for child in children(of: node) { expandExpanded(from: self.item(for: child.path)) }
    }

    private func children(of node: TreeNode) -> [TreeNode] { node.children ?? [] }

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
        guard let item = item as? TreeItem else { return pane.tree.canRaise ? 2 : 1 }
        if item === parentItem { return 0 }
        return pane.tree.node(at: item.path).map { children(of: $0).count } ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let parent = item as? TreeItem else {
            return pane.tree.canRaise && index == 0 ? parentItem : self.item(for: pane.tree.root.path)
        }
        let kids = pane.tree.node(at: parent.path).map { children(of: $0) } ?? []
        return self.item(for: kids[index].path)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? TreeItem, item !== parentItem, let node = pane.tree.node(at: item.path) else { return false }
        if node.children != nil { return !children(of: node).isEmpty }
        return true
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? TreeItem else { return nil }
        let cell = (outlineView.makeView(withIdentifier: Self.cellID, owner: self) as? TreeCellView) ?? {
            let c = TreeCellView()
            c.identifier = Self.cellID
            c.pill.target = self
            c.pill.action = #selector(pillClicked(_:))
            return c
        }()
        if item === parentItem {
            let above = RemotePath.parent(of: pane.tree.root.path)
            cell.textField?.stringValue = ".."
            cell.imageView?.image = NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: nil)
            cell.imageView?.contentTintColor = .secondaryLabelColor
            cell.pill.isHidden = true
            cell.setLoading(false)
            cell.toolTip = "Show \(above) in the tree"
            cell.setAccessibilityLabel("Show \(above) in the folder tree")
            return cell
        }
        guard let info = rowInfo[item.path] else { return nil }
        cell.toolTip = nil
        cell.setAccessibilityLabel(nil)
        cell.textField?.font = .systemFont(ofSize: 12)
        if let range = pane.findHighlight(in: info.name, for: .folders) {
            cell.textField?.attributedStringValue = FindHighlight.string(
                info.name, range: range, font: .systemFont(ofSize: 12), current: pane.findCurrent == item.path)
        } else {
            cell.textField?.stringValue = info.name
        }
        cell.imageView?.image = NSImage(systemSymbolName: info.isCurrent ? "folder.fill" : "folder", accessibilityDescription: nil)
        cell.imageView?.contentTintColor = .controlAccentColor
        cell.setLoading(loading.contains(item.path))
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
        if item === parentItem {
            // Re-select the current folder; the tree reloads once the folder above is listed.
            syncing = true
            selectCurrent()
            syncing = false
            pane.raiseTree()
            return
        }
        pane.navigate(to: item.path)
    }

    private func commandClick(_ row: Int) -> Bool {
        guard let outline, let item = outline.item(atRow: row) as? TreeItem, item !== parentItem else { return false }
        pane.openTab(at: item.path, activate: false)
        return true
    }

    // MARK: Drop target

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let target = item as? TreeItem, target !== parentItem else { return [] }
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
