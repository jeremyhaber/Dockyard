import ConnectionKit
import DockyardCore
import Foundation
import Observation

/// State behind the cron editor sheet: the server's crontab, the user's edits, and loading and saving.
@MainActor @Observable
final class CronEditorModel {
    enum Mode: Hashable { case jobs, text }
    enum Phase: Equatable { case loading, ready, failed(String) }

    let session: ConnectionSession
    private let runner: any RemoteCommandRunner

    private(set) var phase: Phase = .loading
    var mode: Mode = .jobs
    /// The visual model. In text mode `rawText` is the source of truth until the user switches back.
    var crontab = Crontab()
    var rawText = ""
    private(set) var clock: CronServerClock?
    private var clockFetchedAt = Date()
    /// What the server held at the last load or save; the baseline for unsaved changes and conflicts.
    private(set) var loadedText = ""
    /// What the server held when the sheet opened, to undo a save made in this session.
    private(set) var sessionOriginal: String?
    var elevated = false
    private(set) var canElevate = false
    private(set) var saving = false
    private(set) var savedThisSession = false
    var saveError: String?
    /// The server's text when it changed under us; shows the reload / overwrite prompt.
    var conflict: String?

    init(session: ConnectionSession, runner: any RemoteCommandRunner) {
        self.session = session
        self.runner = runner
    }

    private var remote: CronRemote {
        let log = session.log
        return CronRemote(runner: runner, elevated: elevated) { kind, message in
            Task { @MainActor in log.append(kind, message) }
        }
    }

    // MARK: State

    /// The crontab text as it would be saved.
    var currentText: String { mode == .text ? rawText : crontab.serialized() }
    var isDirty: Bool { phase == .ready && currentText != loadedText }
    var canRevert: Bool { isDirty || (savedThisSession && sessionOriginal != nil && sessionOriginal != loadedText) }
    var revertTitle: String { savedThisSession && !isDirty ? "Restore Original" : "Revert" }
    /// Why the crontab cannot be saved from the job list, or nil.
    var validationError: String? {
        guard mode == .jobs else { return nil }
        if let bad = crontab.envVars.first(where: { !CronEnvVar.isValidName($0.name) }) {
            return "\"\(bad.name)\" is not a valid variable name."
        }
        return nil
    }
    var textIssues: [Crontab.Issue] { Crontab(parsing: rawText).issues }
    var jobCount: Int { (mode == .text ? Crontab(parsing: rawText) : crontab).jobs.count }

    /// The zone next-run times are shown in: the crontab's own `CRON_TZ`, else the server's.
    var timeZone: TimeZone {
        if let name = crontab.cronTimeZone, let zone = TimeZone(identifier: name) { return zone }
        return clock?.timeZone ?? .current
    }

    var timeZoneLabel: String {
        let zone = timeZone
        let seconds = zone.secondsFromGMT()
        let offset = String(format: "UTC%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) / 60 % 60)
        if let name = crontab.cronTimeZone, TimeZone(identifier: name) != nil {
            return "Times are in \(zone.identifier) (\(offset)), set by CRON_TZ."
        }
        guard let clock else { return "Server time zone unknown; times are shown in your Mac's zone (\(offset))." }
        return "Times are server time (\(clock.abbreviation), \(offset))."
    }

    /// The server's current time, carried forward from when it was read.
    var serverNow: Date {
        guard let clock else { return Date() }
        return clock.date.addingTimeInterval(Date().timeIntervalSince(clockFetchedAt))
    }

    // MARK: Loading

    func start() async {
        canElevate = await runner.canElevateCommands
        await load()
        sessionOriginal = phase == .ready ? loadedText : nil
    }

    func load() async {
        phase = .loading
        let remote = remote
        async let fetchedClock = remote.serverClock()
        do {
            let text = try await remote.load()
            apply(text)
            clock = await fetchedClock
            clockFetchedAt = Date()
            phase = .ready
        } catch {
            _ = await fetchedClock
            phase = .failed(Self.message(error))
        }
    }

    private func apply(_ text: String) {
        loadedText = text
        crontab = Crontab(parsing: text)
        rawText = text
        mode = .jobs
        saveError = nil
    }

    /// Switches between the job list and raw text. Going back to jobs needs text with no unreadable lines.
    @discardableResult
    func setMode(_ new: Mode) -> Bool {
        guard new != mode else { return true }
        if new == .text {
            rawText = crontab.serialized()
        } else {
            guard textIssues.isEmpty else { return false }
            crontab = Crontab(parsing: rawText)
        }
        mode = new
        return true
    }

    func switchRoot(_ on: Bool) async {
        guard !isDirty else { return }
        elevated = on
        savedThisSession = false
        await load()
        sessionOriginal = phase == .ready ? loadedText : nil
    }

    // MARK: Editing

    func revert() {
        if isDirty {
            apply(loadedText)
        } else if let original = sessionOriginal {
            // After a save: put the original text back as an edit, to be saved again.
            let keepLoaded = loadedText
            apply(original)
            loadedText = keepLoaded
        }
    }

    // MARK: Saving

    func save(overwrite: Bool = false) async {
        guard phase == .ready, !saving else { return }
        saving = true
        saveError = nil
        defer { saving = false }
        let text = currentText
        let remote = remote
        do {
            try await remote.save(text, expecting: overwrite ? nil : loadedText)
            // Read it back: some crons add header lines, and conflict checks compare with what the server prints.
            let installed = (try? await remote.load()) ?? text
            apply(installed)
            savedThisSession = true
            AppModel.shared.showToast("Saved crontab on \(session.connection.name)", symbol: "calendar.badge.clock")
        } catch CronRemoteError.changedOnServer(let current) {
            conflict = current
        } catch {
            saveError = Self.message(error)
        }
    }

    /// Drops the edits and shows what is on the server now.
    func reloadAfterConflict() async {
        conflict = nil
        await load()
    }

    private static func message(_ error: Error) -> String {
        if let cron = error as? CronRemoteError { return cron.description }
        return error.userMessage
    }
}
