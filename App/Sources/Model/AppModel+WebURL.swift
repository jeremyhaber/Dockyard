import AppKit
import ConnectionKit
import DockyardCore
import Foundation

/// Opens the folder-to-website sheet for one connection.
struct WebURLRequest: Identifiable {
    let id = UUID()
    let connectionId: UUID
    /// The open session whose file system the folder tree browses.
    let sessionID: UUID?
    let path: String
    let baseURL: String
    /// Set when changing an existing mapping, so saving at another folder moves it.
    let originalPath: String?
}

// MARK: - Web URLs

extension AppModel {
    func webURL(for path: String, on connection: Connection) -> URL? {
        WebURLResolver.url(for: path, in: connection.webURLs)
    }

    /// Copies the web addresses of `paths`. When none is covered by a mapping, asks for one at `folder` instead.
    func copyWebURLs(_ paths: [String], folder: String, in session: ConnectionSession) {
        let urls = paths.compactMap { webURL(for: $0, on: session.connection) }
        guard !urls.isEmpty else {
            editWebURL(at: folder, in: session)
            return
        }
        Dialogs.copyToPasteboard(urls.map(\.absoluteString).joined(separator: "\n"))
        let text = urls.count == 1 ? "Copied \(urls[0].absoluteString)" : "Copied \(urls.count) web URLs"
        showToast(urls.count < paths.count ? text + " (\(paths.count - urls.count) not under a web folder)" : text, symbol: "link")
    }

    func openInBrowser(_ path: String, in session: ConnectionSession) {
        guard let url = webURL(for: path, on: session.connection) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens the sheet on the mapping that covers `path`, or on a new mapping for `path`.
    func editWebURL(at path: String, in session: ConnectionSession) {
        let existing = WebURLResolver.mapping(for: path, in: session.connection.webURLs)
        webURLRequest = WebURLRequest(
            connectionId: session.connection.id, sessionID: session.id,
            path: existing?.path ?? path, baseURL: existing?.baseURL ?? "", originalPath: existing?.path)
    }

    /// The file system to browse folders of `connectionId`, when a tab for it is connected.
    func browsingFileSystem(for connectionId: UUID, preferring sessionID: UUID? = nil) -> (any RemoteFileSystem)? {
        let candidates = sessions.filter { $0.connection.id == connectionId && $0.status.isConnected }
        return (candidates.first { $0.id == sessionID } ?? candidates.first)?.fs
    }

    func saveWebURL(_ mapping: WebURLMapping, replacing originalPath: String?, on connectionId: UUID) {
        Task {
            do {
                try await connections.update(connectionId) { c in
                    c.webURLs = Self.applying(mapping, replacing: originalPath, to: c.webURLs)
                }
            } catch {
                showToast("Could not save the web URL: \(error.userMessage)", symbol: "exclamationmark.triangle", isError: true)
            }
        }
    }

    func removeWebURL(at path: String, on connectionId: UUID) {
        Task { try? await connections.update(connectionId) { $0.webURLs.removeAll { $0.path == path } } }
    }

    /// Puts `mapping` in place of the one at `originalPath` (or any at the same folder), keeping the order.
    nonisolated static func applying(_ mapping: WebURLMapping, replacing originalPath: String?, to list: [WebURLMapping]) -> [WebURLMapping] {
        var out = list.filter { $0.path != mapping.path || $0.path == originalPath }
        if let originalPath, let index = out.firstIndex(where: { $0.path == originalPath }) {
            out[index] = mapping
        } else {
            out.append(mapping)
        }
        return out
    }
}
