import XCTest
@testable import DockyardCore

final class EditorCommandTests: XCTestCase {
    private func edit(_ editor: String, _ file: String, line: Int? = nil, sudo: Bool = false) -> EditorCommand {
        .edit(editor: editor, file: file, line: line, sudo: sudo)
    }

    func testPlainEditors() {
        for name in ["nano", "pico", "vi", "vim", "nvim", "emacs", "micro", "joe", "jed", "mcedit", "ne", "hx", "kak"] {
            XCTAssertEqual(EditorCommand.parse("\(name) app.ini"), edit(name, "app.ini"), name)
        }
        XCTAssertEqual(EditorCommand.parse("  vim   a.txt  "), edit("vim", "a.txt"))
    }

    func testFileArgumentIsKeptAsTyped() {
        XCTAssertEqual(EditorCommand.parse("vim ~/.bashrc"), edit("vim", "~/.bashrc"))
        XCTAssertEqual(EditorCommand.parse("vim \"my file.txt\""), edit("vim", "\"my file.txt\""))
        XCTAssertEqual(EditorCommand.parse("vim my\\ file.txt"), edit("vim", "my\\ file.txt"))
        XCTAssertEqual(EditorCommand.parse("vim $HOME/x"), edit("vim", "$HOME/x"))
        XCTAssertEqual(EditorCommand.parse("vim '/a;b|c'"), edit("vim", "'/a;b|c'"))
    }

    func testLineNumbersAndFlags() {
        XCTAssertEqual(EditorCommand.parse("vim +42 f"), edit("vim", "f", line: 42))
        XCTAssertEqual(EditorCommand.parse("nano +42:3 f"), edit("nano", "f", line: 42))
        XCTAssertEqual(EditorCommand.parse("nano f +7"), edit("nano", "f", line: 7))
        XCTAssertEqual(EditorCommand.parse("nano -w f"), edit("nano", "f"))
        XCTAssertEqual(EditorCommand.parse("emacs -nw f"), edit("emacs", "f"))
        XCTAssertNil(EditorCommand.parse("vim +/foo f"))
        XCTAssertNil(EditorCommand.parse("vim + f"))
        XCTAssertNil(EditorCommand.parse("vim +0 f"))
        XCTAssertNil(EditorCommand.parse("vim +1 +2 f"))
    }

    func testSudo() {
        XCTAssertEqual(EditorCommand.parse("sudo vim /etc/hosts"), edit("vim", "/etc/hosts", sudo: true))
        XCTAssertEqual(EditorCommand.parse("sudoedit /etc/hosts"), edit("sudoedit", "/etc/hosts", sudo: true))
        XCTAssertEqual(EditorCommand.parse("sudo -e /etc/hosts"), edit("sudoedit", "/etc/hosts", sudo: true))
        XCTAssertNil(EditorCommand.parse("sudo -u bob vim f"))
        XCTAssertNil(EditorCommand.parse("sudo -e a b"))
        XCTAssertNil(EditorCommand.parse("sudo ls"))
    }

    func testCrontab() {
        XCTAssertEqual(EditorCommand.parse("crontab -e"), .crontab)
        XCTAssertNil(EditorCommand.parse("crontab -e -u bob"))
        XCTAssertNil(EditorCommand.parse("crontab -l"))
        XCTAssertNil(EditorCommand.parse("sudo crontab -e"))
    }

    func testRunsNormally() {
        for line in [
            "vim", "vim a b", "vim -R f", "vim -", "vim -c q f", "nano -x f", "view f", "less f", "vimdiff a b",
            "vim f | cat", "vim f; ls", "vim f && ls", "vim f > out", "vim f &", "vim $(which x)", "vim `x`",
            "vim f # note", "vim \"unclosed", "vim 'unclosed", "vim f\\", "vim !$", "cat f", "", "   ",
            "\\vim f", "command vim f", "FOO=1 vim f", "/usr/bin/vim f", "vim (f)", "ls vim f",
        ] {
            XCTAssertNil(EditorCommand.parse(line), line)
        }
    }
}
