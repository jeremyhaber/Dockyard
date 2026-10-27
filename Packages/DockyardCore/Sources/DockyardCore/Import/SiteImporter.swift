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
    public var agentSocket: AgentSocket = .system
    /// Secret references per purpose. Stored on the connection, or resolved and copied to the Keychain when `copyReferencesToKeychain` is set.
    public var secretReferences: [SecretPurpose: String] = [:]
    public var copyReferencesToKeychain = false
    /// Set by the 1Password import: lets a re-import find and update the connection it created.
    public var onePasswordItemId: String?

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
    /// Connections that now take a secret from a reference.
    public var referencesStored = 0
    /// Existing connections refreshed from a re-import.
    public var updated = 0
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

    /// - Parameter referenceResolver: needed only for sites with `copyReferencesToKeychain`.
    public func apply(
        _ parsed: ImportParseResult, passwordReader: (any ImportedPasswordReader)? = nil,
        referenceResolver: (any SecretReferenceResolving)? = nil
    ) async throws -> ImportSummary {
        var summary = ImportSummary(warnings: parsed.warnings)
        let existingFolders = Set(try await folders.all().map { $0.name.lowercased() })
        var folderIds: [String: UUID] = [:]

        for site in parsed.sites {
            if let itemId = site.onePasswordItemId, let existing = try await repository.connection(onePasswordItemId: itemId, source: source) {
                try await update(existing, from: site, resolver: referenceResolver, summary: &summary)
                continue
            }
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
            var connection = Connection(
                name: site.name, clientFolderId: folderId, protocol: site.protocol, host: site.host, port: site.port,
                username: site.username, authMethods: site.authMethods, keyPath: site.keyPath, tags: site.tags,
                notes: site.notes, source: source, createdAt: clock.now(), initialRemotePath: site.remotePath,
                agentSocket: site.agentSocket, onePasswordItemId: site.onePasswordItemId)
            let handled = try await storeSecrets(of: site, for: &connection, resolver: referenceResolver, summary: &summary)
            try await repository.save(connection)
            summary.created += 1
            if handled.contains(.password) { continue }

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

    /// Refreshes what the other app owns and leaves what the user edited: name, notes, host and port follow
    /// `userEditedFields`; folder, favourites and other settings are never touched.
    private func update(
        _ existing: Connection, from site: ImportedSite, resolver: (any SecretReferenceResolving)?, summary: inout ImportSummary
    ) async throws {
        var connection = existing
        if !existing.userEditedFields.contains(.name) { connection.name = site.name }
        if !existing.userEditedFields.contains(.host) { connection.host = site.host }
        if !existing.userEditedFields.contains(.port) { connection.port = site.port }
        connection.protocol = site.protocol
        connection.username = site.username
        connection.authMethods = site.authMethods
        connection.agentSocket = site.agentSocket
        connection.tags += site.tags.filter { !connection.tags.contains($0) }
        connection.removedFromSource = false
        _ = try await storeSecrets(of: site, for: &connection, resolver: resolver, summary: &summary)
        try await repository.save(connection)
        summary.updated += 1
    }

    /// Puts the site's secret references on `connection`, or copies the secrets they point at into the Keychain.
    /// Returns the purposes that now have a secret source.
    private func storeSecrets(
        of site: ImportedSite, for connection: inout Connection, resolver: (any SecretReferenceResolving)?, summary: inout ImportSummary
    ) async throws -> Set<SecretPurpose> {
        guard !site.secretReferences.isEmpty else { return [] }
        guard site.copyReferencesToKeychain else {
            connection.secretReferences.merge(site.secretReferences) { _, new in new }
            summary.referencesStored += 1
            return Set(site.secretReferences.keys)
        }
        var handled: Set<SecretPurpose> = []
        for (purpose, reference) in site.secretReferences {
            guard let resolver, let secrets else {
                summary.warnings.append("\(site.name): cannot copy a secret out of 1Password without a resolver")
                continue
            }
            do {
                try await secrets.setSecret(try await resolver.resolve(reference: reference), for: connection.id, purpose: purpose)
                connection.secretReferences[purpose] = nil
                handled.insert(purpose)
                if purpose == .password { summary.passwordsStored += 1 }
            } catch let error as OnePasswordError where error.needsUserAction {
                throw error
            } catch {
                summary.warnings.append("\(site.name): could not read the \(purpose.rawValue) from 1Password")
            }
        }
        return handled
    }
}
