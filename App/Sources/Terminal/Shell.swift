import ConnectionKit
import DockyardCore
import Foundation

/// What the terminal drawer needs from a remote shell. `ShellChannel` is the real one; `DemoShell` fakes one for screenshots.
protocol ShellBackend: Sendable {
    var output: AsyncStream<Data> { get }
    func write(_ data: Data) async throws
    func resize(cols: Int, rows: Int) async throws
    func close() async
    /// Calls `handler` once the automatic `su -` / `sudo -i` has produced its new shell. False when none is starting.
    func onElevated(_ handler: @escaping @Sendable () -> Void) -> Bool
}

extension ShellChannel: ShellBackend {}

/// A scripted shell for demo mode: prints a short session, then echoes typing and answers a few commands.
final class DemoShell: ShellBackend, @unchecked Sendable {
    private struct State {
        var line = ""
        /// True after an editor command reported to Dockyard: input is a silent reply line, like the real shell function.
        var waiting = false
        /// Phase two of the editor hook: the script body is being read (like `cat`) until Ctrl-D.
        var slurping = false
        var cwd: String
        /// 0 outside an escape sequence, 1 after ESC, 2 inside `ESC [` or `ESC O`.
        var escape = 0
    }

    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let state: LockedBox<State>
    private let host: String
    private let user: String
    private let elevated: Bool
    private let home: String

    init(host: String, user: String, elevated: Bool) {
        let shortHost = host.split(separator: ".").first.map(String.init) ?? host
        self.host = shortHost
        self.user = user
        self.elevated = elevated
        self.home = elevated ? "/root" : "/home/\(user)"
        let work = "/home/\(user)/public_html"
        (output, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        state = LockedBox(State(cwd: work))
        emit(Self.intro(host: shortHost, user: user, elevated: elevated, work: work))
    }

    func write(_ data: Data) async throws {
        for byte in data { handle(byte) }
    }

    func resize(cols: Int, rows: Int) async throws {}

    func close() async { continuation.finish() }

    func onElevated(_ handler: @escaping @Sendable () -> Void) -> Bool { false }

    // MARK: Typing

    private func handle(_ byte: UInt8) {
        // Arrow keys and the like arrive as escape sequences; this shell has no line editor, so it drops them.
        let inEscape = state.withLock { s -> Bool in
            switch (s.escape, byte) {
            case (0, 27): s.escape = 1
            case (1, 91), (1, 79): s.escape = 2
            case (1, _): s.escape = 0
            case (2, 0x40...0x7E): s.escape = 0
            case (2, _): break
            default: return false
            }
            return true
        }
        if inEscape { return }
        if state.withLock({ $0.slurping }) {
            if byte == 4 {
                state.withLock { $0.slurping = false }
                emit("\u{1B}]7734;ready\u{07}" + prompt())
            }
            return
        }
        if state.withLock({ $0.waiting }) {
            switch byte {
            case 13, 10:
                let reply = state.withLock { s -> String in
                    defer { s.line = ""; s.waiting = false }
                    return s.line
                }
                if reply != "e" { emit("[demo: the real editor would run here]\r\n") }
                emit(prompt())
            case 3:
                state.withLock { $0.line = ""; $0.waiting = false }
                emit("^C\r\n" + prompt())
            case 32...126:
                state.withLock { $0.line.append(Character(UnicodeScalar(byte))) }
            default:
                break
            }
            return
        }
        switch byte {
        case 13, 10:
            let line = state.withLock { s -> String in
                defer { s.line = "" }
                return s.line
            }
            emit("\r\n")
            run(line.trimmingCharacters(in: .whitespaces))
        case 21:
            // Ctrl-U: the line is cleared.
            state.withLock { $0.line = "" }
            emit("\r\u{1B}[2K" + prompt())
        case 127, 8:
            let removed = state.withLock { s -> Bool in
                guard !s.line.isEmpty else { return false }
                s.line.removeLast()
                return true
            }
            if removed { emit("\u{8} \u{8}") }
        case 3:
            state.withLock { $0.line = "" }
            emit("^C\r\n" + prompt())
        case 32...126:
            let character = Character(UnicodeScalar(byte))
            state.withLock { $0.line.append(character) }
            emit(String(character))
        default:
            break
        }
    }

    private func run(_ line: String) {
        let words = line.split(separator: " ", maxSplits: 1).map(String.init)
        if line.contains("7734;go") {
            // Dockyard's injection line: report go, then swallow the script body until Ctrl-D and report ready.
            state.withLock { $0.slurping = true }
            emit("\u{1B}]7734;go\u{07}")
            return
        }
        if let report = editorReport(line) {
            state.withLock { $0.waiting = true }
            emit(report)
            return
        }
        switch words.first ?? "" {
        case "":
            break
        case "cd":
            let target = (words.count > 1 ? words[1] : home).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            state.withLock { $0.cwd = target.isEmpty ? home : target }
        case "pwd":
            emit(state.withLock { $0.cwd } + "\r\n")
        case "whoami":
            emit((elevated ? "root" : user) + "\r\n")
        case "ls":
            emit("\u{1B}[1;94mmenu\u{1B}[0m  \u{1B}[1;94mshop\u{1B}[0m  \u{1B}[1;94mwp-content\u{1B}[0m  index.php  order-export.csv  wp-config.php\r\n")
        case "clear":
            emit("\u{1B}[2J\u{1B}[H")
        default:
            emit("bash: \(words[0]): command not found\r\n")
        }
        emit(prompt())
    }

    /// What the shell functions Dockyard defines would print for `nano file`, `sudo vim file`, `sudoedit file` or `crontab -e`.
    private func editorReport(_ line: String) -> String? {
        var words = line.split(separator: " ").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        guard let first = words.first else { return nil }
        let kind: String
        if first == "crontab", words == ["crontab", "-e"] {
            kind = "crontab"
        } else if first == "sudoedit" {
            kind = "sudo"
        } else if first == "sudo", words.count > 1, words[1] == "-e" || EditorShellHook.editors.contains(words[1]) {
            kind = "sudo"
        } else if EditorShellHook.editors.contains(first) {
            kind = "edit"
        } else {
            return nil
        }
        let name = words.removeFirst()
        let cwd = state.withLock { $0.cwd }
        let who = "\(elevated ? "root" : user)@\(host)"
        let fields = [kind, name, who, cwd, String(words.count)] + words
        return "\u{1B}]\(EditorShellHook.requestOSC);" + fields.joined(separator: "\u{7F}") + "\u{07}"
    }

    private func prompt() -> String {
        let cwd = state.withLock { $0.cwd }
        let shown = cwd == home ? "~" : cwd
        let name = elevated ? "root" : user
        return "\u{1B}[01;32m\(name)@\(host)\u{1B}[0m:\u{1B}[1;94m\(shown)\u{1B}[0m\(elevated ? "# " : "$ ")"
    }

    private func emit(_ text: String) { continuation.yield(Data(text.utf8)) }

    private static func intro(host: String, user: String, elevated: Bool, work: String) -> String {
        func prompt(_ name: String, _ dir: String, _ mark: String) -> String {
            "\u{1B}[01;32m\(name)@\(host)\u{1B}[0m:\u{1B}[1;94m\(dir)\u{1B}[0m\(mark)"
        }
        var lines: [String] = ["Last login: Sat Oct 24 09:12:41 2026 from 203.0.113.7"]
        if elevated {
            lines.append(prompt(user, "~", "$ ") + "sudo -i")
            lines.append(prompt("root", "~", "# ") + "cd '\(work)'")
            lines.append(prompt("root", work, "# ") + "ls -l")
        } else {
            lines.append(prompt(user, "~", "$ ") + "cd '\(work)'")
            lines.append(prompt(user, work, "$ ") + "ls -l")
        }
        let owner = elevated ? "root" : user
        lines += [
            "total 28",
            "drwxr-xr-x 2 \(owner) www-data 4096 Oct  9 10:02 \u{1B}[1;94mmenu\u{1B}[0m",
            "drwxr-xr-x 2 \(owner) www-data 4096 Oct 24 17:30 \u{1B}[1;94mshop\u{1B}[0m",
            "drwxr-xr-x 4 \(owner) www-data 4096 Oct 23 08:11 \u{1B}[1;94mwp-content\u{1B}[0m",
            "-rw-r--r-- 1 \(owner) www-data  405 Sep 15 12:40 index.php",
            "-rw-r--r-- 1 \(owner) www-data 82144 Oct 24 23:58 order-export.csv",
            "-rw-r----- 1 \(owner) www-data 3201 Oct  5 14:22 wp-config.php",
            prompt(elevated ? "root" : user, work, elevated ? "# " : "$ "),
        ]
        return lines.joined(separator: "\r\n")
    }
}
