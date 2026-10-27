import ConnectionKit
import Foundation

public struct OnePasswordImportOptions: Sendable, Equatable {
    public enum FolderMode: Sendable, Equatable {
        case none
        /// The vault name becomes the client folder.
        case vault
        /// The item's first tag becomes the client folder.
        case firstTag
    }

    public enum SecretMode: Sendable, Equatable {
        /// Store `op://` references; the secret is read from 1Password at connect time.
        case reference
        /// Read each password once and store it in the Keychain.
        case copyToKeychain
    }

    public var categories: [OnePasswordItem.Category]
    public var folder: FolderMode
    public var secrets: SecretMode
    /// Use the 1Password SSH agent for SFTP sites. nil means "when the scan finds SSH Key items".
    public var useSSHAgent: Bool?

    public init(
        categories: [OnePasswordItem.Category] = OnePasswordCLI.defaultCategories, folder: FolderMode = .none,
        secrets: SecretMode = .reference, useSSHAgent: Bool? = nil
    ) {
        self.categories = categories
        self.folder = folder
        self.secrets = secrets
        self.useSSHAgent = useSSHAgent
    }
}

/// An SSH Key item without a host, offered as a key source: SFTP sites use the 1Password agent, which holds it.
public struct OnePasswordSSHKey: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var vault: String
    public var keyType: String?
    public var fingerprint: String?
    public var publicKey: String?
}

public struct OnePasswordScan: Sendable, Equatable {
    public var parsed = ImportParseResult()
    public var sshKeys: [OnePasswordSSHKey] = []
}

/// Maps 1Password Server, Login and SSH Key items to `ImportedSite`s. The result goes through
/// `SiteImporter(source: .onePasswordImport)`; pass the CLI as its `referenceResolver` for `.copyToKeychain`.
public struct OnePasswordImporter: Sendable {
    private let cli: OnePasswordCLI
    private let options: OnePasswordImportOptions

    public init(cli: OnePasswordCLI, options: OnePasswordImportOptions = OnePasswordImportOptions()) {
        self.cli = cli
        self.options = options
    }

    /// Lists and reads the matching items of each vault (names or ids). Unreadable items become warnings; a locked
    /// app or dismissed prompt stops the scan.
    public func scan(vaults: [String]) async throws -> OnePasswordScan {
        var items: [OnePasswordItem] = []
        var warnings: [String] = []
        for vault in vaults {
            let summaries = try await cli.items(inVault: vault, categories: options.categories)
            for outcome in try await fetch(summaries, vault: vault) {
                switch outcome {
                case .success(let item): items.append(item)
                case .failure(let failure): warnings.append("Could not read \"\(failure.title)\": \(failure.error)")
                }
            }
        }
        var scan = Self.map(items, options: options)
        scan.parsed.warnings = warnings + scan.parsed.warnings
        return scan
    }

    private struct ItemFailure: Error { var title: String; var error: OnePasswordError }

    /// `op item get` is slow, so a few run at once; the order of `summaries` is kept.
    private func fetch(_ summaries: [OnePasswordItem], vault: String) async throws -> [Result<OnePasswordItem, ItemFailure>] {
        let cli = cli
        var results = [Result<OnePasswordItem, ItemFailure>?](repeating: nil, count: summaries.count)
        try await withThrowingTaskGroup(of: (Int, Result<OnePasswordItem, ItemFailure>).self) { group in
            var next = 0
            func enqueue() {
                guard next < summaries.count else { return }
                let index = next, summary = summaries[next]
                next += 1
                group.addTask {
                    do { return (index, .success(try await cli.item(id: summary.id, inVault: vault))) } catch let error as OnePasswordError
                        where !error.needsUserAction { return (index, .failure(ItemFailure(title: summary.title, error: error))) }
                }
            }
            for _ in 0..<4 { enqueue() }
            while let (index, result) = try await group.next() {
                results[index] = result
                enqueue()
            }
        }
        return results.compactMap { $0 }
    }

    // MARK: Mapping

    /// Pure mapping of full items (as returned by `op item get`).
    public static func map(_ items: [OnePasswordItem], options: OnePasswordImportOptions = OnePasswordImportOptions()) -> OnePasswordScan {
        var scan = OnePasswordScan()
        let keyItems = items.filter { $0.category == .sshKey }
        let useAgent = options.useSSHAgent ?? !keyItems.isEmpty

        for item in items {
            switch item.category {
            case .server, .login, .sshKey:
                let isKey = item.category == .sshKey
                guard let endpoint = endpoint(for: item) else {
                    if isKey { scan.sshKeys.append(sshKey(item)) } else {
                        scan.parsed.warnings.append("Skipped \"\(item.title)\": no host or URL")
                    }
                    continue
                }
                guard let site = site(for: item, endpoint: endpoint, useAgent: isKey || useAgent, options: options) else {
                    scan.parsed.warnings.append("Skipped \"\(item.title)\": no username")
                    continue
                }
                scan.parsed.sites.append(site)
            case .other:
                continue
            }
        }
        return scan
    }

    private static func site(for item: OnePasswordItem, endpoint: Endpoint, useAgent: Bool, options: OnePasswordImportOptions) -> ImportedSite? {
        let proto = endpoint.protocol ?? .sftp
        let username = [endpoint.user, item.field(purpose: "USERNAME")?.value, item.field(named: ["username", "user", "login"])?.value]
            .compactMap { $0 }.first { !$0.isEmpty } ?? (proto == .sftp ? "" : "anonymous")
        guard !username.isEmpty else { return nil }

        let portField = item.field(named: ["port"]).flatMap { Int($0.value ?? "") }.flatMap { (1...65535).contains($0) ? $0 : nil }
        var site = ImportedSite(
            name: item.title.isEmpty ? endpoint.host : item.title, protocol: proto, host: endpoint.host,
            port: endpoint.port ?? portField ?? proto.defaultPort, username: username)
        site.remotePath = endpoint.path
        site.tags = item.tags
        site.notes = item.vault.name.isEmpty ? "Imported from 1Password" : "Imported from 1Password (\(item.vault.name))"
        site.onePasswordItemId = item.id
        switch options.folder {
        case .none: break
        case .vault: if !item.vault.name.isEmpty { site.folderPath = [item.vault.name] }
        case .firstTag: if let tag = item.tags.first { site.folderPath = [tag] }
        }

        let password = item.category == .sshKey ? nil : (item.field(purpose: "PASSWORD") ?? item.field(named: ["password"]))
        if let password, !(password.value ?? "").isEmpty {
            site.secretReferences[.password] = password.reference ?? "op://\(item.vault.id)/\(item.id)/\(password.id)"
            site.copyReferencesToKeychain = options.secrets == .copyToKeychain
        }
        if proto == .sftp && useAgent {
            site.agentSocket = .onePassword
            site.authMethods = site.secretReferences[.password] != nil ? [.agent, .password] : .agent
        } else {
            site.authMethods = .password
        }
        return site
    }

    private static func sshKey(_ item: OnePasswordItem) -> OnePasswordSSHKey {
        OnePasswordSSHKey(
            id: item.id, title: item.title, vault: item.vault.name,
            keyType: item.field(named: ["key type"])?.value, fingerprint: item.field(named: ["fingerprint"])?.value,
            publicKey: item.field(named: ["public key", "public_key"])?.value)
    }

    // MARK: Endpoints

    struct Endpoint: Equatable {
        var `protocol`: ConnectionProtocol?
        var user: String?
        var host: String
        var port: Int?
        var path: String?
    }

    /// Server items keep the host in a field; every category may carry website URLs. An FTP-family URL wins over a plain host.
    static func endpoint(for item: OnePasswordItem) -> Endpoint? {
        var texts: [String] = []
        if item.category == .server || item.category == .sshKey {
            texts += ["url", "server", "hostname", "host", "ip address", "ip", "address"]
                .compactMap { item.field(named: [$0])?.value }
        }
        texts += item.urls.sorted { $0.primary && !$1.primary }.map(\.href)
        let endpoints = texts.compactMap(parseEndpoint)
        return endpoints.first { $0.protocol != nil } ?? endpoints.first
    }

    static func parseEndpoint(_ text: String) -> Endpoint? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let hasScheme = trimmed.contains("://")
        guard let components = URLComponents(string: hasScheme ? trimmed : "ssh://" + trimmed),
              let host = components.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else { return nil }
        var proto: ConnectionProtocol?
        switch hasScheme ? components.scheme?.lowercased() : nil {
        case "sftp", "ssh": proto = .sftp
        case "ftp": proto = .ftp
        case "ftps", "ftpes": proto = .ftps
        default: proto = nil
        }
        // A web URL's port (80, 443, 8443) says nothing about the file server.
        let port = hasScheme && proto == nil ? nil : components.port
        let path = components.path.isEmpty || components.path == "/" ? nil : components.path
        return Endpoint(protocol: proto, user: components.user, host: host, port: port, path: path)
    }
}
