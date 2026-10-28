import Foundation

/// One SSH hop in a jump chain: how to reach it and where its secrets live.
public struct SSHJumpHop: Sendable {
    public var config: ConnectionConfig
    public var secrets: any SecretStore
    /// Falls back to the validator of the final connection.
    public var hostKeyValidator: SSHHostKeyValidator?

    public init(config: ConnectionConfig, secrets: any SecretStore, hostKeyValidator: SSHHostKeyValidator? = nil) {
        self.config = config
        self.secrets = secrets
        self.hostKeyValidator = hostKeyValidator
    }
}

enum SSHAuth {
    /// Why a key file can't be used as a private key, for files libssh2 would only call "wrong passphrase".
    static func problem(withKey text: String, path: String) -> String? {
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicPrefixes = ["ssh-", "ecdsa-sha2-", "sk-ssh-", "sk-ecdsa-", "---- BEGIN SSH2 PUBLIC KEY"]
        if publicPrefixes.contains(where: start.hasPrefix) || start.hasPrefix("-----BEGIN PUBLIC KEY") {
            let privatePath = path.hasSuffix(".pub") ? String(path.dropLast(4)) : nil
            return "\(path) is a public key. Choose the private key" + (privatePath.map { " (\($0))" } ?? "") + " instead."
        }
        if start.hasPrefix("PuTTY-User-Key-File") {
            return "\(path) is a PuTTY key. Export it in PuTTYgen with Conversions, Export OpenSSH key, and choose that file."
        }
        return nil
    }


    /// The authentication steps for `config`, in the order they are tried on one connection.
    static func steps(for config: ConnectionConfig, secrets: any SecretStore) async throws -> [SSHAuthStep] {
        let methods = config.authMethods
        var steps: [SSHAuthStep] = []
        if methods.contains(.agent) {
            if let socket = config.agentSocket.resolvedPath() { steps.append(.agentSocket(socket)) } else { steps.append(.agent) }
        }
        if methods.contains(.key) {
            guard let keyPath = config.keyPath else { throw RemoteError.invalidConfiguration("Key authentication needs a key path") }
            let expanded = (keyPath as NSString).expandingTildeInPath
            guard let key = try? String(contentsOfFile: expanded, encoding: .utf8) else {
                throw RemoteError.invalidConfiguration("Cannot read key file at \(keyPath)")
            }
            if let problem = problem(withKey: key, path: keyPath) { throw RemoteError.invalidConfiguration(problem) }
            steps.append(.publicKey(privateKey: key, passphrase: try await secrets.secret(for: config.id, purpose: .keyPassphrase)))
        }
        if methods.contains(.password) || methods.contains(.keyboardInteractive) {
            if let password = try await secrets.secret(for: config.id, purpose: .password) {
                if methods.contains(.password) { steps.append(.password(password)) }
                steps.append(.keyboardInteractive { _, _ in password })
            } else if steps.isEmpty {
                throw RemoteError.authenticationFailed("No password stored for this connection")
            }
        }
        guard !steps.isEmpty else { throw RemoteError.invalidConfiguration("No authentication method selected") }
        return steps
    }
}
