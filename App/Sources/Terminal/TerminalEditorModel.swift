import AppKit
import ConnectionKit
import DockyardCore
import Observation

/// Reads and writes the one file an inline editor has open. The real one goes through the connection's file
/// system; demo mode swaps in an in-memory one.
protocol EditorFileStore: Sendable {
    func stat(_ path: String) async throws -> RemoteItem?
    func read(_ path: String) async throws -> Data
    func write(_ data: Data, to path: String) async throws
    func chmod(_ path: String, mode: UInt16) async throws
}

struct RemoteEditorStore: EditorFileStore, @unchecked Sendable {
    let fs: any RemoteFileSystem

    func stat(_ path: String) async throws -> RemoteItem? { try await fs.stat(path) }

    func read(_ path: String) async throws -> Data {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("dockyard-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await fs.download(path, to: temp, progress: Progress(), resume: false)
        return try Data(contentsOf: temp)
    }

    func write(_ data: Data, to path: String) async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("dockyard-save-\(UUID().uuidString)")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        try await fs.upload(temp, to: path, progress: Progress(), resume: false)
    }

    func chmod(_ path: String, mode: UInt16) async throws { try await fs.chmod(path, mode: mode) }
}

/// The editor that takes over a shell tab: one open file, its dirty state, saving and the prompts around closing.
@MainActor @Observable
final class TerminalEditorModel {
    enum Then: Equatable { case close, openInMacEditor, runInTerminal(String) }
    enum Prompt: Equatable {
        case unsaved(Then)
        case conflict(Then?)
        case goToLine
        /// A check before saving found errors; carries what the save was for.
        case problems(Then?)
        /// A manual check (⌘⇧K) found problems.
        case checkResult
        /// `nginx -t` and friends failed after a save.
        case configFailed
    }

    /// What a checker found in the buffer.
    struct CheckReport: Equatable {
        var label: String
        var problems: [CheckProblem]
        var errors: Int { problems.filter { $0.severity == .error }.count }
        var warnings: Int { problems.count - errors }
    }

    /// A config test that failed after a save, with the bytes that were on the server before it.
    struct ConfigFailure: Equatable {
        var test: EditorChecks.ConfigTest
        var lines: [String]
        var previous: Data?
        var then: Then?
    }

    let path: String
    var name: String { RemotePath.lastComponent(of: path) }
    let language: SyntaxLanguage
    /// What kind of file this is: drives comment toggling, checks and config tests.
    let classification: FileClassification
    private(set) var format: TextFormat
    private(set) var isModified = false
    private(set) var isNewFile: Bool
    private(set) var saving = false
    private(set) var line = 1
    private(set) var column = 1
    var error: String?
    var prompt: Prompt?
    /// The last check's findings, for the inline row.
    private(set) var report: CheckReport?
    private(set) var configFailure: ConfigFailure?
    private(set) var checking = false
    /// A small grey line in the bar: "Not checked: no yamllint on server", "nginx -t: syntax OK", ...
    private(set) var note: String?
    var wrap: Bool {
        didSet {
            UserDefaults.standard.set(wrap, forKey: Self.wrapKey)
            view.setWrap(wrap)
        }
    }

    /// The nano-style key legend under the text. Remembered across files and launches.
    var showShortcuts: Bool {
        didSet { UserDefaults.standard.set(showShortcuts, forKey: Self.shortcutsKey) }
    }

    static let wrapKey = "terminalEditorWrap"
    static let shortcutsKey = "terminalEditorShortcutBar"
    /// The editor the user typed (`nano`, `vim`): the shell is waiting on it, so "Open in nano" closes this editor and
    /// lets the real one run. Nil for a file opened from the file browser, which offers a choice of editors instead.
    var typedEditor: String?

    @ObservationIgnored let view: EditorScrollView
    @ObservationIgnored private let store: any EditorFileStore
    @ObservationIgnored private let log: (LogLine.Kind, String) -> Void
    @ObservationIgnored private var document: TextDocument
    @ObservationIgnored private var stamp: RemoteItem?
    @ObservationIgnored private let runner: (any RemoteCommandRunner)?
    @ObservationIgnored private weak var session: ConnectionSession?
    @ObservationIgnored private var noteClearsOnEdit = false
    @ObservationIgnored private var noteToken = 0
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onOpenInMacEditor: (() -> Void)?
    /// Closes this editor and runs the named terminal editor on the file in the shell.
    @ObservationIgnored var onRunInTerminal: ((String) -> Void)?

    private init(
        path: String, document: TextDocument, stamp: RemoteItem?, line: Int?, theme: EditorTheme,
        store: any EditorFileStore, log: @escaping (LogLine.Kind, String) -> Void,
        runner: (any RemoteCommandRunner)?, session: ConnectionSession?
    ) {
        self.runner = runner
        self.session = session
        self.path = path
        self.document = document
        self.stamp = stamp
        self.format = document.format
        self.isNewFile = stamp == nil
        self.store = store
        self.log = log
        let name = RemotePath.lastComponent(of: path)
        let firstLine = String(document.text.prefix(while: { $0 != "\n" }).prefix(200))
        let classification = FileClassification.detect(fileName: name, path: path, firstLine: firstLine)
        self.classification = classification
        var detected = SyntaxLanguage.detect(fileName: name, path: path)
        if detected == .plain {
            // No telling extension: fall back to the `#!` line.
            switch classification.kind {
            case .shell: detected = .shell
            case .python: detected = .python
            case .javascript: detected = .javascript
            case .php: detected = .php
            default: break
            }
        }
        language = detected
        wrap = UserDefaults.standard.object(forKey: Self.wrapKey) as? Bool ?? true
        showShortcuts = UserDefaults.standard.object(forKey: Self.shortcutsKey) as? Bool ?? true
        view = EditorScrollView(theme: theme)
        view.onEdit = { [weak self] in self?.edited() }
        view.onCaret = { [weak self] line, column in
            self?.line = line
            self?.column = column
        }
        view.textView.onSave = { [weak self] in Task { await self?.save() } }
        view.textView.onClose = { [weak self] in self?.requestClose() }
        view.textView.onGoToLine = { [weak self] in self?.prompt = .goToLine }
        view.textView.onToggleComment = { [weak self] in self?.toggleComment() }
        view.textView.onCheck = { [weak self] in Task { await self?.checkNow() } }
        view.textView.onFormat = { [weak self] in self?.formatJSON() }
        let big = document.text.utf8.count > TextDocument.highlightLimit
        view.load(document.text, language: language, highlight: !big)
        view.setWrap(wrap)
        if let line { view.goToLine(line) }
    }

    /// Stats and reads `path`. Nil (with a log line) when the real editor should run instead: a folder, a binary,
    /// a file over 10 MB, or a read error. A missing file opens as an empty buffer that is created on first Save.
    static func open(
        path: String, line: Int?, theme: EditorTheme, store: any EditorFileStore,
        runner: (any RemoteCommandRunner)? = nil, session: ConnectionSession? = nil,
        log: @escaping (LogLine.Kind, String) -> Void
    ) async -> TerminalEditorModel? {
        do {
            let found = try await store.stat(path)
            var document = TextDocument.empty()
            if let found {
                guard !found.isDirectory else { return nil }
                if let size = found.size, size > UInt64(TextDocument.maxBytes) {
                    log(.status, "\(path) is over 10 MB; running the terminal editor instead")
                    return nil
                }
                guard let decoded = TextDocument.decode(try await store.read(path)) else {
                    log(.status, "\(path) looks like a binary file; running the terminal editor instead")
                    return nil
                }
                document = decoded
            }
            return TerminalEditorModel(
                path: path, document: document, stamp: found, line: line, theme: theme, store: store, log: log,
                runner: runner, session: session)
        } catch {
            log(.warning, "Could not open \(path) in the editor: \(error.userMessage)")
            return nil
        }
    }

    // MARK: State

    private func edited() {
        if !isModified { isModified = true }
        error = nil
        if noteClearsOnEdit { note = nil }
    }

    func focus() { view.focusText() }
    func showFind() { view.textView.showFind(replace: false); view.focusText() }
    func goToLine(_ number: Int) { view.goToLine(number) }
    func dismissPrompt() { prompt = nil; focus() }

    // MARK: Save, revert, close

    /// Saves the buffer to `path`. Before writing, the file is checked again; if it changed since it was opened the
    /// conflict prompt appears instead (`overwrite` skips the check). Returns true when the bytes were written.
    @discardableResult
    func save(overwrite: Bool = false, then: Then? = nil, skipCheck: Bool = false) async -> Bool {
        guard !saving else { return false }
        saving = true
        error = nil
        defer { saving = false }
        let text = view.text
        let (data, newFormat) = document.encode(text)
        do {
            if AppSettings.checkBeforeSaving, !skipCheck, let found = await performCheck(data: data, text: text),
               found.errors > 0 {
                report = found
                prompt = .problems(then)
                return false
            }
            if !overwrite {
                let current = try await store.stat(path)
                if Self.changed(from: stamp, to: current) {
                    prompt = .conflict(then)
                    return false
                }
            }
            // What the server holds now, for "Restore previous version" if a config test fails.
            var previous: Data?
            if !isNewFile, Self.configKinds.contains(classification.kind) {
                previous = overwrite ? try? await store.read(path) : document.encode(document.text).data
            }
            try await store.write(data, to: path)
            var after = try? await store.stat(path)
            // Some servers create the file with default permissions when it is replaced; put the old ones back.
            if let wanted = stamp?.permissions, let now = after?.permissions, wanted != now {
                do { try await store.chmod(path, mode: wanted) } catch {
                    log(.warning, "Saved \(path) but could not restore its permissions: \(error.userMessage)")
                }
                after = try? await store.stat(path)
            }
            stamp = after ?? RemoteItem(name: name, path: path, isDirectory: false, size: UInt64(data.count))
            document = document.rebased(on: text, data: data, format: newFormat)
            format = newFormat
            isNewFile = false
            isModified = view.text != text
            prompt = nil
            log(.status, "Saved \(path) (\(data.count) bytes)")
            if await testConfigAfterSave(previous: previous, then: then) { return true }
            if let then { proceed(then) }
            return true
        } catch {
            self.error = "Could not save: \(error.userMessage)"
            log(.warning, "Could not save \(path): \(error.userMessage)")
            return false
        }
    }

    // MARK: Checks, config tests, formatting, comments

    private static let configKinds: Set<EditorFileKind> = [.nginx, .apache, .phpFpm]

    private enum RunResult {
        case done(stdout: String, stderr: String, status: Int32)
        case timedOut
        case failed(String)
    }

    /// Runs one command on the server with a time limit; cancelling it kills the remote process.
    private func run(_ command: String, stdin: Data? = nil, elevated: Bool = false, timeout: TimeInterval) async -> RunResult {
        guard let runner else { return .failed("this connection cannot run commands") }
        return await withTaskGroup(of: RunResult.self) { group in
            group.addTask {
                do {
                    var out = Data(), err = Data(), status: Int32?
                    for try await event in try await runner.execStream(command, elevated: elevated, stdin: stdin) {
                        switch event {
                        case .stdout(let d): out += d
                        case .stderr(let d): err += d
                        case .exit(let s): status = s
                        }
                    }
                    guard let status else { return .failed("the command ended without an exit status") }
                    return .done(
                        stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self), status: status)
                } catch {
                    return .failed(error.userMessage)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    /// The tools on the server, found once per connection with one exec.
    private func serverTools() async -> ServerTools? {
        if let cached = session?.editorTools { return cached }
        guard case .done(let stdout, _, _) = await run(ServerTools.discoveryCommand, timeout: 8) else { return nil }
        let tools = ServerTools.parse(stdout)
        session?.editorTools = tools
        return tools
    }

    /// Shows a grey note in the bar. `transient` ones go away after a few seconds.
    private func setNote(_ text: String?, transient: Bool = false, clearsOnEdit: Bool = false) {
        note = text
        noteClearsOnEdit = clearsOnEdit
        noteToken += 1
        guard transient, text != nil else { return }
        let token = noteToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if let self, self.noteToken == token { self.note = nil }
        }
    }

    private static func summary(_ report: CheckReport) -> String {
        var parts: [String] = []
        if report.errors > 0 { parts.append("\(report.errors) error\(report.errors == 1 ? "" : "s")") }
        if report.warnings > 0 { parts.append("\(report.warnings) warning\(report.warnings == 1 ? "" : "s")") }
        return parts.isEmpty ? "no problems" : parts.joined(separator: ", ")
    }

    /// Runs the checker for this kind of file on `data`, puts markers in the gutter and logs the outcome. Nil when
    /// there is no checker, it is missing on the server, or it did not finish; the bar says why.
    private func performCheck(data: Data, text: String) async -> CheckReport? {
        checking = true
        defer { checking = false }
        let kind = classification.kind
        let localKinds: Set<EditorFileKind> = [.json, .crontab]
        var tools = ServerTools()
        if runner != nil {
            if let found = await serverTools() {
                tools = found
            } else if !localKinds.contains(kind) {
                let probe = EditorChecks.plan(for: classification, fileName: name, path: path, text: text, tools: ServerTools(paths: ["php": "", "python3": "", "node": "", "yamllint": ""]))
                if probe != .none { setNote("Not checked: could not look for tools on the server") }
                return nil
            }
        } else if !localKinds.contains(kind) {
            return nil
        }
        let plan = EditorChecks.plan(for: classification, fileName: name, path: path, text: text, tools: tools)
        var problems: [CheckProblem] = []
        var labels: [String] = []
        switch plan {
        case .none:
            view.setMarkers([])
            return nil
        case .unavailable(let why):
            view.setMarkers([])
            setNote("Not checked: \(why)")
            return nil
        case .local(let label, let found):
            problems = found
            labels = [label]
        case .run(let steps):
            for step in steps {
                switch await run(step.command, stdin: data, timeout: 8) {
                case .timedOut:
                    setNote("Not checked: \(step.label) took too long")
                    log(.status, "Check of \(path) with \(step.label) timed out")
                case .failed(let message):
                    setNote("Not checked: \(message)")
                case .done(let stdout, let stderr, let status):
                    switch EditorChecks.outcome(of: step, stdout: stdout, stderr: stderr, status: status) {
                    case .inconclusive(let message):
                        setNote("Not checked: \(message)")
                        log(.status, "Check of \(path) with \(step.label) was inconclusive")
                    case .problems(let found):
                        problems += found
                        labels.append(step.label)
                    }
                }
                if problems.contains(where: { $0.severity == .error }) { break }
            }
        }
        guard !labels.isEmpty else { view.setMarkers([]); return nil }
        let found = CheckReport(label: labels.joined(separator: ", "), problems: problems)
        view.setMarkers(problems)
        if note?.hasPrefix("Not checked") == true { setNote(nil) }
        log(found.errors > 0 ? .warning : .status, "Checked \(path) with \(found.label): \(Self.summary(found))")
        return found
    }

    /// The Check button / ⌘⇧K: checks the buffer without saving.
    func checkNow() async {
        guard !saving, !checking else { return }
        prompt = nil
        error = nil
        let text = view.text
        let (data, _) = document.encode(text)
        guard let found = await performCheck(data: data, text: text) else {
            if note == nil { setNote("Nothing to check for this kind of file", transient: true) }
            return
        }
        report = found
        if found.problems.isEmpty {
            setNote("No problems found (\(found.label))", transient: true, clearsOnEdit: true)
        } else if found.errors > 0 {
            prompt = .checkResult
        } else {
            setNote("\(Self.summary(found)) (\(found.label))", clearsOnEdit: true)
        }
        focus()
    }

    var problemSummary: String {
        guard let report, !report.problems.isEmpty else { return "" }
        let first = report.problems.first(where: { $0.severity == .error }) ?? report.problems[0]
        let count = report.problems.count
        return "\(count) problem\(count == 1 ? "" : "s") \u{2014} line \(first.line): \(first.message)"
    }

    func goToFirstProblem() {
        guard let report, let first = report.problems.first(where: { $0.severity == .error }) ?? report.problems.first else { return }
        view.goTo(line: first.line, column: first.column)
    }

    func saveAnyway(then: Then?) { Task { await save(then: then, skipCheck: true) } }

    // MARK: Config test

    private func runConfigTest(_ test: EditorChecks.ConfigTest) async -> EditorChecks.ConfigTestResult? {
        let elevated = await runner?.canElevateCommands ?? false
        switch await run(test.command, elevated: elevated, timeout: 20) {
        case .timedOut:
            setNote("Couldn't test the config: \(test.label) took too long")
            return nil
        case .failed(let message):
            setNote("Couldn't test the config: \(message)")
            return nil
        case .done(let stdout, let stderr, let status):
            return EditorChecks.interpretConfigTest(stdout: stdout, stderr: stderr, status: status, elevated: elevated)
        }
    }

    /// After a successful save of an nginx, Apache or PHP-FPM config. True when it failed and the failure row is
    /// showing (the pending close or open waits for the answer).
    private func testConfigAfterSave(previous: Data?, then: Then?) async -> Bool {
        guard Self.configKinds.contains(classification.kind), runner != nil, let tools = await serverTools() else { return false }
        switch EditorChecks.configTest(for: classification.kind, path: path, tools: tools) {
        case .none:
            return false
        case .unavailable(let why):
            setNote("Config not tested: \(why)", clearsOnEdit: true)
            return false
        case .test(let test):
            guard let result = await runConfigTest(test) else { return false }
            switch result {
            case .ok:
                setNote(test.successNote, transient: true)
                log(.status, "Tested \(path) with \(test.label): OK")
                return false
            case .needsRoot:
                setNote("Couldn't test the config: needs root (set su/sudo for this connection)")
                log(.warning, "Could not test \(path) with \(test.label): needs root")
                return false
            case .failed(let lines):
                configFailure = ConfigFailure(test: test, lines: lines, previous: previous, then: then)
                prompt = .configFailed
                log(.warning, "\(test.label) failed after saving \(path)")
                return true
            }
        }
    }

    func keepAfterConfigFailure() {
        let then = configFailure?.then
        configFailure = nil
        prompt = nil
        if let then { proceed(then) } else { focus() }
    }

    /// Writes back the bytes that were on the server before the failed save, then tests again.
    func restorePreviousVersion() async {
        guard let failure = configFailure, let previous = failure.previous, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await store.write(previous, to: path)
            var after = try? await store.stat(path)
            if let wanted = stamp?.permissions, let now = after?.permissions, wanted != now {
                try? await store.chmod(path, mode: wanted)
                after = try? await store.stat(path)
            }
            stamp = after ?? RemoteItem(name: name, path: path, isDirectory: false, size: UInt64(previous.count))
            if let restored = TextDocument.decode(previous) {
                document = restored
                format = restored.format
            }
            isModified = view.text != document.text
            log(.status, "Restored the previous version of \(path)")
        } catch {
            self.error = "Could not restore: \(error.userMessage)"
            log(.warning, "Could not restore \(path): \(error.userMessage)")
            return
        }
        configFailure = nil
        prompt = nil
        guard let result = await runConfigTest(failure.test) else { return }
        switch result {
        case .ok: setNote("Restored the previous version. \(failure.test.successNote)", transient: true)
        case .needsRoot: setNote("Restored the previous version; couldn't test the config: needs root")
        case .failed(let lines):
            setNote("Restored the previous version, but \(failure.test.label) still fails: \(lines.first ?? "")")
        }
    }

    // MARK: Formatting and comments

    var canFormatJSON: Bool { classification.kind.isJSON }

    /// Format JSON (⌥⇧F): one undo step; invalid JSON changes nothing.
    func formatJSON() {
        guard canFormatJSON else { return }
        let text = view.text
        do {
            let formatted = try JSONFormatter.format(text)
            guard formatted != text else {
                setNote("Already formatted", transient: true)
                return
            }
            error = nil
            let line = view.currentLine
            view.applyEdit(range: NSRange(location: 0, length: (text as NSString).length), replacement: formatted, selection: nil)
            view.goTo(line: line, column: nil)
            setNote(nil)
        } catch let failure as JSONFormatter.ParseError {
            error = "Can\u{2019}t format: the JSON is invalid at line \(failure.line), column \(failure.column): \(failure.message)"
            view.setMarkers([CheckProblem(line: failure.line, column: failure.column, message: failure.message, severity: .error)])
            view.goTo(line: failure.line, column: failure.column)
        } catch {
            self.error = "Can\u{2019}t format this file."
        }
    }

    /// Comment or uncomment the caret line or the selected lines (⌘/).
    func toggleComment() {
        let selection = view.textView.selectedRange()
        guard let edit = CommentToggle.toggle(text: view.text, selection: selection, kind: classification.kind) else {
            setNote("No comment syntax for this kind of file", transient: true)
            return
        }
        view.applyEdit(range: edit.range, replacement: edit.replacement, selection: edit.selection)
    }

    /// A different size or modification time (servers round to seconds), or the file appearing or vanishing.
    nonisolated static func changed(from before: RemoteItem?, to after: RemoteItem?) -> Bool {
        switch (before, after) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case (let a?, let b?):
            if a.size != b.size { return true }
            if let x = a.modified, let y = b.modified { return abs(x.timeIntervalSince(y)) >= 1 }
            return false
        }
    }

    /// Throws the buffer away and reads the file again.
    func revert() async {
        error = nil
        prompt = nil
        do {
            let found = try await store.stat(path)
            var next = TextDocument.empty()
            if let found {
                guard let decoded = TextDocument.decode(try await store.read(path)) else {
                    error = "The file on the server is no longer text."
                    return
                }
                next = decoded
            }
            document = next
            stamp = found
            format = next.format
            isNewFile = found == nil
            view.load(next.text, language: language, highlight: next.text.utf8.count <= TextDocument.highlightLimit)
            report = nil
            configFailure = nil
            isModified = false
            focus()
        } catch {
            self.error = "Could not reload: \(error.userMessage)"
        }
    }

    func requestClose() {
        if isModified { prompt = .unsaved(.close) } else { proceed(.close) }
    }

    func requestOpenInMacEditor() {
        if isModified { prompt = .unsaved(.openInMacEditor) } else { proceed(.openInMacEditor) }
    }

    func requestRunInTerminal(_ editor: String) {
        if isModified { prompt = .unsaved(.runInTerminal(editor)) } else { proceed(.runInTerminal(editor)) }
    }

    /// Prompt answers.
    func saveAndProceed(_ then: Then) { Task { await save(then: then) } }
    func discardAndProceed(_ then: Then) { proceed(then) }

    func proceed(_ then: Then) {
        switch then {
        case .close: onClose?()
        case .openInMacEditor: onOpenInMacEditor?()
        case .runInTerminal(let editor): onRunInTerminal?(editor)
        }
    }
}
