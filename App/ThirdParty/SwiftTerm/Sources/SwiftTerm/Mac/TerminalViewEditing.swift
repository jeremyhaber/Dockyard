//
//  TerminalViewEditing.swift
//
//  Dockyard addition: what a subclass needs to edit the shell's command line with the mouse.
//
#if os(macOS)
import AppKit

extension TerminalView {
    /// The cell under a point in view coordinates. Rows count from the start of the scrollback.
    public func bufferPosition(at point: CGPoint) -> Position {
        calculateMouseHit(at: point).grid
    }

    /// The selected cells, start before end (end exclusive), or nil when nothing is selected.
    public var selectedCells: (start: Position, end: Position)? {
        guard selection.active, selection.hasSelectionRange else { return nil }
        let start = selection.start, end = selection.end
        return Position.compare(start, end) == .after ? (end, start) : (start, end)
    }
}

extension Terminal {
    /// The cursor. Rows count from the start of the scrollback, like `TerminalView.bufferPosition(at:)`.
    public var cursorBufferPosition: Position {
        Position(col: buffer.x, row: buffer.yBase + buffer.y)
    }
}
#endif
