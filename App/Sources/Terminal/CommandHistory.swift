import AppKit
import DockyardCore
import Foundation

/// Commands typed in the terminal, per connection, for autosuggestions. A plain file in the support directory,
/// like `~/.bash_history`. Shells of one connection share a history. Demo mode keeps its own in memory and never
/// touches the file.
@MainActor
final class CommandHistoryStore {
    static let shared = CommandHistoryStore()

    private var histories: [String: CommandHistory] = [:]
    private var loaded = false
    private var saveTask: Task<Void, Never>?
    private let fileURL: URL

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("command-history.json")) {
        self.fileURL = fileURL
        // A command typed just before quitting would otherwise miss the debounced save.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { CommandHistoryStore.shared.flush() }
        }
    }

    /// Writes a pending save now.
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    func history(for connection: UUID) -> CommandHistory {
        if DemoMode.isEnabled { return histories[connection.uuidString] ?? Self.demoHistory }
        load()
        return histories[connection.uuidString] ?? CommandHistory()
    }

    func record(_ line: String, for connection: UUID) {
        var history = self.history(for: connection)
        guard history.record(line) else { return }
        histories[connection.uuidString] = history
        if !DemoMode.isEnabled { scheduleSave() }
    }

    static var demoHistory: CommandHistory {
        CommandHistory(entries: ["wp plugin list", "tail -f wp-content/debug.log", "ls -la"])
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: CommandHistory].self, from: data) else { return }
        histories = stored
    }

    /// Saved a couple of seconds after the last command, so a burst of commands writes once.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveTask = nil
            self?.save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(histories) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
