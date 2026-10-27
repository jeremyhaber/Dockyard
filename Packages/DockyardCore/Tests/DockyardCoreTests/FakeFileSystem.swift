@testable import DockyardCore
import Foundation
import ConnectionKit

/// In-memory RemoteFileSystem with strict parent checks, failure injection and call recording.
final class FakeFileSystem: RemoteFileSystem {
    struct Entry { var data: Data; var modified: Date }
    struct State {
        var files: [String: Entry] = [:]
        var dirs: Set<String> = ["/"]
        var calls: [String] = []
        var active = 0
        var maxActive = 0
        /// path -> (remaining failures, error)
        var failures: [String: (Int, any Error)] = [:]
        /// path -> write only this many bytes then fail
        var failAfterBytes: [String: Int] = [:]
        var listFailures: [String: any Error] = [:]
        var connected = false
    }

    let name: String
    let state = LockedBox(State())
    /// Called at the start of every download/upload with the remote path; may suspend.
    let hook = LockedBox<(@Sendable (String) async throws -> Void)?>(nil)
    private let hub = LogHub()

    init(name: String = "fake") { self.name = name }

    var logStream: AsyncStream<LogLine> { hub.stream() }
    var supportsShell: Bool { false }

    // MARK: Test helpers
    func put(_ path: String, _ text: String, modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        put(path, data: Data(text.utf8), modified: modified)
    }
    func put(_ path: String, data: Data, modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        state.withLock { s in
            var parent = RemotePath.parent(of: path)
            while parent != "/" && !s.dirs.contains(parent) { s.dirs.insert(parent); parent = RemotePath.parent(of: parent) }
            s.files[path] = Entry(data: data, modified: modified)
        }
    }
    func makeDir(_ path: String) {
        state.withLock { s in
            var p = path
            while p != "/" && !s.dirs.contains(p) { s.dirs.insert(p); p = RemotePath.parent(of: p) }
        }
    }
    func text(_ path: String) -> String? { state.withLock { $0.files[path] }.map { String(decoding: $0.data, as: UTF8.self) } }
    func modified(_ path: String) -> Date? { state.withLock { $0.files[path]?.modified } }
    func hasDir(_ path: String) -> Bool { state.withLock { $0.dirs.contains(path) } }
    var calls: [String] { state.withLock { $0.calls } }
    var maxActive: Int { state.withLock { $0.maxActive } }
    func failNext(_ path: String, times: Int = 1, error: any Error = RemoteError.protocolError("boom")) {
        state.withLock { $0.failures[path] = (times, error) }
    }
    func failAfter(bytes: Int, path: String) { state.withLock { $0.failAfterBytes[path] = bytes } }
    func setHook(_ h: (@Sendable (String) async throws -> Void)?) { hook.withLock { $0 = h } }

    private func record(_ s: String) { state.withLock { $0.calls.append(s) } }
    private func checkFailure(_ path: String) throws {
        let err: (any Error)? = state.withLock { s in
            guard let (n, e) = s.failures[path], n > 0 else { return nil }
            s.failures[path] = (n - 1, e)
            return e
        }
        if let err { throw err }
    }

    // MARK: RemoteFileSystem
    func connect() async throws { state.withLock { $0.connected = true } }
    func disconnect() async { state.withLock { $0.connected = false } }
    func homeDirectory() async throws -> String { "/home/user" }

    func list(_ path: String) async throws -> [RemoteItem] {
        record("list \(path)")
        if let e = state.withLock({ $0.listFailures[path] }) { throw e }
        return try state.withLock { s in
            guard s.dirs.contains(path) else { throw RemoteError.notFound(path) }
            var out: [RemoteItem] = []
            for d in s.dirs where d != "/" && RemotePath.parent(of: d) == path {
                out.append(RemoteItem(name: RemotePath.lastComponent(of: d), path: d, isDirectory: true, modified: Date(timeIntervalSince1970: 1_700_000_000)))
            }
            for (f, e) in s.files where RemotePath.parent(of: f) == path {
                out.append(RemoteItem(name: RemotePath.lastComponent(of: f), path: f, isDirectory: false, size: UInt64(e.data.count), modified: e.modified))
            }
            return out.sorted { $0.name < $1.name }
        }
    }

    private func enter() { state.withLock { $0.active += 1; $0.maxActive = max($0.maxActive, $0.active) } }
    private func leave() { state.withLock { $0.active -= 1 } }

    func download(_ remote: String, to local: URL, progress: Progress, resume: Bool) async throws {
        record("download \(remote) resume=\(resume)")
        enter(); defer { leave() }
        if let h = hook.withLock({ $0 }) { try await h(remote) }
        try checkFailure(remote)
        guard let entry = state.withLock({ $0.files[remote] }) else { throw RemoteError.notFound(remote) }
        var offset = 0
        if resume, let existing = LocalFileSize.size(of: local), Int(existing) <= entry.data.count { offset = Int(existing) }
        progress.totalUnitCount = Int64(entry.data.count)
        var out = offset > 0 ? ((try? Data(contentsOf: local)) ?? Data()) : Data()
        let limit = state.withLock { $0.failAfterBytes[remote] }
        let slice = entry.data.suffix(from: offset)
        if let limit, slice.count > limit {
            out.append(slice.prefix(limit))
            try out.write(to: local)
            state.withLock { _ = $0.failAfterBytes.removeValue(forKey: remote) }
            progress.completedUnitCount = Int64(offset + limit)
            throw RemoteError.protocolError("connection reset")
        }
        try Task.checkCancellation()
        out.append(slice)
        try out.write(to: local)
        progress.completedUnitCount = Int64(entry.data.count)
    }

    func upload(_ local: URL, to remote: String, progress: Progress, resume: Bool) async throws {
        record("upload \(remote) resume=\(resume)")
        enter(); defer { leave() }
        if let h = hook.withLock({ $0 }) { try await h(remote) }
        try checkFailure(remote)
        guard state.withLock({ $0.dirs.contains(RemotePath.parent(of: remote)) }) else {
            throw RemoteError.notFound(RemotePath.parent(of: remote))
        }
        let data = try Data(contentsOf: local)
        progress.totalUnitCount = Int64(data.count)
        var offset = 0
        var base = Data()
        if resume, let existing = state.withLock({ $0.files[remote] }), existing.data.count <= data.count {
            offset = existing.data.count; base = existing.data
        }
        let limit = state.withLock { $0.failAfterBytes[remote] }
        let slice = data.suffix(from: offset)
        if let limit, slice.count > limit {
            base.append(slice.prefix(limit))
            state.withLock { s in s.files[remote] = Entry(data: base, modified: Date()); s.failAfterBytes.removeValue(forKey: remote) }
            progress.completedUnitCount = Int64(offset + limit)
            throw RemoteError.protocolError("connection reset")
        }
        try Task.checkCancellation()
        base.append(slice)
        state.withLock { $0.files[remote] = Entry(data: base, modified: Date()) }
        progress.completedUnitCount = Int64(data.count)
    }

    func mkdir(_ path: String) async throws {
        record("mkdir \(path)")
        try state.withLock { s in
            guard s.dirs.contains(RemotePath.parent(of: path)) else { throw RemoteError.notFound(RemotePath.parent(of: path)) }
            s.dirs.insert(path)
        }
    }

    func rename(_ from: String, _ to: String) async throws {
        record("rename \(from) \(to)")
        try state.withLock { s in
            if let e = s.files.removeValue(forKey: from) { s.files[to] = e } else if s.dirs.contains(from) {
                s.dirs.remove(from); s.dirs.insert(to)
            } else { throw RemoteError.notFound(from) }
        }
    }

    func delete(_ path: String, recursive: Bool) async throws {
        record("delete \(path)")
        try state.withLock { s in
            if s.files.removeValue(forKey: path) != nil { return }
            guard s.dirs.contains(path) else { throw RemoteError.notFound(path) }
            s.dirs = s.dirs.filter { $0 != path && !$0.hasPrefix(path + "/") }
            s.files = s.files.filter { !$0.key.hasPrefix(path + "/") }
        }
    }

    func chmod(_ path: String, mode: UInt16) async throws {}
}

