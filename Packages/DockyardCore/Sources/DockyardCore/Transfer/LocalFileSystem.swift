import Foundation
import ConnectionKit

/// The "This Mac" pane's file system. Paths are absolute POSIX paths.
public final class LocalFileSystem: RemoteFileSystem {
    private let hub = LogHub()

    public init() {}

    public var logStream: AsyncStream<LogLine> { hub.stream() }
    public var supportsShell: Bool { false }

    public func connect() async throws {}
    public func disconnect() async { hub.finish() }

    public func homeDirectory() async throws -> String { NSHomeDirectory() }

    public func list(_ path: String) async throws -> [RemoteItem] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { throw RemoteError.notFound(path) }
        guard isDir.boolValue else { throw RemoteError.protocolError("Not a directory: \(path)") }
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: path) } catch {
            throw RemoteError.permissionDenied(path)
        }
        return names.compactMap { Self.item(at: RemotePath.join(path, $0), name: $0) }
    }

    /// Single-entry lookup without listing the parent directory.
    public func stat(path: String) -> RemoteItem? {
        let name = path == "/" ? "/" : RemotePath.lastComponent(of: path)
        return Self.item(at: path, name: name)
    }

    static func item(at path: String, name: String) -> RemoteItem? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else {
            // Dangling symlink: still show it.
            if let target = try? fm.destinationOfSymbolicLink(atPath: path) {
                return RemoteItem(name: name, path: path, isDirectory: false, symlinkTarget: target)
            }
            return nil
        }
        let target = try? fm.destinationOfSymbolicLink(atPath: path)
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: path, isDirectory: &isDir)
        let size = (attrs[.size] as? NSNumber)?.uint64Value
        let perms = (attrs[.posixPermissions] as? NSNumber).map { UInt16($0.uint16Value & 0o7777) }
        return RemoteItem(
            name: name, path: path, isDirectory: isDir.boolValue,
            size: isDir.boolValue ? nil : size, modified: attrs[.modificationDate] as? Date,
            permissions: perms, symlinkTarget: target)
    }

    public func download(_ remote: String, to local: URL, progress: Progress, resume: Bool) async throws {
        hub.emit(.status, "Copying \(remote)")
        try await Self.copy(from: URL(fileURLWithPath: remote), to: local, progress: progress, resume: resume)
    }

    public func upload(_ local: URL, to remote: String, progress: Progress, resume: Bool) async throws {
        hub.emit(.status, "Copying to \(remote)")
        try await Self.copy(from: local, to: URL(fileURLWithPath: remote), progress: progress, resume: resume)
    }

    public func mkdir(_ path: String) async throws {
        do { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) } catch {
            throw RemoteError.permissionDenied(path)
        }
    }

    public func rename(_ from: String, _ to: String) async throws {
        do { try FileManager.default.moveItem(atPath: from, toPath: to) } catch {
            throw RemoteError.protocolError("Cannot rename \(from): \(error.localizedDescription)")
        }
    }

    public func delete(_ path: String, recursive: Bool) async throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { throw RemoteError.notFound(path) }
        if isDir.boolValue, !recursive, !((try? fm.contentsOfDirectory(atPath: path)) ?? []).isEmpty {
            throw RemoteError.protocolError("Directory not empty: \(path)")
        }
        try fm.removeItem(atPath: path)
    }

    public func chmod(_ path: String, mode: UInt16) async throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path)
    }

    /// Chunked copy that reports progress, honours task cancellation and can resume a partial destination.
    static func copy(from src: URL, to dst: URL, progress: Progress, resume: Bool) async throws {
        let fm = FileManager.default
        guard let total = LocalFileSize.size(of: src) else { throw RemoteError.notFound(src.path) }
        progress.totalUnitCount = Int64(total)
        var offset: UInt64 = 0
        if resume, let existing = LocalFileSize.size(of: dst), existing <= total { offset = existing }
        if offset == 0 || !fm.fileExists(atPath: dst.path) {
            offset = 0
            _ = fm.createFile(atPath: dst.path, contents: nil)
        }
        let reader = try FileHandle(forReadingFrom: src)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: dst)
        defer { try? writer.close() }
        try reader.seek(toOffset: offset)
        if offset == 0 { try writer.truncate(atOffset: 0) } else { try writer.seek(toOffset: offset) }
        var done = offset
        progress.completedUnitCount = Int64(done)
        while true {
            try Task.checkCancellation()
            guard let chunk = try reader.read(upToCount: 128 * 1024), !chunk.isEmpty else { break }
            try writer.write(contentsOf: chunk)
            done += UInt64(chunk.count)
            progress.completedUnitCount = Int64(done)
            await Task.yield()
        }
        progress.completedUnitCount = Int64(total)
    }
}

enum LocalFileSize {
    static func size(of url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.uint64Value
    }
}

extension RemoteFileSystem {
    /// Like `stat` but avoids listing the parent for local file systems.
    public func lookup(_ path: String) async throws -> RemoteItem? {
        if let local = self as? LocalFileSystem { return local.stat(path: path) }
        return try await stat(path)
    }
}
