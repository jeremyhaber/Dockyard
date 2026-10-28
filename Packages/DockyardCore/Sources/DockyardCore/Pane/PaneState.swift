import Foundation
import ConnectionKit

public enum SortKey: String, Sendable, Equatable, CaseIterable {
    case name, size, modified, permissions
}

public struct FileSort: Sendable, Equatable {
    public var key: SortKey
    public var ascending: Bool
    public init(key: SortKey = .name, ascending: Bool = true) { self.key = key; self.ascending = ascending }

    /// Clicking a column header: same column flips direction, a new column starts ascending.
    public func toggled(to newKey: SortKey) -> FileSort {
        newKey == key ? FileSort(key: key, ascending: !ascending) : FileSort(key: newKey)
    }
}

/// One folder tab: current folder plus its own back/forward history.
public struct FolderTab: Sendable, Equatable, Identifiable {
    public var id: UUID
    public private(set) var path: String
    public private(set) var backStack: [String]
    public private(set) var forwardStack: [String]
    public var sort: FileSort

    public init(id: UUID = UUID(), path: String, sort: FileSort = FileSort()) {
        self.id = id
        self.path = PathTools.normalize(path)
        self.backStack = []
        self.forwardStack = []
        self.sort = sort
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Returns true when the folder changed.
    @discardableResult
    public mutating func navigate(to newPath: String) -> Bool {
        let target = PathTools.normalize(newPath)
        guard target != path else { return false }
        backStack.append(path)
        forwardStack.removeAll()
        path = target
        return true
    }

    @discardableResult
    public mutating func goBack() -> Bool {
        guard let prev = backStack.popLast() else { return false }
        forwardStack.append(path)
        path = prev
        return true
    }

    @discardableResult
    public mutating func goForward() -> Bool {
        guard let next = forwardStack.popLast() else { return false }
        backStack.append(path)
        path = next
        return true
    }
}

/// All folder tabs of one pane (Local or one server column).
public struct PaneState: Sendable, Equatable {
    public var rules: PathRules
    public private(set) var tabs: [FolderTab]
    public private(set) var activeIndex: Int

    public init(initialPath: String, rules: PathRules = .filesystem) {
        self.rules = rules
        self.tabs = [FolderTab(path: initialPath)]
        self.activeIndex = 0
    }

    /// Rebuilds a pane from saved session tabs. Falls back to `fallbackPath` when none were saved.
    public init(restoring saved: [TabState], active: Int, fallbackPath: String, rules: PathRules = .filesystem) {
        self.rules = rules
        let tabs = saved.map { FolderTab(path: $0.path) }
        self.tabs = tabs.isEmpty ? [FolderTab(path: fallbackPath)] : tabs
        self.activeIndex = min(max(0, active), self.tabs.count - 1)
    }

    public var activeTab: FolderTab { tabs[activeIndex] }
    public var currentPath: String { tabs[activeIndex].path }
    public var canGoBack: Bool { activeTab.canGoBack }
    public var canGoForward: Bool { activeTab.canGoForward }
    public var canGoUp: Bool { rules.hasParentRow(currentPath) }
    public var breadcrumbs: [BreadcrumbSegment] { PathTools.breadcrumbs(for: currentPath) }
    public var showsParentRow: Bool { rules.hasParentRow(currentPath) }

    /// What to persist for session restore.
    public var sessionTabs: [TabState] { tabs.map { TabState(path: $0.path) } }

    /// ⌘T or ⌘-click. Returns the new tab's index.
    @discardableResult
    public mutating func openTab(at path: String? = nil, activate: Bool = true) -> Int {
        tabs.append(FolderTab(path: path ?? currentPath, sort: activeTab.sort))
        if activate { activeIndex = tabs.count - 1 }
        return tabs.count - 1
    }

    /// ⌘W. The last tab cannot be closed. Returns false when nothing was closed.
    @discardableResult
    public mutating func closeTab(at index: Int) -> Bool {
        guard tabs.count > 1, tabs.indices.contains(index) else { return false }
        tabs.remove(at: index)
        if index < activeIndex { activeIndex -= 1 } else if activeIndex >= tabs.count { activeIndex = tabs.count - 1 }
        return true
    }

    public mutating func activate(_ index: Int) {
        if tabs.indices.contains(index) { activeIndex = index }
    }

    /// Index of the first tab other than the active one showing `path` (the tree's tab marker).
    public func otherTabIndex(showing path: String) -> Int? {
        let p = PathTools.normalize(path)
        return tabs.indices.first { $0 != activeIndex && tabs[$0].path == p }
    }

    /// Index of the first tab showing `path`.
    public func tabIndex(showing path: String) -> Int? {
        let p = PathTools.normalize(path)
        return tabs.firstIndex { $0.path == p }
    }

    /// Navigates the active tab. Returns the new path when it changed.
    @discardableResult
    public mutating func navigate(to path: String) -> String? {
        tabs[activeIndex].navigate(to: path) ? currentPath : nil
    }

    @discardableResult
    public mutating func goBack() -> String? { tabs[activeIndex].goBack() ? currentPath : nil }

    @discardableResult
    public mutating func goForward() -> String? { tabs[activeIndex].goForward() ? currentPath : nil }

    @discardableResult
    public mutating func goUp() -> String? {
        guard canGoUp else { return nil }
        return navigate(to: rules.parent(of: currentPath))
    }

    /// Path field submit. Returns the new path, or nil if the text is empty or leads nowhere new.
    @discardableResult
    public mutating func navigate(toTyped text: String, home: String?) -> String? {
        guard let target = PathTools.resolve(text, current: currentPath, home: home) else { return nil }
        return navigate(to: target)
    }

    public mutating func setSort(_ sort: FileSort) { tabs[activeIndex].sort = sort }

    /// If the folder disappeared (deleted elsewhere), go to the nearest existing ancestor.
    public mutating func recoverFromMissingFolder(exists: (String) -> Bool) {
        var p = currentPath
        while p != "/" && !exists(p) { p = RemotePath.parent(of: p) }
        navigate(to: p)
    }
}

// MARK: - File list

public enum FileRow: Sendable, Equatable, Identifiable {
    case parent(path: String)
    case item(RemoteItem)

    public var id: String {
        switch self {
        case .parent(let p): "..:" + p
        case .item(let i): i.path
        }
    }
}

public enum FileListModel {
    /// Folders first, then files, each ordered by `sort`. A `..` row leads unless at the root.
    public static func rows(
        for items: [RemoteItem], at path: String, rules: PathRules = .filesystem,
        sort: FileSort = FileSort(), showHidden: Bool = true
    ) -> [FileRow] {
        var out: [FileRow] = []
        if rules.hasParentRow(path) { out.append(.parent(path: rules.parent(of: path))) }
        out += sorted(items.filter { showHidden || !$0.name.hasPrefix(".") }, by: sort).map(FileRow.item)
        return out
    }

    public static func sorted(_ items: [RemoteItem], by sort: FileSort) -> [RemoteItem] {
        func nameOrder(_ a: RemoteItem, _ b: RemoteItem) -> Bool {
            let r = a.name.compare(b.name, options: [.caseInsensitive, .numeric])
            return r == .orderedSame ? a.name < b.name : r == .orderedAscending
        }
        func ordered<T: Comparable>(_ a: T?, _ b: T?, _ ra: RemoteItem, _ rb: RemoteItem) -> Bool {
            switch (a, b) {
            case (nil, nil): return nameOrder(ra, rb)
            case (nil, _): return false  // unknown values always last
            case (_, nil): return true
            case (let x?, let y?):
                if x == y { return nameOrder(ra, rb) }
                return sort.ascending ? x < y : x > y
            }
        }
        return items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch sort.key {
            case .name: return sort.ascending ? nameOrder(a, b) : nameOrder(b, a)
            case .size: return a.isDirectory ? nameOrder(a, b) : ordered(a.size, b.size, a, b)
            case .modified: return ordered(a.modified, b.modified, a, b)
            case .permissions: return ordered(a.permissions, b.permissions, a, b)
            }
        }
    }

    /// "N files, M folders" (singular forms for 1).
    public static func footer(for items: [RemoteItem]) -> String {
        let folders = items.filter(\.isDirectory).count
        let files = items.count - folders
        return "\(files) \(files == 1 ? "file" : "files"), \(folders) \(folders == 1 ? "folder" : "folders")"
    }
}
