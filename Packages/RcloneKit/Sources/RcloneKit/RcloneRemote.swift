import ConnectionKit
import Foundation

public enum RcloneBackend: String, Sendable, Hashable, Codable, CaseIterable {
    case s3, b2, drive, dropbox, onedrive

    /// Backends authorised with OAuth. Their secret is a token JSON object.
    public var usesOAuth: Bool {
        switch self {
        case .drive, .dropbox, .onedrive: true
        case .s3, .b2: false
        }
    }

    /// Backends whose top level is a list of buckets when no bucket is configured.
    public var hasBuckets: Bool { self == .s3 || self == .b2 }
}

/// Well-known values for the S3 `provider` option.
public enum S3Provider {
    public static let aws = "AWS"
    public static let cloudflare = "Cloudflare"
    public static let minio = "Minio"
    public static let wasabi = "Wasabi"
    public static let other = "Other"
}

/// Everything about a cloud remote that is not a secret.
///
/// Credentials come from the `ConnectionConfig` (`username` is the access key id or B2 account id, `host` the S3 endpoint)
/// and from the `SecretStore` (`.cloudToken` holds the secret access key, B2 application key, or OAuth token JSON).
public struct RcloneRemoteSpec: Sendable, Hashable, Codable {
    public var backend: RcloneBackend
    /// Extra backend options such as `provider`, `region`, `endpoint`, `client_id`, `drive_id`.
    public var options: [String: String]
    /// Path inside the remote the connection is rooted at, e.g. `my-bucket/site`. Empty shows every bucket.
    public var root: String

    public init(backend: RcloneBackend, options: [String: String] = [:], root: String = "") {
        self.backend = backend
        self.options = options
        self.root = root
    }
}

/// A remote resolved to rclone's connection-string syntax, e.g. `:s3,provider=Minio,access_key_id=x:bucket`.
public struct RcloneResolvedRemote: Sendable, Equatable {
    public var fs: String
    /// Same string with secrets replaced by `****`, safe to log.
    public var redactedFs: String
}

extension RcloneRemoteSpec {
    static let secretOptionNames: Set<String> = RcloneRedactor.secretKeys

    public func resolve(username: String, host: String, secret: String?) throws -> RcloneResolvedRemote {
        var params = options
        var secretNames = Set(options.keys).intersection(Self.secretOptionNames)
        let secret = secret?.isEmpty == false ? secret : nil

        switch backend {
        case .s3:
            params["env_auth"] = "false"
            if params["endpoint"] == nil, !host.isEmpty {
                params["endpoint"] = host.contains("://") ? host : "https://\(host)"
            }
            if !username.isEmpty || secret != nil {
                guard !username.isEmpty, let secret else {
                    throw RemoteError.invalidConfiguration("S3 needs both an access key id and a secret access key")
                }
                params["access_key_id"] = username
                params["secret_access_key"] = secret
                secretNames.insert("secret_access_key")
            }
        case .b2:
            guard !username.isEmpty, let secret else {
                throw RemoteError.invalidConfiguration("Backblaze B2 needs an account id and an application key")
            }
            params["account"] = username
            params["key"] = secret
            secretNames.insert("key")
        case .drive, .dropbox, .onedrive:
            guard let secret else {
                throw RemoteError.authenticationFailed("No OAuth token stored for this connection")
            }
            guard let data = secret.data(using: .utf8),
                  let token = try? JSONDecoder().decode([String: JSONValue].self, from: data),
                  token["access_token"] != nil || token["refresh_token"] != nil else {
                throw RemoteError.invalidConfiguration("The stored OAuth token is not a token JSON object")
            }
            params["token"] = secret
            secretNames.insert("token")
        }

        let clean = root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        func render(masking: Bool) -> String {
            let body = params.keys.sorted().map { key in
                let value = masking && secretNames.contains(key) ? "****" : params[key]!
                return "\(key)=\(Self.quote(value))"
            }
            return ":\(backend.rawValue),\(body.joined(separator: ",")):\(clean)"
        }
        return RcloneResolvedRemote(fs: render(masking: false), redactedFs: render(masking: true))
    }

    /// Bare when the value has only characters the connection-string parser stops on never, otherwise double-quoted.
    static func quote(_ value: String) -> String {
        let plain = !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._/-@+*".unicodeScalars.contains($0)
        }
        return plain ? value : "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

public enum RcloneRedactor {
    static let secretKeys: Set<String> = [
        "secret_access_key", "session_token", "access_token", "refresh_token", "token", "key", "password", "pass",
        "client_secret", "sse_customer_key", "sse_customer_key_base64", "sse_kms_key_id", "api_key", "account_key",
    ]

    private static let pattern: NSRegularExpression = {
        let names = secretKeys.sorted().joined(separator: "|")
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_])(\(names))=(\"(?:[^\"]|\"\")*\"|'(?:[^']|'')*'|[^,:\\s]*)",
            options: [.caseInsensitive]
        )
    }()

    /// Masks `secret=value` pairs in connection strings and free text.
    public static func redact(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "$1=****")
    }

    /// One log line for an rc call: only top-level scalars are shown, nested objects are elided.
    public static func describe(method: String, params: [String: JSONValue]) -> String {
        let parts = params.keys.sorted().compactMap { key -> String? in
            if key.hasPrefix("_") { return nil }
            switch params[key]! {
            case .string(let v): return "\(key)=\(secretKeys.contains(key) ? "****" : redact(v))"
            case .int(let v): return "\(key)=\(v)"
            case .double(let v): return "\(key)=\(v)"
            case .bool(let v): return "\(key)=\(v)"
            case .null: return nil
            case .array, .object: return "\(key)=…"
            }
        }
        return (["rc", method] + parts).joined(separator: " ")
    }
}
