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
    let id = UUID()
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
    /// True while the list shows a listing that is still arriving.
    private(set) var isPartial = false
    /// Folders being listed right now (the current folder or one expanding in the tree), for the tree's spinner.
    private(set) var loadingPaths: Set<String> = []
    private(set) var errorMessage: String?
    private(set) var showHidden = true
    /// Bumped by ⌘L / ⌘G and ⌘Y so the path bar reacts.
    private(set) var pathEditToken = 0
    private(set) var historyToken = 0
    private(set) var recentToken = 0
    // The find bar (⌘F): highlights matching names and steps through them, like a browser's find.
    private(set) var findOpen = false
    /// Kept after closing, like a browser, so ⌘F brings the last search back.
    private(set) var findText = ""
    private(set) var findScope: FindScope = .files
    /// Matching list row ids (files) or tree paths (folders), in display order.
    private(set) var findMatches: [String] = []
    /// Index into `findMatches`; nil until the user moves to a match.
    private(set) var findIndex: Int?
    /// Bumped to focus the find field.
    private(set) var findFocusToken = 0
    /// With the focus: put the caret after the text (typing carries on) rather than selecting it all (⌘F).
    private(set) var findCaretAtEnd = false
    /// Bumped when the current match moves, so the list selects or the tree scrolls to it.
    private(set) var findMoveToken = 0

    @ObservationIgnored var selection: [FileRow] = []
    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var onVisit: ((String) -> Void)?
    @ObservationIgnored var onLog: ((LogLine.Kind, String) -> Void)?

    @ObservationIgnored private var cache: [String: [RemoteItem]] = [:]
    @ObservationIgnored private var loadingCounts: [String: Int] = [:]
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var rowGeneration = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var treeTask: Task<Void, Never>?

    init(side: PaneSide, fs: any RemoteFileSystem, state: PaneState, home: String, treeRoot: String = "/") {
        self.side = side
        self.fs = fs
        self.state = state
        self.home = home
        self.tree = FolderTree(rootPath: treeRoot)
    }

    // MARK: Derived

    var currentPath: String { state.currentPath }
    var treeRows: [TreeRow] { tree.visibleRows(for: state) }
    var footer: String {
        if isPartial { return "\(items.count.formatted()) items so far" }
        return FileListModel.footer(for: items)
    }
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

    /// Changes whenever the tree, the current folder, the tabs or the folder search change.
    var treeSignature: Int {
        var hasher = Hasher()
        hasher.combine(treeVersion)
        hasher.combine(findSignature(for: .folders))
        hasher.combine(currentPath)
        hasher.combine(state.activeIndex)
        for tab in state.tabs { hasher.combine(tab.path) }
        return hasher.finalize()
    }

    func item(at path: String) -> RemoteItem? { items.first { $0.path == path } }

    var loader: FolderTree.Loader {
        let fs = self.fs
        return { [weak self] path in
            await self?.beginLoading(path)
            do {
                let list = try await fs.list(path)
                await self?.endLoading(path)
                return list
            } catch {
                await self?.endLoading(path)
                throw error
            }
        }
    }

    /// Marks `path` as loading. The spinner appears only if the listing takes longer than a moment, so quick ones do not flicker.
    private func beginLoading(_ path: String) {
        loadingCounts[path, default: 0] += 1
        guard loadingCounts[path] == 1 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.loadingCounts[path] != nil else { return }
            self.loadingPaths.insert(path)
        }
    }

    private func endLoading(_ path: String) {
        guard let count = loadingCounts[path] else { return }
        if count > 1 {
            loadingCounts[path] = count - 1
        } else {
            loadingCounts[path] = nil
            loadingPaths.remove(path)
        }
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
        beginLoading(path)
        isPartial = false
        // A cached listing stays up until the fresh one is complete; without one, entries show as they arrive.
        let showPartial = cache[path] == nil
        loadTask = Task { [weak self] in
            defer { self?.endLoading(path) }
            var listing = ListingAccumulator()
            var lastShown: ContinuousClock.Instant?
            do {
                for try await update in fs.listStream(path) {
                    guard let self, generation == self.loadGeneration else { return }
                    listing.apply(update)
                    // Re-sorting a huge folder on every batch would swamp the list; refresh a few times a second.
                    let now = ContinuousClock.now
                    if showPartial, lastShown.map({ now - $0 > Self.partialRefresh }) ?? true {
                        lastShown = now
                        self.isPartial = true
                        self.apply(listing.items)
                    }
                }
                // A cancelled stream just ends; never cache what it had so far as the full listing.
                try Task.checkCancellation()
                guard let self, generation == self.loadGeneration else { return }
                let list = listing.items
                self.cache[path] = list
                self.isPartial = false
                self.apply(list)
                self.isLoading = false
                self.syncTree(path: path, list: list)
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.loadGeneration else { return }
                self.isLoading = false
                self.isPartial = false
                self.errorMessage = "Cannot open \(path): \(error.userMessage)"
                self.items = []
                self.rebuildRows()
                self.onLog?(.error, "Cannot list \(path): \(error.userMessage)")
            }
        }
    }

    private static let partialRefresh: Duration = .milliseconds(300)

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
            if findScope == .files { refreshFind(jump: false) }
            return
        }
        Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                FileListModel.rows(for: items, at: path, rules: rules, sort: sort, showHidden: hidden)
            }.value
            guard let self, generation == self.rowGeneration else { return }
            self.rows = built
            self.rowsVersion += 1
            if self.findScope == .files { self.refreshFind(jump: false) }
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
            if self.findScope == .folders { self.refreshFind(jump: false) }
            self.onStateChange?()
        }
    }

    // MARK: Find (⌘F)

    enum FindScope: Hashable { case files, folders }

    /// Opens the find bar and focuses it. `scope` nil keeps the last one.
    func openFind(scope: FindScope? = nil) {
        if let scope, scope != findScope { findScope = scope; findIndex = nil }
        findOpen = true
        findCaretAtEnd = false
        findFocusToken += 1
        refreshFind(jump: findIndex == nil)
    }

    /// Typing in the list or tree: starts a new find with `text` in that view and moves the typing into the bar.
    func startFind(typing text: String, scope: FindScope) {
        findScope = scope
        findOpen = true
        findIndex = nil
        findText = text
        findCaretAtEnd = true
        findFocusToken += 1
        refreshFind(jump: true)
    }

    /// Closes the bar. In the folder tree the pane goes to the current match, the way a browser leaves
    /// the found text selected; in the list the match is already selected. `land: false` just closes.
    func closeFind(land: Bool = true) {
        guard findOpen else { return }
        let landing = land && findScope == .folders ? findCurrent : nil
        findOpen = false
        findMatches = []
        findIndex = nil
        if let landing { navigate(to: landing) }
    }

    func setFindText(_ text: String) {
        guard text != findText else { return }
        let changed = NameFilter.normalized(text) != NameFilter.normalized(findText)
        findText = text
        if changed { refreshFind(jump: true) }
    }

    func setFindScope(_ scope: FindScope) {
        guard scope != findScope else { return }
        findScope = scope
        findIndex = nil
        refreshFind(jump: true)
    }

    /// Find Next / Find Previous (Return / Shift-Return in the bar), wrapping at either end.
    func findStep(forward: Bool) {
        guard findOpen else { return }
        guard let next = NameFilter.step(from: findIndex, count: findMatches.count, forward: forward) else { return }
        moveFind(to: next)
    }

    var findCurrent: String? {
        guard let findIndex, findIndex < findMatches.count else { return nil }
        return findMatches[findIndex]
    }

    /// "3 of 12", "12 matches", "No matches"; empty while the field is blank.
    var findStatus: String {
        guard !NameFilter.normalized(findText).isEmpty else { return "" }
        if findMatches.isEmpty { return "No matches" }
        if let findIndex { return "\((findIndex + 1).formatted()) of \(findMatches.count.formatted())" }
        return findMatches.count == 1 ? "1 match" : "\(findMatches.count.formatted()) matches"
    }

    /// The part of `name` to highlight in the list (`.files`) or the tree (`.folders`); nil when that view is not
    /// being searched or the name does not match.
    func findHighlight(in name: String, for scope: FindScope) -> Range<String.Index>? {
        guard findOpen, findScope == scope else { return nil }
        return NameFilter.matchRange(in: name, filter: findText)
    }

    /// Changes whenever what the list (`.files`) or tree (`.folders`) shows for the search changes.
    func findSignature(for scope: FindScope) -> Int {
        var hasher = Hasher()
        let active = findOpen && findScope == scope
        hasher.combine(active)
        if active {
            hasher.combine(NameFilter.normalized(findText))
            hasher.combine(findCurrent)
            hasher.combine(findMoveToken)
        }
        return hasher.finalize()
    }

    /// Recomputes the matches after the text, the scope or the data changed. With `jump`, moves to the first match
    /// at or after the list selection (files) or the first in the tree (folders), unless the current one still matches.
    private func refreshFind(jump: Bool) {
        guard findOpen else { return }
        let previous = findCurrent
        findMatches = findScope == .files ? NameFilter.matchingRows(rows, filter: findText) : tree.matchingPaths(findText)
        if let previous, let kept = findMatches.firstIndex(of: previous) {
            findIndex = kept
            return
        }
        findIndex = nil
        guard jump, !findMatches.isEmpty else { return }
        moveFind(to: firstMatchFromAnchor())
    }

    private func firstMatchFromAnchor() -> Int {
        guard findScope == .files, let anchor = selection.first?.id,
              let anchorRow = rows.firstIndex(where: { $0.id == anchor }) else { return 0 }
        let position = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return findMatches.firstIndex { (position[$0] ?? 0) >= anchorRow } ?? 0
    }

    private func moveFind(to index: Int) {
        findIndex = index
        findMoveToken += 1
        guard findScope == .folders, let path = findCurrent else { return }
        // Expand the match's parents so its row exists; the tree scrolls to it once it does.
        var collapsedAbove = false
        var parent = RemotePath.parent(of: path)
        while parent != path, let node = tree.node(at: parent) {
            if !node.isExpanded { collapsedAbove = true; break }
            if parent == tree.root.path { break }
            parent = RemotePath.parent(of: parent)
        }
        if collapsedAbove {
            let load = loader
            mutateTree { tree in await tree.reveal(path, loader: load) }
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

    /// Switching tabs re-lists the folder; clicking the tab that is already active refreshes it.
    func activateTab(_ index: Int) {
        guard index != state.activeIndex else {
            reload()
            return
        }
        state.activate(index)
        didChangeFolder(record: false)
    }

    func setSort(_ newSort: FileSort) {
        guard newSort != sort else { return }
        state.setSort(newSort)
        rebuildRows()
        onStateChange?()
    }

    /// Shows the folder above the tree's top (the `..` row).
    func raiseTree() {
        guard tree.canRaise else { return }
        let load = loader
        let target = RemotePath.parent(of: tree.root.path)
        mutateTree { tree in await tree.raise(to: target, loader: load) }
    }

    func toggleTree(_ path: String) {
        let load = loader
        mutateTree { tree in await tree.toggle(path, loader: load) }
    }

    func requestPathEdit() { pathEditToken += 1 }
    func requestHistory() { historyToken += 1 }
    func requestRecentChanges() { recentToken += 1 }

    // MARK: Session

    var sessionTabs: [TabState] { state.sessionTabs }
    var activeTabIndex: Int { state.activeIndex }
    var expandedPaths: [String] { tree.expandedPaths }
}
