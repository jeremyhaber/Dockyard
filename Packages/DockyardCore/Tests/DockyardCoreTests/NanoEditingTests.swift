import Foundation
import Testing
@testable import DockyardCore

@Suite struct NanoEditingTests {
    private let text = "one\ntwo\nthree\n"

    @Test func cutsTheCurrentLine() {
        var nano = NanoEditing()
        let range = nano.cut(in: text, caret: 5, selection: NSRange(location: 5, length: 0))
        #expect(range == NSRange(location: 4, length: 4))
        #expect(nano.buffer == "two\n")
    }

    @Test func consecutiveCutsAppend() {
        var nano = NanoEditing()
        _ = nano.cut(in: text, caret: 0, selection: NSRange(location: 0, length: 0))
        _ = nano.cut(in: "two\nthree\n", caret: 0, selection: NSRange(location: 0, length: 0))
        #expect(nano.buffer == "one\ntwo\n")
        nano.noteOtherAction()
        _ = nano.cut(in: "three\n", caret: 0, selection: NSRange(location: 0, length: 0))
        #expect(nano.buffer == "three\n")
    }

    @Test func pasteReturnsBufferAndEndsAppending() {
        var nano = NanoEditing()
        #expect(nano.paste() == nil)
        _ = nano.cut(in: text, caret: 0, selection: NSRange(location: 0, length: 0))
        #expect(nano.paste() == "one\n")
        _ = nano.cut(in: "two\n", caret: 0, selection: NSRange(location: 0, length: 0))
        #expect(nano.buffer == "two\n")
    }

    @Test func markCutsTheRegion() {
        var nano = NanoEditing()
        nano.toggleMark(at: 2)
        #expect(nano.mark == 2)
        let range = nano.cut(in: text, caret: 6, selection: NSRange(location: 6, length: 0))
        #expect(range == NSRange(location: 2, length: 4))
        #expect(nano.buffer == "e\ntw")
        #expect(nano.mark == nil)
        // Caret before the mark works too.
        nano.toggleMark(at: 6)
        #expect(nano.cut(in: text, caret: 2, selection: NSRange(location: 2, length: 0)) == NSRange(location: 2, length: 4))
    }

    @Test func toggleMarkClears() {
        var nano = NanoEditing()
        nano.toggleMark(at: 3)
        nano.toggleMark(at: 5)
        #expect(nano.mark == nil)
    }

    @Test func selectionCutsWithoutMark() {
        var nano = NanoEditing()
        let range = nano.cut(in: text, caret: 3, selection: NSRange(location: 1, length: 5))
        #expect(range == NSRange(location: 1, length: 5))
    }

    @Test func nothingToCutOnEmptyText() {
        var nano = NanoEditing()
        #expect(nano.cut(in: "", caret: 0, selection: NSRange(location: 0, length: 0)) == nil)
        #expect(nano.cut(in: "a\n", caret: 2, selection: NSRange(location: 2, length: 0)) == nil)
    }

    @Test func markSelection() {
        #expect(NanoEditing.selection(anchor: 4, caret: 9) == NSRange(location: 4, length: 5))
        #expect(NanoEditing.selection(anchor: 9, caret: 4) == NSRange(location: 4, length: 5))
    }
}
