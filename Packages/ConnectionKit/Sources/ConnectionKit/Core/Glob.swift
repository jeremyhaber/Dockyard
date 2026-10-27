import Foundation

/// Shell-style glob matching: `*`, `?`, `[abc]`, `[a-z]`, `[!abc]` and `\` escapes.
public enum Glob {
    /// With `pathAware`, `*` and `?` stop at `/` and `**` crosses directories (gitignore semantics).
    public static func matches(_ pattern: String, _ text: String, pathAware: Bool = false, caseInsensitive: Bool = false) -> Bool {
        let p = Array(caseInsensitive ? pattern.lowercased() : pattern)
        let t = Array(caseInsensitive ? text.lowercased() : text)
        return match(p, 0, t, 0, pathAware)
    }

    public static func hasWildcards(_ pattern: String) -> Bool {
        pattern.contains { "*?[".contains($0) }
    }

    private static func match(_ p: [Character], _ start: Int, _ t: [Character], _ textStart: Int, _ pathAware: Bool) -> Bool {
        var pi = start, ti = textStart
        while pi < p.count {
            let c = p[pi]
            switch c {
            case "*":
                var stars = 0
                while pi + stars < p.count, p[pi + stars] == "*" { stars += 1 }
                let rest = pi + stars
                let crossesSlash = !pathAware || stars >= 2
                // `**/` also matches zero directories.
                if pathAware, stars >= 2, rest < p.count, p[rest] == "/", match(p, rest + 1, t, ti, pathAware) { return true }
                var k = ti
                while true {
                    if match(p, rest, t, k, pathAware) { return true }
                    guard k < t.count, crossesSlash || t[k] != "/" else { return false }
                    k += 1
                }
            case "?":
                guard ti < t.count, !(pathAware && t[ti] == "/") else { return false }
                pi += 1; ti += 1
            case "[":
                guard ti < t.count else { return false }
                if let (matched, next) = bracket(p, pi, t[ti]) {
                    guard matched, !(pathAware && t[ti] == "/") else { return false }
                    pi = next; ti += 1
                } else {
                    // An unterminated class is a literal bracket.
                    guard t[ti] == "[" else { return false }
                    pi += 1; ti += 1
                }
            case "\\" where pi + 1 < p.count:
                guard ti < t.count, t[ti] == p[pi + 1] else { return false }
                pi += 2; ti += 1
            default:
                guard ti < t.count, t[ti] == c else { return false }
                pi += 1; ti += 1
            }
        }
        return ti == t.count
    }

    /// Returns whether `ch` is in the class starting at `p[start] == "["`, and the index after `]`.
    private static func bracket(_ p: [Character], _ start: Int, _ ch: Character) -> (Bool, Int)? {
        var i = start + 1
        var negate = false
        if i < p.count, p[i] == "!" || p[i] == "^" { negate = true; i += 1 }
        var matched = false
        var first = true
        while i < p.count {
            if p[i] == "]" && !first { return (matched != negate, i + 1) }
            first = false
            var lo = p[i]
            if lo == "\\", i + 1 < p.count { i += 1; lo = p[i] }
            if i + 2 < p.count, p[i + 1] == "-", p[i + 2] != "]" {
                if lo <= ch && ch <= p[i + 2] { matched = true }
                i += 3
            } else {
                if lo == ch { matched = true }
                i += 1
            }
        }
        return nil
    }
}
