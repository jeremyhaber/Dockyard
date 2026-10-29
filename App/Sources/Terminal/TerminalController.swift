import AppKit
import ConnectionKit
import DockyardCore
import Observation
import SwiftTerm

/// Receives SwiftTerm's callbacks (on the main thread) and forwards them to closures.
final class TerminalHost: NSObject, TerminalViewDelegate, @unchecked Sendable {
    var onSend: (@Sendable ([UInt8]) -> Void)?
    var onResize: (@Sendable (Int, Int) -> Void)?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { onResize?(newCols, newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { onSend?(Array(data)) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// One terminal per connection: the SwiftTerm view, the shell channel behind it and the snippets for the toolbar.
@MainActor @Observable
final class TerminalController {
    enum Phase: Equatable {
        case idle, starting, running, ended
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var snippets: [Snippet] = []

    @ObservationIgnored let view: TerminalView
    @ObservationIgnored private let host = TerminalHost()
    @ObservationIgnored private let input: AsyncStream<[UInt8]>.Continuation
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var shell: (any ShellBackend)?
    @ObservationIgnored private weak var session: ConnectionSession?

    init(session: ConnectionSession) {
        self.session = session
        let view = ShellTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 220))
        view.nativeBackgroundColor = Palette.ns("DrawerBg")
        view.nativeForegroundColor = NSColor(white: 0.88, alpha: 1)
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.setAccessibilityLabel("Terminal for \(session.connection.name)")
        view.terminalDelegate = host
        self.view = view

        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .unbounded)
        input = continuation
        host.onSend = { bytes in continuation.yield(bytes) }
        host.onResize = { [weak self] cols, rows in
            Task { @MainActor in self?.resize(cols: cols, rows: rows) }
        }
        // Keystrokes are written one after another so they cannot be reordered.
        inputTask = Task { [weak self] in
            for await bytes in stream { await self?.write(bytes) }
        }
    }

    deinit {
        input.finish()
        inputTask?.cancel()
        runTask?.cancel()
    }

    // MARK: Lifecycle

    func start() {
        guard let session, phase != .starting, phase != .running else { return }
        phase = .starting
        let terminal = view.getTerminal()
        let cols = terminal.cols, rows = terminal.rows
        runTask?.cancel()
        runTask = Task { [weak self] in
            do {
                let opened = try await session.openShell(cols: cols, rows: rows)
                guard let self else { return }
                self.shell = opened
                self.phase = .running
                // The view usually got its real size while the shell was opening, and that resize had no shell to
                // go to. A shell left at the old width wraps lines in the wrong place and the caret jumps around.
                let current = self.view.getTerminal()
                if current.cols != cols || current.rows != rows { self.resize(cols: current.cols, rows: current.rows) }
                for await data in opened.output {
                    self.view.feed(byteArray: ArraySlice(data))
                }
                if self.shell != nil {
                    self.view.feed(text: "\r\n[Shell closed]\r\n")
                    self.shell = nil
                    self.phase = .ended
                }
            } catch is CancellationError {
                return
            } catch {
                self?.phase = .failed(error.userMessage)
            }
        }
    }

    func restart() {
        Task {
            await self.stop()
            self.view.feed(text: "\u{1B}[2J\u{1B}[H")
            self.start()
        }
    }

    func stop() async {
        runTask?.cancel()
        runTask = nil
        let current = shell
        shell = nil
        phase = .idle
        await current?.close()
    }

    func focus() { view.window?.makeFirstResponder(view) }

    // MARK: Input

    private func write(_ bytes: [UInt8]) async {
        guard let shell else { return }
        try? await shell.write(Data(bytes))
    }

    private func resize(cols: Int, rows: Int) {
        guard let current = shell, cols > 0, rows > 0 else { return }
        Task { try? await current.resize(cols: cols, rows: rows) }
    }

    /// Types text into the shell. `run` presses Return afterwards.
    func type(_ text: String, run: Bool = false) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r")
        input.yield(Array((run ? normalized + "\r" : normalized).utf8))
        focus()
    }

    /// `cd '<folder>'` for the active server folder, with single quotes escaped.
    func changeDirectory(to path: String) {
        type("cd \(Self.shellQuote(path))", run: true)
    }

    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Snippets

    func reloadSnippets(from repository: SnippetRepository) async {
        guard let id = session?.connection.id else { return }
        snippets = (try? await repository.snippets(for: id)) ?? []
    }
}
