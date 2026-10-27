import Foundation

public enum OnePasswordError: Error, Equatable, CustomStringConvertible {
    case notInstalled
    /// The desktop app does not expose its accounts to the CLI ("Integrate with 1Password CLI" is off, or the app is not running).
    case integrationOff
    /// The app is locked or the account needs a sign-in.
    case appLocked
    /// The Touch ID / system authorization prompt was cancelled or denied.
    case authorizationDismissed
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
            let data = try await run(["account", "list", "--format", "json"], useAccount: false)
            accounts = data.isEmpty ? [] : try decode([OnePasswordAccount].self, from: data)
        } catch OnePasswordError.integrationOff {
            return .integrationOff
        } catch OnePasswordError.appLocked, OnePasswordError.authorizationDismissed {
            return .signedOut([])
        }
        guard !accounts.isEmpty else { return .integrationOff }
        do {
            _ = try await run(["whoami", "--format", "json"])
            return .ready(accounts)
        } catch OnePasswordError.appLocked, OnePasswordError.authorizationDismissed, OnePasswordError.integrationOff {
            return .signedOut(accounts)
        }
    }

    public func vaults() async throws -> [OnePasswordVault] {
        try decode([OnePasswordVault].self, from: try await run(["vault", "list", "--format", "json"]))
    }

    /// Item summaries (no field values). `vault` is a name or id.
    public func items(
        inVault vault: String, categories: [OnePasswordItem.Category] = OnePasswordCLI.defaultCategories
    ) async throws -> [OnePasswordItem] {
        var arguments = ["item", "list", "--vault", try safe(vault)]
        if !categories.isEmpty { arguments += ["--categories", categories.map(\.cliName).joined(separator: ",")] }
        let data = try await run(arguments + ["--format", "json"])
        // `op` prints nothing instead of `[]` for an empty result.
        return data.isEmpty ? [] : try decode([OnePasswordItem].self, from: data)
    }

    /// The full item including field values.
    public func item(id: String, inVault vault: String) async throws -> OnePasswordItem {
        try decode(OnePasswordItem.self, from: try await run(["item", "get", try safe(id), "--vault", try safe(vault), "--format", "json"]))
    }

    /// Reads one secret. `reference` must look like `op://vault/item/[section/]field`.
    public func read(reference: String) async throws -> String {
        try await resolve(reference: reference)
    }

    public func resolve(reference: String) async throws -> String {
        guard Self.isValidReference(reference) else { throw OnePasswordError.invalidReference("<redacted>") }
        let data = try await run(["read", "--no-newline", reference], logged: "op read (reference and value withheld)")
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

    private func run(_ arguments: [String], useAccount: Bool = true, logged: String? = nil) async throws -> Data {
        guard let executable = locate() else { throw OnePasswordError.notInstalled }
        let full = arguments + (useAccount ? account.map { ["--account", $0] } ?? [] : [])
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
