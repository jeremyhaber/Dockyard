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
    /// The inline file editor that has taken over this tab, or nil while the terminal shows. At most one.
    private(set) var editor: TerminalEditorModel?

    /// Stable tab title ("Shell 1"), numbered by creation.
    @ObservationIgnored let id = UUID()
    @ObservationIgnored let title: String
    @ObservationIgnored let view: TerminalView
    @ObservationIgnored private let shellView: ShellTerminalView
    @ObservationIgnored private let host = TerminalHost()
    @ObservationIgnored private let input: AsyncStream<[UInt8]>.Continuation
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var shell: (any ShellBackend)?
    @ObservationIgnored private weak var session: ConnectionSession?
    /// Opens the visual crontab editor when `crontab -e` is typed. Nil runs the real command.
    @ObservationIgnored var onEditCrontab: (() -> Void)?
    /// Hides the shell's output between sending the hook line and its ready marker.
    @ObservationIgnored private var filter = InjectionOutputFilter()
    @ObservationIgnored private var hideTimeout: Task<Void, Never>?
    @ObservationIgnored private var heldKeys: [UInt8] = []
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    /// The hook line is due: the shell has started (or a new one after `su -`) and has not got it yet.
    @ObservationIgnored private var injectionWanted = false
    /// Whether the login shell can take the hook line (nil until asked).
    @ObservationIgnored private var hookShellOK: Bool?
    /// A shell function is blocked waiting for Dockyard's one-line reply.
    @ObservationIgnored private var awaitingReply = false
    /// Who the file connection runs as (`id -un`) and the server's `hostname`, asked once over the SSH connection.
    @ObservationIgnored private var serverIdentity: (user: String, host: String)?

    init(session: ConnectionSession, title: String = "Shell 1") {
        self.session = session
        self.title = title
        let view = ShellTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 220))
        view.nativeBackgroundColor = Palette.ns("DrawerBg")
        view.nativeForegroundColor = NSColor(white: 0.88, alpha: 1)
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.setAccessibilityLabel("Terminal for \(session.connection.name)")
        view.terminalDelegate = host
        self.view = view
        shellView = view

        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .unbounded)
        input = continuation
        // SwiftTerm calls this on the main thread.
        host.onSend = { [weak self] bytes in
            MainActor.assumeIsolated {
                if let self { self.userInput(bytes) } else { continuation.yield(bytes) }
            }
        }
        host.onResize = { [weak self] cols, rows in
            Task { @MainActor in self?.resize(cols: cols, rows: rows) }
        }
        // Keystrokes are written one after another so they cannot be reordered.
        inputTask = Task { [weak self] in
            for await bytes in stream { await self?.write(bytes) }
        }
        view.onCommand = { [weak self] text in self?.record(text) }
        view.suggest = { [weak self] typed in self?.suggestion(for: typed) }
        view.isLive = { [weak self] in self?.phase == .running && self?.awaitingReply != true }
        view.getTerminal().registerOscHandler(code: EditorShellHook.requestOSC) { [weak self] data in
            let payload = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.handleEditRequest(payload) }
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
        filter = InjectionOutputFilter()
        injectionWanted = false
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
                self.prepareEditorHook(for: opened)
                for await data in opened.output {
                    self.show(Array(data))
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
        settleTask?.cancel()
        hideTimeout?.cancel()
        awaitingReply = false
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
        if run { shellView.resetInput() } else { shellView.beginInput() }
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

    // MARK: Editor hook

    private var editorChoice: AppSettings.TerminalEditorChoice { AppSettings.terminalEditorChoice }

    private var handling: EditorHandling {
        switch editorChoice {
        case .dockyard: .inline
        case .terminal: .runInTerminal
        default: .macEditor
        }
    }

    /// Shell output goes through the filter, which holds it back while the hook line is being sent.
    private func show(_ bytes: [UInt8]) {
        let wasHiding = filter.isHiding
        let visible = filter.process(bytes)
        if wasHiding, !filter.isHiding {
            hideTimeout?.cancel()
            shellView.resetInput()
            session?.log.append(.status, "Editor hook ready in \(title)")
            releaseHeldKeys()
        }
        if !visible.isEmpty { shellView.feedOutput(ArraySlice(visible)) }
        if filter.takeGo() { sendHookBody() }
        if injectionWanted { armInjection() }
    }

    /// Wants the hook line once the shell is up: now for a plain shell, after the new shell for `su -` / `sudo -i`.
    private func prepareEditorHook(for shell: any ShellBackend) {
        let elevating = shell.onElevated { [weak self] in
            Task { @MainActor in self?.wantInjection() }
        }
        if !elevating { wantInjection() }
    }

    private func wantInjection() {
        guard editorChoice != .terminal else { return }
        injectionWanted = true
        armInjection()
    }

    /// Waits for the output to go quiet (the prompt is up), then sends the hook line.
    private func armInjection() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.injectHook()
        }
    }

    private func injectHook() async {
        guard injectionWanted, phase == .running, editorChoice != .terminal, !filter.isHiding, !awaitingReply,
              editor == nil, session?.fs != nil else { return }
        if shellView.hasTypedText { return armInjection() }
        if hookShellOK == nil { hookShellOK = await loginShellSupportsHook() }
        guard hookShellOK == true, injectionWanted, phase == .running, !shellView.hasTypedText else { return }
        injectionWanted = false
        filter.begin()
        // Phase one: a short line, in one write. It is the only part the shell's line editor sees.
        input.yield(Array(EditorShellHook.goLine().utf8) + [13])
        hideTimeout?.cancel()
        hideTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.filter.isHiding else { return }
            self.abortHook("did not report go")
        }
    }

    /// Phase two, after the `go` marker: the shell runs `cat` on the terminal (canonical mode, no line editor), so the
    /// script goes in as plain lines, then Ctrl-D. `eval` runs it, and its last statement reports ready.
    private func sendHookBody() {
        guard filter.isHiding else { return }
        hideTimeout?.cancel()
        let lines = EditorShellHook.bodyLines()
        Task { [input] in
            for line in lines {
                input.yield(Array((line + "\n").utf8))
                try? await Task.sleep(for: .milliseconds(5))
            }
            input.yield(Array(EditorShellHook.endOfBody.utf8))
        }
        hideTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.filter.isHiding else { return }
            // Still in `cat` or `eval`: interrupt it so the shell is usable again.
            self.input.yield([3])
            self.abortHook("did not report ready")
        }
    }

    private func abortHook(_ what: String) {
        let seen = filter.hiddenSummary
        filter.abort()
        session?.log.append(.warning, "Editor hook \(what) in \(title); showing shell output again"
                            + (seen.isEmpty ? " (the shell printed nothing)" : ". The shell printed: \(seen.prefix(300))"))
        releaseHeldKeys()
    }

    /// Keys typed while the hook line is going out wait, so they cannot land in the middle of it.
    private func userInput(_ bytes: [UInt8]) {
        if filter.isHiding { heldKeys += bytes } else { input.yield(bytes) }
    }

    private func releaseHeldKeys() {
        guard !heldKeys.isEmpty else { return }
        input.yield(heldKeys)
        heldKeys = []
    }

    /// False for fish, csh and tcsh (no POSIX functions). When `$SHELL` cannot be read (restricted shells may refuse
    /// exec), the line is tried anyway; a shell that cannot run it never sends the ready marker and hiding times out.
    private func loginShellSupportsHook() async -> Bool {
        if DemoMode.isEnabled { return true }
        guard let runner = session?.fs as? any RemoteCommandRunner,
              let result = try? await runner.exec("echo $SHELL"), result.exitStatus == 0 else { return true }
        let path = String(decoding: result.stdout, as: UTF8.self)
        guard HookShell.detect(shellPath: path) != nil else {
            session?.log.append(.status, "Editor hook skipped: login shell is \(path.trimmingCharacters(in: .whitespacesAndNewlines))")
            return false
        }
        return true
    }

    private func sendReply(handled: Bool) {
        guard awaitingReply else { return }
        awaitingReply = false
        input.yield(Array((handled ? EditorShellHook.handledReply : EditorShellHook.runRealReply).utf8))
    }

    /// A shell function (`nano`, `sudo vim`, `crontab -e`...) reported what the user typed and is blocked until
    /// Dockyard answers `e` (handled) or `r` (run the real command). Always answers exactly once.
    private func handleEditRequest(_ payload: String) {
        guard !awaitingReply else { return }
        guard let request = EditorRequest.parse(payload: payload) else {
            // Something printed the OSC that is not a well-formed request; answer only if a function sent it.
            if ["edit", "sudo", "crontab"].contains(where: { payload.hasPrefix($0 + String(EditorShellHook.separator)) }) {
                awaitingReply = true
                runReal("the request from the shell could not be read")
            }
            return
        }
        awaitingReply = true
        shellView.resetInput()
        Task { @MainActor in
            guard let session, phase == .running else { return runReal("the shell is not running") }
            guard editor == nil else { return runReal("an editor is already open in this tab") }
            if let problem = await verify(user: request.user, host: request.host, sudo: request.command?.isSudo ?? false,
                                          session: session) {
                return runReal(problem)
            }
            switch EditorDecision.decide(request, handling: handling) {
            case .runReal:
                runReal(handling == .runInTerminal ? "Settings say to run editors in the terminal"
                        : request.command == nil ? "Dockyard's editor needs exactly one file name (no other options)"
                        : "the file path could not be worked out")
            case .editCrontab:
                if let onEditCrontab {
                    onEditCrontab()
                    sendReply(handled: true)
                } else { runReal("the cron editor is not available here") }
            case .openMacEditor(let path, _):
                let opened = await openInEditor(path, session: session)
                if opened { sendReply(handled: true) } else { runReal("\(path) could not be opened in the Mac editor") }
            case .openInline(let path, let line, _):
                // The reply goes out when the editor closes, so the shell prompt comes back then, like a real nano.
                if !(await openInlineEditor(path, line: line, typedEditor: Self.displayName(of: request))) {
                    runReal("\(path) cannot be edited here (a folder, a binary, over 10 MB, or unreadable)")
                }
            }
        }
    }

    /// Lets the real editor run, and says why in the connection log so a surprise nano can be explained.
    private func runReal(_ reason: String) {
        session?.log.append(.status, "Running the real editor: \(reason)")
        sendReply(handled: false)
    }

    /// What the user typed, for the "Open in nano" button.
    private static func displayName(of request: EditorRequest) -> String {
        guard request.kind == .sudo else { return request.name }
        if request.name == "sudoedit" { return "sudoedit" }
        let first = request.arguments.first ?? ""
        return first == "-e" ? "sudo -e" : first
    }

    /// The shell must be on the machine and account the file browser uses, or the user is browsing as root; `sudo`
    /// forms need root browsing, since the file browser could not write what sudo would.
    /// Nil when it may open, else why not.
    private func verify(user: String, host: String, sudo: Bool, session: ConnectionSession) async -> String? {
        if DemoMode.isEnabled { return nil }
        if sudo, !session.browsingAsRoot { return "sudo needs the file browser to browse as root" }
        // Asked over the file connection rather than taken from the saved login: hosts such as Cloudways map an
        // app login (simplistics-rmj) onto the account that owns the files (qukzervazs).
        if serverIdentity == nil, let runner = session.fs as? any RemoteCommandRunner,
           let result = try? await runner.exec("id -un; hostname"), result.exitStatus == 0 {
            let lines = String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty { serverIdentity = (lines[0], lines[1]) }
        }
        guard let serverIdentity else { return "the file connection's user and hostname could not be read" }
        guard serverIdentity.host == host else { return "the shell is on \(host), not \(serverIdentity.host)" }
        guard user == serverIdentity.user || session.browsingAsRoot else {
            return "the shell user \(user) is not the file connection's user \(serverIdentity.user)"
        }
        return nil
    }

    /// Replaces the terminal in this tab with Dockyard's own editor on `path`. False when the real editor should run
    /// instead (a folder, a binary, over 10 MB, an unreadable file). A missing file opens empty and is created on Save.
    func openInlineEditor(_ path: String, line: Int? = nil, typedEditor: String? = nil) async -> Bool {
        guard let session, let fs = session.fs else { return false }
        if let editor {
            if editor.path != path {
                AppModel.shared.showToast("Close \(editor.name) before opening another file", symbol: "square.and.pencil")
            }
            return true
        }
        let store: any EditorFileStore = DemoMode.isEnabled ? DemoEditorStore.shared : RemoteEditorStore(fs: fs)
        let theme = EditorTheme(
            background: view.nativeBackgroundColor, foreground: view.nativeForegroundColor, font: view.font)
        let runner: (any RemoteCommandRunner)? = DemoMode.isEnabled ? DemoEditorRunner.shared : fs as? any RemoteCommandRunner
        guard let model = await TerminalEditorModel.open(
            path: path, line: line, theme: theme, store: store, runner: runner, session: session, log: { [weak session] kind, message in
                session?.log.append(kind, message)
            }) else { return false }
        model.typedEditor = typedEditor
        model.onClose = { [weak self] in self?.closeEditor() }
        model.onRunInTerminal = { [weak self] editor in
            guard let self else { return }
            if self.awaitingReply, editor == typedEditor {
                self.closeEditor(handled: false)
            } else {
                self.closeEditor(handled: true)
                self.type("command \(editor) \(Self.shellQuote(path))", run: true)
            }
        }
        model.onOpenInMacEditor = { [weak self] in
            guard let self, let session = self.session else { return }
            Task { @MainActor in
                if await self.openInEditor(path, session: session) { self.closeEditor() } else {
                    model.error = "Could not hand the file to the Mac editor."
                }
            }
        }
        editor = model
        session.log.append(.status, "Opened \(path) in the terminal editor")
        return true
    }

    /// Returns to the terminal with the keyboard focus.
    func closeEditor(handled: Bool = true) {
        editor = nil
        sendReply(handled: handled)
        DispatchQueue.main.async { [weak self] in self?.focus() }
    }

    /// Opens a server file in the Mac editor, creating it empty when it does not exist. False when it should be
    /// left to the real editor (a folder, or a stat error).
    private func openInEditor(_ path: String, session: ConnectionSession) async -> Bool {
        guard let fs = session.fs else { return false }
        var item: RemoteItem
        do {
            if let found = try await fs.stat(path) {
                guard !found.isDirectory else { return false }
                item = found
            } else {
                let empty = FileManager.default.temporaryDirectory.appendingPathComponent("dockyard-new-\(UUID().uuidString)")
                try Data().write(to: empty)
                defer { try? FileManager.default.removeItem(at: empty) }
                try await fs.upload(empty, to: path, progress: Progress(), resume: false)
                item = RemoteItem(name: RemotePath.lastComponent(of: path), path: path, isDirectory: false)
                session.log.append(.status, "Created empty \(path) to edit")
            }
        } catch RemoteError.notFound {
            return false
        } catch {
            session.log.append(.warning, "Could not open \(path) in the editor app: \(error.userMessage)")
            return false
        }
        AppModel.shared.edits.edit(item, in: session)
        let app = AppSettings.editorURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        session.log.append(.status, "Terminal editor command opened \(path) in \(app ?? "the default app")")
        AppModel.shared.showToast(
            "Opened \(item.name) in \(app ?? "the default app"): saves upload to the server", symbol: "square.and.pencil")
        return true
    }

    // MARK: Suggestions

    private var suggestionsEnabled: Bool {
        UserDefaults.standard.object(forKey: AppSettings.terminalSuggestions) as? Bool ?? true
    }

    private func record(_ text: String) {
        guard suggestionsEnabled, let id = session?.connection.id else { return }
        CommandHistoryStore.shared.record(text, for: id)
    }

    /// The rest of the newest history entry (then snippet) that starts with `typed`.
    private func suggestion(for typed: String) -> String? {
        guard suggestionsEnabled, let id = session?.connection.id else { return nil }
        return CommandHistoryStore.shared.history(for: id).suggestion(for: typed, snippets: snippets.map(\.command))
    }

    // MARK: Snippets

    func reloadSnippets(from repository: SnippetRepository) async {
        guard let id = session?.connection.id else { return }
        snippets = (try? await repository.snippets(for: id)) ?? []
    }
}
