import Foundation

public struct OnePasswordAccount: Sendable, Hashable, Codable, Identifiable {
    public var url: String
    public var email: String
    public var userUUID: String
    public var accountUUID: String

    public var id: String { accountUUID.isEmpty ? url : accountUUID }

    enum CodingKeys: String, CodingKey {
        case url, email
        case userUUID = "user_uuid"
        case accountUUID = "account_uuid"
    }

    public init(url: String = "", email: String = "", userUUID: String = "", accountUUID: String = "") {
        self.url = url; self.email = email; self.userUUID = userUUID; self.accountUUID = accountUUID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try c.decodeIfPresent(String.self, forKey: .url) ?? "",
            email: try c.decodeIfPresent(String.self, forKey: .email) ?? "",
            userUUID: try c.decodeIfPresent(String.self, forKey: .userUUID) ?? "",
            accountUUID: try c.decodeIfPresent(String.self, forKey: .accountUUID) ?? "")
    }
}

public enum OnePasswordStatus: Sendable, Equatable {
    case notInstalled
    /// `op` exists but knows no account: "Integrate with 1Password CLI" is off in the desktop app.
    case integrationOff
    /// Accounts are known but the app is locked or needs a sign-in.
    case signedOut([OnePasswordAccount])
    case ready([OnePasswordAccount])

    public var isReady: Bool { if case .ready = self { true } else { false } }
}

public struct OnePasswordVault: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// The account's sign-in address, set only when vaults from several accounts are listed together.
    public var account: String?

    public init(id: String, name: String = "", account: String? = nil) { self.id = id; self.name = name; self.account = account }

    /// The name, plus the account when several accounts can have vaults with the same name.
    public var displayName: String { account.map { "\(name) (\($0))" } ?? name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? "",
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "")
    }
}

public struct OnePasswordURL: Sendable, Hashable, Codable {
    public var label: String?
    public var primary: Bool
    public var href: String

    public init(label: String? = nil, primary: Bool = false, href: String) { self.label = label; self.primary = primary; self.href = href }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            label: try c.decodeIfPresent(String.self, forKey: .label),
            primary: try c.decodeIfPresent(Bool.self, forKey: .primary) ?? false,
            href: try c.decodeIfPresent(String.self, forKey: .href) ?? "")
    }
}

public struct OnePasswordField: Sendable, Hashable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public struct Section: Sendable, Hashable, Codable {
        public var id: String?
        public var label: String?
    }

    public var id: String
    /// `STRING`, `CONCEALED`, `URL`, `EMAIL`, `SSHKEY`, ...
    public var type: String
    /// `USERNAME`, `PASSWORD` or `NOTES` for the built-in fields.
    public var purpose: String?
    public var label: String
    public var value: String?
    /// `op://vault/item/[section/]field`, usable with `op read`.
    public var reference: String?
    public var section: Section?

    enum CodingKeys: String, CodingKey { case id, type, purpose, label, value, reference, section }

    public init(
        id: String, type: String = "STRING", purpose: String? = nil, label: String = "", value: String? = nil,
        reference: String? = nil, section: Section? = nil
    ) {
        self.id = id; self.type = type; self.purpose = purpose; self.label = label
        self.value = value; self.reference = reference; self.section = section
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? "",
            type: try c.decodeIfPresent(String.self, forKey: .type) ?? "STRING",
            purpose: try c.decodeIfPresent(String.self, forKey: .purpose),
            label: try c.decodeIfPresent(String.self, forKey: .label) ?? "",
            value: Self.lenientValue(c),
            reference: try c.decodeIfPresent(String.self, forKey: .reference),
            section: try c.decodeIfPresent(Section.self, forKey: .section))
    }

    /// Dates and numbers arrive as JSON numbers; everything the importer reads is text.
    private static func lenientValue(_ c: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let text = try? c.decodeIfPresent(String.self, forKey: .value) { return text }
        if let number = try? c.decodeIfPresent(Int.self, forKey: .value) { return String(number) }
        if let number = try? c.decodeIfPresent(Double.self, forKey: .value) { return String(number) }
        if let flag = try? c.decodeIfPresent(Bool.self, forKey: .value) { return String(flag) }
        return nil
    }

    public var isSecret: Bool {
        ["CONCEALED", "SSHKEY"].contains(type.uppercased()) || purpose?.uppercased() == "PASSWORD"
    }

    /// Never includes a secret value.
    public var description: String {
        "OnePasswordField(\(id), \(type), value: \(value == nil ? "none" : isSecret ? "<redacted>" : value ?? ""))"
    }
    public var debugDescription: String { description }
}

public struct OnePasswordItem: Sendable, Hashable, Codable, Identifiable {
    public enum Category: Sendable, Hashable, Codable {
        case server, login, sshKey, other(String)

        public init(rawValue: String) {
            switch rawValue.uppercased() {
            case "SERVER": self = .server
            case "LOGIN": self = .login
            case "SSH_KEY": self = .sshKey
            default: self = .other(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .server: "SERVER"
            case .login: "LOGIN"
            case .sshKey: "SSH_KEY"
            case .other(let raw): raw
            }
        }

        /// The spelling `op item list --categories` expects.
        public var cliName: String {
            switch self {
            case .server: "Server"
            case .login: "Login"
            case .sshKey: "SSH Key"
            case .other(let raw): raw
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var id: String
    public var title: String
    public var category: Category
    public var vault: OnePasswordVault
    public var tags: [String]
    public var urls: [OnePasswordURL]
    /// Only present in `op item get` output.
    public var fields: [OnePasswordField]
    public var updatedAt: String?

    public init(
        id: String, title: String, category: Category, vault: OnePasswordVault, tags: [String] = [],
        urls: [OnePasswordURL] = [], fields: [OnePasswordField] = [], updatedAt: String? = nil
    ) {
        self.id = id; self.title = title; self.category = category; self.vault = vault
        self.tags = tags; self.urls = urls; self.fields = fields; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, category, vault, tags, urls, fields
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
            category: try c.decodeIfPresent(Category.self, forKey: .category) ?? .other(""),
            vault: try c.decodeIfPresent(OnePasswordVault.self, forKey: .vault) ?? OnePasswordVault(id: ""),
            tags: try c.decodeIfPresent([String].self, forKey: .tags) ?? [],
            urls: try c.decodeIfPresent([OnePasswordURL].self, forKey: .urls) ?? [],
            fields: try c.decodeIfPresent([OnePasswordField].self, forKey: .fields) ?? [],
            updatedAt: try c.decodeIfPresent(String.self, forKey: .updatedAt))
    }

    public func field(purpose: String) -> OnePasswordField? {
        fields.first { $0.purpose?.caseInsensitiveCompare(purpose) == .orderedSame }
    }

    /// The first field whose label or id matches one of `names` (case-insensitive), in the order of `names`, with a non-empty value.
    public func field(named names: [String]) -> OnePasswordField? {
        for name in names {
            if let match = fields.first(where: {
                ($0.label.caseInsensitiveCompare(name) == .orderedSame || $0.id.caseInsensitiveCompare(name) == .orderedSame)
                    && !($0.value ?? "").isEmpty
            }) { return match }
        }
        return nil
    }
}
