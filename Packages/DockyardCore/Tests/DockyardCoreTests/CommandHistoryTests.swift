import Testing
@testable import DockyardCore

@Suite struct CommandHistoryTests {
    @Test func recordsDedupesAndSkips() {
        var history = CommandHistory()
        let added = [history.record("ls -la"), history.record("pwd"), history.record("ls -la")]
        #expect(added == [true, true, true])
        #expect(history.entries == ["pwd", "ls -la"])
        let skipped = [history.record(""), history.record("   "), history.record(" secret"), history.record("ls -la")]
        #expect(skipped == [false, false, false, false])
        #expect(history.entries.count == 2)
    }

    @Test func capsAtCapacity() {
        var history = CommandHistory()
        for index in 0..<(CommandHistory.capacity + 5) { history.record("cmd \(index)") }
        #expect(history.entries.count == CommandHistory.capacity)
        #expect(history.entries.first == "cmd 5")
    }

    @Test func suggestsNewestThenSnippets() {
        var history = CommandHistory()
        history.record("wp plugin list")
        history.record("wp post list")
        #expect(history.suggestion(for: "wp p") == "ost list")
        #expect(history.suggestion(for: "wp plu") == "gin list")
        #expect(history.suggestion(for: "wp post list") == nil)
        #expect(history.suggestion(for: "") == nil)
        #expect(history.suggestion(for: "WP") == nil)
        #expect(history.suggestion(for: "tail", snippets: ["tail -f log", "tail -n 5\nfoo"]) == " -f log")
        #expect(history.suggestion(for: "tail", snippets: ["tail -n 5\nfoo"]) == nil)
    }

    @Test func nextWord() {
        #expect(CommandHistory.nextWord(of: " -f wp-content/debug.log") == " -f")
        #expect(CommandHistory.nextWord(of: "ail -f x") == "ail")
        #expect(CommandHistory.nextWord(of: "") == "")
        #expect(CommandHistory.nextWord(of: "  ") == "  ")
    }
}
