import Foundation
import ConnectionKit

/// Name matching for a pane's find bar (⌘F) and the sidebar's connection search.
///
/// Matches anywhere in a name, ignoring case and accents, like a browser's find. `*` (any run of characters),
/// `?` (one character) and `[a-z]` / `[!a-z]` work too: `wp-*ont` finds `wp-content`, `*.php` finds `index.php`.
public enum NameFilter {
    /// The text without surrounding whitespace; empty means no search.
    public static func normalized(_ filter: String) -> String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `name` matches. An empty filter matches everything.
    public static func matches(_ name: String, filter: String) -> Bool {
        let needle = normalized(filter)
        if needle.isEmpty { return true }
        return matchRange(in: name, needle: needle) != nil
    }

    /// The part of `name` to highlight (the first, longest match). Nil when it does not match or the filter is empty.
    public static func matchRange(in name: String, filter: String) -> Range<String.Index>? {
        let needle = normalized(filter)
        if needle.isEmpty { return nil }
        return matchRange(in: name, needle: needle)
    }

    /// The glob as the server search's `find -iname` pattern, so it finds what the find bar would: `*text*`.
    public static func serverPattern(_ filter: String) -> String {
        let needle = normalized(filter)
        guard Glob.hasWildcards(needle) else { return needle }
        return (needle.hasPrefix("*") ? "" : "*") + needle + (needle.hasSuffix("*") && !needle.hasSuffix("\\*") ? "" : "*")
    }

    private static func matchRange(in name: String, needle: String) -> Range<String.Index>? {
        guard Glob.hasWildcards(needle), let regex = regex(for: needle) else {
            return name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
        }
        // Fold one character at a time so offsets in the folded text map back to the name.
        let chars = Array(name)
        let folded = chars.map { c -> String in
            let f = String(c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return f.count == 1 ? f : String(c).lowercased()
        }
        let text = folded.joined()
        guard let hit = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let found = Range(hit.range, in: text) else { return nil }
        // Turn character offsets in `text` into indices in `name`.
        var start = 0, end = 0, offset = text.startIndex
        for (i, piece) in folded.enumerated() {
            if offset == found.lowerBound { start = i }
            offset = text.index(offset, offsetBy: piece.count)
            if offset == found.upperBound { end = i + 1 }
        }
        if found.isEmpty { return nil }
        let lower = name.index(name.startIndex, offsetBy: start)
        return lower..<name.index(name.startIndex, offsetBy: max(end, start))
    }

    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexLock = NSLock()

    /// `*` → `.*`, `?` → `.`, `[!a-c]` → `[^a-c]`, `\x` → a literal `x`; everything else literal. Folded like names.
    private static func regex(for glob: String) -> NSRegularExpression? {
        regexLock.lock()
        defer { regexLock.unlock() }
        if let cached = regexCache[glob] { return cached }
        let p = Array(glob.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        var out = ""
        var i = 0
        while i < p.count {
            let c = p[i]
            switch c {
            case "*":
                while i + 1 < p.count, p[i + 1] == "*" { i += 1 }
                out += ".*"
            case "?":
                out += "."
            case "\\" where i + 1 < p.count:
                i += 1
                out += NSRegularExpression.escapedPattern(for: String(p[i]))
            case "[":
                var j = i + 1
                if j < p.count, p[j] == "!" || p[j] == "^" { j += 1 }
                if j < p.count, p[j] == "]" { j += 1 }
                while j < p.count, p[j] != "]" { j += 1 }
                if j < p.count {
                    var body = ""
                    var k = i + 1
                    if p[k] == "!" || p[k] == "^" { body += "^"; k += 1 }
                    while k < j {
                        let ch = p[k]
                        body += (ch == "\\" || ch == "[" || ch == "]" || ch == "^" || ch == "&" || ch == "~") ? "\\" + String(ch) : String(ch)
                        k += 1
                    }
                    out += "[" + body + "]"
                    i = j
                } else {
                    out += "\\["
                }
            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        let regex = try? NSRegularExpression(pattern: out, options: [.dotMatchesLineSeparators])
        if regexCache.count > 64 { regexCache.removeAll() }
        regexCache[glob] = regex
        return regex
    }

    /// Saved connections whose name, host, user name or client name match, in their given order.
    public static func connections(
        _ connections: [Connection], matching filter: String, clientNames: [UUID: String] = [:], limit: Int = .max
    ) -> [Connection] {
        let needle = normalized(filter)
        guard !needle.isEmpty else { return [] }
        let hits = connections.lazy.filter { c in
            guard c.deletedAt == nil else { return false }
            let client = c.clientFolderId.flatMap { clientNames[$0] } ?? ""
            return [c.name, c.host, c.username, client].contains { matches($0, filter: needle) }
        }
        return Array(hits.prefix(limit))
    }

    /// Ids of the list rows whose name matches, in row order. The `..` row never matches.
    public static func matchingRows(_ rows: [FileRow], filter: String) -> [String] {
        guard !normalized(filter).isEmpty else { return [] }
        return rows.compactMap { row in
            guard case .item(let item) = row, matches(item.name, filter: filter) else { return nil }
            return row.id
        }
    }

    /// Moves through `count` matches like a browser's Find Next / Find Previous, wrapping at either end.
    /// With no current match, forward starts at the first and backward at the last.
    public static func step(from current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current < count else { return forward ? 0 : count - 1 }
        return forward ? (current + 1) % count : (current - 1 + count) % count
    }
}

extension FolderTree {
    /// Paths of the loaded folders whose name matches, depth first (the tree's order), collapsed branches included.
    /// The tree's top folder is not searched. Empty when `filter` is blank.
    public func matchingPaths(_ filter: String) -> [String] {
        guard !NameFilter.normalized(filter).isEmpty else { return [] }
        var out: [String] = []
        func visit(_ node: TreeNode) {
            if NameFilter.matches(node.name, filter: filter) { out.append(node.path) }
            for child in node.children ?? [] { visit(child) }
        }
        for child in root.children ?? [] { visit(child) }
        return out
    }
}
