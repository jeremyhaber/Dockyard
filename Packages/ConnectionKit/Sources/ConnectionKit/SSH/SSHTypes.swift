import Foundation

public struct SSHHostKey: Sendable, Equatable {
    /// OpenSSH algorithm name such as `ssh-ed25519` or `ecdsa-sha2-nistp256`.
    public let algorithm: String
    /// `SHA256:` followed by the unpadded base64 digest, as printed by `ssh-keygen -l`.
    public let fingerprint: String
    /// The raw public key blob.
    public let key: Data

    public init(algorithm: String, fingerprint: String, key: Data) {
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.key = key
    }
}

/// Decides whether to continue with a server's host key. Trust-on-first-use storage lives in the app.
public struct SSHHostKeyValidator: Sendable {
    public var validate: @Sendable (SSHHostKey) async -> Bool

    public init(_ validate: @escaping @Sendable (SSHHostKey) async -> Bool) {
        self.validate = validate
    }

    public static func acceptAnything() -> SSHHostKeyValidator { SSHHostKeyValidator { _ in true } }
}

/// Answers a keyboard-interactive prompt. Must not block.
public typealias SSHPromptResponder = @Sendable (_ prompt: String, _ echo: Bool) -> String

/// One authentication attempt. Steps are tried in order on the same connection, so a server that
/// requires `publickey,password` is satisfied by `[.publicKey, .password]`.
public enum SSHAuthStep: Sendable, CustomStringConvertible {
    case agent
    case publicKey(privateKey: String, passphrase: String?)
    case password(String)
    case keyboardInteractive(SSHPromptResponder)

    public var description: String {
        switch self {
        case .agent: "ssh-agent"
        case .publicKey: "public key"
        case .password: "password"
        case .keyboardInteractive: "keyboard-interactive"
        }
    }
}

public struct SSHExecResult: Sendable {
    public var stdout: Data
    public var stderr: Data
    public var exitStatus: Int32

    public init(stdout: Data = Data(), stderr: Data = Data(), exitStatus: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public struct SSHSessionOptions: Sendable {
    public var connectTimeout: TimeInterval = 15
    /// Seconds between SSH keepalive messages; 0 disables them.
    public var keepAliveInterval: TimeInterval = 15
    /// Gives up when the server stays silent this long during one operation.
    public var operationTimeout: TimeInterval = 60

    public init() {}
}

/// Password prompts for `su -` and `sudo -i` in an interactive shell.
public struct ShellElevation: Sendable {
    public var kind: Elevation
    public var password: String?

    public init(kind: Elevation, password: String?) {
        self.kind = kind
        self.password = password
    }
}
