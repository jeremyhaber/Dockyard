import Foundation
import ConnectionKit

/// Gathers what goes into an export file from the stores.
public struct ExportCollector: Sendable {
    private let connections: ConnectionRepository
    private let folders: ClientFolderRepository
    private let whmSources: WHMSourceRepository
    private let secrets: (any SecretStore)?

    public init(connections: ConnectionRepository, folders: ClientFolderRepository, whmSources: WHMSourceRepository, secrets: (any SecretStore)?) {
        self.connections = connections
        self.folders = folders
        self.whmSources = whmSources
        self.secrets = secrets
    }

    /// Secrets are only read when `includeSecrets` is true and a secret store was given.
    public func collect(includeSecrets: Bool, settings: [String: SettingValue] = [:], now: Date = Date()) async throws -> ExportContents {
        var contents = ExportContents(
            connections: try await connections.fetch(.all), folders: try await folders.all(),
            whmSources: try await whmSources.all(), settings: settings, createdAt: now)
        guard includeSecrets, let secrets else { return contents }
        for connection in contents.connections {
            var found: [SecretPurpose: String] = [:]
            for purpose in SecretPurpose.allCases {
                if let value = try await secrets.secret(for: connection.id, purpose: purpose) { found[purpose] = value }
            }
            if !found.isEmpty { contents.secrets[connection.id] = found }
        }
        return contents
    }
}

public struct ExportMergeSummary: Sendable, Equatable {
    public var connectionsCreated = 0
    /// Same protocol, host, port and user as an existing connection.
    public var connectionsSkipped = 0
    public var foldersCreated = 0
    public var whmSourcesCreated = 0
    public var secretsRestored = 0
    /// Settings are returned for the app to apply; they are not written anywhere here.
    public var settings: [String: SettingValue] = [:]
}

/// Merges an export into the current stores. Existing connections always win: nothing is overwritten.
public struct ExportMerger: Sendable {
    private let connections: ConnectionRepository
    private let folders: ClientFolderRepository
    private let whmSources: WHMSourceRepository
    private let secrets: (any SecretStore)?

    public init(connections: ConnectionRepository, folders: ClientFolderRepository, whmSources: WHMSourceRepository, secrets: (any SecretStore)?) {
        self.connections = connections
        self.folders = folders
        self.whmSources = whmSources
        self.secrets = secrets
    }

    public func merge(_ contents: ExportContents) async throws -> ExportMergeSummary {
        var summary = ExportMergeSummary(settings: contents.settings)

        // Folders by name, case-insensitive.
        var folderMap: [UUID: UUID] = [:]
        let existingFolders = try await folders.all()
        for folder in contents.folders {
            if let same = existingFolders.first(where: { $0.name.caseInsensitiveCompare(folder.name) == .orderedSame }) {
                folderMap[folder.id] = same.id
            } else {
                let created = try await folders.create(name: folder.name)
                folderMap[folder.id] = created.id
                summary.foldersCreated += 1
            }
        }

        // WHM sources: same id, or same host and API user.
        var sourceMap: [UUID: UUID] = [:]
        let existingSources = try await whmSources.all()
        for source in contents.whmSources {
            if let same = existingSources.first(where: { $0.id == source.id || ($0.host.lowercased() == source.host.lowercased() && $0.apiUser == source.apiUser) }) {
                sourceMap[source.id] = same.id
            } else {
                try await whmSources.save(source)
                sourceMap[source.id] = source.id
                summary.whmSourcesCreated += 1
            }
        }

        // Connections. Duplicates (protocol, host, port, user) map to the existing or earlier-imported connection.
        var idMap: [UUID: UUID] = [:]
        var created: [Connection] = []
        var createdByEndpoint: [String: UUID] = [:]
        for original in contents.connections {
            var connection = original
            if let same = try await connections.connection(protocol: connection.protocol, host: connection.host, port: connection.port, username: connection.username) {
                idMap[original.id] = same.id
                continue
            }
            if let earlier = createdByEndpoint[connection.endpointKey] {
                idMap[original.id] = earlier
                continue
            }
            if try await connections.connection(id: connection.id) != nil { connection.id = UUID() }
            idMap[original.id] = connection.id
            createdByEndpoint[connection.endpointKey] = connection.id
            connection.clientFolderId = original.clientFolderId.flatMap { folderMap[$0] }
            if let whm = original.source.whmServerId { connection.source = sourceMap[whm].map { .whm($0) } ?? .manual }
            connection.lastConnectedAt = nil
            created.append(connection)
        }
        summary.connectionsSkipped = contents.connections.count - created.count
        // Jump hosts reference other rows, so save everything first and link afterwards.
        for var connection in created {
            connection.jumpHost = nil
            try await connections.save(connection)
        }
        for connection in created {
            guard let original = connection.jumpHost.flatMap({ idMap[$0] }) else { continue }
            try await connections.update(connection.id) { $0.jumpHost = original }
        }
        summary.connectionsCreated = created.count

        if let secrets {
            for (originalId, byPurpose) in contents.secrets {
                // Only connections that this merge created; secrets of existing connections are never touched.
                guard let newId = idMap[originalId], created.contains(where: { $0.id == newId }) else { continue }
                for (purpose, value) in byPurpose {
                    try await secrets.setSecret(value, for: newId, purpose: purpose)
                    summary.secretsRestored += 1
                }
            }
        }
        return summary
    }
}
