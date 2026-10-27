import Foundation
import ConnectionKit

/// Path rules for one pane. Remote panes use `/` as root; cloud panes treat a bucket's top level as the root.
public struct PathRules: Sendable, Equatable {
    /// Number of leading components that cannot be left. `0` means only `/` is the root; `1` means
    /// `/bucket` is the top level (no `..` row there).
    public var protectedDepth: Int

    public init(protectedDepth: Int = 0) { self.protectedDepth = protectedDepth }

    public static let filesystem = PathRules()
    public static let cloudBucket = PathRules(protectedDepth: 1)

    public func isRoot(_ path: String) -> Bool {
        PathTools.components(of: path).count <= protectedDepth
    }

    /// Every folder except the root shows a `..` row.
    public func hasParentRow(_ path: String) -> Bool { !isRoot(path) }

    /// Parent folder, or the same path at the root.
    public func parent(of path: String) -> String {
        isRoot(path) ? PathTools.normalize(path) : RemotePath.parent(of: PathTools.normalize(path))
    }
}

public enum PathTools {
    public static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Collapses `//`, `.` and `..`, removes a trailing slash. Always absolute.
    public static func normalize(_ path: String) -> String {
        var stack: [String] = []
        for part in components(of: path) {
            switch part {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(part)
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    /// Interprets text typed or pasted in the path field.
    /// Handles quotes, `~`, relative paths (against `current`) and `.`/`..`.
    public static func resolve(_ input: String, current: String, home: String?) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let f = text.first, f == text.last, f == "\"" || f == "'" {
            text = String(text.dropFirst().dropLast())
        }
        guard !text.isEmpty else { return nil }
        if text == "~" || text.hasPrefix("~/") {
            guard let home else { return nil }
            text = text == "~" ? home : RemotePath.join(home, String(text.dropFirst(2)))
        }
        // file:// URLs pasted from Finder.
        if text.hasPrefix("file://"), let url = URL(string: text) { text = url.path }
        if text.hasPrefix("/") { return normalize(text) }
        return normalize(RemotePath.join(current, text))
    }
}

public struct BreadcrumbSegment: Sendable, Equatable, Identifiable {
    public var title: String
    public var path: String
    public var id: String { path }
}

extension PathTools {
    /// `/var/www/html` -> [`/`, `var`, `www`, `html`], each with the path it navigates to.
    public static func breadcrumbs(for path: String, rootTitle: String = "/") -> [BreadcrumbSegment] {
        var out = [BreadcrumbSegment(title: rootTitle, path: "/")]
        var acc = ""
        for c in components(of: path) {
            acc += "/" + c
            out.append(BreadcrumbSegment(title: c, path: acc))
        }
        return out
    }
}
