import ConnectionKit
import DockyardCore
import Foundation

extension AppModel {
    /// Downloads server items into the Scratch folder, where they expire (HANDOFF 7).
    func downloadToScratch(_ items: [RemoteItem], from session: ConnectionSession) {
        guard !items.isEmpty else { return }
        let folder: String
        do {
            folder = try scratch.ensureFolder()
        } catch {
            showToast("Could not create the Scratch folder: \(error.localizedDescription)", symbol: "exclamationmark.triangle", isError: true)
            return
        }
        scratch.noteDownload(items, from: session.connection.name)
        // A file downloaded again replaces the older copy and starts a new clock.
        transfer(items, from: session, .server, to: session, .local, directory: folder, move: false, conflict: .overwrite)
        let what = items.count == 1 ? items[0].name : "\(items.count) items"
        showToast("Downloading \(what) to Scratch", symbol: "clock.arrow.circlepath",
                  action: ToastAction(title: "Show") { [weak self] in
                      self?.drawerTab = .scratch
                      self?.drawerVisible = true
                  })
    }

    /// Where the local pane starts for a connection: its own folder, Scratch or the default folder.
    func localStartFolder(for c: Connection) -> String {
        if DemoMode.isEnabled { return "/Users/demo" }
        let fallback = AppSettings.localFolder ?? NSHomeDirectory()
        switch c.localStart {
        case .defaultFolder:
            return fallback
        case .folder:
            guard let folder = c.localFolder, !folder.isEmpty, FileManager.default.fileExists(atPath: folder) else { return fallback }
            return folder
        case .scratch:
            return (try? scratch.ensureFolder()) ?? fallback
        }
    }
}
