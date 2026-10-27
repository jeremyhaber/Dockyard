import Foundation

/// Which ssh-agent socket the `.agent` auth method talks to.
public enum AgentSocket: Sendable, Hashable, RawRepresentable {
    /// `SSH_AUTH_SOCK` of the process.
    case system
    /// 1Password's SSH agent at `onePasswordDefaultPath`.
    case onePassword
    case custom(String)

    /// Where the 1Password desktop app listens for SSH agent requests.
    public static let onePasswordDefaultPath = "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

    public var rawValue: String {
        switch self {
        case .system: "system"
        case .onePassword: "onePassword"
        case .custom(let path): "custom:\(path)"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "system": self = .system
        case "onePassword": self = .onePassword
        default:
            guard rawValue.hasPrefix("custom:"), rawValue.count > 7 else { return nil }
            self = .custom(String(rawValue.dropFirst(7)))
        }
    }

    /// The socket path to hand to the agent client, or nil for `SSH_AUTH_SOCK`. `~` means the real home folder.
    public func resolvedPath(home: String = AgentSocket.realHomeDirectory) -> String? {
        switch self {
        case .system: nil
        case .onePassword: Self.expand(Self.onePasswordDefaultPath, home: home)
        case .custom(let path): Self.expand(path, home: home)
        }
    }

    /// The account's home folder, which differs from `NSHomeDirectory()` inside an app sandbox container.
    public static var realHomeDirectory: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    private static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}

extension AgentSocket: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = AgentSocket(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown agent socket \(raw)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
