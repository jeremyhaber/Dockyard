import Foundation
import ConnectionKit

/// Skip rules for folder transfers, compare/sync and watch folders, in `.gitignore` syntax:
/// `*.log`, `node_modules/` (folders only), `/build` (anchored to the transfer root), `**/cache`,
/// `!keep.log` (re-include), `#` comments, `\#` and `\!` escapes.
///
/// Paths are relative to the root of the transfer, with `/` separators. As in git, anything inside an
/// ignored folder is ignored and cannot be re-included.
public struct TransferFilter: Sendable, Equatable {
    public static let globalDefaults = [".DS_Store", ".git/", "node_modules/", "Thumbs.db"]

    public struct Rule: Sendable, Equatable {
        public var pattern: String
        public var negated: Bool
        public var directoriesOnly: Bool
        public var anchored: Bool
    }

    public let rules: [Rule]

    public init(patterns: [String]) {
        rules = patterns.compactMap(Self.parse)
    }

    /// Global defaults (unless `includeDefaults` is false) followed by the site's own rules, so a site can
    /// re-include something with `!`.
    public init(site: [String], includeDefaults: Bool = true) {
        self.init(patterns: (includeDefaults ? Self.globalDefaults : []) + site)
    }

    public init(connection: Connection, includeDefaults: Bool = true) {
        self.init(site: connection.transferFilters, includeDefaults: includeDefaults)
    }

    public static let defaults = TransferFilter(patterns: globalDefaults)
    public static let none = TransferFilter(patterns: [])

    public var isEmpty: Bool { rules.isEmpty }

    /// True when the path is skipped by the rules.
    public func matches(path: String, isDirectory: Bool) -> Bool {
        let parts = Self.components(path)
        guard !parts.isEmpty, !rules.isEmpty else { return false }
        for depth in 1...parts.count {
            let isDir = depth < parts.count || isDirectory
            let relative = parts[0..<depth].joined(separator: "/")
            if isIgnored(relative: relative, name: parts[depth - 1], isDirectory: isDir) { return true }
        }
        return false
    }

    /// Splits `items` into those to transfer and those the filter skips.
    public func apply<T>(_ items: [T], path: (T) -> String, isDirectory: (T) -> Bool) -> (kept: [T], skipped: [T]) {
        var kept: [T] = [], skipped: [T] = []
        for item in items {
            if matches(path: path(item), isDirectory: isDirectory(item)) { skipped.append(item) } else { kept.append(item) }
        }
        return (kept, skipped)
    }

    // MARK: Matching

    /// The last rule that matches decides.
    private func isIgnored(relative: String, name: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for rule in rules {
            if rule.directoriesOnly && !isDirectory { continue }
            let hit = rule.anchored
                ? Glob.matches(rule.pattern, relative, pathAware: true)
                : Glob.matches(rule.pattern, name, pathAware: true)
            if hit { ignored = !rule.negated }
        }
        return ignored
    }

    // MARK: Parsing

    static func parse(_ line: String) -> Rule? {
        var text = Substring(line)
        // Trailing spaces are ignored unless escaped.
        while text.hasSuffix(" ") && !text.hasSuffix("\\ ") { text = text.dropLast() }
        guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
        var negated = false
        if text.hasPrefix("!") { negated = true; text = text.dropFirst() }
        var directoriesOnly = false
        if text.hasSuffix("/") { directoriesOnly = true; text = text.dropLast() }
        guard !text.isEmpty else { return nil }
        var anchored = text.contains("/")
        if text.hasPrefix("/") { text = text.dropFirst(); anchored = true }
        guard !text.isEmpty else { return nil }
        return Rule(pattern: String(text), negated: negated, directoriesOnly: directoriesOnly, anchored: anchored)
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
    }
}
