import Foundation
import Testing
@testable import ConnectionKit

/// Runs against the containers from `scripts/integration-servers.sh`; skipped unless DOCKYARD_INTEGRATION=1.
enum Env {
    static let enabled = ProcessInfo.processInfo.environment["DOCKYARD_INTEGRATION"] == "1"
    static let host = ProcessInfo.processInfo.environment["DOCKYARD_HOST"] ?? "127.0.0.1"
    static let user = "dockyard"
    static let password = "dockyard-test-pw"
    static let keyPassphrase = "dockyard-key-pw"
    static let sshPort = 2222
    static let bothPort = 2223
    static let kbdPort = 2224
    static let slowPort = 2225
    static let rootPort = 2226
    /// An account on the root-login port with no login shell, like a cPanel account without shell access.
    static let accountUser = "cpuser"
    static let rootPassword = "root-test-pw"
    static let ftpPort = 2121
    static let vsftpdPort = 2122

    static let keyDir: String = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent(".integration/keys").path
    }()
    static func key(_ name: String) -> String { keyDir + "/" + name }
}

func sftpConfig(auth: AuthMethods, key: String? = nil, port: Int = Env.sshPort) -> ConnectionConfig {
    ConnectionConfig(protocol: .sftp, host: Env.host, port: port, username: Env.user, authMethods: auth, keyPath: key)
}

func store(password: String? = Env.password, passphrase: String? = nil, for config: ConnectionConfig) async -> InMemorySecretStore {
    let store = InMemorySecretStore()
    if let password { await store.setSecret(password, for: config.id, purpose: .password) }
    if let passphrase { await store.setSecret(passphrase, for: config.id, purpose: .keyPassphrase) }
    return store
}

/// Collects log lines in the background so tests can assert on them.
final class LogCollector: Sendable {
    private let lines = LockedBox<[LogLine]>([])
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<LogLine>) {
        let lines = self.lines
        task = Task { for await line in stream { lines.withLock { $0.append(line) } } }
    }

    func snapshot() async -> [LogLine] {
        try? await Task.sleep(for: .milliseconds(100))
        return lines.withLock { $0 }
    }

    deinit { task.cancel() }
}

func randomData(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    var words = [UInt64](repeating: 0, count: (count + 7) / 8)
    for index in words.indices { words[index] = generator.next() }
    return words.withUnsafeBytes { Data($0.prefix(count)) }
}

/// The common create / upload / download / rename / delete scenario.
func exercise(_ fs: any RemoteFileSystem, supportsPermissions: Bool = true, missingDirectoryThrows: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    try await fs.connect()
    let home = try await fs.homeDirectory()
    _ = try await fs.list(home)

    let base = RemotePath.join(home, "dockyard-it-\(UUID().uuidString.prefix(8))")
    try await fs.mkdir(base)
    #expect(try await fs.exists(base), sourceLocation: sourceLocation)

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dockyard-it-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // upload + list + download, byte for byte
    let content = randomData(1_500_000)
    let source = tmp.appendingPathComponent("source.bin")
    try content.write(to: source)
    let remoteFile = RemotePath.join(base, "data file.bin")
    let up = Progress(totalUnitCount: 0)
    try await fs.upload(source, to: remoteFile, progress: up)
    #expect(up.totalUnitCount == Int64(content.count), sourceLocation: sourceLocation)
    #expect(up.completedUnitCount == Int64(content.count), sourceLocation: sourceLocation)

    let listed = try await fs.list(base)
    let streamed = try await fs.collectListing(base)
    #expect(streamed.map(\.name).sorted() == listed.map(\.name).sorted(), sourceLocation: sourceLocation)
    let item = try #require(listed.first { $0.name == "data file.bin" }, sourceLocation: sourceLocation)
    #expect(item.size == UInt64(content.count), sourceLocation: sourceLocation)
    #expect(!item.isDirectory, sourceLocation: sourceLocation)
    #expect(item.modified != nil, sourceLocation: sourceLocation)

    let downloaded = tmp.appendingPathComponent("downloaded.bin")
    let down = Progress(totalUnitCount: 0)
    try await fs.download(remoteFile, to: downloaded, progress: down)
    #expect(try Data(contentsOf: downloaded) == content, sourceLocation: sourceLocation)
    #expect(down.completedUnitCount == Int64(content.count), sourceLocation: sourceLocation)

    // resumed download: local file already has the first part
    let partial = tmp.appendingPathComponent("partial.bin")
    try content.prefix(600_000).write(to: partial)
    let resumed = Progress(totalUnitCount: 0)
    try await fs.download(remoteFile, to: partial, progress: resumed, resume: true)
    #expect(try Data(contentsOf: partial) == content, sourceLocation: sourceLocation)

    // resumed upload: remote file already has the first part
    let halfSource = tmp.appendingPathComponent("half.bin")
    try content.prefix(700_000).write(to: halfSource)
    let resumableRemote = RemotePath.join(base, "resume.bin")
    try await fs.upload(halfSource, to: resumableRemote, progress: Progress(totalUnitCount: 0))
    try await fs.upload(source, to: resumableRemote, progress: Progress(totalUnitCount: 0), resume: true)
    let resumedCopy = tmp.appendingPathComponent("resumed-copy.bin")
    try await fs.download(resumableRemote, to: resumedCopy, progress: Progress(totalUnitCount: 0))
    #expect(try Data(contentsOf: resumedCopy) == content, sourceLocation: sourceLocation)

    // empty file, overwrite
    let empty = tmp.appendingPathComponent("empty")
    try Data().write(to: empty)
    try await fs.upload(empty, to: RemotePath.join(base, "empty"), progress: Progress(totalUnitCount: 0))
    #expect(try await fs.list(base).first { $0.name == "empty" }?.size == 0, sourceLocation: sourceLocation)
    try await fs.upload(empty, to: remoteFile, progress: Progress(totalUnitCount: 0))
    #expect(try await fs.list(base).first { $0.name == "data file.bin" }?.size == 0, sourceLocation: sourceLocation)

    // rename a file and a directory
    let renamed = RemotePath.join(base, "renamed.bin")
    try await fs.rename(remoteFile, renamed)
    #expect(try await fs.exists(renamed), sourceLocation: sourceLocation)
    #expect(try await !fs.exists(remoteFile), sourceLocation: sourceLocation)

    let sub = RemotePath.join(base, "sub")
    try await fs.mkdir(sub)
    try await fs.mkdir(RemotePath.join(sub, "nested"))
    try await fs.upload(source, to: RemotePath.join(sub, "nested/deep.bin"), progress: Progress(totalUnitCount: 0))
    let sub2 = RemotePath.join(base, "sub2")
    try await fs.rename(sub, sub2)
    let subItem = try #require(try await fs.stat(sub2), sourceLocation: sourceLocation)
    #expect(subItem.isDirectory, sourceLocation: sourceLocation)

    if supportsPermissions {
        try await fs.chmod(renamed, mode: 0o640)
        #expect(try await fs.list(base).first { $0.name == "renamed.bin" }?.permissions == 0o640, sourceLocation: sourceLocation)
    }

    // errors
    if missingDirectoryThrows {
        await #expect(throws: (any Error).self, sourceLocation: sourceLocation) { try await fs.list(RemotePath.join(base, "missing")) }
    }
    await #expect(throws: (any Error).self, sourceLocation: sourceLocation) { try await fs.mkdir(sub2) }
    await #expect(throws: (any Error).self, sourceLocation: sourceLocation) {
        try await fs.download(RemotePath.join(base, "missing.bin"), to: tmp.appendingPathComponent("x"), progress: Progress(totalUnitCount: 0))
    }
    // still usable after errors
    #expect(try await fs.exists(renamed), sourceLocation: sourceLocation)

    // delete a file, then a populated directory recursively
    try await fs.delete(renamed, recursive: false)
    #expect(try await !fs.exists(renamed), sourceLocation: sourceLocation)
    try await fs.delete(base, recursive: true)
    #expect(try await !fs.exists(base), sourceLocation: sourceLocation)
    await fs.disconnect()
}

@Suite(.serialized, .enabled(if: Env.enabled)) struct SFTPIntegrationTests {
    @Test func passwordAuth() async throws {
        let config = sftpConfig(auth: .password)
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config))
        let log = LogCollector(fs.logStream)
        try await exercise(fs)
        let lines = await log.snapshot()
        #expect(lines.contains { $0.message.contains("Authenticated with password") })
        #expect(lines.contains { $0.message.hasPrefix("rename ") })
        #expect(!lines.contains { $0.message.contains(Env.password) })
    }

    @Test func reconnectsAfterDroppedConnection() async throws {
        let config = sftpConfig(auth: .password)
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config))
        try await fs.connect()
        _ = try await fs.list("/")
        // Kill this connection's sshd process from the server side, as an idle timeout or network change would.
        _ = try? await fs.exec("kill -9 $PPID")
        // The next listing reconnects transparently, even though the session only learns it is dead on this call.
        _ = try await fs.list("/")
        await fs.disconnect()
    }

    @Test func reopensSFTPAfterTheServerClosesIt() async throws {
        let config = sftpConfig(auth: .password)
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config))
        let log = LogCollector(fs.logStream)
        try await fs.connect()
        let home = try await fs.homeDirectory()
        // Only the SFTP channel goes away (an sftp-server idle timeout); the SSH connection stays up.
        _ = try await fs.exec("pkill -9 -u \"$(id -u)\" -x sftp-server")
        _ = try await fs.list(home)
        // Actions that are not retried work on the next try too.
        let folder = RemotePath.join(home, "reopen-\(UUID().uuidString.prefix(8))")
        _ = try? await fs.exec("pkill -9 -u \"$(id -u)\" -x sftp-server")
        _ = try? await fs.rename(RemotePath.join(home, "missing-a"), RemotePath.join(home, "missing-b"))
        try await fs.mkdir(folder)
        try await fs.delete(folder, recursive: true)
        await fs.disconnect()
        let lines = await log.snapshot()
        #expect(lines.contains { $0.message.contains("SFTP channel closed, reopening") })
    }

    @Test(arguments: [("id_ed25519", nil), ("id_ed25519_enc", Env.keyPassphrase)] as [(String, String?)])
    func keyAuth(keyName: String, passphrase: String?) async throws {
        let config = sftpConfig(auth: .key, key: Env.key(keyName))
        let fs = SFTPFileSystem(config: config, secrets: await store(password: nil, passphrase: passphrase, for: config))
        let log = LogCollector(fs.logStream)
        try await fs.connect()
        _ = try await fs.list(try await fs.homeDirectory())
        await fs.disconnect()
        let lines = await log.snapshot()
        #expect(lines.contains { $0.message.contains("Authenticated with public key") })
        if let passphrase { #expect(!lines.contains { $0.message.contains(passphrase) }) }
    }

    /// OpenSSH 9 refuses ssh-rsa (SHA-1) signatures, so this only passes with rsa-sha2-256/512.
    @Test func rsaKeyAuth() async throws {
        let config = sftpConfig(auth: .key, key: Env.key("id_rsa"))
        let fs = SFTPFileSystem(config: config, secrets: await store(password: nil, for: config))
        try await fs.connect()
        _ = try await fs.list(try await fs.homeDirectory())
        await fs.disconnect()
    }

    @Test func keyThenPasswordFallsBackToPassword() async throws {
        // A key the server does not know, then the stored password.
        let unknown = FileManager.default.temporaryDirectory.appendingPathComponent("unknown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: unknown) }
        try Self.writeUnknownEd25519Key(to: unknown)

        let config = sftpConfig(auth: .both, key: unknown.path)
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config))
        let log = LogCollector(fs.logStream)
        try await fs.connect()
        _ = try await fs.list(try await fs.homeDirectory())
        await fs.disconnect()
        let lines = await log.snapshot().map(\.message)
        #expect(lines.contains("Authenticating as dockyard using public key"))
        #expect(lines.contains("Public key authentication rejected; trying password"))
        #expect(lines.contains { $0.contains("Authenticated with password") })
    }

    @Test func keyThenPasswordUsesKeyWhenAccepted() async throws {
        let config = sftpConfig(auth: .both, key: Env.key("id_ed25519"))
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config))
        let log = LogCollector(fs.logStream)
        try await fs.connect()
        await fs.disconnect()
        #expect(await log.snapshot().contains { $0.message.contains("Authenticated with public key") })
    }

    @Test func wrongPasswordIsAuthenticationFailure() async throws {
        let config = sftpConfig(auth: .password)
        let fs = SFTPFileSystem(config: config, secrets: await store(password: "nope", for: config))
        await #expect {
            try await fs.connect()
        } throws: { error in
            if case RemoteError.authenticationFailed = error { return true }
            Issue.record("Unexpected error: \(error)")
            return false
        }
    }

    @Test func wrongKeyPassphrase() async throws {
        let config = sftpConfig(auth: .key, key: Env.key("id_ed25519_enc"))
        let fs = SFTPFileSystem(config: config, secrets: await store(password: nil, passphrase: "wrong", for: config))
        await #expect(throws: (any Error).self) { try await fs.connect() }
    }

    @Test func manyListingsDoNotExhaustServerHandles() async throws {
        let config = sftpConfig(auth: .password)
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config))
        try await fs.connect()
        let home = try await fs.homeDirectory()
        for _ in 0..<250 { _ = try await fs.list(home) }
        await fs.disconnect()
    }

    @Test func streamedListingArrivesInBatchesAndResolvesSymlinksAfter() async throws {
        let config = sftpConfig(auth: .password)
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config))
        try await fs.connect()
        let home = try await fs.homeDirectory()
        let dir = RemotePath.join(home, "dockyard-stream-\(UUID().uuidString.prefix(8))")
        // More entries than one readdir reply holds, and more links than one resolution group.
        let setup = try await fs.exec(
            "mkdir -p \(dir)/sub && cd \(dir) && touch $(seq -f 'f%04g' 1 400) && "
                + "for i in $(seq 1 70); do ln -s f0001 l$i; done && ln -s sub ldir && ln -s missing ldangling")
        #expect(setup.exitStatus == 0)
        defer { Task { _ = try? await fs.exec("rm -rf \(dir)"); await fs.disconnect() } }

        var added = 0, updates: [RemoteItem] = []
        var listing = ListingAccumulator()
        var sawUnresolvedLink = false
        for try await update in fs.listStream(dir) {
            switch update {
            case .added(let items):
                added += 1
                if items.contains(where: { $0.symlinkTarget == "" }) { sawUnresolvedLink = true }
            case .updated(let items): updates += items
            }
            listing.apply(update)
        }
        #expect(added > 1)
        #expect(sawUnresolvedLink)
        #expect(updates.count == 72)
        let items = listing.items
        #expect(items.count == 400 + 1 + 72)
        #expect(Set(items.map(\.path)).count == items.count)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(byName["l1"]?.symlinkTarget == "f0001" && byName["l1"]?.isDirectory == false)
        #expect(byName["ldir"]?.symlinkTarget == "sub" && byName["ldir"]?.isDirectory == true)
        #expect(byName["ldangling"]?.symlinkTarget == "missing" && byName["ldangling"]?.isDirectory == false)
        #expect(byName["sub"]?.isDirectory == true && byName["sub"]?.isSymlink == false)
        // list() is the same listing, collected.
        #expect(try await fs.list(dir) == items)
    }

    @Test(arguments: [true, false])
    func recursiveDeleteRemovesTheWholeTree(shell: Bool) async throws {
        let config = sftpConfig(auth: .password)
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config), options: .init(shellFolderDelete: shell))
        let lines = LogCollector(fs.logStream)
        try await fs.connect()
        let home = try await fs.homeDirectory()
        let dir = RemotePath.join(home, "dockyard-rm '$(x)-\(UUID().uuidString.prefix(8))")
        let quoted = ShellQuote.quote(dir)
        let setup = try await fs.exec(
            "mkdir -p \(quoted)/a/b && cd \(quoted) && touch $(seq -f 'f%03g' 1 50) a/x a/b/y && ln -s /etc ldir")
        #expect(setup.exitStatus == 0)
        defer { Task { _ = try? await fs.exec("rm -rf \(quoted)"); await fs.disconnect() } }

        try await fs.delete(dir, recursive: true)

        #expect(try await fs.stat(dir) == nil)
        #expect(try await fs.stat("/etc/hostname") != nil)
        let usedShell = await lines.snapshot().contains { $0.kind == .command && $0.message.contains("rm -rf -- ") }
        #expect(usedShell == shell)
    }

    @Test func shellDeleteOnAnSFTPOnlyAccountFallsBackToSFTP() async throws {
        // ForceCommand internal-sftp: any command starts sftp-server, which exits 0 at EOF without deleting anything.
        var config = sftpConfig(auth: .password)
        config.username = "sftponly"
        let turnedOff = LockedBox(0)
        var options = SFTPFileSystem.Options()
        options.onShellFolderDeleteUnavailable = { turnedOff.withLock { $0 += 1 } }
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config), options: options)
        let lines = LogCollector(fs.logStream)
        try await fs.connect()
        defer { Task { await fs.disconnect() } }
        let home = try await fs.homeDirectory()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rm-\(UUID().uuidString)")
        try randomData(10).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // The second delete on the connection goes straight to SFTP, without another command.
        for _ in 0..<2 {
            let dir = RemotePath.join(home, "dockyard-rm-\(UUID().uuidString.prefix(8))")
            try await fs.mkdir(dir)
            try await fs.mkdir(RemotePath.join(dir, "sub"))
            try await fs.upload(tmp, to: RemotePath.join(dir, "sub/f"), progress: Progress(totalUnitCount: 0))
            try await fs.delete(dir, recursive: true)
            #expect(try await fs.stat(dir) == nil)
        }
        let snapshot = await lines.snapshot()
        #expect(snapshot.filter { $0.kind == .command && $0.message.contains("rm -rf -- ") }.count == 1)
        #expect(snapshot.filter { $0.kind == .warning }.count == 1)
        #expect(turnedOff.withLock { $0 } == 1)
        // The SFTP fallback logs each item it removes, then a summary.
        #expect(snapshot.contains { $0.kind == .command && $0.message.hasPrefix("rm ") && $0.message.hasSuffix("/sub/f") })
        #expect(snapshot.contains { $0.kind == .command && $0.message.hasPrefix("rmdir ") && $0.message.hasSuffix("/sub") })
        #expect(snapshot.contains { $0.kind == .status && $0.message.hasPrefix("Deleted ") && $0.message.hasSuffix("(3 items)") })
    }

    @Test func shellDeleteNeverRunsWhenTheShellSeesOtherFiles() async throws {
        // splitview: SFTP sees the real /home/splitview, shell commands a chroot with a decoy victim folder.
        var config = sftpConfig(auth: .password)
        config.username = "splitview"
        let turnedOff = LockedBox(0)
        var options = SFTPFileSystem.Options()
        options.onShellFolderDeleteUnavailable = { turnedOff.withLock { $0 += 1 } }
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config), options: options)
        let lines = LogCollector(fs.logStream)
        try await fs.connect()
        defer { Task { await fs.disconnect() } }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rm-\(UUID().uuidString)")
        try randomData(10).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        func makeTree(_ dir: String) async throws {
            try await fs.mkdir(dir)
            try await fs.mkdir(RemotePath.join(dir, "sub"))
            try await fs.upload(tmp, to: RemotePath.join(dir, "sub/f"), progress: Progress(totalUnitCount: 0))
        }
        let victim = "/home/splitview/victim"
        try await makeTree(victim)
        #expect(try await fs.exec("mkdir -p \(victim)/keep").exitStatus == 0)

        try await fs.delete(victim, recursive: true)

        #expect(try await fs.stat(victim) == nil)
        #expect(try await fs.exec("test -d \(victim)/keep").exitStatus == 0, "the decoy in the shell's view survives")
        #expect(await lines.snapshot().contains { $0.kind == .warning && $0.message.contains("see different files than SFTP") })

        // Later deletes on this connection skip the shell entirely.
        let second = "/home/splitview/second-\(UUID().uuidString.prefix(8))"
        try await makeTree(second)
        try await fs.delete(second, recursive: true)
        #expect(try await fs.stat(second) == nil)
        let deleteCommands = await lines.snapshot().filter { $0.kind == .command && $0.message.contains("rm -rf -- ") }
        #expect(deleteCommands.count == 1)
        #expect(turnedOff.withLock { $0 } == 1)
    }

    @Test func shellDeleteFallsBackToSFTPWhenTheFolderSurvives() async throws {
        // A root-owned file in a folder the user owns: rm -rf fails on the subfolder, SFTP then reports it.
        let config = sftpConfig(auth: .password)
        let turnedOff = LockedBox(0)
        var options = SFTPFileSystem.Options()
        options.onShellFolderDeleteUnavailable = { turnedOff.withLock { $0 += 1 } }
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config), options: options)
        let lines = LogCollector(fs.logStream)
        try await fs.connect()
        let home = try await fs.homeDirectory()
        let dir = RemotePath.join(home, "dockyard-rm-locked-\(UUID().uuidString.prefix(8))")
        #expect(try await fs.exec("mkdir -p \(dir)/locked && touch \(dir)/locked/f \(dir)/free && chmod 555 \(dir)/locked").exitStatus == 0)
        defer { Task { _ = try? await fs.exec("chmod -R 755 \(dir); rm -rf \(dir)"); await fs.disconnect() } }

        await #expect(throws: RemoteError.self) { try await fs.delete(dir, recursive: true) }
        #expect(try await fs.stat(RemotePath.join(dir, "locked/f")) != nil)
        #expect(await lines.snapshot().contains { $0.kind == .warning && $0.message.contains("deleting the rest over SFTP") })
        #expect(turnedOff.withLock { $0 } == 0, "a protected file is not a reason to give up on shell deletes")
    }

    @Test func fullScenario() async throws {
        let config = sftpConfig(auth: .password)
        try await exercise(SFTPFileSystem(config: config, secrets: await store(for: config)))
    }

    private static func writeUnknownEd25519Key(to url: URL) throws {
        // Generated once per run so it is never authorised on the server.
        let key = Curve25519SigningKeyFactory.makeOpenSSHPrivateKey()
        try key.write(to: url, atomically: true, encoding: .utf8)
    }
}

private func ftpConfig(protocol proto: ConnectionProtocol = .ftp, port: Int = Env.ftpPort) -> ConnectionConfig {
    ConnectionConfig(protocol: proto, host: Env.host, port: port, username: Env.user, authMethods: .password)
}

@Suite(.serialized, .enabled(if: Env.enabled)) struct FTPIntegrationTests {
    @Test func plainFTPWithMLSDAndEPSV() async throws {
        let config = ftpConfig()
        let fs = FTPFileSystem(config: config, secrets: await store(for: config))
        let log = LogCollector(fs.logStream)
        try await exercise(fs, supportsPermissions: true)
        let lines = await log.snapshot()
        let commands = lines.filter { $0.kind == .command }.map(\.message)
        #expect(commands.contains("PASS ****"))
        #expect(commands.contains("EPSV"))
        #expect(commands.contains { $0.hasPrefix("MLSD") })
        #expect(commands.contains { $0.hasPrefix("RETR") } && commands.contains { $0.hasPrefix("STOR") })
        #expect(commands.contains { $0.hasPrefix("REST") })
        #expect(lines.contains { $0.kind == .response && $0.message.hasPrefix("227") || $0.message.hasPrefix("229") })
        #expect(!lines.contains { $0.message.contains(Env.password) })
    }

    @Test func plainFTPWithPASVOnly() async throws {
        let config = ftpConfig()
        let fs = FTPFileSystem(config: config, secrets: await store(for: config), options: .init(preferEPSV: false))
        let log = LogCollector(fs.logStream)
        try await exercise(fs)
        let commands = await log.snapshot().filter { $0.kind == .command }.map(\.message)
        #expect(commands.contains("PASV"))
        #expect(!commands.contains("EPSV"))
    }

    @Test func listFallbackWhenServerHasNoMLSD() async throws {
        let config = ftpConfig(port: Env.vsftpdPort)
        let fs = FTPFileSystem(config: config, secrets: await store(for: config))
        let log = LogCollector(fs.logStream)
        // vsftpd answers LIST for a missing directory with an empty listing.
        try await exercise(fs, missingDirectoryThrows: false)
        let commands = await log.snapshot().filter { $0.kind == .command }.map(\.message)
        #expect(!commands.contains { $0.hasPrefix("MLSD") })
        #expect(commands.contains { $0.hasPrefix("LIST") })
    }

    @Test func explicitTLS() async throws {
        let config = ftpConfig(protocol: .ftps)
        let fs = FTPFileSystem(config: config, secrets: await store(for: config), options: .init(verifyCertificate: false))
        let log = LogCollector(fs.logStream)
        try await exercise(fs)
        let commands = await log.snapshot().filter { $0.kind == .command }.map(\.message)
        #expect(Array(commands.prefix(3)) == ["AUTH TLS", "PBSZ 0", "PROT P"])
    }

    @Test func selfSignedCertificateIsRejectedByDefault() async throws {
        let config = ftpConfig(protocol: .ftps)
        let fs = FTPFileSystem(config: config, secrets: await store(for: config))
        await #expect(throws: (any Error).self) { try await fs.connect() }
    }

    @Test func wrongPasswordIsAuthenticationFailure() async throws {
        let config = ftpConfig()
        let fs = FTPFileSystem(config: config, secrets: await store(password: "nope", for: config))
        await #expect(throws: RemoteError.authenticationFailed("Login authentication failed")) { try await fs.connect() }
    }

    @Test func reconnectsAfterDroppedConnection() async throws {
        let config = ftpConfig()
        let fs = FTPFileSystem(config: config, secrets: await store(for: config))
        try await fs.connect()
        _ = try await fs.list("/")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID().uuidString)")
        try randomData(8_000_000).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let progress = Progress(totalUnitCount: 0)
        let remote = "/cancel-\(UUID().uuidString.prefix(6)).bin"
        let task = Task { try await fs.upload(tmp, to: remote, progress: progress) }
        while progress.completedUnitCount < 1_000_000 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        _ = await task.result
        // The aborted transfer drops the control connection; the next call reconnects transparently.
        _ = try await fs.list("/")
        try? await fs.delete(remote, recursive: false)
        await fs.disconnect()
    }
}
