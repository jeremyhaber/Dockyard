@testable import DockyardCore
import Foundation
import ConnectionKit

/// Wraps `FakeFileSystem` with a configurable home directory and rename failures. No shell.
class ShellFakeFileSystem: RemoteFileSystem, @unchecked Sendable {
    let base: FakeFileSystem
    let home: String
    let renameFails = LockedBox<Bool>(false)

    init(base: FakeFileSystem = FakeFileSystem(), home: String = "/home/user") {
        self.base = base
        self.home = home
        base.makeDir(home)
    }

    var logStream: AsyncStream<LogLine> { base.logStream }
    var supportsShell: Bool { true }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func homeDirectory() async throws -> String { home }
    func list(_ path: String) async throws -> [RemoteItem] { try await base.list(path) }
    func download(_ remote: String, to local: URL, progress: Progress, resume: Bool) async throws {
        try await base.download(remote, to: local, progress: progress, resume: resume)
    }
    func upload(_ local: URL, to remote: String, progress: Progress, resume: Bool) async throws {
        try await base.upload(local, to: remote, progress: progress, resume: resume)
    }
    func mkdir(_ path: String) async throws { try await base.mkdir(path) }
    func rename(_ from: String, _ to: String) async throws {
        if renameFails.withLock({ $0 }) { throw RemoteError.protocolError("Invalid cross-device link") }
        try base.state.withLock { s in
            guard s.dirs.contains(RemotePath.parent(of: to)) else { throw RemoteError.notFound(RemotePath.parent(of: to)) }
            if let entry = s.files.removeValue(forKey: from) {
                s.files[to] = entry
            } else if s.dirs.contains(from) {
                for dir in s.dirs where dir == from || dir.hasPrefix(from + "/") {
                    s.dirs.remove(dir); s.dirs.insert(to + dir.dropFirst(from.count))
                }
                for (path, entry) in s.files where path.hasPrefix(from + "/") {
                    s.files.removeValue(forKey: path); s.files[to + path.dropFirst(from.count)] = entry
                }
            } else {
                throw RemoteError.notFound(from)
            }
        }
    }
    func delete(_ path: String, recursive: Bool) async throws { try await base.delete(path, recursive: recursive) }
    func chmod(_ path: String, mode: UInt16) async throws {}
}

/// Adds a scripted shell: `handler` maps a command line to its output.
final class ScriptedShellFileSystem: ShellFakeFileSystem, RemoteCommandRunner, @unchecked Sendable {
    let handler = LockedBox<@Sendable (String) -> (stdout: String, stderr: String, status: Int32)>({ _ in ("", "", 127) })
    let commands = LockedBox<[String]>([])

    func script(_ reply: @escaping @Sendable (String) -> (stdout: String, stderr: String, status: Int32)) {
        handler.withLock { $0 = reply }
    }

    func exec(_ command: String) async throws -> SSHExecResult {
        commands.withLock { $0.append(command) }
        let reply = handler.withLock { $0 }(command)
        return SSHExecResult(stdout: Data(reply.stdout.utf8), stderr: Data(reply.stderr.utf8), exitStatus: reply.status)
    }

    func execStream(_ command: String, elevated: Bool) async throws -> AsyncThrowingStream<SSHExecEvent, Error> {
        let result = try await exec(command)
        return AsyncThrowingStream { continuation in
            if !result.stdout.isEmpty { continuation.yield(.stdout(result.stdout)) }
            if !result.stderr.isEmpty { continuation.yield(.stderr(result.stderr)) }
            continuation.yield(.exit(result.exitStatus))
            continuation.finish()
        }
    }
}
