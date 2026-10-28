import Foundation
import ConnectionKit

public struct TreeNode: Sendable, Equatable {
    public var name: String
    public var path: String
    /// `nil` until the folder has been listed (lazy expansion).
    public var children: [TreeNode]?
    public var isExpanded: Bool = false
    public var loadFailed: Bool = false
}

public struct TreeRow: Sendable, Equatable, Identifiable {
    public var path: String
    public var name: String
    public var depth: Int
    public var isExpanded: Bool
    /// False once we know the folder has no subfolders.
    public var isExpandable: Bool
    public var isCurrent: Bool
    /// Index of another tab that already shows this folder; clicking the marker switches to it.
    public var openInTabIndex: Int?
    public var id: String { path }
}

/// Lazy folder tree for a pane. Pure data; loading goes through a closure so any file system can feed it.
public struct FolderTree: Sendable, Equatable {
    public typealias Loader = @Sendable (String) async throws -> [RemoteItem]

    public private(set) var root: TreeNode

    public init(rootPath: String = "/", rootName: String? = nil) {
        let p = PathTools.normalize(rootPath)
        root = TreeNode(name: rootName ?? (p == "/" ? "/" : RemotePath.lastComponent(of: p)), path: p, children: nil, isExpanded: false)
    }

    // MARK: Mutation

    /// Records a listing (folders only are kept).
    public mutating func setChildren(of path: String, from items: [RemoteItem]) {
        let dirs = FileListModel.sorted(items.filter(\.isDirectory), by: FileSort())
        let nodes = dirs.map { TreeNode(name: $0.name, path: RemotePath.join(path == "/" ? "" : path, $0.name), children: nil) }
        update(path) { node in
            // Keep state of children we already knew.
            let old = Dictionary(uniqueKeysWithValues: (node.children ?? []).map { ($0.path, $0) })
            node.children = nodes.map { old[$0.path] ?? $0 }
            node.loadFailed = false
        }
    }

    public mutating func collapse(_ path: String) { update(path) { $0.isExpanded = false } }

    /// Expands a folder, listing it first if it has not been loaded.
    public mutating func expand(_ path: String, loader: Loader) async {
        let p = PathTools.normalize(path)
        guard let node = find(p) else { return }
        if node.children == nil {
            do { setChildren(of: p, from: try await loader(p)) } catch { update(p) { $0.loadFailed = true; $0.children = [] } }
        }
        update(p) { $0.isExpanded = true }
    }

    public mutating func toggle(_ path: String, loader: Loader) async {
        if find(PathTools.normalize(path))?.isExpanded == true { collapse(path) } else { await expand(path, loader: loader) }
    }

    /// Expands every ancestor of `path` so it is visible (used when the current folder changes).
    /// A folder outside the tree raises the root to the nearest common ancestor first.
    public mutating func reveal(_ path: String, loader: Loader) async {
        let p = PathTools.normalize(path)
        if !Self.contains(root.path, p) { await raise(to: Self.commonAncestor(root.path, p), loader: loader) }
        var acc = root.path
        await expandIfNeeded(acc, loader: loader)
        for c in PathTools.components(of: p).dropFirst(PathTools.components(of: root.path).count).dropLast() {
            acc = RemotePath.join(acc == "/" ? "" : acc, c)
            // Make sure the next level is known before expanding it.
            guard find(acc) != nil else { return }
            await expandIfNeeded(acc, loader: loader)
        }
        // The deepest folder is revealed, not expanded.
    }

    /// Moves the root up to `ancestor` (the `..` row), keeping everything already loaded below the old root.
    public mutating func raise(to ancestor: String, loader: Loader) async {
        let target = PathTools.normalize(ancestor)
        let old = root
        guard target != old.path, Self.contains(target, old.path) else { return }
        var tree = FolderTree(rootPath: target)
        await tree.expand(target, loader: loader)
        await tree.reveal(old.path, loader: loader)
        tree.graft(old)
        self = tree
    }

    /// Puts `subtree` at its path, adding any folders a failed listing left out, and expands its parents.
    private mutating func graft(_ subtree: TreeNode) {
        let rest = PathTools.components(of: subtree.path).dropFirst(PathTools.components(of: root.path).count)
        Self.graft(subtree, into: &root, rest)
    }

    private static func graft(_ subtree: TreeNode, into node: inout TreeNode, _ rest: ArraySlice<String>) {
        guard let next = rest.first else { node = subtree; return }
        var kids = node.children ?? []
        let path = RemotePath.join(node.path == "/" ? "" : node.path, next)
        let index: Int
        if let found = kids.firstIndex(where: { $0.path == path }) {
            index = found
        } else {
            kids.append(TreeNode(name: next, path: path, children: nil))
            index = kids.count - 1
        }
        graft(subtree, into: &kids[index], rest.dropFirst())
        node.children = kids
        node.isExpanded = true
    }

    private mutating func expandIfNeeded(_ path: String, loader: Loader) async {
        guard let node = find(path), !(node.isExpanded && node.children != nil) else { return }
        await expand(path, loader: loader)
    }

    /// Re-expands folders saved in a session. Missing folders are skipped. Parents come first.
    public mutating func restoreExpanded(_ paths: [String], loader: Loader) async {
        for p in paths.map(PathTools.normalize).sorted(by: { PathTools.components(of: $0).count < PathTools.components(of: $1).count }) {
            guard find(p) != nil || p == root.path else { continue }
            await expand(p, loader: loader)
        }
    }

    // MARK: Queries

    /// True when there is a folder above the root to show (the `..` row).
    public var canRaise: Bool { root.path != "/" }

    public var expandedPaths: [String] {
        var out: [String] = []
        func walk(_ n: TreeNode) {
            if n.isExpanded { out.append(n.path) }
            n.children?.forEach(walk)
        }
        walk(root)
        return out
    }

    public func node(at path: String) -> TreeNode? { find(PathTools.normalize(path)) }

    /// Rows to display, depth first.
    public func visibleRows(for pane: PaneState) -> [TreeRow] {
        var rows: [TreeRow] = []
        let current = pane.currentPath
        func marker(_ path: String) -> Int? {
            pane.otherTabIndex(showing: path)
        }
        func walk(_ n: TreeNode, depth: Int) {
            rows.append(TreeRow(path: n.path, name: n.name, depth: depth, isExpanded: n.isExpanded,
                                isExpandable: n.children.map { !$0.isEmpty } ?? true,
                                isCurrent: n.path == current, openInTabIndex: marker(n.path)))
            if n.isExpanded { n.children?.forEach { walk($0, depth: depth + 1) } }
        }
        walk(root, depth: 0)
        return rows
    }

    // MARK: Internals

    private func find(_ path: String) -> TreeNode? {
        var node = root
        guard Self.contains(root.path, path) else { return nil }
        if path == root.path { return node }
        let rest = PathTools.components(of: path).dropFirst(PathTools.components(of: root.path).count)
        var acc = root.path
        for c in rest {
            acc = RemotePath.join(acc == "/" ? "" : acc, c)
            guard let child = node.children?.first(where: { $0.path == acc }) else { return nil }
            node = child
        }
        return node
    }

    private mutating func update(_ path: String, _ change: (inout TreeNode) -> Void) {
        let p = PathTools.normalize(path)
        let rootComps = PathTools.components(of: root.path).count
        let comps = Array(PathTools.components(of: p).dropFirst(rootComps))
        guard Self.contains(root.path, p) else { return }
        Self.apply(&root, comps[...], change)
    }

    /// True when `path` is `ancestor` or inside it. Both normalized.
    static func contains(_ ancestor: String, _ path: String) -> Bool {
        ancestor == "/" || path == ancestor || path.hasPrefix(ancestor + "/")
    }

    static func commonAncestor(_ a: String, _ b: String) -> String {
        let shared = zip(PathTools.components(of: a), PathTools.components(of: b)).prefix { $0 == $1 }.map(\.0)
        return "/" + shared.joined(separator: "/")
    }

    private static func apply(_ node: inout TreeNode, _ rest: ArraySlice<String>, _ change: (inout TreeNode) -> Void) {
        guard let next = rest.first else { change(&node); return }
        guard var kids = node.children, let i = kids.firstIndex(where: { $0.name == next }) else { return }
        apply(&kids[i], rest.dropFirst(), change)
        node.children = kids
    }
}
