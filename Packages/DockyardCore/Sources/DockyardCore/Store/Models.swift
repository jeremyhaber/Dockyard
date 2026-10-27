import Foundation
import GRDB
import ConnectionKit

/// Where a connection came from. Stored as `manual`, `quickConnect`, `filezillaImport` or `whm:<serverId>`.
public enum ConnectionSource: Sendable, Hashable, RawRepresentable {
    case manual
    case quickConnect
    case filezillaImport
    case transmitImport
    case cyberduckImport
    case sshConfigImport
    case onePasswordImport
    case whm(UUID)

    public var rawValue: String {
        switch self {
        case .manual: "manual"
        case .quickConnect: "quickConnect"
        case .filezillaImport: "filezillaImport"
        case .transmitImport: "transmitImport"
        case .cyberduckImport: "cyberduckImport"
        case .sshConfigImport: "sshConfigImport"
        case .onePasswordImport: "onePasswordImport"
        case .whm(let id): "whm:\(id.uuidString)"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "manual": self = .manual
        case "quickConnect": self = .quickConnect
        case "filezillaImport": self = .filezillaImport
        case "transmitImport": self = .transmitImport
        case "cyberduckImport": self = .cyberduckImport
        case "sshConfigImport": self = .sshConfigImport
        case "onePasswordImport": self = .onePasswordImport
        default:
            guard rawValue.hasPrefix("whm:"), let id = UUID(uuidString: String(rawValue.dropFirst(4))) else { return nil }
            self = .whm(id)
        }
    }

    public var whmServerId: UUID? { if case .whm(let id) = self { id } else { nil } }
}

/// Connection fields the user can edit that a sync must not clobber.
public enum UserEditableField: String, Sendable, Hashable, Codable, CaseIterable {
    case name, notes, host, port
}

/// Backend settings for `rclone` connections. Mirrors `RcloneRemoteSpec` with plain strings so this module
/// does not depend on RcloneKit. Secrets are never stored here.
public struct CloudSpec: Sendable, Hashable, Codable {
    /// rclone backend name: `s3`, `b2`, `drive`, `dropbox`, `onedrive`.
    public var backend: String
    public var options: [String: String]
    /// Path inside the remote the connection is rooted at, e.g. `my-bucket/site`. Empty shows every bucket.
    public var root: String

    public init(backend: String, options: [String: String] = [:], root: String = "") {
        self.backend = backend
        self.options = options
        self.root = root
    }

    /// True when the top level lists buckets, so each bucket's top is a root for the `..` rule.
    public var listsBuckets: Bool {
        (backend == "s3" || backend == "b2") && root.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
    }
}

/// A server folder pinned on a connection.
public struct PinnedFolder: Sendable, Hashable, Codable {
    public var path: String
    public var label: String?
    public init(path: String, label: String? = nil) { self.path = path; self.label = label }

    public var title: String { label ?? RemotePath.lastComponent(of: path) }
}

public struct Connection: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var clientFolderId: UUID?
    public var `protocol`: ConnectionProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var authMethods: AuthMethods
    public var keyPath: String?
    public var elevation: Elevation
    public var elevateFileBrowsing: Bool
    public var askBeforeElevatingOnProd: Bool
    public var isProd: Bool
    public var favorite: Bool
    public var tags: [String]
    public var notes: String
    public var source: ConnectionSource
    public var restoreSession: Bool
    public var mountInFinder: Bool
    public var mountOnLaunch: Bool
    public var mountReadOnly: Bool
    public var lastConnectedAt: Date?
    public var createdAt: Date
    /// True when a sync source (WHM) no longer lists this connection. It is kept, never deleted.
    public var removedFromSource: Bool
    /// Shows the `NEW` tag in the sidebar until cleared.
    public var isNew: Bool
    /// Fields edited by the user; sync never overwrites these.
    public var userEditedFields: Set<UserEditableField>
    /// Initial remote folder, if the user set one (e.g. from a pasted URL).
    public var initialRemotePath: String?
    /// Default local folder when there is no session to restore.
    public var localFolder: String?
    /// Set for `rclone` connections.
    public var cloud: CloudSpec?
    /// Moves deleted files into the remote trash instead of deleting them. Off by default.
    public var trashOnDelete: Bool
    /// Moves a file that an upload would overwrite into the remote trash first. Off by default.
    public var keepVersionsOnOverwrite: Bool
    /// Blocks uploads, deletes, renames, chmod and extract.
    public var readOnly: Bool
    public var verifyChecksums: Bool
    /// Another saved connection to tunnel through (ProxyJump). Chains follow the referenced connection's own jump host.
    public var jumpHost: UUID?
    public var pinnedFolders: [PinnedFolder]
    /// Per-site skip patterns (gitignore style), on top of the global defaults.
    public var transferFilters: [String]

    /// Which ssh-agent the `.agent` auth method uses.
    public var agentSocket: AgentSocket
    /// Secret references per purpose (`op://Vault/Item/password`), resolved at connect time instead of reading the Keychain.
    /// References are not secrets, but keep them out of logs.
    public var secretReferences: [SecretPurpose: String]
    /// The 1Password item this connection was imported from; re-import matches on it.
    public var onePasswordItemId: String?

    /// Most simultaneous connections the transfer queue may open to this site (1...10).
    public var maxConnections: Int
    /// Minimum pause between opening two connections to this site, for hosts that rate-limit logins.
    public var connectDelayMs: Int

    public static let defaultMaxConnections = 3
    public static let maxConnectionsRange = 1...10

    public init(
        id: UUID = UUID(),
        name: String,
        clientFolderId: UUID? = nil,
        protocol: ConnectionProtocol = .sftp,
        host: String,
        port: Int? = nil,
        username: String,
        authMethods: AuthMethods = .password,
        keyPath: String? = nil,
        elevation: Elevation = .none,
        elevateFileBrowsing: Bool = false,
        askBeforeElevatingOnProd: Bool = true,
        isProd: Bool = false,
        favorite: Bool = false,
        tags: [String] = [],
        notes: String = "",
        source: ConnectionSource = .manual,
        restoreSession: Bool = true,
        mountInFinder: Bool = false,
        mountOnLaunch: Bool = false,
        mountReadOnly: Bool? = nil,
        lastConnectedAt: Date? = nil,
        createdAt: Date = Date(),
        removedFromSource: Bool = false,
        isNew: Bool = false,
        userEditedFields: Set<UserEditableField> = [],
        initialRemotePath: String? = nil,
        localFolder: String? = nil,
        cloud: CloudSpec? = nil,
        trashOnDelete: Bool = false,
        keepVersionsOnOverwrite: Bool = false,
        readOnly: Bool = false,
        verifyChecksums: Bool = false,
        jumpHost: UUID? = nil,
        pinnedFolders: [PinnedFolder] = [],
        transferFilters: [String] = [],
        maxConnections: Int = Connection.defaultMaxConnections,
        connectDelayMs: Int = 0,
        agentSocket: AgentSocket = .system,
        secretReferences: [SecretPurpose: String] = [:],
        onePasswordItemId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.clientFolderId = clientFolderId
        self.protocol = `protocol`
        self.host = host
        self.port = port ?? `protocol`.defaultPort
        self.username = username
        self.authMethods = authMethods
        self.keyPath = keyPath
        self.elevation = elevation
        self.elevateFileBrowsing = elevateFileBrowsing
        self.askBeforeElevatingOnProd = askBeforeElevatingOnProd
        self.isProd = isProd
        self.favorite = favorite
        self.tags = tags
        self.notes = notes
        self.source = source
        self.restoreSession = restoreSession
        self.mountInFinder = mountInFinder
        self.mountOnLaunch = mountOnLaunch
        self.mountReadOnly = mountReadOnly ?? isProd
        self.lastConnectedAt = lastConnectedAt
        self.createdAt = createdAt
        self.removedFromSource = removedFromSource
        self.isNew = isNew
        self.userEditedFields = userEditedFields
        self.initialRemotePath = initialRemotePath
        self.localFolder = localFolder
        self.cloud = cloud
        self.trashOnDelete = trashOnDelete
        self.keepVersionsOnOverwrite = keepVersionsOnOverwrite
        self.readOnly = readOnly
        self.verifyChecksums = verifyChecksums
        self.jumpHost = jumpHost
        self.pinnedFolders = pinnedFolders
        self.transferFilters = transferFilters
        self.maxConnections = min(max(maxConnections, Self.maxConnectionsRange.lowerBound), Self.maxConnectionsRange.upperBound)
        self.connectDelayMs = max(0, connectDelayMs)
        self.agentSocket = agentSocket
        self.secretReferences = secretReferences
        self.onePasswordItemId = onePasswordItemId
    }

    /// The `ConnectionKit` view of this connection.
    public var config: ConnectionConfig {
        ConnectionConfig(
            id: id, protocol: `protocol`, host: host, port: port, username: username,
            authMethods: authMethods, keyPath: keyPath, elevation: elevation, agentSocket: agentSocket
        )
    }

    /// Identity used to dedupe quick connects.
    public var endpointKey: String {
        Connection.endpointKey(protocol: `protocol`, host: host, port: port, username: username)
    }

    public static func endpointKey(protocol p: ConnectionProtocol, host: String, port: Int, username: String) -> String {
        "\(p.rawValue)|\(host.lowercased())|\(port)|\(username)"
    }
}

extension Connection: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "connection"

    public init(row: Row) throws {
        func uuid(_ column: String) throws -> UUID {
            let s: String = row[column]
            guard let u = UUID(uuidString: s) else {
                throw DatabaseError(message: "Invalid UUID in column \(column)")
            }
            return u
        }
        let tagsJSON: String = row["tags"]
        let editedJSON: String = row["userEditedFields"]
        let proto: String = row["protocol"]
        let sourceRaw: String = row["source"]
        let elevationRaw: String = row["elevation"]
        let folder: String? = row["clientFolderId"]
        self.init(
            id: try uuid("id"),
            name: row["name"],
            clientFolderId: folder.flatMap { UUID(uuidString: $0) },
            protocol: ConnectionProtocol(rawValue: proto) ?? .sftp,
            host: row["host"],
            port: row["port"],
            username: row["username"],
            authMethods: AuthMethods(rawValue: UInt8(truncatingIfNeeded: (row["authMethods"] as Int))),
            keyPath: row["keyPath"],
            elevation: Elevation(rawValue: elevationRaw) ?? .none,
            elevateFileBrowsing: row["elevateFileBrowsing"],
            askBeforeElevatingOnProd: row["askBeforeElevatingOnProd"],
            isProd: row["isProd"],
            favorite: row["favorite"],
            tags: (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? [],
            notes: row["notes"],
            source: ConnectionSource(rawValue: sourceRaw) ?? .manual,
            restoreSession: row["restoreSession"],
            mountInFinder: row["mountInFinder"],
            mountOnLaunch: row["mountOnLaunch"],
            mountReadOnly: row["mountReadOnly"],
            lastConnectedAt: row["lastConnectedAt"],
            createdAt: row["createdAt"],
            removedFromSource: row["removedFromSource"],
            isNew: row["isNew"],
            userEditedFields: Set(((try? JSONDecoder().decode([String].self, from: Data(editedJSON.utf8))) ?? [])
                .compactMap(UserEditableField.init(rawValue:))),
            initialRemotePath: row["initialRemotePath"],
            localFolder: row["localFolder"],
            cloud: Self.decodeCloud(row),
            trashOnDelete: row["trashOnDelete"],
            keepVersionsOnOverwrite: row["keepVersionsOnOverwrite"],
            readOnly: row["readOnly"],
            verifyChecksums: row["verifyChecksums"],
            jumpHost: (row["jumpHost"] as String?).flatMap { UUID(uuidString: $0) },
            pinnedFolders: Self.decodeJSON(row["pinnedFolders"], default: []),
            transferFilters: Self.decodeJSON(row["transferFilters"], default: []),
            maxConnections: row["maxConnections"],
            connectDelayMs: row["connectDelayMs"],
            agentSocket: (row["agentSocket"] as String?).flatMap(AgentSocket.init(rawValue:)) ?? .system,
            secretReferences: Self.decodeReferences(row["secretReferences"]),
            onePasswordItemId: row["onePasswordItemId"]
        )
    }

    private static func decodeReferences(_ json: String?) -> [SecretPurpose: String] {
        let raw = (json.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }) ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in SecretPurpose(rawValue: key).map { ($0, value) } })
    }

    private static func decodeCloud(_ row: Row) -> CloudSpec? {
        let backend: String? = row["cloudBackend"]
        guard let backend, !backend.isEmpty else { return nil }
        let optionsJSON: String = row["cloudOptions"] ?? "{}"
        let options = (try? JSONDecoder().decode([String: String].self, from: Data(optionsJSON.utf8))) ?? [:]
        let root: String = row["cloudRoot"] ?? ""
        return CloudSpec(backend: backend, options: options, root: root)
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.uuidString
        container["name"] = name
        container["clientFolderId"] = clientFolderId?.uuidString
        container["protocol"] = `protocol`.rawValue
        container["host"] = host
        container["port"] = port
        container["username"] = username
        container["authMethods"] = Int(authMethods.rawValue)
        container["keyPath"] = keyPath
        container["elevation"] = elevation.rawValue
        container["elevateFileBrowsing"] = elevateFileBrowsing
        container["askBeforeElevatingOnProd"] = askBeforeElevatingOnProd
        container["isProd"] = isProd
        container["favorite"] = favorite
        container["tags"] = String(decoding: try JSONEncoder().encode(tags), as: UTF8.self)
        container["notes"] = notes
        container["source"] = source.rawValue
        container["restoreSession"] = restoreSession
        container["mountInFinder"] = mountInFinder
        container["mountOnLaunch"] = mountOnLaunch
        container["mountReadOnly"] = mountReadOnly
        container["lastConnectedAt"] = lastConnectedAt
        container["createdAt"] = createdAt
        container["removedFromSource"] = removedFromSource
        container["isNew"] = isNew
        container["userEditedFields"] = String(
            decoding: try JSONEncoder().encode(userEditedFields.map(\.rawValue).sorted()), as: UTF8.self)
        container["initialRemotePath"] = initialRemotePath
        container["localFolder"] = localFolder
        container["cloudBackend"] = cloud?.backend
        container["cloudOptions"] = try cloud.map { String(decoding: try JSONEncoder().encode($0.options), as: UTF8.self) }
        container["cloudRoot"] = cloud?.root
        container["trashOnDelete"] = trashOnDelete
        container["keepVersionsOnOverwrite"] = keepVersionsOnOverwrite
        container["readOnly"] = readOnly
        container["verifyChecksums"] = verifyChecksums
        container["jumpHost"] = jumpHost?.uuidString
        container["pinnedFolders"] = String(decoding: try JSONEncoder().encode(pinnedFolders), as: UTF8.self)
        container["transferFilters"] = String(decoding: try JSONEncoder().encode(transferFilters), as: UTF8.self)
        container["maxConnections"] = maxConnections
        container["connectDelayMs"] = connectDelayMs
        container["agentSocket"] = agentSocket.rawValue
        container["secretReferences"] = String(
            decoding: try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: secretReferences.map { ($0.key.rawValue, $0.value) })),
            as: UTF8.self)
        container["onePasswordItemId"] = onePasswordItemId
    }

    private static func decodeJSON<T: Decodable>(_ text: String, default fallback: T) -> T {
        (try? JSONDecoder().decode(T.self, from: Data(text.utf8))) ?? fallback
    }
}

public struct ClientFolder: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

extension ClientFolder: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "clientFolder"
    public init(row: Row) throws {
        let s: String = row["id"]
        self.init(id: UUID(uuidString: s) ?? UUID(), name: row["name"])
    }
    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.uuidString
        container["name"] = name
    }
}

public struct TabState: Sendable, Hashable, Codable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct SessionState: Sendable, Hashable, Codable {
    public var connectionId: UUID
    public var localTabs: [TabState]
    public var remoteTabs: [TabState]
    public var activeLocalTab: Int
    public var activeRemoteTab: Int
    public var localTreeExpanded: [String]
    public var remoteTreeExpanded: [String]
    public var savedAt: Date

    public init(
        connectionId: UUID,
        localTabs: [TabState] = [],
        remoteTabs: [TabState] = [],
        activeLocalTab: Int = 0,
        activeRemoteTab: Int = 0,
        localTreeExpanded: [String] = [],
        remoteTreeExpanded: [String] = [],
        savedAt: Date = Date()
    ) {
        self.connectionId = connectionId
        self.localTabs = localTabs
        self.remoteTabs = remoteTabs
        self.activeLocalTab = activeLocalTab
        self.activeRemoteTab = activeRemoteTab
        self.localTreeExpanded = localTreeExpanded
        self.remoteTreeExpanded = remoteTreeExpanded
        self.savedAt = savedAt
    }
}

extension SessionState: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "sessionState"
    public init(row: Row) throws {
        func decode<T: Decodable>(_ column: String, as: T.Type, default d: T) -> T {
            let s: String = row[column]
            return (try? JSONDecoder().decode(T.self, from: Data(s.utf8))) ?? d
        }
        let id: String = row["connectionId"]
        self.init(
            connectionId: UUID(uuidString: id) ?? UUID(),
            localTabs: decode("localTabs", as: [TabState].self, default: []),
            remoteTabs: decode("remoteTabs", as: [TabState].self, default: []),
            activeLocalTab: row["activeLocalTab"],
            activeRemoteTab: row["activeRemoteTab"],
            localTreeExpanded: decode("localTreeExpanded", as: [String].self, default: []),
            remoteTreeExpanded: decode("remoteTreeExpanded", as: [String].self, default: []),
            savedAt: row["savedAt"]
        )
    }
    public func encode(to container: inout PersistenceContainer) throws {
        func json<T: Encodable>(_ v: T) throws -> String { String(decoding: try JSONEncoder().encode(v), as: UTF8.self) }
        container["connectionId"] = connectionId.uuidString
        container["localTabs"] = try json(localTabs)
        container["remoteTabs"] = try json(remoteTabs)
        container["activeLocalTab"] = activeLocalTab
        container["activeRemoteTab"] = activeRemoteTab
        container["localTreeExpanded"] = try json(localTreeExpanded)
        container["remoteTreeExpanded"] = try json(remoteTreeExpanded)
        container["savedAt"] = savedAt
    }
}

public struct FolderHistoryEntry: Sendable, Hashable, Identifiable {
    public var id: Int64?
    public var connectionId: UUID
    public var path: String
    public var visitedAt: Date
    public init(id: Int64? = nil, connectionId: UUID, path: String, visitedAt: Date) {
        self.id = id; self.connectionId = connectionId; self.path = path; self.visitedAt = visitedAt
    }
}

extension FolderHistoryEntry: FetchableRecord, MutablePersistableRecord, TableRecord {
    public static let databaseTableName = "folderHistory"
    public init(row: Row) throws {
        let c: String = row["connectionId"]
        self.init(id: row["id"], connectionId: UUID(uuidString: c) ?? UUID(), path: row["path"], visitedAt: row["visitedAt"])
    }
    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["connectionId"] = connectionId.uuidString
        container["path"] = path
        container["visitedAt"] = visitedAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct WHMSource: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var label: String
    public var host: String
    /// WHM API port (2087 by default).
    public var apiPort: Int
    /// WHM API user (`root` or a reseller).
    public var apiUser: String
    /// Reference to the token in the secret store / Keychain. The token itself is never stored here.
    public var apiTokenKeychainRef: String
    public var lastSyncAt: Date?
    public var lastSyncError: String?

    public init(
        id: UUID = UUID(), label: String, host: String, apiPort: Int = 2087, apiUser: String = "root",
        apiTokenKeychainRef: String = "", lastSyncAt: Date? = nil, lastSyncError: String? = nil
    ) {
        self.id = id; self.label = label; self.host = host; self.apiPort = apiPort; self.apiUser = apiUser
        self.apiTokenKeychainRef = apiTokenKeychainRef.isEmpty ? id.uuidString : apiTokenKeychainRef
        self.lastSyncAt = lastSyncAt; self.lastSyncError = lastSyncError
    }
}

extension WHMSource: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "whmSource"
    public init(row: Row) throws {
        let s: String = row["id"]
        self.init(
            id: UUID(uuidString: s) ?? UUID(), label: row["label"], host: row["host"], apiPort: row["apiPort"],
            apiUser: row["apiUser"], apiTokenKeychainRef: row["apiTokenKeychainRef"],
            lastSyncAt: row["lastSyncAt"], lastSyncError: row["lastSyncError"]
        )
    }
    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.uuidString
        container["label"] = label
        container["host"] = host
        container["apiPort"] = apiPort
        container["apiUser"] = apiUser
        container["apiTokenKeychainRef"] = apiTokenKeychainRef
        container["lastSyncAt"] = lastSyncAt
        container["lastSyncError"] = lastSyncError
    }
}

/// A saved terminal command. `connectionId == nil` means available on every connection.
public struct Snippet: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var command: String
    public var connectionId: UUID?
    public var sortOrder: Int
    public init(id: UUID = UUID(), name: String, command: String, connectionId: UUID? = nil, sortOrder: Int = 0) {
        self.id = id; self.name = name; self.command = command; self.connectionId = connectionId; self.sortOrder = sortOrder
    }
}

extension Snippet: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "snippet"
    public init(row: Row) throws {
        let s: String = row["id"]
        let c: String? = row["connectionId"]
        self.init(id: UUID(uuidString: s) ?? UUID(), name: row["name"], command: row["command"],
                  connectionId: c.flatMap { UUID(uuidString: $0) }, sortOrder: row["sortOrder"])
    }
    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.uuidString
        container["name"] = name
        container["command"] = command
        container["connectionId"] = connectionId?.uuidString
        container["sortOrder"] = sortOrder
    }
}
