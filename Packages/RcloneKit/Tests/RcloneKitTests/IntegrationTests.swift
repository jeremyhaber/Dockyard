import ConnectionKit
import Foundation
import Testing
@testable import RcloneKit

/// Runs against MinIO from `scripts/minio.sh`; skipped unless DOCKYARD_INTEGRATION=1 and DOCKYARD_LIBRCLONE points at a built librclone.
private enum Env {
    static let library: RcloneLibrary? = {
        guard ProcessInfo.processInfo.environment["DOCKYARD_INTEGRATION"] == "1" else { return nil }
        return try? RcloneLibrary.load(explicit: nil)
    }()
    static var enabled: Bool { library != nil }
    static let endpoint = ProcessInfo.processInfo.environment["DOCKYARD_MINIO_ENDPOINT"] ?? "http://127.0.0.1:9000"
    static let accessKey = "dockyard"
    static let secretKey = "dockyard-test-secret"
}

private final class LogCollector: Sendable {
    private let lines = LockedBox<[LogLine]>([])
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<LogLine>) {
        let lines = lines
        task = Task { for await line in stream { lines.withLock { $0.append(line) } } }
    }

    var messages: [String] { lines.withLock { $0.map(\.message) } }
    deinit { task.cancel() }
}

private func connect(root: String = "") async throws -> RcloneFileSystem {
    let library = try #require(Env.library)
    let config = ConnectionConfig(protocol: .rclone, host: Env.endpoint, username: Env.accessKey)
    let secrets = InMemorySecretStore()
    await secrets.setSecret(Env.secretKey, for: config.id, purpose: .cloudToken)
    let spec = RcloneRemoteSpec(backend: .s3, options: ["provider": S3Provider.minio, "region": "us-east-1"], root: root)
    let fs = RcloneFileSystem(config: config, spec: spec, secrets: secrets, transport: library)
    try await fs.connect()
    return fs
}

private func tempFile(_ name: String, bytes: Int) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rclonekit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    let chunk = Data((0..<(1 << 20)).map { _ in UInt8.random(in: 0...255) })
    var remaining = bytes
    while remaining > 0 {
        let n = min(remaining, chunk.count)
        try handle.write(contentsOf: chunk.prefix(n))
        remaining -= n
    }
    try handle.close()
    return url
}

private func setBandwidth(_ rate: String) async throws {
    let client = RcloneClient(transport: try #require(Env.library))
    try await client.call("core/bwlimit", ["rate": .string(rate)])
}

@Suite(.serialized, .enabled(if: Env.enabled)) struct RcloneIntegrationTests {
    @Test func bucketLifecycleAndTransfers() async throws {
        let fs = try await connect()
        let logs = LogCollector(fs.logStream)
        let bucket = "it-\(UUID().uuidString.prefix(8).lowercased())"
        let base = "/\(bucket)"

        try await fs.mkdir(base)
        #expect(try await fs.list("/").contains { $0.name == bucket && $0.isDirectory })
        #expect(fs.isRoot(base))

        try await fs.mkdir("\(base)/docs")
        let source = try tempFile("hello.bin", bytes: 300_000)
        try await fs.upload(source, to: "\(base)/docs/hello.bin", progress: Progress(totalUnitCount: 0))
        let listing = try await fs.list("\(base)/docs")
        #expect(listing.map(\.name) == ["hello.bin"])
        #expect(listing[0].size == 300_000)
        #expect(listing[0].path == "\(base)/docs/hello.bin")
        #expect(listing[0].modified != nil)

        let back = source.deletingLastPathComponent().appendingPathComponent("back/copy.bin")
        try await fs.download("\(base)/docs/hello.bin", to: back, progress: Progress(totalUnitCount: 0))
        #expect(try Data(contentsOf: back) == Data(contentsOf: source))

        try await fs.rename("\(base)/docs/hello.bin", "\(base)/docs/renamed.bin")
        #expect(try await fs.exists("\(base)/docs/renamed.bin"))
        #expect(try await fs.exists("\(base)/docs/hello.bin") == false)

        try await fs.rename("\(base)/docs", "\(base)/papers")
        #expect(try await fs.list("\(base)/papers").map(\.name) == ["renamed.bin"])

        try await fs.chmod("\(base)/papers/renamed.bin", mode: 0o600)
        try await fs.delete("\(base)/papers/renamed.bin", recursive: false)
        #expect(try await fs.list("\(base)/papers").isEmpty)

        await #expect(throws: RemoteError.self) {
            try await fs.download("\(base)/missing", to: back, progress: Progress(totalUnitCount: 0))
        }

        try await fs.delete(base, recursive: true)
        #expect(try await fs.list("/").contains { $0.name == bucket } == false)

        try await Task.sleep(for: .milliseconds(200))
        let messages = logs.messages
        #expect(messages.contains { $0.hasPrefix("rc operations/copyfile") })
        #expect(messages.allSatisfy { !$0.contains(Env.secretKey) })
        await fs.disconnect()
    }

    @Test func bucketRootedConnection() async throws {
        let admin = try await connect()
        let bucket = "it-\(UUID().uuidString.prefix(8).lowercased())"
        try await admin.mkdir("/\(bucket)")
        defer { Task { try? await admin.delete("/\(bucket)", recursive: true) } }

        let fs = try await connect(root: bucket)
        try await fs.mkdir("/sub")
        let file = try tempFile("a.txt", bytes: 10)
        try await fs.upload(file, to: "/sub/a.txt", progress: Progress(totalUnitCount: 0))
        #expect(try await fs.list("/").map(\.name) == ["sub"])
        #expect(try await fs.list("/sub").map(\.name) == ["a.txt"])
        #expect(fs.isRoot("/") && !fs.isRoot("/sub"))
        try await admin.delete("/\(bucket)", recursive: true)
    }

    @Test func reportsProgressOnLargeFile() async throws {
        let fs = try await connect()
        let bucket = "it-\(UUID().uuidString.prefix(8).lowercased())"
        try await fs.mkdir("/\(bucket)")
        let size = 24 * 1024 * 1024
        let file = try tempFile("big.bin", bytes: size)
        try await setBandwidth("12M")
        defer { Task { try? await setBandwidth("off") } }

        let progress = Progress(totalUnitCount: Int64(size))
        let seen = LockedBox<Set<Int64>>([])
        let sampler = Task {
            while !Task.isCancelled {
                seen.withLock { _ = $0.insert(progress.completedUnitCount) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        try await fs.upload(file, to: "/\(bucket)/big.bin", progress: progress)
        sampler.cancel()

        #expect(progress.completedUnitCount == Int64(size))
        #expect(seen.withLock { $0.filter { $0 > 0 && $0 < Int64(size) }.count } >= 2)
        #expect(try await fs.stat("/\(bucket)/big.bin")?.size == UInt64(size))
        try await setBandwidth("off")
        try await fs.delete("/\(bucket)", recursive: true)
    }

    @Test func cancelStopsTransfer() async throws {
        let fs = try await connect()
        let bucket = "it-\(UUID().uuidString.prefix(8).lowercased())"
        try await fs.mkdir("/\(bucket)")
        let file = try tempFile("cancel.bin", bytes: 24 * 1024 * 1024)
        try await setBandwidth("4M")
        defer { Task { try? await setBandwidth("off") } }

        let progress = Progress(totalUnitCount: 0)
        let task = Task { try await fs.upload(file, to: "/\(bucket)/cancel.bin", progress: progress) }
        try await Task.sleep(for: .milliseconds(1200))
        task.cancel()
        do {
            try await task.value
            Issue.record("upload should have been cancelled")
        } catch is CancellationError {
        }
        try await setBandwidth("off")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await fs.exists("/\(bucket)/cancel.bin") == false)
        try await fs.delete("/\(bucket)", recursive: true)
    }

    @Test func wrongSecretFailsAuthentication() async throws {
        let library = try #require(Env.library)
        let config = ConnectionConfig(protocol: .rclone, host: Env.endpoint, username: Env.accessKey)
        let secrets = InMemorySecretStore()
        await secrets.setSecret("wrong-secret", for: config.id, purpose: .cloudToken)
        let spec = RcloneRemoteSpec(backend: .s3, options: ["provider": S3Provider.minio])
        let fs = RcloneFileSystem(config: config, spec: spec, secrets: secrets, transport: library)
        await #expect(throws: RemoteError.self) { try await fs.connect() }
    }
}
