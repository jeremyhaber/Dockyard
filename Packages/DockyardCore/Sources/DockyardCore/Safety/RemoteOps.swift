import Foundation
import ConnectionKit

/// Namespace helpers shared by the safety net and the trash browser.
struct RemoteOps {
    let fs: any RemoteFileSystem
    let log: @Sendable (LogLine.Kind, String) -> Void
    private let knownDirectories = LockedBox<Set<String>>([])

    init(_ fs: any RemoteFileSystem, log: @escaping @Sendable (LogLine.Kind, String) -> Void = { _, _ in }) {
        self.fs = fs
        self.log = log
    }

    /// `mkdir -p`. Remembers what it created or saw during this object's lifetime.
    func ensureDirectory(_ path: String) async throws {
        var current = ""
        for part in TrashLayout.components(path) {
            current += "/" + part
            if knownDirectories.withLock({ $0.contains(current) }) { continue }
            if try await fs.stat(current) == nil {
                do { try await fs.mkdir(current) } catch {
                    // Another client may have created it in the meantime.
                    guard try await fs.stat(current) != nil else { throw error }
                }
            }
            knownDirectories.withLock { _ = $0.insert(current) }
        }
    }

    func forgetAll() { knownDirectories.withLock { $0.removeAll() } }

    func forget(_ path: String) {
        knownDirectories.withLock { known in known = known.filter { $0 != path && !$0.hasPrefix(path + "/") } }
    }

    /// Copies a file or folder on the server: `cp -a` where a shell exists, otherwise through this Mac.
    func copy(_ item: RemoteItem, to destination: String) async throws {
        if let runner = fs as? any RemoteCommandRunner {
            let result = try await runner.exec("cp -a -- \(ShellQuote.quote(item.path)) \(ShellQuote.quote(destination))")
            guard result.exitStatus == 0 else {
                throw RemoteError.protocolError("cp failed: \(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return
        }
        try await relay(item, to: destination)
    }

    private func relay(_ item: RemoteItem, to destination: String) async throws {
        if item.isSymlink && !item.isDirectory { throw RemoteError.unsupported("copying a symbolic link") }
        if item.isDirectory {
            try await fs.mkdir(destination)
            for child in try await fs.list(item.path) where child.name != "." && child.name != ".." {
                try await relay(child, to: RemotePath.join(destination, child.name))
            }
            return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("dockyard-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await fs.download(item.path, to: temp, progress: Progress(totalUnitCount: 0))
        try await fs.upload(temp, to: destination, progress: Progress(totalUnitCount: 0))
    }

    /// Creates an empty file.
    func touch(_ path: String) async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("dockyard-empty-\(UUID().uuidString)")
        try Data().write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        try await fs.upload(temp, to: path, progress: Progress(totalUnitCount: 0))
    }

    /// Removes `path` and then each parent up to (not including) `stop` while it is empty. Best effort.
    func pruneEmptyDirectories(from path: String, upTo stop: String) async {
        var current = path
        while current.count > stop.count, current.hasPrefix(stop + "/") {
            guard let children = try? await fs.list(current), children.isEmpty else { return }
            do { try await fs.delete(current, recursive: false) } catch { return }
            forget(current)
            current = RemotePath.parent(of: current)
        }
    }
}
