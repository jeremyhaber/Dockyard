import Foundation
import Testing
@testable import ConnectionKit

@Suite struct ExecMarkerFilterTests {
    @Test func stripsTheMarkerAndKeepsTheRest() {
        var filter = ExecMarkerFilter(dropPreamble: false)
        #expect(filter.feed(Data("DKYD-PID:123:120\nhello\n".utf8)) == Data("hello\n".utf8))
        #expect(filter.pid == "123" && filter.pgid == "120")
        #expect(filter.feed(Data("more".utf8)) == Data("more".utf8))
    }

    @Test func handlesMarkersSplitAcrossChunks() {
        var filter = ExecMarkerFilter(dropPreamble: false)
        #expect(filter.feed(Data("DKYD-".utf8)).isEmpty)
        #expect(filter.feed(Data("PID:7:7".utf8)).isEmpty)
        #expect(filter.feed(Data("\nout".utf8)) == Data("out".utf8))
        #expect(filter.pgid == "7")
    }

    @Test func dropsPasswordPromptsBeforeTheMarkerForSu() {
        var filter = ExecMarkerFilter(dropPreamble: true)
        #expect(filter.feed(Data("Password: \r\nDKYD-PID:9:9\nrest".utf8)) == Data("rest".utf8))
    }

    @Test func releasesOutputWhenNoMarkerEverComes() {
        var filter = ExecMarkerFilter(dropPreamble: false)
        #expect(filter.feed(Data("sudo: a password is required\n".utf8)).isEmpty)
        #expect(filter.flush() == Data("sudo: a password is required\n".utf8))
    }

    @Test func connectionLimitMessagesAreRecognised() {
        for text in ["421 Too many connections (5) from this IP", "530 Sorry, the maximum number of clients (2) from your host are already connected",
                     "There are too many connections from your internet address", "Rate limit exceeded", "kex_exchange_identification: MaxStartups"] {
            #expect(RemoteError.looksLikeConnectionLimit(text), "\(text)")
        }
        for text in ["Permission denied", "No such file", "Login incorrect"] { #expect(!RemoteError.looksLikeConnectionLimit(text)) }
        #expect(RemoteError.ftpRefusal(code: 421, message: "Service not available") != nil)
        #expect(RemoteError.ftpRefusal(code: 530, message: "Login incorrect") == nil)
        #expect(RemoteError.ftpRefusal(code: 530, message: "Too many connections from your host") != nil)
    }
}

private func connected(elevation: Elevation = .none, password: String = Env.rootPassword, browseAsRoot: Bool = false) async throws -> SFTPFileSystem {
    var config = sftpConfig(auth: .password)
    config.elevation = elevation
    let secrets = await store(for: config)
    if elevation != .none { await secrets.setSecret(elevation == .su ? Env.rootPassword : Env.password, for: config.id, purpose: .elevationPassword) }
    let fs = SFTPFileSystem(config: config, secrets: secrets, options: .init(browseAsRoot: browseAsRoot))
    try await fs.connect()
    return fs
}

private final class Collected: Sendable {
    private let state = LockedBox((out: Data(), err: Data()))
    func add(_ isStderr: Bool, _ data: Data) { state.withLock { if !isStderr { $0.out.append(data) } else { $0.err.append(data) } } }
    var stdout: String { String(decoding: state.withLock { $0.out }, as: UTF8.self) }
    var stderr: String { String(decoding: state.withLock { $0.err }, as: UTF8.self) }
}

@Suite(.enabled(if: Env.enabled)) struct SSHCommandIntegrationTests {
    @Test func streamsOutputAndReturnsTheExitStatus() async throws {
        let fs = try await connected()
        let collected = Collected()
        let status = try await fs.runCommand("echo one; echo two >&2; sleep 0.3; echo three; exit 7", elevated: false) { collected.add($0, $1) }
        #expect(status == 7)
        #expect(collected.stdout == "one\nthree\n")
        #expect(collected.stderr == "two\n")
        await fs.disconnect()
    }

    @Test func runsCommandsWithNastyArgumentsLiterally() async throws {
        let fs = try await connected()
        let collected = Collected()
        let name = "it's a $HOME `x`; \"test\""
        _ = try await fs.runCommand("printf %s \(ShellQuote.quote(name))", elevated: false) { collected.add($0, $1) }
        #expect(collected.stdout == name)
        await fs.disconnect()
    }

    @Test(arguments: [Elevation.sudo, Elevation.su])
    func elevatedCommandsRunAsRoot(kind: Elevation) async throws {
        let fs = try await connected(elevation: kind, browseAsRoot: true)
        #expect(await fs.canElevateCommands)
        let collected = Collected()
        let status = try await fs.runCommand("id -un; echo done", elevated: true) { collected.add($0, $1) }
        #expect(status == 0)
        #expect(collected.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) } == ["root", "done"])
        #expect(!collected.stdout.contains(Env.password) && !collected.stdout.contains(Env.rootPassword))
        await fs.disconnect()
    }

    @Test(arguments: [(Elevation.none, false), (Elevation.sudo, true), (Elevation.su, true)])
    func cancellingKillsTheRemoteProcessGroup(kind: Elevation, elevated: Bool) async throws {
        let fs = try await connected(elevation: kind, browseAsRoot: elevated)
        let marker = "dockyard-cancel-\(UUID().uuidString.prefix(8))"
        let collected = Collected()
        let task = Task {
            // A pipeline, so there is more than one process to kill.
            try await fs.runCommand("echo started; sleep 300 | cat # \(marker)", elevated: elevated) { collected.add($0, $1) }
        }
        #expect(await waitUntil(timeout: 10) { collected.stdout.contains("started") })
        let probe = try await fs.exec("pgrep -f '[s]leep 300' | wc -l")
        #expect(Int(probe.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 >= 1)
        let started = Date()
        task.cancel()
        do { _ = try await task.value; Issue.record("expected cancellation") } catch is CancellationError {}
        #expect(Date().timeIntervalSince(started) < 8)
        var left = 1
        for _ in 0..<20 {
            left = Int((try await fs.exec("pgrep -f '[s]leep 300' | wc -l")).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            if left == 0 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(left == 0)
        await fs.disconnect()
    }
}

func waitUntil(timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
