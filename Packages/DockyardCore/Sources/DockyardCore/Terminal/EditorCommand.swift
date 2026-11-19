import Foundation

/// A typed shell command that Dockyard can run itself instead: a terminal editor on one file, or `crontab -e`.
/// Anything the parser is not sure about is nil, so the line runs in the shell as typed.
public enum EditorCommand: Equatable, Sendable {
    /// `file` is the argument exactly as typed, quotes and all, so the remote shell resolves `~`, `$VARS` and globs.
    /// `sudo` is true for `sudo vim f`, `sudoedit f` and `sudo -e f`.
    case edit(editor: String, file: String, line: Int?, sudo: Bool)
    case crontab

    static let editors: Set<String> = [
        "nano", "pico", "vi", "vim", "nvim", "emacs", "micro", "joe", "jed", "mcedit", "ne", "hx", "kak",
    ]

    /// Flags that change nothing about which file opens or how it saves.
    private static let harmlessFlags: [String: Set<String>] = [
        "nano": ["-w", "-l"], "pico": [], "emacs": ["-nw"],
    ]

    public static func parse(_ text: String) -> EditorCommand? {
        guard let words = tokens(text) else { return nil }
        return parse(words: words)
    }

    /// Same rules for words that are already final (the shell expanded them), such as a function's `"$@"`.
    public static func parse(words input: [String]) -> EditorCommand? {
        var words = input
        guard !words.isEmpty else { return nil }
        if words == ["crontab", "-e"] { return .crontab }
        var sudo = false
        if words[0] == "sudoedit" {
            guard words.count == 2, isFile(words[1]) else { return nil }
            return .edit(editor: "sudoedit", file: words[1], line: nil, sudo: true)
        }
        if words[0] == "sudo" {
            sudo = true
            words.removeFirst()
            if words.first == "-e" {
                guard words.count == 2, isFile(words[1]) else { return nil }
                return .edit(editor: "sudoedit", file: words[1], line: nil, sudo: true)
            }
        }
        guard let editor = words.first, editors.contains(editor) else { return nil }
        var file: String?
        var line: Int?
        for word in words.dropFirst() {
            if word.hasPrefix("+") {
                guard line == nil, let number = lineNumber(word) else { return nil }
                line = number
            } else if word.hasPrefix("-") {
                guard harmlessFlags[editor]?.contains(word) == true else { return nil }
            } else {
                guard file == nil, isFile(word) else { return nil }
                file = word
            }
        }
        guard let file else { return nil }
        return .edit(editor: editor, file: file, line: line, sudo: sudo)
    }

    /// `+42` or `+42:3` (the column is ignored).
    private static func lineNumber(_ word: String) -> Int? {
        let parts = word.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let first = parts.first, first.allSatisfy(\.isASCIINumber), let number = Int(first),
              number > 0 else { return nil }
        if parts.count == 2, !(parts[1].allSatisfy(\.isASCIINumber) && !parts[1].isEmpty) { return nil }
        return number
    }

    private static func isFile(_ word: String) -> Bool {
        !word.isEmpty && word != "-" && !word.hasPrefix("-") && !word.hasPrefix("+")
    }

    /// Splits like a shell would, keeping each word as typed. Nil when the line has anything that is not a plain
    /// command: pipes, `;`, `&`, redirects, subshells, backticks, `$(`, comments, `!` or an unclosed quote.
    static func tokens(_ text: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            index += 1
            if escaped {
                escaped = false
                current.append(c)
                continue
            }
            if c == "\n" || c == "\r" || c == "`" { return nil }
            if quote == "'" {
                if c == "'" { quote = nil }
                current.append(c)
                continue
            }
            if c == "$", index < chars.count, chars[index] == "(" { return nil }
            if quote == "\"" {
                if c == "\"" { quote = nil }
                if c == "\\" { escaped = true }
                if c == "!" { return nil }
                current.append(c)
                continue
            }
            switch c {
            case " ", "\t":
                if !current.isEmpty { words.append(current); current = "" }
            case "'", "\"":
                quote = c
                current.append(c)
            case "\\":
                escaped = true
                current.append(c)
            case "|", "&", ";", "<", ">", "(", ")", "!":
                return nil
            case "#" where current.isEmpty:
                return nil
            default:
                current.append(c)
            }
        }
        guard quote == nil, !escaped else { return nil }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

private extension Character {
    var isASCIINumber: Bool { isASCII && isNumber }
}

public extension EditorCommand {
    /// True for the `sudo` forms, which need the file browser to be root.
    var isSudo: Bool {
        if case .edit(_, _, _, let sudo) = self { return sudo }
        return false
    }
}
