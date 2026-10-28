import ConnectionKit
import DockyardCore
import Foundation

// MARK: - Testing a WHM server's account login

extension AppModel {
    /// Tests the login the WHM sheet describes, before it is saved. "Through root" logs in as root, then opens one
    /// synced account as that account; the per-account logins open one synced account.
    func testWHMLogin(host: String, login: WHMAccountLogin, passphrase: String, source: WHMSource?) async -> ConnectionTestResult {
        var result = await testFormLogin(host: host, login: login, passphrase: passphrase, source: source)
        if result.success, let id = source?.id {
            let other = allConnections.filter { $0.source.whmServerId == id && !$0.removedFromSource && !login.matches($0) }.count
            if other > 0 {
                result.message += " \(other) \(other == 1 ? "account still logs" : "accounts still log") in another way; click Save to move "
                    + "the ones on this server's login, or change the others in their site editor."
            }
        }
        return result
    }

    private func testFormLogin(host: String, login: WHMAccountLogin, passphrase: String, source: WHMSource?) async -> ConnectionTestResult {
        let account = firstAccount(of: source)
        let port = account?.port ?? 22
        let storedPassphrase = await savedPassphrase(source: source, typed: passphrase)
        do {
            switch login {
            case .password:
                return ConnectionTestResult(
                    success: false, message: "Each account logs in with its own password. Test one from its site editor.")
            case .key, .agent:
                guard let account else {
                    return ConnectionTestResult(success: false, message: "Sync the server first, then test with one of its accounts.")
                }
                var connection = account
                login.apply(to: &connection)
                let home = try await probe(connection, passphrase: storedPassphrase)
                return ConnectionTestResult(success: true, message: "\(account.username) logged in. Opened \(home).")
            case .throughRoot(let root):
                var rootConnection = Connection(name: "root@\(host)", host: host, port: port, username: WHMAccountLogin.rootUser)
                WHMAccountLogin.throughRoot(root).apply(to: &rootConnection)
                rootConnection.loginUser = nil
                _ = try await probe(rootConnection, passphrase: storedPassphrase)
                guard let account else {
                    return ConnectionTestResult(success: true, message: "Root logged in with \(Self.describe(root)). Sync to add the accounts.")
                }
                var connection = account
                login.apply(to: &connection)
                do {
                    let home = try await probe(connection, passphrase: storedPassphrase)
                    return ConnectionTestResult(
                        success: true, message: "Root logged in with \(Self.describe(root)) and opened \(home) as \(account.username).")
                } catch {
                    return ConnectionTestResult(
                        success: false, message: "Root logged in, but working as \(account.username) failed: \(error.userMessage)")
                }
            }
        } catch {
            return ConnectionTestResult(success: false, message: error.userMessage)
        }
    }

    /// Tries the keys this Mac has against root on `host`, one connection each, and returns the first that logs in.
    /// Candidates, in order: IdentityFile lines for the host in ~/.ssh/config, the SSH agent, 1Password's agent,
    /// then private keys in ~/.ssh that have a matching .pub file.
    func findRootKey(host: String, passphrase: String, source: WHMSource?) async -> (found: WHMAccountLogin.RootAuth?, message: String) {
        let port = firstAccount(of: source)?.port ?? 22
        let candidates = await Task.detached { Self.rootKeyCandidates(host: host) }.value
        guard !candidates.isEmpty else {
            return (nil, "No keys found in ~/.ssh or an SSH agent. Create one in Terminal: ssh-keygen -t ed25519")
        }
        let storedPassphrase = await savedPassphrase(source: source, typed: passphrase)
        var tried: [String] = []
        for candidate in candidates {
            var connection = Connection(name: "root@\(host)", host: host, port: port, username: WHMAccountLogin.rootUser)
            WHMAccountLogin.throughRoot(candidate).apply(to: &connection)
            connection.loginUser = nil
            do {
                _ = try await probe(connection, passphrase: storedPassphrase)
                return (candidate, "Root logs in with \(Self.describe(candidate)). It's selected above; click Save to use it.")
            } catch let error as RemoteError {
                switch error {
                case .authenticationFailed, .invalidConfiguration:
                    tried.append(Self.describe(candidate))
                default:
                    // Unreachable host, rejected host key and the like: no other key will do better.
                    return (nil, error.userMessage)
                }
            } catch AppError.cancelled {
                return (nil, "Cancelled.")
            } catch {
                return (nil, error.userMessage)
            }
        }
        return (nil, "Root did not accept any of: \(tried.joined(separator: ", ")). An encrypted key needs its passphrase typed above.")
    }

    /// The synced account a test opens: the first by name that is still on the server.
    private func firstAccount(of source: WHMSource?) -> Connection? {
        guard let id = source?.id else { return nil }
        return allConnections
            .filter { $0.source.whmServerId == id && !$0.removedFromSource }
            .min { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Connects, opens the home folder and disconnects. Returns the home folder.
    private func probe(_ connection: Connection, passphrase: String?) async throws -> String {
        let memory = InMemorySecretStore()
        if let passphrase { await memory.setSecret(passphrase, for: connection.id, purpose: .keyPassphrase) }
        let log = LogBuffer(capacity: 200)
        let validator = hostKeyValidator(host: connection.host, port: connection.port, log: log)
        let fs = try FileSystemFactory.make(for: connection, secrets: memory, hostKeyValidator: validator)
        do {
            try await fs.connect()
            let home = (try? await fs.homeDirectory()) ?? "/"
            _ = try await fs.list(home)
            await fs.disconnect()
            return home
        } catch {
            await fs.disconnect()
            throw error
        }
    }

    /// The typed passphrase, else the one saved under the WHM server.
    private func savedPassphrase(source: WHMSource?, typed: String) async -> String? {
        if !typed.isEmpty { return typed }
        guard let source else { return nil }
        return try? await keychainSecrets.secret(for: source.id, purpose: .keyPassphrase)
    }

    nonisolated static func describe(_ root: WHMAccountLogin.RootAuth) -> String {
        switch root {
        case .key(let path):
            let home = AgentSocket.realHomeDirectory
            return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        case .agent(.system): return "the SSH agent"
        case .agent(.onePassword): return "1Password's SSH agent"
        case .agent(.custom(let path)): return "the agent at \(path)"
        }
    }

    nonisolated static func rootKeyCandidates(host: String) -> [WHMAccountLogin.RootAuth] {
        let home = AgentSocket.realHomeDirectory
        let files = FileManager.default
        var seen: Set<String> = []
        func keys(_ paths: [String]) -> [WHMAccountLogin.RootAuth] {
            paths.compactMap { path in
                let expanded = path == "~" || path.hasPrefix("~/") ? home + path.dropFirst(1) : path
                guard files.isReadableFile(atPath: expanded), seen.insert(expanded).inserted else { return nil }
                return .key(path: expanded)
            }
        }

        let wanted = host.lowercased()
        let configured = SSHConfigParser(home: home).parseDefault().entries
            .filter { $0.alias.lowercased() == wanted || $0.hostName.lowercased() == wanted }
            .flatMap(\.identityFiles)
        var result = keys(configured)
        if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], files.fileExists(atPath: socket) {
            result.append(.agent(.system))
        }
        if let socket = AgentSocket.onePassword.resolvedPath(home: home), files.fileExists(atPath: socket) {
            result.append(.agent(.onePassword))
        }

        let ssh = home + "/.ssh"
        let defaults = ["id_ed25519", "id_ecdsa", "id_rsa"]
        let others = ((try? files.contentsOfDirectory(atPath: ssh)) ?? [])
            .filter { $0.hasSuffix(".pub") }
            .map { String($0.dropLast(4)) }
            .filter { !defaults.contains($0) }
            .sorted()
        result += keys((defaults + others).map { ssh + "/" + $0 })
        return Array(result.prefix(10))
    }
}
