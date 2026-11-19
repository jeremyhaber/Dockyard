import AppKit
import DockyardCore

/// Start offsets of every line, rebuilt lazily after edits. Feeds the gutter and the `Ln, Col` readout.
final class LineIndex {
    private var starts = [0]
    private var dirty = true
    private let text: () -> String

    init(text: @escaping () -> String) { self.text = text }

    func invalidate() { dirty = true }

    private func refresh() {
        guard dirty else { return }
        dirty = false
        var found = [0]
        var offset = 0
        for unit in text().utf16 {
            offset += 1
            if unit == 10 { found.append(offset) }
        }
        starts = found
    }

    var count: Int { refresh(); return starts.count }

    /// 1-based line holding the UTF-16 offset.
    func line(at offset: Int) -> Int {
        refresh()
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    func start(ofLine line: Int) -> Int {
        refresh()
        return starts[min(max(line, 1), starts.count) - 1]
    }

    func isLineStart(_ offset: Int) -> Bool {
        refresh()
        return starts[line(at: offset) - 1] == offset
    }
}

/// Colours that match the terminal drawer, with explicit selection colours so selected text stays readable.
struct EditorTheme {
    var background: NSColor
    var foreground: NSColor
    var font: NSFont

    static let selection = NSColor(calibratedRed: 0.20, green: 0.38, blue: 0.70, alpha: 1)
    static let gutterText = NSColor(white: 0.5, alpha: 1)

    func color(for kind: SyntaxKind) -> NSColor {
        switch kind {
        case .comment: NSColor(calibratedRed: 0.50, green: 0.60, blue: 0.50, alpha: 1)
        case .string: NSColor(calibratedRed: 0.95, green: 0.69, blue: 0.47, alpha: 1)
        case .number: NSColor(calibratedRed: 0.72, green: 0.84, blue: 0.54, alpha: 1)
        case .keyword: NSColor(calibratedRed: 0.80, green: 0.60, blue: 0.95, alpha: 1)
        case .key: NSColor(calibratedRed: 0.50, green: 0.78, blue: 0.98, alpha: 1)
        case .variable: NSColor(calibratedRed: 0.52, green: 0.88, blue: 0.82, alpha: 1)
        case .tag: NSColor(calibratedRed: 0.94, green: 0.58, blue: 0.62, alpha: 1)
        }
    }
}

/// The text view. Its shortcuts only fire while it is the first responder, so they never reach the rest of the window.
final class EditorTextView: NSTextView {
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?
    var onGoToLine: (() -> Void)?
    var onToggleComment: (() -> Void)?
    var onCheck: (() -> Void)?
    var onFormat: (() -> Void)?

    private var isFocused: Bool { window?.firstResponder === self }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isFocused else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command {
            switch key {
            case "s": onSave?(); return true
            case "w": onClose?(); return true
            case "l": onGoToLine?(); return true
            case "f": showFind(replace: false); return true
            case "/": onToggleComment?(); return true
            default: break
            }
        }
        if flags == [.command, .shift], key == "k" { onCheck?(); return true }
        if flags == [.option, .shift], event.keyCode == 3 { onFormat?(); return true }   // ⌥⇧F
        if flags == [.command, .option], key == "f" { showFind(replace: true); return true }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: nano keys

    private var nano = NanoEditing()
    /// While the mark is set, the caret moves on its own and the text between it and the mark is selected.
    private var markCaret = 0

    /// nano's own keys while this view has focus: ^X exit, ^O write out, ^K cut, ^U paste, ^W search, ^\ replace,
    /// ^_ go to line, ^6 mark, Alt-U undo, Alt-E redo. The other Control combinations stay Emacs-style text keys
    /// (^A ^E ^F ^B ^N ^P). Keys are matched by key code, because ⌥U and ⌥E are dead keys on a Mac keyboard.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if flags == .control || flags == [.control, .shift] {
            switch event.keyCode {
            case 7: onClose?(); return                                    // ^X
            case 31: onSave?(); return                                    // ^O
            case 40: cutForNano(); return                                 // ^K
            case 32: pasteForNano(); return                               // ^U
            case 13: nano.noteOtherAction(); showFind(replace: false); return   // ^W
            case 42: nano.noteOtherAction(); showFind(replace: true); return    // ^\
            case 27, 44: nano.noteOtherAction(); onGoToLine?(); return    // ^_ and ^/
            case 22: toggleMark(); return                                 // ^6 (^^)
            default: break
            }
        } else if flags == .option {
            switch event.keyCode {
            case 32: undoForNano(); return                                // M-U
            case 14: redoForNano(); return                                // M-E
            default: break
            }
        }
        nano.noteOtherAction()
        if nano.mark != nil { moveWithMark(event) } else { super.keyDown(with: event) }
    }

    private func moveWithMark(_ event: NSEvent) {
        let before = string
        setSelectedRange(NSRange(location: min(markCaret, (string as NSString).length), length: 0))
        super.keyDown(with: event)
        guard let anchor = nano.mark, string == before else {
            nano.clearMark()
            return
        }
        markCaret = selectedRange().location
        setSelectedRange(NanoEditing.selection(anchor: anchor, caret: markCaret))
    }

    func toggleMark() {
        nano.toggleMark(at: selectedRange().location)
        markCaret = selectedRange().location
        if nano.mark == nil { setSelectedRange(NSRange(location: markCaret, length: 0)) }
    }

    func cutForNano() {
        let caret = nano.mark != nil ? markCaret : selectedRange().location
        guard let range = nano.cut(in: string, caret: caret, selection: selectedRange()),
              shouldChangeText(in: range, replacementString: "") else { return }
        replaceCharacters(in: range, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: 0))
    }

    func pasteForNano() {
        guard let text = nano.paste() else { return }
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: text) else { return }
        replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
    }

    func undoForNano() { nano.noteOtherAction(); undoManager?.undo() }
    func redoForNano() { nano.noteOtherAction(); undoManager?.redo() }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    func showFind(replace: Bool) {
        let item = NSMenuItem()
        item.tag = (replace ? NSTextFinder.Action.showReplaceInterface : .showFindInterface).rawValue
        performTextFinderAction(item)
    }
}

/// A problem shown in the gutter for one line.
struct EditorMarker: Equatable {
    var severity: CheckProblem.Severity
    var message: String

    var color: NSColor {
        severity == .error ? NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.36, alpha: 1)
            : NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.25, alpha: 1)
    }
}

/// Line numbers beside the text. Only logical lines are numbered, so soft-wrapped rows carry no number.
final class LineNumberRuler: NSRulerView {
    private let index: LineIndex
    private let theme: EditorTheme
    /// Check findings by 1-based line number; drawn as a coloured number and dot, with the message as tooltip.
    var problemMarkers: [Int: EditorMarker] = [:] { didSet { needsDisplay = true } }

    init(scrollView: NSScrollView, textView: NSTextView, index: LineIndex, theme: EditorTheme) {
        self.index = index
        self.theme = theme
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        removeAllToolTips()
        addToolTip(NSRect(origin: .zero, size: newSize), owner: self, userData: nil)
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard !problemMarkers.isEmpty, let textView = clientView as? NSTextView, let layout = textView.layoutManager,
              let container = textView.textContainer else { return "" }
        let inText = textView.convert(point, from: self)
        let origin = textView.textContainerOrigin
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: inText.y - origin.y), in: container)
        let line = index.line(at: layout.characterIndexForGlyph(at: glyph))
        return problemMarkers[line]?.message ?? ""
    }

    func refresh() {
        let digits = max(2, String(index.count).count)
        let width = CGFloat(digits) * 7.5 + 16
        if abs(width - ruleThickness) > 0.5 { ruleThickness = width }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView, let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        theme.background.setFill()
        bounds.fill()
        NSColor(white: 1, alpha: 0.08).setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(theme.font.pointSize - 2, 9), weight: .regular),
            .foregroundColor: EditorTheme.gutterText,
        ]
        let origin = textView.textContainerOrigin
        func draw(_ number: Int, fragment: NSRect) {
            var labelAttributes = attributes
            let marker = problemMarkers[number]
            if let marker { labelAttributes[.foregroundColor] = marker.color }
            let label = NSAttributedString(string: String(number), attributes: labelAttributes)
            let point = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView)
            let size = label.size()
            if let marker {
                marker.color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 3, y: point.y + (fragment.height - 6) / 2, width: 6, height: 6)).fill()
            }
            label.draw(at: NSPoint(x: bounds.maxX - size.width - 6, y: point.y + (fragment.height - size.height) / 2))
        }

        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(
            forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let offset = layout.characterIndexForGlyph(at: range.location)
            if self.index.isLineStart(offset) { draw(self.index.line(at: offset), fragment: fragment) }
        }
        // The empty last line after a trailing newline (or an empty file) has no glyphs.
        let extra = layout.extraLineFragmentRect
        if !extra.isEmpty, extra.intersects(visible.offsetBy(dx: -origin.x, dy: -origin.y)) {
            draw(index.count, fragment: extra)
        }
    }
}

/// The scroll view, text view and gutter as one hosted unit. The model owns it, so the open buffer survives SwiftUI
/// rebuilding the view tree (the same way the terminal view is owned by its controller).
final class EditorScrollView: NSScrollView, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    let textView: EditorTextView
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let theme: EditorTheme
    private var ruler: LineNumberRuler?
    private lazy var lineIndex = LineIndex { [weak self] in self?.storage.string ?? "" }
    private var language = SyntaxLanguage.plain
    private var highlighting = false
    private var lastCaret = (line: 0, column: 0)

    var onEdit: (() -> Void)?
    var onCaret: ((Int, Int) -> Void)?
    /// Gutter markers by line. A marker goes away when its line is edited and moves with lines inserted or removed above it.
    private(set) var markers: [Int: EditorMarker] = [:] { didSet { ruler?.problemMarkers = markers } }

    var text: String { storage.string }

    init(theme: EditorTheme) {
        self.theme = theme
        // Built by hand so it uses TextKit 1, which the gutter and the find bar rely on.
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        textView = EditorTextView(frame: .zero, textContainer: container)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 220))

        storage.delegate = self
        textView.delegate = self
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.font = theme.font
        textView.textColor = theme.foreground
        textView.backgroundColor = theme.background
        textView.drawsBackground = true
        textView.insertionPointColor = .white
        textView.selectedTextAttributes = [.backgroundColor: EditorTheme.selection, .foregroundColor: NSColor.white]
        textView.typingAttributes = baseAttributes
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.setAccessibilityLabel("File editor")

        drawsBackground = true
        backgroundColor = theme.background
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        scrollerKnobStyle = .light
        documentView = textView
        findBarPosition = .aboveContent

        let ruler = LineNumberRuler(scrollView: self, textView: textView, index: lineIndex, theme: theme)
        self.ruler = ruler
        verticalRulerView = ruler
        hasVerticalRuler = true
        rulersVisible = true
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private var baseAttributes: [NSAttributedString.Key: Any] { [.font: theme.font, .foregroundColor: theme.foreground] }

    @objc private func scrolled() { ruler?.needsDisplay = true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.makeFirstResponder(textView)
    }

    // MARK: Content

    /// Replaces the whole buffer. `highlight` is false for big files.
    func load(_ string: String, language: SyntaxLanguage, highlight: Bool) {
        self.language = language
        highlighting = highlight && language != .plain
        markers = [:]
        storage.setAttributedString(NSAttributedString(string: string, attributes: baseAttributes))
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        lineIndex.invalidate()
        ruler?.refresh()
        reportCaret()
    }

    func setWrap(_ wrap: Bool) {
        guard let container = textView.textContainer else { return }
        hasHorizontalScroller = !wrap
        textView.isHorizontallyResizable = !wrap
        container.widthTracksTextView = wrap
        if wrap {
            textView.autoresizingMask = [.width]
            container.size = NSSize(width: max(textView.bounds.width, 0), height: CGFloat.greatestFiniteMagnitude)
            textView.frame.size.width = max(contentSize.width, 0)
        } else {
            textView.autoresizingMask = []
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.needsDisplay = true
    }

    func goToLine(_ line: Int) {
        let offset = lineIndex.start(ofLine: line)
        textView.setSelectedRange(NSRange(location: offset, length: 0))
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        window?.makeFirstResponder(textView)
    }

    func focusText() { window?.makeFirstResponder(textView) }

    var currentLine: Int { lineIndex.line(at: textView.selectedRange().location) }

    /// Jumps to a line, and to a column when known.
    func goTo(line: Int, column: Int?) {
        var offset = lineIndex.start(ofLine: line)
        if let column, column > 1 {
            let next = line < lineIndex.count ? lineIndex.start(ofLine: line + 1) - 1 : (storage.string as NSString).length
            offset = min(offset + column - 1, max(next, offset))
        }
        textView.setSelectedRange(NSRange(location: offset, length: 0))
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        window?.makeFirstResponder(textView)
    }

    func setMarkers(_ problems: [CheckProblem]) {
        var found: [Int: EditorMarker] = [:]
        for problem in problems {
            if var existing = found[problem.line] {
                existing.message += "\n" + problem.message
                if problem.severity == .error { existing.severity = .error }
                found[problem.line] = existing
            } else {
                found[problem.line] = EditorMarker(severity: problem.severity, message: problem.message)
            }
        }
        markers = found
    }

    /// Replaces `range` as one undoable edit and optionally sets the selection afterwards.
    func applyEdit(range: NSRange, replacement: String, selection: NSRange?) {
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        if let selection { textView.setSelectedRange(selection) }
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// Drops the markers of edited lines and shifts the later ones by the lines added or removed.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !markers.isEmpty else { return true }
        let string = storage.string as NSString
        let end = min(range.location + range.length, string.length)
        let removed = string.substring(with: NSRange(location: min(range.location, end), length: end - min(range.location, end)))
            .reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let added = (replacementString ?? "").reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let first = lineIndex.line(at: range.location)
        var next: [Int: EditorMarker] = [:]
        for (line, marker) in markers {
            if line < first {
                next[line] = marker
            } else if line > first + removed {
                next[line + added - removed] = marker
            }
        }
        if next != markers { markers = next }
        return true
    }

    // MARK: Delegates

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        lineIndex.invalidate()
        guard highlighting else { return }
        highlight(around: editedRange)
    }

    func textDidChange(_ notification: Notification) {
        ruler?.refresh()
        onEdit?()
    }

    func textViewDidChangeSelection(_ notification: Notification) { reportCaret() }

    private func reportCaret() {
        let location = textView.selectedRange().location
        let line = lineIndex.line(at: location)
        let column = location - lineIndex.start(ofLine: line) + 1
        guard (line, column) != (lastCaret.line, lastCaret.column) else { return }
        lastCaret = (line, column)
        onCaret?(line, column)
    }

    /// Re-colours only the paragraphs the edit touched.
    private func highlight(around edited: NSRange) {
        let string = storage.string as NSString
        guard string.length > 0 else { return }
        let clamped = NSRange(location: min(edited.location, string.length), length: 0)
        let span = NSUnionRange(clamped, NSIntersectionRange(edited, NSRange(location: 0, length: string.length)))
        let paragraphs = string.paragraphRange(for: span)
        storage.addAttribute(.foregroundColor, value: theme.foreground, range: paragraphs)
        string.enumerateSubstrings(in: paragraphs, options: [.byLines]) { line, lineRange, _, _ in
            guard let line else { return }
            for found in SyntaxHighlighter.spans(in: line, language: self.language) {
                self.storage.addAttribute(
                    .foregroundColor, value: self.theme.color(for: found.kind),
                    range: NSRange(location: lineRange.location + found.start, length: found.length))
            }
        }
    }
}
