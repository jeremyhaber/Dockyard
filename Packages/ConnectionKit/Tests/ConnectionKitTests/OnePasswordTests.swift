import Foundation
import Testing
@testable import ConnectionKit

// Fixtures modelled on `op` v2 output (`--format json`). Values are fake.
enum OPFixtures {
    static let accounts = """
    [{"url":"my.1password.com","email":"jeremy@example.com","user_uuid":"ZQ5M4XTFYZEXNF7PWDQQ2LTUHM","account_uuid":"7HXKQ2LMNBF5DKPT3WZ4VCJYRA"}]
    """
    static let whoami = """
    {"url":"https://my.1password.com/","email":"jeremy@example.com","user_uuid":"ZQ5M4XTFYZEXNF7PWDQQ2LTUHM","account_uuid":"7HXKQ2LMNBF5DKPT3WZ4VCJYRA"}
    """
    static let vaults = """
    [{"id":"bq3d6fz7yzvsr5lk4rpxu2h6im","name":"Infrastructure","content_version":412},
     {"id":"p9a2c4e6g8i0k2m4o6q8s0u2wy","name":"Clients","content_version":97}]
    """
    static let itemList = """
    [{"id":"x7k2m4qv5nj6h3tdwl2ofp7e3a","title":"Acme web01","version":3,"vault":{"id":"bq3d6fz7yzvsr5lk4rpxu2h6im","name":"Infrastructure"},
      "category":"SERVER","last_edited_by":"ZQ5M4XTFYZEXNF7PWDQQ2LTUHM","created_at":"2025-03-02T09:14:41Z","updated_at":"2026-01-11T16:02:09Z",
      "additional_information":"deploy","tags":["acme","production"],"urls":[{"label":"website","primary":true,"href":"sftp://web01.acme.example:2222"}]},
     {"id":"k9s8r7q6p5o4n3m2l1j0i9h8g7","title":"Deploy key","version":1,"vault":{"id":"bq3d6fz7yzvsr5lk4rpxu2h6im","name":"Infrastructure"},
      "category":"SSH_KEY","created_at":"2025-04-01T09:00:00Z","updated_at":"2025-04-01T09:00:00Z"}]
    """
    static let itemGet = """
    {"id":"x7k2m4qv5nj6h3tdwl2ofp7e3a","title":"Acme web01","version":3,"vault":{"id":"bq3d6fz7yzvsr5lk4rpxu2h6im","name":"Infrastructure"},
     "category":"SERVER","updated_at":"2026-01-11T16:02:09Z","tags":["acme"],
     "sections":[{"id":"add more"}],
     "fields":[
       {"id":"username","type":"STRING","purpose":"USERNAME","label":"username","value":"deploy","reference":"op://Infrastructure/Acme web01/username"},
       {"id":"password","type":"CONCEALED","purpose":"PASSWORD","label":"password","value":"hunter2-secret","reference":"op://Infrastructure/Acme web01/password"},
       {"id":"expires","type":"DATE","label":"expires","value":1767225600,"reference":"op://Infrastructure/Acme web01/expires"}]}
    """
}

final class FakeOp: CommandExecuting {
    let handler: @Sendable (CommandInvocation) throws -> CommandResult
    let calls = LockedBox<[CommandInvocation]>([])

    init(_ handler: @escaping @Sendable (CommandInvocation) throws -> CommandResult) { self.handler = handler }

    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        calls.withLock { $0.append(invocation) }
        return try handler(invocation)
    }

    var arguments: [[String]] { calls.withLock { $0.map(\.arguments) } }
}

func opOK(_ text: String) -> CommandResult { CommandResult(exitCode: 0, stdout: Data(text.utf8)) }
func opFail(_ stderr: String, code: Int32 = 1) -> CommandResult { CommandResult(exitCode: code, stderr: stderr) }

func makeCLI(_ fake: FakeOp, account: String? = nil, log: @escaping @Sendable (String) -> Void = { _ in }) -> OnePasswordCLI {
    OnePasswordCLI(executor: fake, account: account, locator: { "/fake/bin/op" }, log: log)
}

@Suite struct OnePasswordCLITests {
    @Test func locatesOpInHomebrewThenUsrLocalThenPath() {
        let all: Set<String> = ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/custom/bin/op"]
        #expect(OnePasswordCLI.locateExecutable(environment: ["PATH": "/custom/bin"], isExecutable: all.contains) == "/opt/homebrew/bin/op")
        #expect(OnePasswordCLI.locateExecutable(environment: ["PATH": "/custom/bin"], isExecutable: { $0 != "/opt/homebrew/bin/op" && all.contains($0) }) == "/usr/local/bin/op")
        #expect(OnePasswordCLI.locateExecutable(environment: ["PATH": "/x:/custom/bin"], isExecutable: { $0 == "/custom/bin/op" }) == "/custom/bin/op")
        #expect(OnePasswordCLI.locateExecutable(environment: [:], isExecutable: { _ in false }) == nil)
    }

    // MARK: Status

    @Test func statusNotInstalled() async throws {
        let cli = OnePasswordCLI(executor: FakeOp { _ in opOK("") }, locator: { nil })
        #expect(try await cli.status() == .notInstalled)
    }

    @Test func statusIntegrationOffWhenNoAccountsAreListed() async throws {
        let empty = makeCLI(FakeOp { _ in opOK("") })
        #expect(try await empty.status() == .integrationOff)
        let emptyArray = makeCLI(FakeOp { _ in opOK("[]") })
        #expect(try await emptyArray.status() == .integrationOff)
        let message = makeCLI(FakeOp { _ in opFail("No accounts configured for use with 1Password CLI.") })
        #expect(try await message.status() == .integrationOff)
    }

    @Test func statusReadyListsAccounts() async throws {
        let fake = FakeOp { invocation in
            invocation.arguments.first == "account" ? opOK(OPFixtures.accounts) : opOK(OPFixtures.whoami)
        }
        let status = try await makeCLI(fake).status()
        guard case .ready(let accounts) = status else { Issue.record("expected ready, got \(status)"); return }
        #expect(accounts.count == 1 && accounts[0].email == "jeremy@example.com" && accounts[0].url == "my.1password.com")
        #expect(accounts[0].accountUUID == "7HXKQ2LMNBF5DKPT3WZ4VCJYRA")
        #expect(fake.arguments == [["account", "list", "--format", "json"], ["whoami", "--format", "json"]])
    }

    @Test func statusSignedOutWhenWhoamiFails() async throws {
        for stderr in ["[ERROR] 2026/01/02 10:00:00 account is not signed in", "[ERROR] 2026/01/02 10:00:00 authorization prompt dismissed, please try again"] {
            let fake = FakeOp { $0.arguments.first == "account" ? opOK(OPFixtures.accounts) : opFail(stderr) }
            let status = try await makeCLI(fake).status()
            guard case .signedOut(let accounts) = status else { Issue.record("expected signedOut, got \(status)"); return }
            #expect(accounts.count == 1)
        }
    }

    @Test func statusPropagatesUnexpectedFailures() async throws {
        let cli = makeCLI(FakeOp { _ in opFail("[ERROR] 2026/01/02 10:00:00 something exploded", code: 2) })
        await #expect(throws: OnePasswordError.commandFailed(exitCode: 2, message: "something exploded")) { try await cli.status() }
    }

    // MARK: Listing

    @Test func listsVaults() async throws {
        let fake = FakeOp { _ in opOK(OPFixtures.vaults) }
        let vaults = try await makeCLI(fake).vaults()
        #expect(vaults == [OnePasswordVault(id: "bq3d6fz7yzvsr5lk4rpxu2h6im", name: "Infrastructure"), OnePasswordVault(id: "p9a2c4e6g8i0k2m4o6q8s0u2wy", name: "Clients")])
        #expect(fake.arguments == [["vault", "list", "--format", "json"]])
    }

    @Test func listsItemsWithCategoriesAndParsesSummaries() async throws {
        let fake = FakeOp { _ in opOK(OPFixtures.itemList) }
        let items = try await makeCLI(fake).items(inVault: "Infrastructure")
        #expect(fake.arguments == [["item", "list", "--vault", "Infrastructure", "--categories", "Server,Login,SSH Key", "--format", "json"]])
        #expect(items.map(\.title) == ["Acme web01", "Deploy key"])
        #expect(items.map(\.category) == [.server, .sshKey])
        #expect(items[0].tags == ["acme", "production"] && items[0].urls.first?.href == "sftp://web01.acme.example:2222")
        #expect(items[0].vault.name == "Infrastructure" && items[0].fields.isEmpty)
    }

    @Test func anEmptyListingIsNotAnError() async throws {
        #expect(try await makeCLI(FakeOp { _ in opOK("") }).items(inVault: "Empty").isEmpty)
    }

    @Test func getsAFullItem() async throws {
        let fake = FakeOp { _ in opOK(OPFixtures.itemGet) }
        let item = try await makeCLI(fake).item(id: "x7k2m4qv5nj6h3tdwl2ofp7e3a", inVault: "Infrastructure")
        #expect(fake.arguments == [["item", "get", "x7k2m4qv5nj6h3tdwl2ofp7e3a", "--vault", "Infrastructure", "--format", "json"]])
        let password = try #require(item.field(purpose: "PASSWORD"))
        #expect(password.value == "hunter2-secret" && password.reference == "op://Infrastructure/Acme web01/password" && password.isSecret)
        #expect(item.field(named: ["user", "username"])?.value == "deploy")
        #expect(item.fields.first { $0.id == "expires" }?.value == "1767225600")
        #expect(!String(describing: item).contains("hunter2-secret"))
    }

    @Test func accountFlagIsAddedToCalls() async throws {
        let fake = FakeOp { _ in opOK(OPFixtures.vaults) }
        _ = try await makeCLI(fake, account: "my.1password.com").vaults()
        #expect(fake.arguments == [["vault", "list", "--format", "json", "--account", "my.1password.com"]])
    }

    @Test func argumentsThatLookLikeFlagsAreRefused() async throws {
        let fake = FakeOp { _ in opOK("[]") }
        let cli = makeCLI(fake)
        await #expect(throws: OnePasswordError.self) { _ = try await cli.items(inVault: "--account=evil") }
        await #expect(throws: OnePasswordError.self) { _ = try await cli.item(id: "-x", inVault: "V") }
        #expect(fake.arguments.isEmpty)
    }

    @Test func malformedJSONIsReportedWithoutQuotingIt() async throws {
        let cli = makeCLI(FakeOp { _ in opOK(#"{"id":"abc","fields":"hunter2-secret"}"#) })
        do {
            _ = try await cli.item(id: "abc", inVault: "V")
            Issue.record("expected a decoding error")
        } catch let error as OnePasswordError {
            guard case .unexpectedOutput = error else { Issue.record("wrong error \(error)"); return }
            #expect(!"\(error)".contains("hunter2"))
        }
    }

    // MARK: Reading references

    @Test func readReturnsTheValueExactly() async throws {
        let fake = FakeOp { _ in opOK("p@ss w0rd\nline2\n") }
        let value = try await makeCLI(fake).read(reference: "op://Infrastructure/Acme web01/password")
        #expect(value == "p@ss w0rd\nline2\n")
        #expect(fake.arguments == [["read", "--no-newline", "op://Infrastructure/Acme web01/password"]])
    }

    @Test(arguments: ["", "Infrastructure/Acme/password", "op://", "op://V/I", "op://V//password", "--help", "op://V/I/f\n--x"])
    func readRejectsMalformedReferences(reference: String) async throws {
        let fake = FakeOp { _ in opOK("never") }
        await #expect(throws: OnePasswordError.invalidReference("<redacted>")) { try await makeCLI(fake).read(reference: reference) }
        #expect(fake.arguments.isEmpty)
    }

    @Test func referenceSyntax() {
        #expect(OnePasswordCLI.isValidReference("op://Vault/Item/password"))
        #expect(OnePasswordCLI.isValidReference("op://Vault/Item/Section/field"))
        #expect(OnePasswordCLI.isValidReference("op://Vault/Item/private key?ssh-format=openssh"))
        #expect(!OnePasswordCLI.isValidReference("https://example.com"))
    }

    @Test func readNeverLogsReferencesOrValues() async throws {
        let logged = LockedBox<[String]>([])
        let cli = makeCLI(FakeOp { $0.arguments.first == "read" ? opOK("super-secret-value") : opOK(OPFixtures.vaults) }, log: { line in logged.withLock { $0.append(line) } })
        _ = try await cli.read(reference: "op://Infrastructure/Acme web01/password")
        _ = try await cli.vaults()
        let lines = logged.withLock { $0 }
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { !$0.contains("super-secret") && !$0.contains("Acme") && !$0.contains("op://") })
    }

    @Test func failedReadDoesNotLeakOutput() async throws {
        let fake = FakeOp { _ in CommandResult(exitCode: 1, stdout: Data("leaked-value".utf8), stderr: "[ERROR] 2026/01/02 10:00:00 boom") }
        do {
            _ = try await makeCLI(fake).read(reference: "op://V/I/f")
            Issue.record("expected failure")
        } catch {
            #expect(!"\(error)".contains("leaked-value"))
        }
        #expect(!CommandResult(exitCode: 0, stdout: Data("leaked-value".utf8)).description.contains("leaked-value"))
        #expect(!String(reflecting: CommandResult(exitCode: 0, stdout: Data("leaked-value".utf8))).contains("leaked-value"))
    }

    // MARK: Error mapping

    @Test(arguments: [
        ("[ERROR] 2026/01/02 10:00:00 authorization prompt dismissed, please try again", OnePasswordError.authorizationDismissed),
        ("[ERROR] 2026/01/02 10:00:00 authorization denied by user", .authorizationDismissed),
        ("[ERROR] 2026/01/02 10:00:00 1Password is locked", .appLocked),
        ("[ERROR] 2026/01/02 10:00:00 account is not signed in", .appLocked),
        ("[ERROR] 2026/01/02 10:00:00 You are not currently signed in. Please run `op signin`", .appLocked),
        ("[ERROR] 2026/01/02 10:00:00 No accounts configured for use with 1Password CLI.", .integrationOff),
        ("[ERROR] 2026/01/02 10:00:00 1Password CLI couldn't connect to the 1Password desktop app. To fix: Integrate with 1Password CLI", .integrationOff),
        ("[ERROR] 2026/01/02 10:00:00 \"nope\" isn't an item in the \"Infrastructure\" vault.", .notFound("the requested item, vault or field")),
        ("[ERROR] 2026/01/02 10:00:00 \"Nope\" isn't a vault in this account.", .notFound("the requested item, vault or field")),
        ("[ERROR] 2026/01/02 10:00:00 could not read secret 'op://V/I/x': the item could not be found", .notFound("the requested item, vault or field")),
        ("[ERROR] 2026/01/02 10:00:00 unknown flag", .commandFailed(exitCode: 1, message: "unknown flag")),
    ])
    func mapsStderr(stderr: String, expected: OnePasswordError) {
        #expect(OnePasswordCLI.map(stderr: stderr, exitCode: 1) == expected)
    }

    @Test func executorFailuresBecomeTypedErrors() async throws {
        let timeout = makeCLI(FakeOp { _ in throw CommandError.timedOut })
        await #expect(throws: OnePasswordError.timedOut) { try await timeout.vaults() }
        let missing = makeCLI(FakeOp { _ in throw CommandError.launchFailed("no such file") })
        await #expect(throws: OnePasswordError.notInstalled) { try await missing.vaults() }
        #expect(OnePasswordError.appLocked.needsUserAction && !OnePasswordError.timedOut.needsUserAction)
    }

    @Test func longStderrIsTruncated() {
        guard case .commandFailed(_, let message) = OnePasswordCLI.map(stderr: String(repeating: "x", count: 5000), exitCode: 3) else {
            Issue.record("expected commandFailed"); return
        }
        #expect(message.count == 300)
    }
}

/// Drives the real `Process` path with a shell script standing in for `op`.
@Suite struct FakeOpScriptTests {
    private func makeScript(_ body: String) throws -> (path: String, cleanup: @Sendable () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-op-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("op")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url.path, { try? FileManager.default.removeItem(at: dir) })
    }

    private func cli(script: String, timeout: TimeInterval = 10) -> OnePasswordCLI {
        OnePasswordCLI(timeout: timeout, locator: { script })
    }

    private static let fakeOp = """
    case "$1" in
      account) echo '\(OPFixtures.accounts)' ;;
      whoami) echo '\(OPFixtures.whoami)' ;;
      vault) echo '\(OPFixtures.vaults)' ;;
      item)
        if [ "$2" = "get" ]; then echo '\(OPFixtures.itemGet)'; else echo '\(OPFixtures.itemList)'; fi ;;
      read)
        if [ "$3" = "op://V/I/locked" ]; then echo "[ERROR] 2026/01/02 10:00:00 authorization prompt dismissed, please try again" >&2; exit 1; fi
        printf '%s' "value-of-$3" ;;
      *) echo "unknown: $*" >&2; exit 64 ;;
    esac
    """

    @Test func statusListingAndReadingThroughARealProcess() async throws {
        let script = try makeScript(Self.fakeOp)
        defer { script.cleanup() }
        let cli = cli(script: script.path)
        #expect(try await cli.status().isReady)
        #expect(try await cli.vaults().count == 2)
        #expect(try await cli.items(inVault: "Infrastructure").count == 2)
        #expect(try await cli.item(id: "x7k2m4qv5nj6h3tdwl2ofp7e3a", inVault: "Infrastructure").title == "Acme web01")
        #expect(try await cli.read(reference: "op://V/I/password") == "value-of-op://V/I/password")
        await #expect(throws: OnePasswordError.authorizationDismissed) { try await cli.read(reference: "op://V/I/locked") }
    }

    @Test func nonZeroExitAndStderrAreCaptured() async throws {
        let script = try makeScript("echo out; echo 'bad thing' >&2; exit 7")
        defer { script.cleanup() }
        let result = try await ProcessCommandExecutor().run(CommandInvocation(executable: script.path, arguments: []))
        #expect(result.exitCode == 7 && result.stderr == "bad thing\n" && String(decoding: result.stdout, as: UTF8.self) == "out\n")
    }

    @Test func timeoutTerminatesTheProcess() async throws {
        let script = try makeScript("exec sleep 30")
        defer { script.cleanup() }
        let started = Date()
        await #expect(throws: CommandError.timedOut) {
            try await ProcessCommandExecutor().run(CommandInvocation(executable: script.path, arguments: [], timeout: 0.3))
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func stdinIsClosedAndLargeOutputDoesNotBlock() async throws {
        let script = try makeScript("cat >/dev/null; head -c 300000 /dev/zero | tr '\\0' 'a'; head -c 300000 /dev/zero | tr '\\0' 'b' >&2")
        defer { script.cleanup() }
        let result = try await ProcessCommandExecutor().run(CommandInvocation(executable: script.path, arguments: []))
        #expect(result.exitCode == 0 && result.stdout.count == 300_000 && result.stderr.count == 300_000)
    }

    @Test func environmentIsMergedAndArgumentsAreNotInterpretedByAShell() async throws {
        let script = try makeScript("printf '%s|%s' \"$DOCKYARD_FAKE_OP\" \"$1\"")
        defer { script.cleanup() }
        let result = try await ProcessCommandExecutor().run(
            CommandInvocation(executable: script.path, arguments: ["$(touch /nonexistent); `x`"], environment: ["DOCKYARD_FAKE_OP": "yes"]))
        #expect(String(decoding: result.stdout, as: UTF8.self) == "yes|$(touch /nonexistent); `x`")
    }

    @Test func missingExecutableIsALaunchFailure() async throws {
        await #expect(throws: CommandError.self) {
            try await ProcessCommandExecutor().run(CommandInvocation(executable: "/nonexistent/op", arguments: []))
        }
        await #expect(throws: OnePasswordError.notInstalled) {
            try await OnePasswordCLI(locator: { "/nonexistent/op" }).vaults()
        }
    }

    @Test func cancellationStopsTheProcess() async throws {
        let script = try makeScript("exec sleep 30")
        defer { script.cleanup() }
        let started = Date()
        let task = Task { try await ProcessCommandExecutor().run(CommandInvocation(executable: script.path, arguments: [], timeout: 60)) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = try? await task.value
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
