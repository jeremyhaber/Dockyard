import Foundation

public enum OnePasswordError: Error, Equatable, CustomStringConvertible {
    case notInstalled
    /// The desktop app does not expose its accounts to the CLI ("Integrate with 1Password CLI" is off, or the app is not running).
    case integrationOff
    /// The app is locked or the account needs a sign-in.
    case appLocked
    /// The Touch ID / system authorization prompt was cancelled or denied.
    case authorizationDismissed
    /// Several accounts are signed in and the call named none of them.
    case multipleAccounts
    case notFound(String)
    case invalidReference(String)
    case timedOut
    case commandFailed(exitCode: Int32, message: String)
    case unexpectedOutput(String)

    public var description: String {
        switch self {
        case .notInstalled: "The 1Password CLI (op) is not installed"
        case .integrationOff: "1Password CLI integration is off. Turn on \"Integrate with 1Password CLI\" in 1Password > Settings > Developer"
        case .appLocked: "1Password is locked. Unlock it and try again"
        case .authorizationDismissed: "The 1Password authorization prompt was dismissed"
        case .multipleAccounts: "Several 1Password accounts are signed in and op could not tell which one to use"
        case .notFound(let what): "1Password could not find \(what)"
        case .invalidReference(let reference): "Not a 1Password secret reference: \(reference)"
        case .timedOut: "1Password did not answer in time"
        case .commandFailed(let code, let message): "op exited with status \(code): \(message)"
        case .unexpectedOutput(let message): "Unexpected output from op: \(message)"
        }
    }

    /// True when waiting for the user to unlock, approve or enable something may fix it.
    public var needsUserAction: Bool {
        switch self {
        case .notInstalled, .integrationOff, .appLocked, .authorizationDismissed: true
        default: false
        }
    }
}

/// A small async wrapper around the 1Password CLI (`op`, v2) using the desktop app integration.
/// Item JSON contains secrets: nothing from stdout is ever logged, and `read` logs no reference or value.
public struct OnePasswordCLI: Sendable, SecretReferenceResolving {
    public typealias Locator = @Sendable () -> String?

    public static let defaultCategories: [OnePasswordItem.Category] = [.server, .login, .sshKey]

    private let executor: any CommandExecuting
    private let locate: Locator
    private let account: String?
    private let timeout: TimeInterval
    private let log: @Sendable (String) -> Void
    private let memo = LockedBox(Memo())

    /// Learned from `op` when several accounts are signed in: their ids, and which account each listed vault is in.
    private struct Memo {
        var accounts: [OnePasswordAccount] = []
        var vaultAccounts: [String: String] = [:]
    }

    /// - Parameters:
    ///   - account: passed as `--account`, for people with several 1Password accounts.
    ///   - locator: finds the `op` executable; defaults to `OnePasswordCLI.locateExecutable()`.
    public init(
        executor: any CommandExecuting = ProcessCommandExecutor(),
        account: String? = nil,
        timeout: TimeInterval = 45,
        locator: @escaping Locator = { OnePasswordCLI.locateExecutable() },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.executor = executor
        self.account = account
        self.timeout = timeout
        self.locate = locator
        self.log = log
    }

    /// Homebrew (Apple silicon and Intel) first, then every `PATH` entry.
    public static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let fixed = ["/opt/homebrew/bin", "/usr/local/bin"]
        let fromPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        for directory in fixed + fromPath where !directory.isEmpty && seen.insert(directory).inserted {
            let candidate = directory + "/op"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    // MARK: Calls

    public func status() async throws -> OnePasswordStatus {
        guard locate() != nil else { return .notInstalled }
        let accounts: [OnePasswordAccount]
        do {
            let data = try await run(["account", "list", "--format", "json"], account: nil)
            accounts = data.isEmpty ? [] : try decode([OnePasswordAccount].self, from: data)
        } catch OnePasswordError.integrationOff {
            return .integrationOff
        } catch OnePasswordError.appLocked, OnePasswordError.authorizationDismissed {
            return .signedOut([])
        }
        guard !accounts.isEmpty else { return .integrationOff }
        memo.withLock { $0.accounts = accounts }
        // With several accounts, `op` refuses calls that name none of them.
        let targets: [String?] = account.map { [$0] } ?? (accounts.count > 1 ? accounts.map(\.id) : [nil])
        do {
            for target in targets {
                do {
                    _ = try await run(["whoami", "--format", "json"], account: target)
                    return .ready(accounts)
                } catch OnePasswordError.appLocked, OnePasswordError.authorizationDismissed, OnePasswordError.integrationOff,
                    OnePasswordError.multipleAccounts {}
            }
            // `whoami` only reports a session that already exists and never asks for one, so an unlocked app still looks
            // signed out until something authorizes Dockyard. Listing vaults asks (Touch ID, or unlocking the app).
            _ = try await run(["vault", "list", "--format", "json"], account: targets[0])
            return .ready(accounts)
        } catch OnePasswordError.appLocked, OnePasswordError.authorizationDismissed, OnePasswordError.integrationOff {
            return .signedOut(accounts)
        }
    }

    /// Every vault, from each account when several are signed in.
    public func vaults() async throws -> [OnePasswordVault] {
        var accounts = account == nil ? memo.withLock { $0.accounts } : []
        if accounts.count <= 1 {
            do {
                return try decode([OnePasswordVault].self, from: try await run(["vault", "list", "--format", "json"]))
            } catch OnePasswordError.multipleAccounts where account == nil {
                accounts = try await signedInAccounts()
            }
        }
        var all: [OnePasswordVault] = []
        for owner in accounts {
            let list = try decode([OnePasswordVault].self, from: try await run(["vault", "list", "--format", "json"], account: owner.id))
            memo.withLock { memo in for vault in list { memo.vaultAccounts[vault.id] = owner.id } }
            all += list.map { OnePasswordVault(id: $0.id, name: $0.name, account: owner.url) }
        }
        return all
    }

    /// Item summaries (no field values). `vault` is a name or id.
    public func items(
        inVault vault: String, categories: [OnePasswordItem.Category] = OnePasswordCLI.defaultCategories
    ) async throws -> [OnePasswordItem] {
        var arguments = ["item", "list", "--vault", try safe(vault)]
        if !categories.isEmpty { arguments += ["--categories", categories.map(\.cliName).joined(separator: ",")] }
        let data = try await inSomeAccount(vault: vault) { try await run(arguments + ["--format", "json"], account: $0) }
        // `op` prints nothing instead of `[]` for an empty result.
        return data.isEmpty ? [] : try decode([OnePasswordItem].self, from: data)
    }

    /// The full item including field values.
    public func item(id: String, inVault vault: String) async throws -> OnePasswordItem {
        let arguments = ["item", "get", try safe(id), "--vault", try safe(vault), "--format", "json"]
        return try decode(OnePasswordItem.self, from: try await inSomeAccount(vault: vault) { try await run(arguments, account: $0) })
    }

    /// Reads one secret. `reference` must look like `op://vault/item/[section/]field`.
    public func read(reference: String) async throws -> String {
        try await resolve(reference: reference)
    }

    public func resolve(reference: String) async throws -> String {
        guard Self.isValidReference(reference) else { throw OnePasswordError.invalidReference("<redacted>") }
        let data = try await inSomeAccount {
            try await run(["read", "--no-newline", reference], account: $0, logged: "op read (reference and value withheld)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func isValidReference(_ reference: String) -> Bool {
        guard reference.hasPrefix("op://"), !reference.contains("\n") else { return false }
        let parts = reference.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty }
    }

    // MARK: Plumbing

    private func safe(_ argument: String) throws -> String {
        guard !argument.isEmpty, !argument.hasPrefix("-") else { throw OnePasswordError.notFound("an item or vault named \"\(argument)\"") }
        return argument
    }

    /// Runs `body` with the configured account, or with none. When `op` answers that several accounts are signed in,
    /// tries each account in turn until one has the vault, item or field. References name a vault, not an account.
    private func inSomeAccount<T>(vault: String? = nil, _ body: (String?) async throws -> T) async throws -> T {
        if let account { return try await body(account) }
        if let vault, let owner = memo.withLock({ $0.vaultAccounts[vault] }) { return try await body(owner) }
        var accounts = memo.withLock { $0.accounts }
        if accounts.count <= 1 {
            do { return try await body(nil) } catch OnePasswordError.multipleAccounts { accounts = try await signedInAccounts() }
        }
        var missing = OnePasswordError.notFound("the requested item, vault or field")
        for candidate in accounts {
            do { return try await body(candidate.id) } catch let error as OnePasswordError {
                guard case .notFound = error else { throw error }
                missing = error
            }
        }
        throw missing
    }

    private func signedInAccounts() async throws -> [OnePasswordAccount] {
        let data = try await run(["account", "list", "--format", "json"], account: nil)
        let accounts = data.isEmpty ? [] : try decode([OnePasswordAccount].self, from: data)
        memo.withLock { $0.accounts = accounts }
        return accounts
    }

    private func run(_ arguments: [String], logged: String? = nil) async throws -> Data {
        try await run(arguments, account: account, logged: logged)
    }

    private func run(_ arguments: [String], account: String?, logged: String? = nil) async throws -> Data {
        guard let executable = locate() else { throw OnePasswordError.notInstalled }
        let full = arguments + (account.map { ["--account", $0] } ?? [])
        log(logged ?? "op " + arguments.prefix(2).joined(separator: " "))
        let result: CommandResult
        do {
            result = try await executor.run(CommandInvocation(executable: executable, arguments: full, timeout: timeout))
        } catch CommandError.timedOut {
            throw OnePasswordError.timedOut
        } catch CommandError.launchFailed {
            throw OnePasswordError.notInstalled
        }
        guard result.exitCode == 0 else { throw Self.map(stderr: result.stderr, exitCode: result.exitCode) }
        return result.stdout
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            // The decoder's message can quote the document, which holds secrets.
            throw OnePasswordError.unexpectedOutput("not the JSON shape expected for \(T.self)")
        }
    }

    /// Maps `op`'s stderr (`[ERROR] 2026/01/02 15:04:05 message`) to a typed error. Matching is on documented phrases.
    static func map(stderr: String, exitCode: Int32) -> OnePasswordError {
        let message = stderr.split(separator: "\n").map(String.init)
            .map { $0.replacingOccurrences(of: #"^\[ERROR\]\s+\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s*"#, with: "", options: .regularExpression) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = message.lowercased()
        func has(_ phrases: String...) -> Bool { phrases.contains { text.contains($0) } }

        if has("authorization prompt dismissed", "authorization denied", "prompt dismissed", "user denied", "authorization timeout") {
            return .authorizationDismissed
        }
        if has("multiple accounts found") { return .multipleAccounts }
        if has("no accounts configured", "integrate with 1password cli", "couldn't connect to the 1password desktop app",
               "could not connect to the 1password desktop app", "desktop app integration") {
            return .integrationOff
        }
        if has("is locked", "not signed in", "not currently signed in", "no active session", "sign in to", "session expired") {
            return .appLocked
        }
        if has("isn't an item", "isn't a vault", "isn't a field", "isn't a section", "could not be found", "not found", "no such") {
            return .notFound("the requested item, vault or field")
        }
        return .commandFailed(exitCode: exitCode, message: String(message.prefix(300)))
    }
}
