import AppKit
import ConnectionKit
import DockyardCore
import QuickLookUI

/// Space on a selected file shows Quick Look. Local files open in place; server files are downloaded into a
/// cache first, asking before anything over `confirmAbove` bytes.
@MainActor
final class QuickLookCenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCenter()
    static let confirmAbove: UInt64 = 50 * 1_048_576
    private static let maxFiles = 12

    private var urls: [URL] = []
    private var task: Task<Void, Never>?

    func toggle(_ items: [RemoteItem], side: PaneSide, session: ConnectionSession) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        let files = Array(items.filter { !$0.isDirectory }.prefix(Self.maxFiles))
        guard !files.isEmpty else { return }
        if side == .local {
            show(files.map { URL(fileURLWithPath: $0.path) })
            return
        }
        guard let fs = session.fs else { return }
        if let big = files.first(where: { $0.size > Self.confirmAbove }) {
            let proceed = Dialogs.confirm(
                title: "Preview \"\(big.name)\"?",
                message: "It is \(FileDisplay.size(big.size)). Quick Look downloads the file to a cache on this Mac before showing it.",
                confirm: "Download and Preview", destructive: false)
            if !proceed { return }
        }
        task?.cancel()
        let connectionID = session.connection.id
        task = Task {
            var local: [URL] = []
            for item in files {
                do {
                    local.append(try await Self.cached(item, fs: fs, connectionID: connectionID))
                } catch is CancellationError {
                    return
                } catch {
                    session.operationError = "Preview \(item.name): \(error.userMessage)"
                    return
                }
            }
            show(local)
        }
    }

    func show(_ files: [URL]) {
        urls = files
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Cache

    private static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Dockyard/QuickLook", isDirectory: true)
    }

    private static func cached(_ item: RemoteItem, fs: any RemoteFileSystem, connectionID: UUID) async throws -> URL {
        let folder = cacheRoot
            .appendingPathComponent(connectionID.uuidString, isDirectory: true)
            .appendingPathComponent(String(UInt32(truncatingIfNeeded: item.path.hashValue), radix: 16), isDirectory: true)
        let target = folder.appendingPathComponent(item.name)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
           (attributes[.size] as? UInt64) == item.size,
           let modified = item.modified, (attributes[.modificationDate] as? Date) == modified {
            return target
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        if item.size > 1_048_576 {
            AppModel.shared.showToast("Downloading \(item.name) for Quick Look", symbol: "arrow.down.circle")
        }
        try await fs.download(item.path, to: target, progress: Progress(totalUnitCount: 0))
        if let modified = item.modified { try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path) }
        return target
    }

    /// Removes cached previews older than a day. Runs once at launch.
    nonisolated static func purgeStaleCache() {
        let fm = FileManager.default
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Dockyard/QuickLook", isDirectory: true)
        guard let connections = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for connection in connections {
            for folder in (try? fm.contentsOfDirectory(at: connection, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if modified < cutoff { try? fm.removeItem(at: folder) }
            }
            if ((try? fm.contentsOfDirectory(atPath: connection.path)) ?? []).isEmpty { try? fm.removeItem(at: connection) }
        }
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { index < urls.count ? urls[index] as NSURL : nil }
    }
}
