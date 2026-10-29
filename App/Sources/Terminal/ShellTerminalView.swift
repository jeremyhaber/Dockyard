import AppKit
import SwiftTerm

/// The terminal with text-field habits on the shell's command line: a click moves the caret, and typing, Delete, Cut
/// or Paste replaces selected text. The shell only understands keys, so this sends arrow keys and backspaces. It only
/// applies to the line the cursor is on (soft-wrapped rows included), on the normal screen, when the program running
/// is not tracking the mouse; full-screen programs such as vim and less get the plain terminal behaviour.
final class ShellTerminalView: TerminalView {
    private var pressPoint: CGPoint?
    private var dragged = false
    /// Where the last edit sent the caret, until the shell's echo moves the cursor there.
    private var expectedCaret: (position: Position, until: Date)?

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
        pressPoint = plain && event.clickCount == 1 ? convert(event.locationInWindow, from: nil) : nil
        dragged = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        defer { pressPoint = nil }
        guard let point = pressPoint, !dragged, selectedCells == nil, let line = commandLine() else { return }
        let target = bufferPosition(at: point)
        guard line.rows.contains(target.row) else { return }
        // Past the end of what is typed, the caret goes to the end, as in a text field.
        moveCaret(to: Position.compare(target, line.end) == .after ? line.end : target)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if selectedCells != nil, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch event.keyCode {
            case 51, 117:  // Delete, Forward Delete
                if deleteSelection() { return }
            default:
                if let text = event.characters, Self.isTyping(text) { _ = deleteSelection() }
            }
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any) {
        _ = deleteSelection()
        super.paste(sender)
    }

    @objc func cut(_ sender: Any?) {
        guard selectionOnCommandLine() != nil else { return }
        copy(sender as Any)
        _ = deleteSelection()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(cut(_:)) { return selectionOnCommandLine() != nil }
        return super.validateUserInterfaceItem(item)
    }

    /// Printable text, not Return, Escape, Tab or the arrow and function keys (U+F700 and up).
    private static func isTyping(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
    }

    // MARK: Editing

    /// The rows of the line being edited and the cell after its last typed character, or nil when arrow keys
    /// would not edit it (a full-screen program, or one that reads the mouse).
    private func commandLine() -> (rows: ClosedRange<Int>, end: Position)? {
        let terminal = getTerminal()
        guard !terminal.isCurrentBufferAlternate, terminal.mouseMode == .off else { return nil }
        let cursor = caret()
        var top = cursor.row, bottom = cursor.row
        while top > 0, terminal.bufferLine(atRow: top)?.isWrapped == true { top -= 1 }
        while terminal.bufferLine(atRow: bottom + 1)?.isWrapped == true { bottom += 1 }

        var end = cursor
        search: for row in stride(from: bottom, through: top, by: -1) {
            guard let line = terminal.bufferLine(atRow: row) else { continue }
            for col in stride(from: min(line.count, terminal.cols) - 1, through: 0, by: -1) {
                let character = line[col].getCharacter()
                guard character != " ", character != "\0" else { continue }
                let last = Position(col: col + 1, row: row)
                if Position.compare(last, cursor) == .after { end = last }
                break search
            }
        }
        return (top...bottom, end)
    }

    /// The selection, clipped to the typed text, when it lies on the line being edited.
    private func selectionOnCommandLine() -> (start: Position, end: Position)? {
        guard let range = selectedCells, let line = commandLine(),
              line.rows.contains(range.start.row), line.rows.contains(range.end.row),
              Position.compare(range.start, line.end) == .before else { return nil }
        return (range.start, Position.compare(range.end, line.end) == .after ? line.end : range.end)
    }

    /// Moves the caret to the end of the selection and backspaces over it. False when the selection is elsewhere.
    private func deleteSelection() -> Bool {
        guard let range = selectionOnCommandLine() else { return false }
        let count = characters(from: range.start, to: range.end)
        moveCaret(to: range.end)
        send(txt: String(repeating: "\u{7F}", count: count))
        expectedCaret = (range.start, Date().addingTimeInterval(1))
        selectNone()
        return true
    }

    private func moveCaret(to target: Position) {
        let count = characters(from: caret(), to: target)
        guard count != 0 else { return }
        let application = getTerminal().applicationCursor
        let key = count < 0 ? (application ? "\u{1B}OD" : "\u{1B}[D") : (application ? "\u{1B}OC" : "\u{1B}[C")
        send(txt: String(repeating: key, count: abs(count)))
        expectedCaret = (target, Date().addingTimeInterval(1))
    }

    /// The cursor, or where the last edit sent it while the shell has not echoed that yet, so quick clicks add up.
    private func caret() -> Position {
        let cursor = getTerminal().cursorBufferPosition
        if let expected = expectedCaret, expected.position != cursor, Date() < expected.until { return expected.position }
        expectedCaret = nil
        return cursor
    }

    /// Characters between two cells, negative when `to` comes first. A wide character counts once.
    private func characters(from: Position, to: Position) -> Int {
        let terminal = getTerminal()
        let backwards = Position.compare(from, to) == .after
        var cell = backwards ? to : from
        let end = backwards ? from : to
        var count = 0
        while Position.compare(cell, end) == .before {
            if let line = terminal.bufferLine(atRow: cell.row), cell.col < line.count, line[cell.col].width > 0 { count += 1 }
            cell.col += 1
            if cell.col >= terminal.cols { cell = Position(col: 0, row: cell.row + 1) }
        }
        return backwards ? -count : count
    }
}
