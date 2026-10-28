import Foundation

/// POSIX `sh` quoting. Every path that reaches a remote command goes through here.
public enum ShellQuote {
    /// Wraps `value` in single quotes, turning each embedded `'` into `'\''`. Safe for spaces, `$`,
    /// backticks and newlines. A leading `-` only matters to the receiving program, see `operand`.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quotes a path used as a command operand. Relative paths that start with `-` get `./` so programs
    /// cannot mistake them for options.
    public static func operand(_ path: String) -> String {
        quote(path.hasPrefix("-") ? "./" + path : path)
    }

    public static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }
}
