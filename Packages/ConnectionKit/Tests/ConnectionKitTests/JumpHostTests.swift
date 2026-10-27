import Foundation
import Testing
@testable import ConnectionKit

/// `inner-sshd` is only reachable from `dockyard-test-sftp`, and `deep-sshd` only from `inner-sshd`
/// (see `scripts/integration-servers.sh`). The tests therefore pass only if the tunnels really work.
private func hop(_ host: String, port: Int = 2222, secrets: InMemorySecretStore, password: String = Env.password) async -> SSHJumpHop {
    let config = ConnectionConfig(protocol: .sftp, host: host, port: port, username: Env.user, authMethods: .password)
    await secrets.setSecret(password, for: config.id, purpose: .password)
    return SSHJumpHop(config: config, secrets: secrets)
}

private func target(_ host: String, secrets: InMemorySecretStore) async -> ConnectionConfig {
    let config = ConnectionConfig(protocol: .sftp, host: host, port: 2222, username: Env.user, authMethods: .password)
    await secrets.setSecret(Env.password, for: config.id, purpose: .password)
    return config
}

@Suite(.serialized, .enabled(if: Env.enabled)) struct JumpHostIntegrationTests {
    @Test func targetIsNotReachableDirectly() async throws {
        let secrets = InMemorySecretStore()
        let config = await target("inner-sshd", secrets: secrets)
        let fs = SFTPFileSystem(config: config, secrets: secrets)
        await #expect(throws: (any Error).self) { try await fs.connect() }
    }

    @Test func sftpThroughOneJumpHost() async throws {
        let secrets = InMemorySecretStore()
        var options = SFTPFileSystem.Options()
        options.jumpHosts = [await hop(Env.host, secrets: secrets)]
        let config = await target("inner-sshd", secrets: secrets)
        let fs = SFTPFileSystem(config: config, secrets: secrets, options: options)
        let log = LogCollector(fs.logStream)
        try await exercise(fs)
        await fs.disconnect()
        let messages = await log.snapshot().map(\.message)
        #expect(messages.contains { $0.contains("jump host") })
    }

    @Test func execAndShellThroughTwoJumpHosts() async throws {
        let secrets = InMemorySecretStore()
        var options = SFTPFileSystem.Options()
        options.jumpHosts = [await hop(Env.host, secrets: secrets), await hop("inner-sshd", secrets: secrets)]
        let config = await target("deep-sshd", secrets: secrets)
        let fs = SFTPFileSystem(config: config, secrets: secrets, options: options)
        try await fs.connect()
        let result = try await fs.exec("hostname")
        #expect(result.exitStatus == 0)
        let directConfig = sftpConfig(auth: .password)
        let direct = SFTPFileSystem(config: directConfig, secrets: await store(for: directConfig))
        try await direct.connect()
        let directName = try await direct.exec("hostname").stdoutString
        #expect(result.stdoutString != directName)

        let shell = try await fs.openShell(cols: 80, rows: 24)
        try await shell.write(Data("echo via-$((20+1))-hops\n".utf8))
        var seen = ""
        let deadline = Date().addingTimeInterval(15)
        outer: for await chunk in shell.output {
            seen += String(decoding: chunk, as: UTF8.self)
            if seen.contains("via-21-hops\r\n") || Date() > deadline { break outer }
        }
        #expect(seen.contains("via-21-hops"))
        try await shell.write(Data("exit\n".utf8))
        _ = try await fs.list(try await fs.homeDirectory())
        await fs.disconnect()
        await direct.disconnect()
    }

    @Test func wrongPasswordOnJumpHostFailsCleanly() async throws {
        let secrets = InMemorySecretStore()
        var options = SFTPFileSystem.Options()
        options.jumpHosts = [await hop(Env.host, secrets: secrets, password: "nope")]
        let config = await target("inner-sshd", secrets: secrets)
        let fs = SFTPFileSystem(config: config, secrets: secrets, options: options)
        await #expect(throws: RemoteError.self) { try await fs.connect() }
    }

    @Test func unreachableTargetReportsTunnelError() async throws {
        let secrets = InMemorySecretStore()
        var options = SFTPFileSystem.Options()
        options.jumpHosts = [await hop(Env.host, secrets: secrets)]
        let config = await target("no-such-host.invalid", secrets: secrets)
        let fs = SFTPFileSystem(config: config, secrets: secrets, options: options)
        await #expect(throws: RemoteError.self) { try await fs.connect() }
    }

    @Test func manyConcurrentChannelsThroughTunnel() async throws {
        let secrets = InMemorySecretStore()
        var options = SFTPFileSystem.Options()
        options.jumpHosts = [await hop(Env.host, secrets: secrets)]
        let config = await target("inner-sshd", secrets: secrets)
        let fs = SFTPFileSystem(config: config, secrets: secrets, options: options)
        try await fs.connect()
        try await withThrowingTaskGroup(of: Int32.self) { group in
            for i in 0..<8 { group.addTask { try await fs.exec("echo \(i)").exitStatus } }
            for try await status in group { #expect(status == 0) }
        }
        await fs.disconnect()
    }
}

@Suite(.serialized, .enabled(if: Env.enabled)) struct ExecStreamIntegrationTests {
    @Test func streamsOutputAndExitStatus() async throws {
        let config = sftpConfig(auth: .password)
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config))
        try await fs.connect()
        var out = Data(), exit: Int32?
        for try await event in try await fs.execStream("printf a; sleep 0.2; printf b; exit 3") {
            switch event {
            case .stdout(let d): out += d
            case .exit(let s): exit = s
            case .stderr: break
            }
        }
        #expect(String(decoding: out, as: UTF8.self) == "ab" && exit == 3)
        await fs.disconnect()
    }

    @Test func cancellingTheStreamClosesTheChannel() async throws {
        let config = sftpConfig(auth: .password)
        let fs = SFTPFileSystem(config: config, secrets: await store(for: config))
        try await fs.connect()
        let task = Task {
            for try await _ in try await fs.execStream("while true; do echo x; sleep 0.05; done") {}
        }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        _ = try? await task.value
        // The connection stays usable.
        #expect(try await fs.exec("echo ok").stdoutString == "ok\n")
        await fs.disconnect()
    }
}

@Suite struct ShellQuoteTests {
    @Test func quoting() {
        #expect(ShellQuote.quote("plain") == "'plain'")
        #expect(ShellQuote.quote("it's") == "'it'\\''s'")
        #expect(ShellQuote.quote("a b; rm -rf /") == "'a b; rm -rf /'")
        #expect(ShellQuote.quote(["a", "b c"]) == "'a' 'b c'")
        #expect(ShellQuote.quote("") == "''")
    }
}
