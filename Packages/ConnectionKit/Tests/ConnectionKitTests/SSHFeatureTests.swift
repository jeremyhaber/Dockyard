import Foundation
import Testing
@testable import ConnectionKit

/// Needs the containers from `scripts/integration-servers.sh`; skipped unless DOCKYARD_INTEGRATION=1.
private func connectAndList(_ config: ConnectionConfig, secrets: SecretStore, options: SFTPFileSystem.Options = .init()) async throws -> [String] {
    let fs = SFTPFileSystem(config: config, secrets: secrets, options: options)
    let log = LogCollector(fs.logStream)
    try await fs.connect()
    _ = try await fs.list(try await fs.homeDirectory())
    await fs.disconnect()
    return await log.snapshot().map(\.message)
}

/// Accumulates shell output so tests can wait for text to appear.
private final class OutputCollector: Sendable {
    private let text = LockedBox("")
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<Data>) {
        let text = self.text
        task = Task { for await data in stream { text.withLock { $0 += String(decoding: data, as: UTF8.self) } } }
    }

    var contents: String { text.withLock { $0 } }

    func wait(for needle: String, seconds: Double = 15) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if contents.contains(needle) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return contents.contains(needle)
    }

    func waitForLine(_ line: String, seconds: Double = 15) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if contents.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == line }) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    deinit { task.cancel() }
}

private func elevatedStore(_ config: ConnectionConfig, elevationPassword: String) async -> InMemorySecretStore {
    let secrets = await store(for: config)
    await secrets.setSecret(elevationPassword, for: config.id, purpose: .elevationPassword)
    return secrets
}

@Suite(.serialized, .enabled(if: Env.enabled)) struct SSHFeatureIntegrationTests {
    @Test(arguments: [
        ("id_rsa_pem", nil), ("id_rsa_pem_enc", Env.keyPassphrase), ("id_rsa_pkcs8", nil),
        ("id_ecdsa", nil), ("id_ecdsa_384_pem", nil), ("id_ed25519_pkcs8", nil),
    ] as [(String, String?)])
    func keyFormats(keyName: String, passphrase: String?) async throws {
        let config = sftpConfig(auth: .key, key: Env.key(keyName))
        let lines = try await connectAndList(config, secrets: await store(password: nil, passphrase: passphrase, for: config))
        #expect(lines.contains { $0.contains("Authenticated with public key") })
    }

    @Test func keyboardInteractiveOnlyServer() async throws {
        let config = sftpConfig(auth: .keyboardInteractive, port: Env.kbdPort)
        let lines = try await connectAndList(config, secrets: await store(for: config))
        #expect(lines.contains { $0.contains("Authenticated with keyboard-interactive") })
        #expect(!lines.contains { $0.contains(Env.password) })
    }

    @Test func passwordMethodFallsBackToKeyboardInteractive() async throws {
        let config = sftpConfig(auth: .password, port: Env.kbdPort)
        let lines = try await connectAndList(config, secrets: await store(for: config))
        #expect(lines.contains("Password authentication rejected; trying keyboard-interactive"))
        #expect(lines.contains { $0.contains("Authenticated with keyboard-interactive") })
    }

    @Test func keyAndPasswordOnOneConnection() async throws {
        // The server requires `publickey,password`: the key succeeds partially, then the password completes.
        let config = sftpConfig(auth: .both, key: Env.key("id_ed25519"), port: Env.bothPort)
        let lines = try await connectAndList(config, secrets: await store(for: config))
        #expect(lines.contains("Authenticating as dockyard using public key"))
        #expect(lines.contains { $0.contains("Authenticated with password") })
    }

    @Test func keyAloneIsNotEnoughForTwoFactorServer() async throws {
        let config = sftpConfig(auth: .key, key: Env.key("id_ed25519"), port: Env.bothPort)
        let fs = SFTPFileSystem(config: config, secrets: await store(password: nil, for: config))
        await #expect(throws: (any Error).self) { try await fs.connect() }
    }

    @Test func hostKeyValidatorSeesFingerprintAndCanReject() async throws {
        let config = sftpConfig(auth: .password)
        let seen = LockedBox<SSHHostKey?>(nil)
        let accepting = SSHHostKeyValidator { key in
            seen.withLock { $0 = key }
            return true
        }
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config), hostKeyValidator: accepting)
        try await fs.connect()
        await fs.disconnect()
        let key = try #require(seen.withLock { $0 })
        #expect(key.fingerprint.hasPrefix("SHA256:"))
        #expect(!key.fingerprint.contains("="))
        #expect(!key.key.isEmpty)

        let rejecting = SFTPFileSystem(config: config, secrets: await store(for: config), hostKeyValidator: SSHHostKeyValidator { _ in false })
        await #expect {
            try await rejecting.connect()
        } throws: { error in
            if case RemoteError.hostKeyRejected(let fingerprint) = error { return fingerprint == key.fingerprint }
            return false
        }
    }

    @Test(arguments: ["id_ed25519", "id_rsa"])
    func sshAgent(keyName: String) async throws {
        let agent = try TestSSHAgent.start()
        defer { agent.stop() }
        try agent.add(Env.key(keyName))
        let config = sftpConfig(auth: .agent)
        let lines = try await connectAndList(config, secrets: await store(password: nil, for: config))
        #expect(lines.contains { $0.contains("Authenticated with ssh-agent") })
    }

    @Test func execChannel() async throws {
        let config = sftpConfig(auth: .password)
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config))
        try await fs.connect()
        let result = try await fs.exec("echo out; echo err >&2; exit 3")
        #expect(result.stdoutString == "out\n")
        #expect(result.stderrString == "err\n")
        #expect(result.exitStatus == 3)
        _ = try await fs.list(try await fs.homeDirectory())
        await fs.disconnect()
    }

    @Test func shellChannelWithResize() async throws {
        let config = sftpConfig(auth: .password)
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config))
        try await fs.connect()
        let shell = try await fs.openShell(cols: 80, rows: 24)
        let output = OutputCollector(shell.output)
        try await shell.write(Data("echo hi-$((40+2))\n".utf8))
        #expect(await output.wait(for: "hi-42\r\n"))
        try await shell.resize(cols: 100, rows: 30)
        try await shell.write(Data("stty size\n".utf8))
        #expect(await output.wait(for: "30 100\r\n"))
        // File operations keep working while the shell is open.
        _ = try await fs.list(try await fs.homeDirectory())
        try await shell.write(Data("exit\n".utf8))
        for await _ in shell.output {}
        await fs.disconnect()
    }

    @Test(arguments: [(Elevation.sudo, Env.password), (Elevation.su, Env.rootPassword)])
    func elevatedShell(kind: Elevation, password: String) async throws {
        var config = sftpConfig(auth: .password)
        config.elevation = kind
        let fs = SFTPFileSystem(config: config, secrets: await elevatedStore(config, elevationPassword: password))
        let log = LogCollector(fs.logStream)
        try await fs.connect()
        let shell = try await fs.openShell(cols: 80, rows: 24)
        let output = OutputCollector(shell.output)
        #expect(await output.wait(for: "assword"))
        try await Task.sleep(for: .seconds(1))
        try await shell.write(Data("id -un\n".utf8))
        #expect(await output.waitForLine("root"), "output: \(output.contents)")
        #expect(!output.contents.contains(password))
        await shell.close()
        await fs.disconnect()
        let lines = await log.snapshot().map(\.message)
        #expect(lines.contains("Sent elevation password"))
        #expect(!lines.contains { $0.contains(password) })
    }

    @Test(arguments: [(Elevation.sudo, Env.password), (Elevation.su, Env.rootPassword)])
    func browseFilesAsRoot(kind: Elevation, password: String) async throws {
        var config = sftpConfig(auth: .password)
        config.elevation = kind
        let secrets = await elevatedStore(config, elevationPassword: password)
        let fs = SFTPFileSystem(config: config, secrets: secrets, options: .init(browseAsRoot: true))
        let log = LogCollector(fs.logStream)
        try await fs.connect()
        #expect(await fs.isBrowsingAsRoot)
        _ = try await fs.list("/root")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("root-\(UUID().uuidString)")
        try randomData(300_000).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let remote = "/tmp/dockyard-root-\(UUID().uuidString.prefix(8)).bin"
        try await fs.upload(tmp, to: remote, progress: Progress(totalUnitCount: 0))
        let owner = try await fs.exec("stat -c %U \(remote)").stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(owner == "root")
        try await fs.delete(remote, recursive: false)
        await fs.disconnect()

        let lines = await log.snapshot().map(\.message)
        #expect(lines.contains("Browsing files as root"))
        #expect(!lines.contains { $0.contains(password) })
    }

    @Test func rootBrowsingFallsBackToNormalUserWhenElevationFails() async throws {
        var config = sftpConfig(auth: .password)
        config.elevation = .sudo
        let secrets = await elevatedStore(config, elevationPassword: "wrong-password")
        let fs = SFTPFileSystem(config: config, secrets: secrets, options: .init(browseAsRoot: true))
        let log = LogCollector(fs.logStream)
        try await fs.connect()
        #expect(await !fs.isBrowsingAsRoot)
        await #expect(throws: (any Error).self) { try await fs.list("/root") }
        _ = try await fs.list(try await fs.homeDirectory())
        await fs.disconnect()
        let warnings = await log.snapshot().filter { $0.kind == .warning }
        #expect(warnings.contains { $0.message.contains("Could not browse as root") })
        #expect(!warnings.contains { $0.message.contains("wrong-password") })
    }

    /// 40 ms round trip through scripts/latency-proxy.py: one 32 KiB request per round trip would need about 10 s per 8 MB.
    @Test func pipelinedTransfersOverHighLatency() async throws {
        let config = sftpConfig(auth: .password, port: Env.slowPort)
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config))
        try await fs.connect()
        let home = try await fs.homeDirectory()
        let content = randomData(8_000_000)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("slow-\(UUID().uuidString)")
        try content.write(to: local)
        let back = local.appendingPathExtension("back")
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: back)
        }
        let remote = RemotePath.join(home, "slow-\(UUID().uuidString.prefix(8)).bin")

        let clock = ContinuousClock()
        let upload = try await clock.measure { try await fs.upload(local, to: remote, progress: Progress(totalUnitCount: 0)) }
        let download = try await clock.measure { try await fs.download(remote, to: back, progress: Progress(totalUnitCount: 0)) }
        #expect(try Data(contentsOf: back) == content)
        try await fs.delete(remote, recursive: false)
        await fs.disconnect()
        #expect(upload < .seconds(5), "upload took \(upload)")
        #expect(download < .seconds(5), "download took \(download)")
    }

    @Test func uploadPreservesModificationTime() async throws {
        let config = sftpConfig(auth: .password)
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config))
        try await fs.connect()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("mtime-\(UUID().uuidString)")
        try Data("x".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: local.path)
        let remote = RemotePath.join(try await fs.homeDirectory(), "mtime-\(UUID().uuidString.prefix(8))")
        try await fs.upload(local, to: remote, progress: Progress(totalUnitCount: 0))
        #expect(try await fs.stat(remote)?.modified == date)
        try await fs.delete(remote, recursive: false)
        await fs.disconnect()
    }
}

/// A throwaway ssh-agent on a private socket; the process environment points at it while it runs.
/// Uses posix_spawn because Foundation's `Process.waitUntilExit` can hang on Linux outside a run loop.
private struct TestSSHAgent {
    let pid: pid_t
    let socket: String

    static func start() throws -> TestSSHAgent {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString.prefix(8)).sock").path
        let pid = try spawn("/usr/bin/ssh-agent", ["-D", "-a", socket], environment: [:])
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) { Thread.sleep(forTimeInterval: 0.05) }
        setenv("SSH_AUTH_SOCK", socket, 1)
        return TestSSHAgent(pid: pid, socket: socket)
    }

    func add(_ key: String) throws {
        let pid = try Self.spawn("/usr/bin/ssh-add", [key], environment: ["SSH_AUTH_SOCK": socket])
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        guard status == 0 else { throw RemoteError.invalidConfiguration("ssh-add failed for \(key)") }
    }

    func stop() {
        unsetenv("SSH_AUTH_SOCK")
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        try? FileManager.default.removeItem(atPath: socket)
    }

    private static func spawn(_ path: String, _ arguments: [String], environment: [String: String]) throws -> pid_t {
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, nil, nil, argv, envp) == 0 else {
            throw RemoteError.invalidConfiguration("Cannot start \(path)")
        }
        return pid
    }
}
