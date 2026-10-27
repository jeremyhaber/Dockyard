import ConnectionKit
import DockyardCore
import Foundation
import Observation

enum PaneSide: String, Sendable, Hashable, Codable {
    case local, server
}

/// One pane: folder tabs, the current listing and the lazy folder tree over one file system.
@MainActor @Observable
final class PaneModel {
    let side: PaneSide
    let fs: any RemoteFileSystem
    let home: String

    private(set) var state: PaneState
    private(set) var tree: FolderTree
    private(set) var items: [RemoteItem] = []
    private(set) var rows: [FileRow] = []
    private(set) var rowsVersion = 0
    private(set) var treeVersion = 0
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var showHidden = true
    /// Bumped by ⌘L / ⌘G and ⌘Y so the path bar reacts.
    private(set) var pathEditToken = 0
    private(set) var historyToken = 0

    @ObservationIgnored var selection: [FileRow] = []
    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var onVisit: ((String) -> Void)?
    @ObservationIgnored var onLog: ((LogLine.Kind, String) -> Void)?

    @ObservationIgnored private var cache: [String: [RemoteItem]] = [:]
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var rowGeneration = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var treeTask: Task<Void, Never>?

    init(side: PaneSide, fs: any RemoteFileSystem, state: PaneState, home: String) {
        self.side = side
        self.fs = fs
        self.state = state
        self.home = home
        self.tree = FolderTree(rootPath: "/", rootName: "/")
    }

    // MARK: Derived

    var currentPath: String { state.currentPath }
    var treeRows: [TreeRow] { tree.visibleRows(for: state) }
    var footer: String { FileListModel.footer(for: items) }
    var sort: FileSort { state.activeTab.sort }
    var selectedItems: [RemoteItem] {
        var out: [RemoteItem] = []
        for row in selection {
            if case .item(let item) = row { out.append(item) }
        }
        return out
    }

    func setShowHidden(_ value: Bool) {
        guard value != showHidden else { return }
        showHidden = value
        rebuildRows()
    }

    /// Changes whenever the tree, the current folder or the tabs change.
    var treeSignature: Int {
        var hasher = Hasher()
        hasher.combine(treeVersion)
        hasher.combine(currentPath)
        hasher.combine(state.activeIndex)
        for tab in state.tabs { hasher.combine(tab.path) }
        return hasher.finalize()
    }

    func item(at path: String) -> RemoteItem? { items.first { $0.path == path } }

    var loader: FolderTree.Loader {
        let fs = self.fs
        return { path in try await fs.list(path) }
    }

    // MARK: Start

    func start(expanded: [String]) {
        reload()
        let load = loader
        let target = currentPath
        mutateTree { tree in
            await tree.restoreExpanded(expanded, loader: load)
            await tree.reveal(target, loader: load)
        }
    }

    // MARK: Loading

    func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let path = currentPath
        if let cached = cache[path] { apply(cached) }
        isLoading = true
        errorMessage = nil
        loadTask?.cancel()
        let fs = self.fs
        loadTask = Task { [weak self] in
            do {
                let list = try await fs.list(path)
                guard let self, generation == self.loadGeneration else { return }
                self.cache[path] = list
                self.apply(list)
                self.isLoading = false
                self.syncTree(path: path, list: list)
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.loadGeneration else { return }
                self.isLoading = false
                self.errorMessage = "Cannot open \(path): \(error.userMessage)"
                self.items = []
                self.rebuildRows()
                self.onLog?(.error, "Cannot list \(path): \(error.userMessage)")
            }
        }
    }

    /// Forgets cached listings (after a change made through this app).
    func invalidate() { cache.removeAll() }

    private func apply(_ list: [RemoteItem]) {
        items = list
        rebuildRows()
    }

    private func rebuildRows() {
        rowGeneration += 1
        let generation = rowGeneration
        let items = self.items
        let path = currentPath
        let rules = state.rules
        let sort = self.sort
        let hidden = showHidden
        if items.count < 1500 {
            rows = FileListModel.rows(for: items, at: path, rules: rules, sort: sort, showHidden: hidden)
            rowsVersion += 1
            return
        }
        Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                FileListModel.rows(for: items, at: path, rules: rules, sort: sort, showHidden: hidden)
            }.value
            guard let self, generation == self.rowGeneration else { return }
            self.rows = built
            self.rowsVersion += 1
        }
    }

    private func syncTree(path: String, list: [RemoteItem]) {
        let load = loader
        mutateTree { tree in
            await tree.reveal(path, loader: load)
            tree.setChildren(of: path, from: list)
        }
    }

    private func mutateTree(_ body: @escaping @Sendable (inout FolderTree) async -> Void) {
        let previous = treeTask
        treeTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var copy = self.tree
            await body(&copy)
            self.tree = copy
            self.treeVersion += 1
            self.onStateChange?()
        }
    }

    // MARK: Navigation

    private func didChangeFolder(record: Bool = true) {
        reload()
        if record { onVisit?(currentPath) }
        onStateChange?()
    }

    func navigate(to path: String) {
        guard state.navigate(to: path) != nil else { return }
        didChangeFolder()
    }

    func navigate(toTyped text: String) {
        guard state.navigate(toTyped: text, home: home) != nil else { return }
        didChangeFolder()
    }

    func goBack() { if state.goBack() != nil { didChangeFolder() } }
    func goForward() { if state.goForward() != nil { didChangeFolder() } }
    func goUp() { if state.goUp() != nil { didChangeFolder() } }
    func goHome() { navigate(to: home) }

    func openTab(at path: String? = nil, activate: Bool = true) {
        state.openTab(at: path, activate: activate)
        if activate { didChangeFolder() } else { onStateChange?() }
    }

    func closeTab(at index: Int) {
        let before = state.activeIndex
        guard state.closeTab(at: index) else { return }
        if state.activeIndex != before || index == before { didChangeFolder(record: false) } else { onStateChange?() }
    }

    func closeActiveTab() { closeTab(at: state.activeIndex) }

    func activateTab(_ index: Int) {
        guard index != state.activeIndex else { return }
        state.activate(index)
        didChangeFolder(record: false)
    }

    func setSort(_ newSort: FileSort) {
        guard newSort != sort else { return }
        state.setSort(newSort)
        rebuildRows()
        onStateChange?()
    }

    func toggleTree(_ path: String) {
        let load = loader
        mutateTree { tree in await tree.toggle(path, loader: load) }
    }

    func requestPathEdit() { pathEditToken += 1 }
    func requestHistory() { historyToken += 1 }

    // MARK: Session

    var sessionTabs: [TabState] { state.sessionTabs }
    var activeTabIndex: Int { state.activeIndex }
    var expandedPaths: [String] { tree.expandedPaths }
}
