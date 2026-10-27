import Foundation
import ConnectionKit

// MARK: - Watching

/// Reports when a local file has been saved. Implementations: polling (portable, below) and, in the app,
/// FSEvents/DispatchSource-based ones that conform to the same protocol.
public protocol FileChangeWatcher: Sendable {
    /// Emits once for each settled change. The stream ends when the consumer stops iterating.
    func changes(of url: URL) -> AsyncStream<Void>
}

/// Compares size and modification time every `interval` seconds. A change is reported after the file
/// looks the same on two consecutive polls, so half-written saves are not uploaded.
public struct PollingFileWatcher: FileChangeWatcher {
    private let clock: any DockyardClock
    private let interval: TimeInterval

    public init(clock: any DockyardClock = SystemClock(), interval: TimeInterval = 1.0) {
        self.clock = clock
        self.interval = max(0.01, interval)
    }

    struct Signature: Equatable {
        var size: UInt64
        var modified: Date
    }

    static func signature(_ url: URL) -> Signature? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value, let mod = attrs[.modificationDate] as? Date else { return nil }
        return Signature(size: size, modified: mod)
    }

    public func changes(of url: URL) -> AsyncStream<Void> {
        let clock = self.clock, interval = self.interval
        let baseline = Self.signature(url)
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            var reported = baseline
            var previous = baseline
            while !Task.isCancelled {
                do { try await clock.sleep(seconds: interval) } catch { break }
                // An editor that saves by replacing the file may leave a gap with no file; wait it out.
                guard let current = Self.signature(url) else { continue }
                if current == previous, current != reported {
                    reported = current
                    continuation.yield()
                }
                previous = current
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

// MARK: - Events

public struct EditEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case opened
        case changeDetected
        case uploaded(bytes: UInt64)
        case uploadFailed(String)
        /// The server copy changed since it was downloaded; the upload still went ahead.
        case remoteChangedWarning
        case closed
    }

    public var sessionId: UUID
    public var connectionId: UUID
    public var connectionName: String
    public var remotePath: String
    public var kind: Kind

    public var fileName: String { RemotePath.lastComponent(of: remotePath) }

    /// Text for the toast, or nil for events that need none.
    public var toast: String? {
        switch kind {
        case .uploaded: "Uploaded \(fileName) to \(connectionName)"
        case .uploadFailed: "Could not upload \(fileName)"
        case .remoteChangedWarning: "\(fileName) changed on the server while you were editing"
        case .opened, .changeDetected, .closed: nil
        }
    }

    /// The line to add to the connection's Log.
    public var logLine: (kind: LogLine.Kind, message: String)? {
        switch kind {
        case .opened: (.status, "Opened \(remotePath) for editing")
        case .changeDetected: (.status, "Detected save of \(fileName)")
        case .uploaded(let bytes): (.status, "Uploaded \(remotePath) after edit (\(bytes) bytes)")
        case .uploadFailed(let m): (.error, "Upload of \(remotePath) after edit failed: \(m)")
        case .remoteChangedWarning: (.warning, "\(remotePath) changed on the server since it was opened; uploading your version anyway")
        case .closed: (.status, "Stopped watching \(remotePath)")
        }
    }
}

public struct EditSession: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var connectionId: UUID
    public var connectionName: String
    public var remotePath: String
    public var localURL: URL
}

// MARK: - Coordinator

/// Download to a temp folder, hand the file to the user's editor, watch it and upload on every save.
public actor EditInPlaceCoordinator {
    /// Called before the first upload of an edit session replaces the server file (the safety net keeps that version).
    public typealias BeforeOverwrite = @Sendable (_ path: String, _ fs: any RemoteFileSystem) async throws -> Void

    private final class Live {
        let session: EditSession
        let fs: any RemoteFileSystem
        var watchTask: Task<Void, Never>?
        var baseModified: Date?
        var baseSize: UInt64?
        var uploading = false
        var dirty = false
        var unsynced = false
        var versionKept = false
        let beforeOverwrite: BeforeOverwrite?
        init(session: EditSession, fs: any RemoteFileSystem, beforeOverwrite: BeforeOverwrite?) {
            self.session = session; self.fs = fs; self.beforeOverwrite = beforeOverwrite
        }
    }

    private let watcher: any FileChangeWatcher
    private let root: URL
    private var live: [UUID: Live] = [:]
    private var subscribers: [UUID: AsyncStream<EditEvent>.Continuation] = [:]

    public init(
        watcher: any FileChangeWatcher = PollingFileWatcher(),
        rootDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("dockyard-edit")
    ) {
        self.watcher = watcher
        self.root = rootDirectory
    }

    public var sessions: [EditSession] { live.values.map(\.session).sorted { $0.remotePath < $1.remotePath } }

    public func events() -> AsyncStream<EditEvent> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<EditEvent>.makeStream(bufferingPolicy: .unbounded)
        subscribers[key] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(key) } }
        return stream
    }

    /// Downloads the file and starts watching it. Opening the same file again returns the running session.
    public func open(
        fs: any RemoteFileSystem, remotePath: String, connectionId: UUID, connectionName: String, beforeOverwrite: BeforeOverwrite? = nil
    ) async throws -> EditSession {
        if let existing = live.values.first(where: { $0.session.connectionId == connectionId && $0.session.remotePath == remotePath }) {
            return existing.session
        }
        let id = UUID()
        let dir = root.appendingPathComponent(connectionId.uuidString).appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(RemotePath.lastComponent(of: remotePath))
        do {
            try await Self.download(fs, remotePath, to: local)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        let session = EditSession(id: id, connectionId: connectionId, connectionName: connectionName, remotePath: remotePath, localURL: local)
        let entry = Live(session: session, fs: fs, beforeOverwrite: beforeOverwrite)
        if let item = try? await fs.lookup(remotePath) { entry.baseModified = item.modified; entry.baseSize = item.size }
        live[id] = entry
        // Local copy keeps the server's modification time so "newer" comparisons stay meaningful.
        if let m = entry.baseModified { try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: local.path) }
        let changes = watcher.changes(of: local)
        entry.watchTask = Task { [weak self] in
            for await _ in changes { await self?.fileChanged(id) }
        }
        emit(session, .opened)
        return session
    }

    /// Uploads the current local copy now (retry after a failure).
    public func uploadNow(_ sessionId: UUID) async {
        await fileChanged(sessionId)
    }

    /// True while saved changes have not reached the server.
    public func hasUnsyncedChanges(_ sessionId: UUID) -> Bool { live[sessionId]?.unsynced ?? false }

    /// Stops watching. The temp copy is deleted unless it holds changes that never uploaded (unless `force`).
    public func stop(_ sessionId: UUID, force: Bool = false) {
        guard let entry = live.removeValue(forKey: sessionId) else { return }
        entry.watchTask?.cancel()
        if force || !entry.unsynced {
            try? FileManager.default.removeItem(at: entry.session.localURL.deletingLastPathComponent())
        }
        emit(entry.session, .closed)
    }

    public func stopAll(connectionId: UUID? = nil, force: Bool = false) {
        for (id, e) in live where connectionId == nil || e.session.connectionId == connectionId { _ = e; stop(id, force: force) }
    }

    // MARK: Internals

    private func removeSubscriber(_ key: UUID) { subscribers.removeValue(forKey: key) }

    private func emit(_ s: EditSession, _ kind: EditEvent.Kind) {
        let event = EditEvent(sessionId: s.id, connectionId: s.connectionId, connectionName: s.connectionName, remotePath: s.remotePath, kind: kind)
        for c in subscribers.values { c.yield(event) }
    }

    private func fileChanged(_ id: UUID) async {
        guard let entry = live[id] else { return }
        entry.unsynced = true
        if entry.uploading { entry.dirty = true; return }  // picked up when the running upload ends
        entry.uploading = true
        defer { entry.uploading = false }
        repeat {
            entry.dirty = false
            emit(entry.session, .changeDetected)
            await upload(entry)
        } while entry.dirty && live[id] != nil
    }

    private func upload(_ entry: Live) async {
        let s = entry.session
        if let remote = try? await entry.fs.lookup(s.remotePath), let base = entry.baseModified,
           let current = remote.modified, current != base || (entry.baseSize != nil && remote.size != entry.baseSize) {
            emit(s, .remoteChangedWarning)
        }
        let bytes = LocalFileSize.size(of: s.localURL) ?? 0
        do {
            if !entry.versionKept, let keep = entry.beforeOverwrite {
                try await keep(s.remotePath, entry.fs)
                entry.versionKept = true
            }
            try await Self.upload(entry.fs, s.localURL, to: s.remotePath)
            if let item = try? await entry.fs.lookup(s.remotePath) { entry.baseModified = item.modified; entry.baseSize = item.size }
            entry.unsynced = entry.dirty  // a newer save may already be waiting
            emit(s, .uploaded(bytes: bytes))
        } catch {
            emit(s, .uploadFailed(TransferQueue.describe(error)))
        }
    }

    private nonisolated static func download(_ fs: any RemoteFileSystem, _ remote: String, to local: URL) async throws {
        try await fs.download(remote, to: local, progress: Progress(totalUnitCount: 0), resume: false)
    }

    private nonisolated static func upload(_ fs: any RemoteFileSystem, _ local: URL, to remote: String) async throws {
        try await fs.upload(local, to: remote, progress: Progress(totalUnitCount: 0), resume: false)
    }
}
