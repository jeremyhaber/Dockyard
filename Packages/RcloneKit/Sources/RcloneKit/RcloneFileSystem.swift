import ConnectionKit
import Foundation

/// Cloud storage through librclone. Paths are POSIX style and rooted at the remote's configured root (`/`).
public final class RcloneFileSystem: RemoteFileSystem {
    private struct State {
        var remote: RcloneResolvedRemote?
    }

    private let config: ConnectionConfig
    private let spec: RcloneRemoteSpec
    private let secrets: any SecretStore
    private let hub = LogHub()
    private let client: RcloneClient
    private let state = LockedBox(State())

    public var supportsShell: Bool { false }
    public var logStream: AsyncStream<LogLine> { hub.stream() }

    public init(config: ConnectionConfig, spec: RcloneRemoteSpec, secrets: any SecretStore, transport: any RcloneTransport) {
        self.config = config
        self.spec = spec
        self.secrets = secrets
        let hub = hub
        client = RcloneClient(transport: transport) { kind, message in hub.emit(kind, message) }
    }

    public convenience init(config: ConnectionConfig, spec: RcloneRemoteSpec, secrets: any SecretStore, library: RcloneLibrary? = nil) throws {
        try self.init(config: config, spec: spec, secrets: secrets, transport: library ?? RcloneLibrary.load())
    }

    // MARK: Roots

    /// The path the UI treats as the top, always `/`.
    public var rootPath: String { "/" }

    /// True for `/` and, for bucket-based backends rooted above any bucket, for each bucket's top level.
    /// Navigation should not go above a root, so `..` at a bucket stops there.
    public func isRoot(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        if parts.isEmpty { return true }
        return spec.backend.hasBuckets && spec.root.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty && parts.count == 1
    }

    // MARK: Connection

    public func connect() async throws {
        let secret = try await secrets.secret(for: config.id, purpose: .cloudToken)
        let remote = try spec.resolve(username: config.username, host: config.host, secret: secret)
        hub.emit(.status, "Connecting to \(spec.backend.rawValue) remote \(remote.redactedFs)")
        do {
            _ = try await client.call("operations/list", ["fs": .string(remote.fs), "remote": ""])
        } catch {
            throw map(error, path: "/")
        }
        state.withLock { $0.remote = remote }
        hub.emit(.status, "Connected")
    }

    public func disconnect() async {
        state.withLock { $0.remote = nil }
        hub.emit(.status, "Disconnected")
    }

    public func homeDirectory() async throws -> String { "/" }

    // MARK: Operations

    public func list(_ path: String) async throws -> [RemoteItem] {
        let fs = try currentFs()
        do {
            let result = try await client.call(
                "operations/list", ["fs": .string(fs), "remote": .string(Self.remotePath(path))], as: ListResponse.self
            )
            return result.list.map { $0.item(in: path) }
        } catch {
            throw map(error, path: path)
        }
    }

    public func stat(_ path: String) async throws -> RemoteItem? {
        let remote = Self.remotePath(path)
        if remote.isEmpty { return RemoteItem(name: "/", path: "/", isDirectory: true) }
        let fs = try currentFs()
        do {
            let result = try await client.call(
                "operations/stat", ["fs": .string(fs), "remote": .string(remote)], as: StatResponse.self, quiet: true
            )
            return result.item?.item(in: RemotePath.parent(of: path))
        } catch {
            throw map(error, path: path)
        }
    }

    public func download(_ remote: String, to local: URL, progress: Progress, resume: Bool) async throws {
        let fs = try currentFs()
        guard let item = try await stat(remote) else { throw RemoteError.notFound(remote) }
        if progress.totalUnitCount <= 0, let size = item.size { progress.totalUnitCount = Int64(size) }
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        hub.emit(.status, "Downloading \(remote)")
        try await transfer(
            "operations/copyfile",
            [
                "srcFs": .string(fs), "srcRemote": .string(Self.remotePath(remote)),
                "dstFs": .string(Self.localFs(local.deletingLastPathComponent())), "dstRemote": .string(local.lastPathComponent),
            ],
            progress: progress, path: remote
        )
        hub.emit(.status, "Downloaded \(remote)")
    }

    public func upload(_ local: URL, to remote: String, progress: Progress, resume: Bool) async throws {
        let fs = try currentFs()
        if progress.totalUnitCount <= 0, let size = Self.localSize(of: local) { progress.totalUnitCount = Int64(size) }
        hub.emit(.status, "Uploading \(remote)")
        try await transfer(
            "operations/copyfile",
            [
                "srcFs": .string(Self.localFs(local.deletingLastPathComponent())), "srcRemote": .string(local.lastPathComponent),
                "dstFs": .string(fs), "dstRemote": .string(Self.remotePath(remote)),
            ],
            progress: progress, path: remote
        )
        hub.emit(.status, "Uploaded \(remote)")
    }

    public func mkdir(_ path: String) async throws {
        let fs = try currentFs()
        do {
            try await client.call("operations/mkdir", ["fs": .string(fs), "remote": .string(Self.remotePath(path))])
        } catch {
            throw map(error, path: path)
        }
    }

    public func rename(_ from: String, _ to: String) async throws {
        let fs = try currentFs()
        guard let item = try await stat(from) else { throw RemoteError.notFound(from) }
        let src = Self.remotePath(from), dst = Self.remotePath(to)
        do {
            if item.isDirectory {
                try await client.call("sync/move", [
                    "srcFs": .string(Self.join(fs, src)), "dstFs": .string(Self.join(fs, dst)),
                    "createEmptySrcDirs": true, "deleteEmptySrcDirs": true,
                ])
            } else {
                try await client.call("operations/movefile", [
                    "srcFs": .string(fs), "srcRemote": .string(src), "dstFs": .string(fs), "dstRemote": .string(dst),
                ])
            }
        } catch {
            throw map(error, path: from)
        }
    }

    public func delete(_ path: String, recursive: Bool) async throws {
        let fs = try currentFs()
        guard let item = try await stat(path) else { throw RemoteError.notFound(path) }
        let params: [String: JSONValue] = ["fs": .string(fs), "remote": .string(Self.remotePath(path))]
        do {
            if !item.isDirectory {
                try await client.call("operations/deletefile", params)
            } else {
                try await client.call(recursive ? "operations/purge" : "operations/rmdir", params)
            }
        } catch {
            throw map(error, path: path)
        }
    }

    public func chmod(_ path: String, mode: UInt16) async throws {}

    // MARK: Jobs

    private func transfer(_ method: String, _ params: [String: JSONValue], progress: Progress, path: String) async throws {
        let group = "dockyard-\(UUID().uuidString)"
        var body = params
        body["_async"] = true
        body["_group"] = .string(group)
        let client = client
        do {
            let job = try await client.call(method, body, as: JobStart.self)
            try await withTaskCancellationHandler {
                try await follow(job: job.jobid, group: group, progress: progress)
            } onCancel: {
                Task { _ = try? await client.call("job/stop", ["jobid": .int(job.jobid)], quiet: true) }
            }
        } catch {
            _ = try? await client.call("core/stats-delete", ["group": .string(group)], quiet: true)
            if error is CancellationError { throw error }
            throw map(error, path: path)
        }
        _ = try? await client.call("core/stats-delete", ["group": .string(group)], quiet: true)
    }

    private func follow(job: Int, group: String, progress: Progress) async throws {
        var lastRetries = 0
        while true {
            if Task.isCancelled || progress.isCancelled {
                _ = try? await client.call("job/stop", ["jobid": .int(job)], quiet: true)
                throw CancellationError()
            }
            let status = try await client.call("job/status", ["jobid": .int(job)], as: JobStatus.self, quiet: true)
            if let stats = try? await client.call("core/stats", ["group": .string(group)], as: Stats.self, quiet: true) {
                let active = stats.transferring?.reduce(Int64(0)) { $0 + $1.bytes } ?? 0
                let done = max(stats.bytes, active)
                if done > progress.completedUnitCount { progress.completedUnitCount = done }
                let retries = (stats.lowLevelRetries ?? 0) + (stats.retries ?? 0)
                if retries > lastRetries {
                    lastRetries = retries
                    hub.emit(.warning, "Retrying: \(RcloneRedactor.redact(stats.lastError ?? "transient error"))")
                }
            }
            if status.finished {
                if status.success {
                    if progress.totalUnitCount > 0 { progress.completedUnitCount = progress.totalUnitCount }
                    return
                }
                if Task.isCancelled { throw CancellationError() }
                let message = RcloneRedactor.redact(status.error ?? "transfer failed")
                if message.lowercased().contains("context canceled") { throw CancellationError() }
                throw RcloneRPCError(method: "job/status", status: 500, message: message)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Helpers

    private func currentFs() throws -> String {
        guard let remote = state.withLock({ $0.remote }) else { throw RemoteError.notConnected }
        return remote.fs
    }

    /// `:s3,...:bucket` + `a/b` -> `:s3,...:bucket/a/b`.
    private static func join(_ fs: String, _ path: String) -> String {
        guard !path.isEmpty else { return fs }
        return fs.hasSuffix(":") || fs.hasSuffix("/") ? fs + path : fs + "/" + path
    }

    static func remotePath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func localSize(of url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    static func localFs(_ directory: URL) -> String {
        ":local:" + directory.path
    }

    private func map(_ error: Error, path: String) -> Error {
        guard let rpc = error as? RcloneRPCError else { return error }
        let text = rpc.message.lowercased()
        let mapped: RemoteError
        if rpc.status == 404 || text.contains("not found") || text.contains("nosuchbucket") || text.contains("nosuchkey")
            || text.contains("doesn't exist") {
            mapped = .notFound(path)
        } else if rpc.status == 401 || text.contains("invalidaccesskeyid") || text.contains("signaturedoesnotmatch")
            || text.contains("invalid_grant") || text.contains("unauthorized") || text.contains("bad credentials") {
            mapped = .authenticationFailed(rpc.message)
        } else if rpc.status == 403 || text.contains("accessdenied") || text.contains("permission denied") {
            mapped = .permissionDenied(rpc.message)
        } else {
            mapped = .protocolError(rpc.message)
        }
        hub.emit(.error, mapped.description)
        return mapped
    }
}

// MARK: rc payloads

struct RcloneListEntry: Decodable, Equatable {
    var name: String
    var size: Int64
    var modTime: String?
    var isDir: Bool

    enum CodingKeys: String, CodingKey {
        case name = "Name", size = "Size", modTime = "ModTime", isDir = "IsDir"
    }

    func item(in directory: String) -> RemoteItem {
        RemoteItem(
            name: name,
            path: RemotePath.join(directory.isEmpty ? "/" : directory, name),
            isDirectory: isDir,
            size: isDir || size < 0 ? nil : UInt64(size),
            modified: modTime.flatMap(RcloneDate.parse)
        )
    }
}

struct ListResponse: Decodable { var list: [RcloneListEntry] }
struct StatResponse: Decodable { var item: RcloneListEntry? }
struct JobStart: Decodable { var jobid: Int }

struct JobStatus: Decodable {
    var finished: Bool
    var success: Bool
    var error: String?
}

struct Stats: Decodable {
    struct Transfer: Decodable { var bytes: Int64 }
    var bytes: Int64
    var lowLevelRetries: Int?
    var retries: Int?
    var lastError: String?
    var transferring: [Transfer]?
}

enum RcloneDate {
    /// Parses RFC 3339 timestamps with up to nanosecond precision.
    static func parse(_ string: String) -> Date? {
        var s = string
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let fraction = s[s.index(after: dot)..<end].prefix(3)
            s = String(s[..<dot]) + "." + fraction + String(s[end...])
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}
