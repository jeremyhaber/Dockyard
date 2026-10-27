import Foundation
import ConnectionKit

public struct CompressRequest: Sendable {
    /// Folder that contains the items; the archive stores them by name.
    public var directory: String
    public var names: [String]
    /// Full path of the archive to create.
    public var destination: String
    public var format: ArchiveFormat

    public init(directory: String, names: [String], destination: String, format: ArchiveFormat) {
        self.directory = directory; self.names = names; self.destination = destination; self.format = format
    }
}

public struct ExtractRequest: Sendable {
    public var archive: String
    /// Folder the contents are placed in (existing entries go through the conflict policy).
    public var destination: String
    public var format: ArchiveFormat?

    public init(archive: String, destination: String, format: ArchiveFormat? = nil) {
        self.archive = archive; self.destination = destination; self.format = format
    }
}

public struct ArchiveResult: Sendable, Equatable {
    /// Paths created or overwritten.
    public var placed: [String]
    public var skipped: Int
}

/// Compress and extract on a server (over an exec channel, so no bytes pass through this Mac) or locally.
///
/// Extraction never writes into the destination directly: the archive is unpacked into a hidden temporary
/// folder next to the destination, then every top-level entry is moved into place through the conflict
/// policy (folders merge, files ask/overwrite/skip/rename). Compression writes to a temporary file and
/// renames it, so a cancelled or failed run leaves nothing behind. Cancel by cancelling the task.
public final class ArchiveService: Sendable {
    public let log = LogHub()
    private let policy: ConflictPolicy
    private let resolver: ConflictResolver?
    private let maxLoggedLines = 1000

    public init(conflictPolicy: ConflictPolicy = .ask, resolver: ConflictResolver? = nil) {
        self.policy = conflictPolicy
        self.resolver = resolver
    }

    // MARK: Entry points

    public func compress(_ request: CompressRequest, on fs: any RemoteFileSystem & CommandRunning) async throws -> ArchiveResult {
        try await compress(request, host: RemoteArchiveHost(fs: fs, runner: fs, elevated: await fs.canElevateCommands))
    }

    public func extract(_ request: ExtractRequest, on fs: any RemoteFileSystem & CommandRunning) async throws -> ArchiveResult {
        try await extract(request, host: RemoteArchiveHost(fs: fs, runner: fs, elevated: await fs.canElevateCommands))
    }

    public func compressLocally(_ request: CompressRequest) async throws -> ArchiveResult {
        try await compress(request, host: LocalArchiveHost())
    }

    public func extractLocally(_ request: ExtractRequest) async throws -> ArchiveResult {
        try await extract(request, host: LocalArchiveHost())
    }

    // MARK: Compress

    func compress(_ request: CompressRequest, host: any ArchiveHost) async throws -> ArchiveResult {
        guard request.format.canCreate else { throw ArchiveError.unsupported("Cannot create .\(request.format.fileExtension) archives") }
        guard !request.names.isEmpty else { throw ArchiveError.unsupported("Nothing to compress") }
        if request.format == .zip, request.names.contains(where: { $0.contains("\n") }) {
            throw ArchiveError.unsupported("The zip tools cannot store names containing line breaks; use .tar.gz instead")
        }
        let available = try await host.availableTools(["zip", "tar", "gzip", "bzip2", "xz", "bsdtar"])
        try require(ArchiveCommands.compressTools(request.format, available: available), in: available, host: host)

        let fs = host.fs
        let parent = RemotePath.parent(of: request.destination)
        let name = RemotePath.lastComponent(of: request.destination)
        var target = request.destination
        if let existing = try await fs.lookup(target) {
            switch try await resolve(existing: existing, source: nil, name: name, path: target, fs: fs) {
            case .skip: return ArchiveResult(placed: [], skipped: 1)
            case .overwrite: break
            case .rename(let path): target = path
            }
        }
        let temp = RemotePath.join(parent, ".dockyard-\(UUID().uuidString.prefix(8))-\(RemotePath.lastComponent(of: target))")
        let command = ArchiveCommands.compress(
            request.format, directory: request.directory, names: request.names, archive: temp, available: available)
        do {
            try await execute(command, host: host)
            if try await fs.lookup(target) != nil { try await fs.delete(target, recursive: true) }
            try await fs.rename(temp, target)
        } catch {
            await Task.detached { try? await fs.delete(temp, recursive: false) }.value
            throw error
        }
        log.emit(.status, "Created \(target)")
        return ArchiveResult(placed: [target], skipped: 0)
    }

    // MARK: Extract

    func extract(_ request: ExtractRequest, host: any ArchiveHost) async throws -> ArchiveResult {
        let archiveName = RemotePath.lastComponent(of: request.archive)
        guard let format = request.format ?? ArchiveFormat.detect(fileName: archiveName) else {
            throw ArchiveError.unsupported("\(archiveName) is not a supported archive (.zip, .tar, .tar.gz, .tgz, .tar.bz2, .tar.xz)")
        }
        let available = try await host.availableTools(["unzip", "tar", "gzip", "bzip2", "xz", "bsdtar"])
        try require(ArchiveCommands.extractTools(format, available: available), in: available, host: host)

        let fs = host.fs
        try await Self.ensureDirectory(fs, request.destination)
        let temp = RemotePath.join(request.destination, ".dockyard-extract-\(UUID().uuidString.prefix(8))")
        try await fs.mkdir(temp)
        let result: ArchiveResult
        do {
            try await execute(
                ArchiveCommands.extract(format, archive: request.archive, into: temp, available: available), host: host)
            result = try await place(from: temp, into: request.destination, fs: fs)
        } catch {
            await Task.detached { await host.removeTree(temp) }.value
            throw error
        }
        await Task.detached { await host.removeTree(temp) }.value
        log.emit(.status, "Extracted \(archiveName) to \(request.destination)")
        return result
    }

    /// Moves everything in `source` into `destination`, merging folders and applying the conflict policy to files.
    private func place(from source: String, into destination: String, fs: any RemoteFileSystem) async throws -> ArchiveResult {
        var result = ArchiveResult(placed: [], skipped: 0)
        for entry in try await fs.list(source).sorted(by: { $0.name < $1.name }) {
            try Task.checkCancellation()
            var target = RemotePath.join(destination, entry.name)
            if let existing = try await fs.lookup(target) {
                if existing.isDirectory && entry.isDirectory {
                    let merged = try await place(from: entry.path, into: target, fs: fs)
                    result.placed += merged.placed
                    result.skipped += merged.skipped
                    continue
                }
                switch try await resolve(existing: existing, source: entry, name: entry.name, path: target, fs: fs) {
                case .skip:
                    result.skipped += 1
                    continue
                case .overwrite: try await fs.delete(target, recursive: true)
                case .rename(let path): target = path
                }
            }
            try await fs.rename(entry.path, target)
            result.placed.append(target)
        }
        return result
    }

    // MARK: Conflicts

    private enum Resolution { case skip, overwrite, rename(String) }

    private func resolve(
        existing: RemoteItem, source: RemoteItem?, name: String, path: String, fs: any RemoteFileSystem
    ) async throws -> Resolution {
        var action: ConflictAction
        switch policy {
        case .overwrite: action = .overwrite
        case .overwriteIfNewer: action = .overwriteIfNewer
        case .skip: action = .skip
        case .rename: action = .rename
        case .ask:
            guard let resolver else { return .skip }  // never overwrite without being told to
            let info = ConflictInfo(
                jobId: UUID(), name: name, route: "archive", sourcePath: source?.path ?? "", destinationPath: path,
                sourceSize: source?.size, sourceModified: source?.modified,
                destinationSize: existing.size, destinationModified: existing.modified)
            action = await resolver(info).action
        }
        switch action {
        case .cancel: throw CancellationError()
        case .skip: return .skip
        case .overwrite: return .overwrite
        case .overwriteIfNewer:
            guard let new = source?.modified, let old = existing.modified else { return .overwrite }
            return new.timeIntervalSince(old) > 1 ? .overwrite : .skip
        case .rename:
            let dir = RemotePath.parent(of: path)
            var n = 1
            while true {
                let candidate = RemotePath.join(dir, FileNaming.numbered(name, n))
                if try await fs.lookup(candidate) == nil { return .rename(candidate) }
                n += 1
            }
        }
    }

    // MARK: Running

    private func require(_ tools: [String], in available: Set<String>, host: any ArchiveHost) throws {
        if let missing = tools.first(where: { !available.contains($0) }) {
            throw ArchiveError.missingTool(missing, where: host.place)
        }
    }

    private func execute(_ command: ArchiveCommand, host: any ArchiveHost) async throws {
        log.emit(.command, command.shellLine)
        let log = self.log
        let limit = maxLoggedLines
        let state = LockedBox((splitter: LineSplitter(), count: 0, tail: [String]()))
        let status = try await host.run(command) { data in
            let lines = state.withLock { s -> [String] in
                let lines = s.splitter.feed(data)
                s.tail = Array((s.tail + lines).suffix(5))
                return lines
            }
            for line in lines {
                let n = state.withLock { s -> Int in s.count += 1; return s.count }
                if n <= limit { log.emit(.response, line) } else if n == limit + 1 { log.emit(.status, "Further output not shown") }
            }
        }
        let tail = state.withLock { s -> [String] in s.tail + s.splitter.finish() }
        try Task.checkCancellation()
        guard status == 0 else {
            throw ArchiveError.commandFailed(status: status, output: tail.suffix(3).joined(separator: " | "))
        }
    }

    private static func ensureDirectory(_ fs: any RemoteFileSystem, _ path: String) async throws {
        try await TransferQueue.ensureDirectory(fs, path)
    }
}
