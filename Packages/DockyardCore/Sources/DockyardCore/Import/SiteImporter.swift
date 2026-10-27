import Foundation
import ConnectionKit

/// Where an app stored the password for an imported site. The Dockyard app reads Keychain items it is
/// allowed to read (an internet-password lookup by server, account, port and protocol) and hands the result
/// to `SiteImporter` through an `ImportedPasswordReader`.
public struct KeychainPasswordRequest: Sendable, Equatable {
    public enum Application: String, Sendable, Equatable { case transmit, cyberduck }

    public var application: Application
    public var server: String
    public var account: String
    public var port: Int?
    /// The other app's protocol name (`sftp`, `ftp`, ...), useful for `kSecAttrProtocol` matching.
    public var protocolName: String?
}

/// Reads another app's saved password. The macOS app implements this with `SecItemCopyMatching`;
/// returning nil means "not readable", and the connection asks on first connect.
public protocol ImportedPasswordReader: Sendable {
    func password(for request: KeychainPasswordRequest) async -> String?
}

/// A site found in another app's data, before it becomes a `Connection`.
public struct ImportedSite: Sendable, Equatable {
    public var name: String
    public var folderPath: [String] = []
    public var `protocol`: ConnectionProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var authMethods: AuthMethods = .password
    public var keyPath: String?
    public var remotePath: String?
    public var notes: String = ""
    public var tags: [String] = []
    public var keychain: KeychainPasswordRequest?

    public var clientFolderName: String? { folderPath.isEmpty ? nil : folderPath.joined(separator: " / ") }
}

public struct ImportParseResult: Sendable, Equatable {
    public var sites: [ImportedSite] = []
    public var warnings: [String] = []
}

public struct PendingPassword: Sendable, Equatable {
    public var connectionId: UUID
    public var request: KeychainPasswordRequest
}

public struct ImportSummary: Sendable, Equatable {
    public var created = 0
    public var skippedDuplicates = 0
    public var foldersCreated = 0
    public var passwordsStored = 0
    /// Connections that ask for a password on first connect.
    public var needingPassword = 0
    public var warnings: [String] = []
    /// Passwords the app can still try to read from the other app's Keychain items (when no reader was supplied).
    public var pendingPasswords: [PendingPassword] = []
}

/// Turns `ImportedSite`s into connections, skipping duplicates (same protocol, host, port and user).
public struct SiteImporter: Sendable {
    private let repository: ConnectionRepository
    private let folders: ClientFolderRepository
    private let secrets: (any SecretStore)?
    private let source: ConnectionSource
    private let clock: any DockyardClock

    public init(
        repository: ConnectionRepository, folders: ClientFolderRepository, source: ConnectionSource,
        secrets: (any SecretStore)? = nil, clock: any DockyardClock = SystemClock()
    ) {
        self.repository = repository
        self.folders = folders
        self.source = source
        self.secrets = secrets
        self.clock = clock
    }

    public func apply(_ parsed: ImportParseResult, passwordReader: (any ImportedPasswordReader)? = nil) async throws -> ImportSummary {
        var summary = ImportSummary(warnings: parsed.warnings)
        let existingFolders = Set(try await folders.all().map { $0.name.lowercased() })
        var folderIds: [String: UUID] = [:]

        for site in parsed.sites {
            if try await repository.connection(protocol: site.protocol, host: site.host, port: site.port, username: site.username) != nil {
                summary.skippedDuplicates += 1
                continue
            }
            var folderId: UUID?
            if let name = site.clientFolderName {
                if let id = folderIds[name.lowercased()] { folderId = id } else {
                    let folder = try await folders.findOrCreate(name: name)
                    folderIds[name.lowercased()] = folder.id
                    folderId = folder.id
                    if !existingFolders.contains(name.lowercased()) { summary.foldersCreated += 1 }
                }
            }
            let connection = Connection(
                name: site.name, clientFolderId: folderId, protocol: site.protocol, host: site.host, port: site.port,
                username: site.username, authMethods: site.authMethods, keyPath: site.keyPath, tags: site.tags,
                notes: site.notes, source: source, createdAt: clock.now(), initialRemotePath: site.remotePath)
            try await repository.save(connection)
            summary.created += 1

            guard site.authMethods.contains(.password), let request = site.keychain else {
                if site.authMethods.contains(.password), site.username != "anonymous" { summary.needingPassword += 1 }
                continue
            }
            if let reader = passwordReader, let secrets, let password = await reader.password(for: request) {
                try await secrets.setSecret(password, for: connection.id, purpose: .password)
                summary.passwordsStored += 1
            } else {
                summary.needingPassword += 1
                summary.pendingPasswords.append(PendingPassword(connectionId: connection.id, request: request))
            }
        }
        return summary
    }
}
