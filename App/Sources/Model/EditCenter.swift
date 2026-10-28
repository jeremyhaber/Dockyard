import AppKit
import ConnectionKit
import DockyardCore
import Observation

/// A file being edited in place, as shown in the "Editing N files" indicator.
struct EditEntry: Identifiable, Equatable {
    var id: UUID
    var connectionName: String
    var remotePath: String
    var fileName: String { RemotePath.lastComponent(of: remotePath) }
}

/// Edit-in-place for server files: download, open in the chosen editor, watch, upload on every save (HANDOFF 4).
@MainActor @Observable
final class EditCenter {
    private(set) var entries: [EditEntry] = []

    @ObservationIgnored private let coordinator = EditInPlaceCoordinator()
    @ObservationIgnored var onEvent: ((EditEvent) -> Void)?

    /// Starts listening for coordinator events. Called once by `AppModel`.
    func start() {
        let coordinator = self.coordinator
        Task {
            for await event in await coordinator.events() {
                self.onEvent?(event)
                await self.refresh()
            }
        }
    }

    func edit(_ item: RemoteItem, in session: ConnectionSession) {
        guard let fs = session.fs else { return }
        let id = session.connection.id
        let name = session.connection.name
        let coordinator = self.coordinator
        let keepVersion = AppModel.shared.overwriteHook(for: session.connection)
        Task {
            do {
                let edit = try await coordinator.open(
                    fs: fs, remotePath: item.path, connectionId: id, connectionName: name, beforeOverwrite: keepVersion)
                await self.refresh()
                Self.openInEditor(edit.localURL)
            } catch {
                session.operationError = "Edit \(item.name): \(error.userMessage)"
            }
        }
    }

    /// Opens `url` in the editor chosen in Settings, or in the file's default app when none is set.
    static func openInEditor(_ url: URL) {
        guard let editor = AppSettings.editorURL else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    func stop(_ id: UUID) {
        let coordinator = self.coordinator
        entries.removeAll { $0.id == id }
        Task {
            await coordinator.stop(id)
            await self.refresh()
        }
    }

    func stopAll(connectionID: UUID) async {
        await coordinator.stopAll(connectionId: connectionID)
        await refresh()
    }

    func refresh() async {
        guard !DemoMode.isEnabled else { return }
        let live = await coordinator.sessions
        entries = live.map { EditEntry(id: $0.id, connectionName: $0.connectionName, remotePath: $0.remotePath) }
    }

    /// Two files in the indicator for the screenshots.
    func seedDemo() {
        entries = [
            EditEntry(id: UUID(), connectionName: "Acme Corp", remotePath: "/home/acme/public_html/wp-config.php"),
            EditEntry(id: UUID(), connectionName: "Acme Corp", remotePath: "/home/acme/public_html/.htaccess"),
        ]
    }
}
