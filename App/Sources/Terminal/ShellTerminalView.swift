import AppKit
import DockyardCore
import SwiftTerm

/// The terminal with text-field habits on the shell's command line: a click moves the caret, and typing, Delete, Cut
/// or Paste replaces selected text. The shell only understands keys, so this sends arrow keys and backspaces. It only
/// applies to the line the cursor is on (soft-wrapped rows included), on the normal screen, when the program running
/// is not tracking the mouse; full-screen programs such as vim and less get the plain terminal behaviour.
///
/// It also draws fish-style autosuggestions after the typed text (see "Suggestions" below): →, End or ⌥→ accept.
final class ShellTerminalView: TerminalView {
    private var pressPoint: CGPoint?
    private var dragged = false
    /// Where the last edit sent the caret, until the shell's echo moves the cursor there.
    private var expectedCaret: (position: Position, until: Date)?

    // Suggestions
    /// Called with the typed text when Return runs a command line.
    var onCommand: ((String) -> Void)?
    /// The rest of a command to show after what is typed, or nil.
    var suggest: ((String) -> String?)?
    /// False while no shell is attached, which hides the suggestion.
    var isLive: () -> Bool = { true }
    /// Where the shell's prompt ended when the current line was started; nil until the first key of a line.
    private var inputStart: Position?
    /// Set when the line cannot be read reliably; nothing is suggested or recorded until the next Return.
    private var suppressed = false
    private var lastOutput = Date.distantPast
    /// An accepted suggestion has been sent but not echoed yet, so a second accept would repeat it.
    private var acceptedPending = false
    private var updatePending = false
    private let ghost = GhostView()

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
        scheduleGhostUpdate()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        scheduleGhostUpdate()
        defer { pressPoint = nil }
        guard let point = pressPoint, !dragged, selectedCells == nil, let line = commandLine() else { return }
        let target = bufferPosition(at: point)
        guard line.rows.contains(target.row) else { return }
        // Past the end of what is typed, the caret goes to the end, as in a text field.
        moveCaret(to: Position.compare(target, line.end) == .after ? line.end : target)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if acceptSuggestion(event) { return }
        defer { scheduleGhostUpdate() }
        noteKey(event)
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
        beginInput()
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

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        scheduleGhostUpdate()
    }

    override func becomeFirstResponder() -> Bool {
        defer { scheduleGhostUpdate() }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { scheduleGhostUpdate() }
        return super.resignFirstResponder()
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

    // MARK: Suggestions

    /// Feeds the shell's output and notes when it arrived: a key pressed while output is still flowing is not the
    /// start of a command line.
    func feedOutput(_ data: ArraySlice<UInt8>) {
        lastOutput = Date()
        acceptedPending = false
        feed(byteArray: data)
        scheduleGhostUpdate()
    }

    /// The next line starts fresh: the following key marks where its prompt ended.
    func resetInput() {
        inputStart = nil
        suppressed = false
    }

    /// Records where the prompt ended, at the first key of a line. We cannot see the shell's line editor, only the
    /// screen, so when the line may not be a command (output still flowing, a program with the mouse or the
    /// alternate screen, a password prompt) it stays unread until the next Return.
    func beginInput() {
        guard inputStart == nil, !suppressed else { return }
        guard Date().timeIntervalSince(lastOutput) > 0.25, commandLine() != nil, !promptAsksForSecret() else {
            suppressed = true
            return
        }
        inputStart = caret()
    }

    private func drop() {
        suppressed = true
        inputStart = nil
    }

    /// Return records the line, Ctrl-C and friends start over, and keys that redraw the line (search, clear) give up.
    private func noteKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.contains(.command) else { return }
        if event.keyCode == 36 || event.keyCode == 76 {
            if let text = typedLine()?.text, !text.isEmpty { onCommand?(text) }
            resetInput()
            acceptedPending = false
            return
        }
        if flags.contains(.control), let key = event.charactersIgnoringModifiers {
            switch key {
            case "c", "d", "z", "\\": resetInput(); return
            case "r", "s", "l", "x", "g": if inputStart != nil { drop() }
            default: break
            }
        }
        beginInput()
    }

    /// True when something is typed on the command line that Return has not run yet.
    var hasTypedText: Bool { typedLine()?.text.isEmpty == false }

    /// The typed text, from the end of the prompt to the end of the line, when it can be read.
    private func typedLine() -> (text: String, end: Position)? {
        guard !suppressed, let start = inputStart else { return nil }
        guard let line = commandLine() else { drop(); return nil }
        // The cursor before the prompt's end, or the line scrolled away (Tab listings, clear), means the screen no
        // longer matches what we saw.
        guard line.rows.contains(start.row), Position.compare(start, caret()) != .after else { drop(); return nil }
        return (text(from: start, to: line.end), line.end)
    }

    /// The text of the cells from `start` up to `end`, wrapped rows joined.
    private func text(from start: Position, to end: Position) -> String {
        let terminal = getTerminal()
        var cell = start
        var result = ""
        while Position.compare(cell, end) == .before {
            if let line = terminal.bufferLine(atRow: cell.row), cell.col < line.count, line[cell.col].width > 0 {
                let character = line[cell.col].getCharacter()
                result.append(character == "\0" ? " " : character)
            }
            cell.col += 1
            if cell.col >= terminal.cols { cell = Position(col: 0, row: cell.row + 1) }
        }
        return result
    }

    /// True when the prompt row ends like a password prompt ("Password:"), whose input is not echoed.
    private func promptAsksForSecret() -> Bool {
        let cursor = caret()
        let prompt = text(from: Position(col: 0, row: cursor.row), to: cursor).lowercased().trimmingCharacters(in: .whitespaces)
        guard prompt.hasSuffix(":") else { return false }
        return ["password", "passphrase", "passcode", "verification code", "secret"].contains { prompt.contains($0) }
    }

    /// The rest of a suggested command, when one should show: the cursor is at the end of the typed text, on the
    /// normal screen, at the bottom, with the terminal focused, no selection and a shell running.
    private func currentSuggestion() -> String? {
        let terminal = getTerminal()
        guard let suggest, isLive(), window?.firstResponder === self, selectedCells == nil,
              terminal.isScrolledToBottom,
              let typed = typedLine(), !typed.text.isEmpty, typed.end == caret() else { return nil }
        return suggest(typed.text)
    }

    /// → or End send the whole suggestion, ⌥→ the next word, instead of the key. False for any other key.
    private func acceptSuggestion(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let word: Bool
        switch (event.keyCode, flags) {
        case (124, []), (119, []): word = false
        case (124, .option): word = true
        default: return false
        }
        guard !acceptedPending, let rest = currentSuggestion() else { return false }
        let text = word ? CommandHistory.nextWord(of: rest) : rest
        guard !text.isEmpty else { return false }
        send(txt: text)
        acceptedPending = true
        return true
    }

    /// Coalesced on the main run loop, after the output or key that changed things has been applied.
    private func scheduleGhostUpdate() {
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in self?.updateGhost() }
    }

    private func updateGhost() {
        updatePending = false
        let terminal = getTerminal()
        let cell = caretFrame.size
        let cursor = terminal.cursorBufferPosition
        let room = terminal.cols - cursor.col
        guard room > 0, cell.width > 0, cell.height > 0, let rest = currentSuggestion() else {
            ghost.isHidden = true
            return
        }
        // One row only: the part that would wrap is cut off.
        let shown = String(rest.prefix(room))
        let row = cursor.row - terminal.buffer.yDisp
        ghost.font = font
        ghost.color = nativeForegroundColor.withAlphaComponent(0.4)
        ghost.text = shown
        ghost.frame = CGRect(x: cell.width * CGFloat(cursor.col), y: frame.height - cell.height * CGFloat(row + 1),
                             width: cell.width * CGFloat(shown.count), height: cell.height)
        if ghost.superview == nil { addSubview(ghost) }
        ghost.isHidden = false
    }
}

/// The dim suggestion text. Never takes clicks, so the terminal underneath still gets them.
private final class GhostView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) { didSet { needsDisplay = true } }
    var color = NSColor.gray { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let lineHeight = font.ascender - font.descender
        (text as NSString).draw(at: NSPoint(x: 0, y: (bounds.height - lineHeight) / 2),
                                withAttributes: [.font: font, .foregroundColor: color])
    }
}
