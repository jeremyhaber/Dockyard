import ConnectionKit
import Foundation

/// What the terminal drawer needs from a remote shell. `ShellChannel` is the real one; `DemoShell` fakes one for screenshots.
protocol ShellBackend: Sendable {
    var output: AsyncStream<Data> { get }
    func write(_ data: Data) async throws
    func resize(cols: Int, rows: Int) async throws
    func close() async
}

extension ShellChannel: ShellBackend {}

/// A scripted shell for demo mode: prints a short session, then echoes typing and answers a few commands.
final class DemoShell: ShellBackend, @unchecked Sendable {
    private struct State {
        var line = ""
        var cwd: String
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

    // MARK: Typing

    private func handle(_ byte: UInt8) {
        switch byte {
        case 13, 10:
            let line = state.withLock { s -> String in
                defer { s.line = "" }
                return s.line
            }
            emit("\r\n")
            run(line.trimmingCharacters(in: .whitespaces))
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
            emit("\u{1B}[01;34mmenu\u{1B}[0m  \u{1B}[01;34mshop\u{1B}[0m  \u{1B}[01;34mwp-content\u{1B}[0m  index.php  order-export.csv  wp-config.php\r\n")
        case "clear":
            emit("\u{1B}[2J\u{1B}[H")
        default:
            emit("bash: \(words[0]): command not found\r\n")
        }
        emit(prompt())
    }

    private func prompt() -> String {
        let cwd = state.withLock { $0.cwd }
        let shown = cwd == home ? "~" : cwd
        let name = elevated ? "root" : user
        return "\u{1B}[01;32m\(name)@\(host)\u{1B}[0m:\u{1B}[01;34m\(shown)\u{1B}[0m\(elevated ? "# " : "$ ")"
    }

    private func emit(_ text: String) { continuation.yield(Data(text.utf8)) }

    private static func intro(host: String, user: String, elevated: Bool, work: String) -> String {
        func prompt(_ name: String, _ dir: String, _ mark: String) -> String {
            "\u{1B}[01;32m\(name)@\(host)\u{1B}[0m:\u{1B}[01;34m\(dir)\u{1B}[0m\(mark)"
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
            "drwxr-xr-x 2 \(owner) www-data 4096 Oct  9 10:02 \u{1B}[01;34mmenu\u{1B}[0m",
            "drwxr-xr-x 2 \(owner) www-data 4096 Oct 24 17:30 \u{1B}[01;34mshop\u{1B}[0m",
            "drwxr-xr-x 4 \(owner) www-data 4096 Oct 23 08:11 \u{1B}[01;34mwp-content\u{1B}[0m",
            "-rw-r--r-- 1 \(owner) www-data  405 Sep 15 12:40 index.php",
            "-rw-r--r-- 1 \(owner) www-data 82144 Oct 24 23:58 order-export.csv",
            "-rw-r----- 1 \(owner) www-data 3201 Oct  5 14:22 wp-config.php",
            prompt(elevated ? "root" : user, work, elevated ? "# " : "$ "),
        ]
        return lines.joined(separator: "\r\n")
    }
}
