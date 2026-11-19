import Foundation

/// The commands typed in one connection's shells, oldest first, and the autosuggestion drawn from them.
public struct CommandHistory: Codable, Equatable, Sendable {
    public static let capacity = 1000

    public private(set) var entries: [String]

    public init(entries: [String] = []) { self.entries = Array(entries.suffix(Self.capacity)) }

    /// Adds a command that was typed and run. Blank lines and lines starting with a space are skipped (as with
    /// `HISTCONTROL=ignorespace`), and a repeat moves to the end. True when the history changed.
    @discardableResult
    public mutating func record(_ line: String) -> Bool {
        let command = line.trimmingCharacters(in: .newlines)
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty, !command.hasPrefix(" "),
              !command.contains(where: \.isNewline) else { return false }
        if entries.last == command { return false }
        entries.removeAll { $0 == command }
        entries.append(command)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        return true
    }

    /// The rest of the command to show after `typed`: the newest history entry that starts with it, else the first
    /// snippet command that does. Nil for empty input or when nothing is strictly longer than what is typed.
    public func suggestion(for typed: String, snippets: [String] = []) -> String? {
        guard !typed.isEmpty else { return nil }
        for candidate in entries.reversed() + snippets.filter({ !$0.contains(where: \.isNewline) }) {
            if candidate.count > typed.count, candidate.hasPrefix(typed) { return String(candidate.dropFirst(typed.count)) }
        }
        return nil
    }

    /// The part of `suggestion` that ⌥→ accepts: any leading spaces plus the next word (up to the next space).
    public static func nextWord(of suggestion: String) -> String {
        var result = ""
        var inWord = false
        for character in suggestion {
            if character == " " {
                if inWord { break }
            } else {
                inWord = true
            }
            result.append(character)
        }
        return result
    }
}
