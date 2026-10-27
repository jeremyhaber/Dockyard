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
    /// The authentication steps for `config`, in the order they are tried on one connection.
    static func steps(for config: ConnectionConfig, secrets: any SecretStore) async throws -> [SSHAuthStep] {
        let methods = config.authMethods
        var steps: [SSHAuthStep] = []
        if methods.contains(.agent) { steps.append(.agent) }
        if methods.contains(.key) {
            guard let keyPath = config.keyPath else { throw RemoteError.invalidConfiguration("Key authentication needs a key path") }
            let expanded = (keyPath as NSString).expandingTildeInPath
            guard let key = try? String(contentsOfFile: expanded, encoding: .utf8) else {
                throw RemoteError.invalidConfiguration("Cannot read key file at \(keyPath)")
            }
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
