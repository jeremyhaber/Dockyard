import Foundation
import Testing
import ConnectionKit
@testable import DockyardCore

/// Runs against the containers from `Packages/ConnectionKit/scripts/integration-servers.sh`; skipped unless DOCKYARD_INTEGRATION=1.
enum Live {
    static let enabled = ProcessInfo.processInfo.environment["DOCKYARD_INTEGRATION"] == "1"
    static let host = ProcessInfo.processInfo.environment["DOCKYARD_HOST"] ?? "127.0.0.1"
    static let user = "dockyard"
    static let password = "dockyard-test-pw"
    static let rootPassword = "root-test-pw"
    static let sshPort = 2222
    static let limitedFTPPort = 2123
}

private func sftp(elevation: Elevation = .none, browseAsRoot: Bool = false) async throws -> SFTPFileSystem {
    var config = ConnectionConfig(protocol: .sftp, host: Live.host, port: Live.sshPort, username: Live.user, authMethods: .password, elevation: elevation)
    config.id = UUID()
    let secrets = InMemorySecretStore()
    await secrets.setSecret(Live.password, for: config.id, purpose: .password)
    await secrets.setSecret(elevation == .su ? Live.rootPassword : Live.password, for: config.id, purpose: .elevationPassword)
    let fs = SFTPFileSystem(config: config, secrets: secrets, options: .init(browseAsRoot: browseAsRoot))
    try await fs.connect()
    return fs
}

private func owner(_ fs: SFTPFileSystem, _ path: String) async throws -> String {
    try await fs.exec("stat -c %U \(ShellQuote.quote(path))").stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
}

@Suite(.enabled(if: Live.enabled), .serialized) struct ArchiveIntegrationTests {
    private func populate(_ fs: SFTPFileSystem, _ base: String, newlines: Bool) async throws {
        _ = try await fs.exec("mkdir -p \(ShellQuote.quote(base))")
        let local = try makeTempDir("seed")
        defer { try? FileManager.default.removeItem(at: local) }
        for (i, name) in nastyNames.enumerated() where newlines || !name.contains("\n") {
            let file = local.appendingPathComponent("seed")
            try Data("content \(i)".utf8).write(to: file)
            try await fs.upload(file, to: RemotePath.join(base, name), progress: Progress(totalUnitCount: 0))
        }
        try await fs.mkdir(RemotePath.join(base, "odd folder $x 'q'"))
        let file = local.appendingPathComponent("seed")
        try Data("inner".utf8).write(to: file)
        try await fs.upload(file, to: RemotePath.join(base, "odd folder $x 'q'/in side.txt"), progress: Progress(totalUnitCount: 0))
    }

    private func remoteTree(_ fs: SFTPFileSystem, _ base: String) async throws -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ dir: String, _ prefix: String) async throws {
            for item in try await fs.list(dir) {
                if item.isDirectory { try await walk(item.path, prefix + item.name + "/"); continue }
                let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: local) }
                try await fs.download(item.path, to: local, progress: Progress(totalUnitCount: 0))
                out[prefix + item.name] = try String(contentsOf: local, encoding: .utf8)
            }
        }
        try await walk(base, "")
        return out
    }

    @Test(arguments: [ArchiveFormat.zip, .tarGz, .tar])
    func compressAndExtractRoundTripWithNastyNames(format: ArchiveFormat) async throws {
        let fs = try await sftp()
        let base = "/tmp/dockyard-arch-\(UUID().uuidString.prefix(8))"
        defer { Task { _ = try? await fs.exec("rm -rf \(ShellQuote.quote(base))"); await fs.disconnect() } }
        try await populate(fs, base + "/src dir", newlines: format != .zip)  // Info-ZIP mangles line breaks in names
        let names = try await fs.list(base + "/src dir").map(\.name).sorted()
        let service = ArchiveService(conflictPolicy: .overwrite)
        let lines = LockedBox<[String]>([])
        let stream = service.log.stream()
        let collector = Task { for await l in stream { lines.withLock { $0.append("\(l.kind.rawValue): \(l.message)") } } }

        let archive = "\(base)/it's an archive.\(format.fileExtension)"
        let made = try await service.compress(CompressRequest(directory: base + "/src dir", names: names, destination: archive, format: format), on: fs)
        #expect(made.placed == [archive])
        #expect(try await fs.lookup(archive)?.size ?? 0 > 0)
        #expect(try await fs.list(base).map(\.name).sorted() == ["it's an archive.\(format.fileExtension)", "src dir"])

        let result = try await service.extract(ExtractRequest(archive: archive, destination: base + "/out put"), on: fs)
        #expect(result.placed.count == names.count)
        #expect(try await remoteTree(fs, base + "/out put") == remoteTree(fs, base + "/src dir"))
        #expect(try await fs.list(base + "/out put").map(\.name).sorted() == names)  // no temp folder left

        try await Task.sleep(nanoseconds: 100_000_000)
        collector.cancel()
        let log = lines.withLock { $0 }
        #expect(log.contains { $0.hasPrefix("command:") })
        #expect(!log.contains { $0.contains(Live.password) })
    }

    @Test(arguments: [Elevation.sudo, Elevation.su])
    func browsingAsRootProducesRootOwnedArchivesAndFiles(kind: Elevation) async throws {
        let fs = try await sftp(elevation: kind, browseAsRoot: true)
        #expect(await fs.isBrowsingAsRoot)
        let base = "/tmp/dockyard-root-\(UUID().uuidString.prefix(8))"
        defer { Task { _ = try? await fs.runCommand("rm -rf \(base)", elevated: true) { _, _ in }; await fs.disconnect() } }
        try await fs.mkdir(base)
        try await fs.mkdir(base + "/src")
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("as root".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        try await fs.upload(local, to: base + "/src/file.txt", progress: Progress(totalUnitCount: 0))

        let service = ArchiveService(conflictPolicy: .overwrite)
        _ = try await service.compress(
            CompressRequest(directory: base + "/src", names: ["file.txt"], destination: base + "/a.tar.gz", format: .tarGz), on: fs)
        #expect(try await owner(fs, base + "/a.tar.gz") == "root")
        _ = try await service.extract(ExtractRequest(archive: base + "/a.tar.gz", destination: base + "/out"), on: fs)
        #expect(try await owner(fs, base + "/out/file.txt") == "root")
    }

    @Test func cancellingAnExtractionStopsTheRemoteTarAndLeavesNothingBehind() async throws {
        let fs = try await sftp()
        let base = "/tmp/dockyard-cancel-\(UUID().uuidString.prefix(8))"
        defer { Task { _ = try? await fs.exec("rm -rf \(base)"); await fs.disconnect() } }
        // A big, slow-to-unpack archive: lots of files.
        _ = try await fs.exec("mkdir -p \(base)/src && cd \(base)/src && for i in $(seq 1 3000); do head -c 20000 /dev/urandom > f$i; done && tar -czf \(base)/big.tar.gz .")
        let service = ArchiveService(conflictPolicy: .overwrite)
        let task = Task { try await service.extract(ExtractRequest(archive: base + "/big.tar.gz", destination: base + "/out"), on: fs) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do { _ = try await task.value; Issue.record("finished before it could be cancelled") } catch is CancellationError {} catch { Issue.record("\(error)") }
        try await Task.sleep(nanoseconds: 500_000_000)
        let running = try await fs.exec("pgrep -f '[b]ig.tar.gz' | wc -l").stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(running == "0")
        #expect(try await fs.list(base + "/out").isEmpty)
    }
}

@Suite(.enabled(if: Live.enabled), .serialized) struct BackoffIntegrationTests {
    @Test func aServerLimitedToTwoConnectionsIsNeverOverloadedAndNothingFails() async throws {
        let config = ConnectionConfig(protocol: .ftp, host: Live.host, port: Live.limitedFTPPort, username: Live.user, authMethods: .password)
        let secrets = InMemorySecretStore()
        await secrets.setSecret(Live.password, for: config.id, purpose: .password)
        let site = TransferSite(id: config.id, label: "Limited FTP", maxConnections: 6) { FTPFileSystem(config: config, secrets: secrets) }

        let env = try TransferEnv()
        let q = TransferQueue(maxConcurrent: 10, conflictPolicy: .overwrite, tempDirectory: env.dir, progressInterval: 0.05,
                              publishInterval: 0.05, recoverAfter: 1000, refusalRetryDelay: 0.3, maxRefusalRetries: 12)
        await q.register(site: site)
        let remote = "/backoff-\(UUID().uuidString.prefix(8))"
        let probe = FTPFileSystem(config: config, secrets: secrets)
        try await probe.connect()
        try await probe.mkdir(remote)
        await probe.disconnect()  // the server allows two connections and the queue should have them
        let endpoint = TransferEndpoint(fs: probe, label: "Limited FTP", siteId: site.id)

        let logs = q.log.stream()
        let warnings = LockedBox(0)
        let watcher = Task { for await l in logs where l.kind == .warning { warnings.withLock { $0 += 1 } } }
        var requests: [TransferRequest] = []
        for i in 0..<40 {
            try env.write("f\(i).bin", String(repeating: "x", count: 20_000))
            requests.append(upload(env, "f\(i).bin", to: endpoint, "\(remote)/f\(i).bin"))
        }
        await q.enqueue(requests)
        await q.waitUntilIdle()
        let snap = await q.snapshot()
        print("BACKOFF: completed \(snap.completedCount), failed \(snap.failedCount), final live limit \(snap.sites.first?.liveLimit ?? -1), warnings \(warnings.withLock { $0 })")
        #expect(snap.completedCount == 40 && snap.failedCount == 0)
        #expect(snap.sites.first?.liveLimit ?? 99 <= 2)
        #expect(warnings.withLock { $0 } > 0)
        await q.shutdown()
        watcher.cancel()
        try await probe.connect()
        #expect(try await probe.list(remote).count == 40)
        try? await probe.delete(remote, recursive: true)
        await probe.disconnect()
    }
}
