import Foundation

/// One text replacement that toggles comments, with the selection to restore afterwards. Offsets are UTF-16, like NSRange.
public struct CommentEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange
}

/// IDE-style "toggle line comment" (⌘/), following VS Code's rules:
/// - the lines are the ones the selection touches (a selection ending at the very start of a line leaves that line out);
/// - the marker goes at the smallest indentation among the non-blank lines, followed by one space;
/// - if every non-blank line is already commented the marker (and one space after it) is removed, otherwise all are commented;
/// - blank lines are left alone.
/// CSS and HTML only have block comments, so each line is wrapped on its own (`/* x */`, `<!-- x -->`), exactly as VS
/// Code does; that stays correct when lines already hold comments elsewhere and makes uncommenting symmetrical.
/// In a PHP file a caret outside `<?php ... ?>` is HTML, so those lines use `<!-- -->`.
public enum CommentToggle {
    public static func toggle(text: String, selection: NSRange, kind: EditorFileKind) -> CommentEdit? {
        let ns = text as NSString
        let length = ns.length
        let location = min(max(selection.location, 0), length)
        let end = min(max(selection.location + selection.length, location), length)

        var style = kind.commentStyle
        if kind == .php, isHTML(in: ns, at: location) { style = .block(open: "<!--", close: "-->") }
        guard let style else { return nil }

        // The lines touched, without the last line break.
        let start = lineStart(ns, location)
        var probe = end
        if end > location, ns.character(at: end - 1) == 10 { probe = end - 1 }
        let blockEnd = lineEnd(ns, probe)
        let range = NSRange(location: start, length: blockEnd - start)
        let block = ns.substring(with: range)

        struct Line { var text: NSString; var offset: Int; var indent: Int; var blank: Bool }
        var lines: [Line] = []
        var offset = start
        for part in block.components(separatedBy: "\n") {
            let piece = part as NSString
            var indent = 0
            while indent < piece.length, isSpace(piece.character(at: indent)) { indent += 1 }
            lines.append(Line(text: piece, offset: offset, indent: indent, blank: indent == piece.length))
            offset += piece.length + 1
        }
        let active = lines.filter { !$0.blank }
        guard let minIndent = active.map(\.indent).min() else { return nil }

        func contentEnd(_ line: Line) -> Int {
            var e = line.text.length
            while e > line.indent, isSpace(line.text.character(at: e - 1)) { e -= 1 }
            return e
        }
        func isCommented(_ line: Line) -> Bool {
            let rest = line.text.substring(from: line.indent)
            switch style {
            case .line(let marker): return rest.hasPrefix(marker)
            case .block(let open, let close):
                let trimmed = line.text.substring(with: NSRange(location: line.indent, length: contentEnd(line) - line.indent))
                return trimmed.count >= open.count + close.count && trimmed.hasPrefix(open) && trimmed.hasSuffix(close)
            }
        }
        let uncomment = active.allSatisfy(isCommented)

        // Edits in document offsets: remove `removed` characters at `at`, put `insert` there.
        struct Edit { var at: Int; var removed: Int; var insert: String; var movesCaretAtStart: Bool }
        var edits: [Edit] = []
        for line in active {
            switch style {
            case .line(let marker):
                if uncomment {
                    let after = line.indent + (marker as NSString).length
                    let space = after < line.text.length && line.text.character(at: after) == 32 ? 1 : 0
                    edits.append(Edit(at: line.offset + line.indent, removed: (marker as NSString).length + space, insert: "", movesCaretAtStart: false))
                } else {
                    edits.append(Edit(at: line.offset + minIndent, removed: 0, insert: marker + " ", movesCaretAtStart: true))
                }
            case .block(let open, let close):
                let openLength = (open as NSString).length, closeLength = (close as NSString).length
                let contentEnd = contentEnd(line)
                if uncomment {
                    let afterOpen = line.indent + openLength
                    let space = afterOpen < contentEnd - closeLength && line.text.character(at: afterOpen) == 32 ? 1 : 0
                    edits.append(Edit(at: line.offset + line.indent, removed: openLength + space, insert: "", movesCaretAtStart: false))
                    let closeStart = contentEnd - closeLength
                    let before = closeStart - 1 >= afterOpen + space && line.text.character(at: closeStart - 1) == 32 ? 1 : 0
                    edits.append(Edit(at: line.offset + closeStart - before, removed: closeLength + before, insert: "", movesCaretAtStart: false))
                } else {
                    edits.append(Edit(at: line.offset + minIndent, removed: 0, insert: open + " ", movesCaretAtStart: true))
                    edits.append(Edit(at: line.offset + contentEnd, removed: 0, insert: " " + close, movesCaretAtStart: false))
                }
            }
        }

        // Apply back to front so offsets stay valid.
        let result = NSMutableString(string: block)
        for edit in edits.sorted(by: { $0.at > $1.at }) {
            result.replaceCharacters(in: NSRange(location: edit.at - start, length: edit.removed), with: edit.insert)
        }

        func map(_ position: Int) -> Int {
            var shifted = position
            for edit in edits.sorted(by: { $0.at < $1.at }) {
                let insertLength = (edit.insert as NSString).length
                let delta = insertLength - edit.removed
                if position >= edit.at + edit.removed, position > edit.at || edit.movesCaretAtStart || edit.removed > 0 {
                    shifted += delta
                } else if position > edit.at, position < edit.at + edit.removed {
                    // Inside text that was removed: land where it used to start.
                    shifted += edit.at - position + insertLength
                }
            }
            return shifted
        }
        let newStart = map(location), newEnd = map(end)
        return CommentEdit(
            range: range, replacement: result as String,
            selection: NSRange(location: newStart, length: max(0, newEnd - newStart)))
    }

    // MARK: PHP context

    /// True when `offset` is outside every `<?php ... ?>` block, i.e. in the HTML around them.
    static func isHTML(in text: NSString, at offset: Int) -> Bool {
        let prefix = text.substring(to: offset) as NSString
        var lastOpen = -1
        var search = NSRange(location: 0, length: prefix.length)
        while true {
            let found = prefix.range(of: "<?", options: [], range: search)
            if found.location == NSNotFound { break }
            lastOpen = found.location
            search = NSRange(location: found.location + 2, length: prefix.length - found.location - 2)
        }
        let lastClose = prefix.range(of: "?>", options: .backwards).location
        if lastOpen < 0 { return true }
        return lastClose != NSNotFound && lastClose > lastOpen
    }

    // MARK: Lines

    private static func isSpace(_ unit: unichar) -> Bool { unit == 32 || unit == 9 || unit == 13 }

    private static func lineStart(_ text: NSString, _ offset: Int) -> Int {
        var i = offset
        while i > 0, text.character(at: i - 1) != 10 { i -= 1 }
        return i
    }

    private static func lineEnd(_ text: NSString, _ offset: Int) -> Int {
        var i = offset
        while i < text.length, text.character(at: i) != 10 { i += 1 }
        return i
    }
}
