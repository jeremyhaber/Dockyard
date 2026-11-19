import Foundation

/// nano's cut buffer and mark, on plain text so it can be tested. Offsets are UTF-16 (what `NSTextView` uses).
///
/// ^K cuts the marked region (or the selection, or the current line including its newline). Cuts made one right
/// after another append to the buffer, like nano; any other key in between starts a new buffer. ^U pastes it.
public struct NanoEditing: Equatable, Sendable {
    public private(set) var buffer = ""
    /// The anchor set by ^6, or nil.
    public private(set) var mark: Int?
    private var appendNext = false

    public init() {}

    /// What to delete and what the buffer now holds. Nil when there is nothing to cut (an empty last line).
    public mutating func cut(in text: String, caret: Int, selection: NSRange) -> NSRange? {
        let ns = text as NSString
        let caret = min(max(caret, 0), ns.length)
        let range: NSRange
        if let mark {
            let anchor = min(mark, ns.length)
            range = NSRange(location: min(anchor, caret), length: abs(anchor - caret))
        } else if selection.length > 0, NSMaxRange(selection) <= ns.length {
            range = selection
        } else {
            range = ns.lineRange(for: NSRange(location: caret, length: 0))
        }
        mark = nil
        guard range.length > 0 else {
            appendNext = false
            return nil
        }
        let piece = ns.substring(with: range)
        buffer = appendNext ? buffer + piece : piece
        appendNext = true
        return range
    }

    /// The text ^U inserts, or nil when nothing was cut yet.
    public mutating func paste() -> String? {
        appendNext = false
        return buffer.isEmpty ? nil : buffer
    }

    /// Any key other than ^K: the next cut starts a fresh buffer.
    public mutating func noteOtherAction() { appendNext = false }

    /// ^6 sets the mark at the caret, or clears it when set.
    public mutating func toggleMark(at caret: Int) {
        mark = mark == nil ? caret : nil
        appendNext = false
    }

    public mutating func clearMark() { mark = nil }

    /// The highlighted region while the mark is set and the caret moves.
    public static func selection(anchor: Int, caret: Int) -> NSRange {
        NSRange(location: min(anchor, caret), length: abs(anchor - caret))
    }
}
