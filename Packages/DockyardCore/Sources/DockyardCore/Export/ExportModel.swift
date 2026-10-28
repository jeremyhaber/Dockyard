import Foundation
import ConnectionKit

/// A settings value that survives the JSON round trip.
public enum SettingValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([SettingValue])
    case object([String: SettingValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([SettingValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: SettingValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// Everything that goes into an export file.
public struct ExportContents: Sendable, Equatable {
    public var connections: [Connection] = []
    public var folders: [ClientFolder] = []
    public var whmSources: [WHMSource] = []
    /// Application settings (the app decides the keys).
    public var settings: [String: SettingValue] = [:]
    /// Per connection and purpose. Empty unless the user chose to include secrets.
    public var secrets: [UUID: [SecretPurpose: String]] = [:]
    /// WHM API tokens by `WHMSource.apiTokenKeychainRef`, filled in by the app when it includes secrets.
    public var whmTokens: [String: String] = [:]
    public var createdAt: Date = Date()

    public init(connections: [Connection] = [], folders: [ClientFolder] = [], whmSources: [WHMSource] = [],
                settings: [String: SettingValue] = [:], secrets: [UUID: [SecretPurpose: String]] = [:],
                whmTokens: [String: String] = [:], createdAt: Date = Date()) {
        self.connections = connections; self.folders = folders; self.whmSources = whmSources
        self.settings = settings; self.secrets = secrets; self.whmTokens = whmTokens; self.createdAt = createdAt
    }

    public var includesSecrets: Bool { !secrets.isEmpty || !whmTokens.isEmpty }
}

// MARK: - Serialised form

/// The JSON payload inside the encrypted file. Independent of the database schema, so it only changes with `formatVersion`.
struct ExportPayload: Codable {
    static let currentVersion = 1

    var formatVersion: Int
    var createdAt: Date
    var folders: [FolderDTO]
    var connections: [ConnectionDTO]
    var whmSources: [WHMSourceDTO]
    var settings: [String: SettingValue]
    var secrets: [String: [String: String]]
    var whmTokens: [String: String]

    struct FolderDTO: Codable { var id: UUID; var name: String }

    struct WHMSourceDTO: Codable {
        var id: UUID, label: String, host: String, apiPort: Int, apiUser: String, apiTokenKeychainRef: String
        /// Missing in exports made before per-server account login existed.
        var accountLogin: String?
    }

    struct ConnectionDTO: Codable {
        var id: UUID
        var name: String
        var clientFolderId: UUID?
        var `protocol`: String
        var host: String
        var port: Int
        var username: String
        var authMethods: UInt8
        var keyPath: String?
        var elevation: String
        var elevateFileBrowsing: Bool
        var askBeforeElevatingOnProd: Bool
        var isProd: Bool
        var favorite: Bool
        var tags: [String]
        var notes: String
        var source: String
        var restoreSession: Bool
        var mountInFinder: Bool
        var mountOnLaunch: Bool
        var mountReadOnly: Bool
        var createdAt: Date
        var initialRemotePath: String?
        var trashOnDelete: Bool
        var keepVersionsOnOverwrite: Bool
        var readOnly: Bool
        var verifyChecksums: Bool
        var jumpHost: UUID?
        var pinnedFolders: [PinnedFolder]
        var transferFilters: [String]
        /// Optional so exports from before web URLs and icons still decode.
        var webURLs: [WebURLMapping]?
        var icon: ConnectionIcon?
        var color: ConnectionColor?
        var faviconSite: String?
        /// Optional so exports from before the tree-root setting still decode.
        var treeRoot: FolderTreeRoot?
        var loginUser: String?

        init(_ c: Connection) {
            id = c.id; name = c.name; clientFolderId = c.clientFolderId; `protocol` = c.protocol.rawValue
            host = c.host; port = c.port; username = c.username; authMethods = c.authMethods.rawValue; keyPath = c.keyPath
            elevation = c.elevation.rawValue; elevateFileBrowsing = c.elevateFileBrowsing
            askBeforeElevatingOnProd = c.askBeforeElevatingOnProd; isProd = c.isProd; favorite = c.favorite
            tags = c.tags; notes = c.notes; source = c.source.rawValue; restoreSession = c.restoreSession
            mountInFinder = c.mountInFinder; mountOnLaunch = c.mountOnLaunch; mountReadOnly = c.mountReadOnly
            createdAt = c.createdAt; initialRemotePath = c.initialRemotePath
            trashOnDelete = c.trashOnDelete; keepVersionsOnOverwrite = c.keepVersionsOnOverwrite; readOnly = c.readOnly
            verifyChecksums = c.verifyChecksums; jumpHost = c.jumpHost; pinnedFolders = c.pinnedFolders
            transferFilters = c.transferFilters; webURLs = c.webURLs; icon = c.icon; color = c.color; faviconSite = c.faviconSite
            treeRoot = c.treeRoot; loginUser = c.loginUser
        }

        var connection: Connection {
            var c = Connection(
                id: id, name: name, clientFolderId: clientFolderId, protocol: ConnectionProtocol(rawValue: `protocol`) ?? .sftp,
                host: host, port: port, username: username, authMethods: AuthMethods(rawValue: authMethods), keyPath: keyPath,
                elevation: Elevation(rawValue: elevation) ?? .none, elevateFileBrowsing: elevateFileBrowsing,
                askBeforeElevatingOnProd: askBeforeElevatingOnProd, isProd: isProd, favorite: favorite, tags: tags, notes: notes,
                source: ConnectionSource(rawValue: source) ?? .manual, restoreSession: restoreSession,
                mountInFinder: mountInFinder, mountOnLaunch: mountOnLaunch, mountReadOnly: mountReadOnly,
                createdAt: createdAt, initialRemotePath: initialRemotePath, treeRoot: treeRoot ?? .home, trashOnDelete: trashOnDelete,
                keepVersionsOnOverwrite: keepVersionsOnOverwrite, readOnly: readOnly, verifyChecksums: verifyChecksums,
                jumpHost: jumpHost, pinnedFolders: pinnedFolders, transferFilters: transferFilters,
                webURLs: webURLs ?? [], icon: icon, color: color, faviconSite: faviconSite)
            c.loginUser = loginUser
            return c
        }
    }

    init(_ contents: ExportContents) {
        formatVersion = Self.currentVersion
        createdAt = contents.createdAt
        folders = contents.folders.map { FolderDTO(id: $0.id, name: $0.name) }
        connections = contents.connections.map(ConnectionDTO.init)
        whmSources = contents.whmSources.map {
            WHMSourceDTO(id: $0.id, label: $0.label, host: $0.host, apiPort: $0.apiPort, apiUser: $0.apiUser, apiTokenKeychainRef: $0.apiTokenKeychainRef,
                         accountLogin: $0.accountLogin.rawValue)
        }
        settings = contents.settings
        secrets = Dictionary(uniqueKeysWithValues: contents.secrets.map { id, byPurpose in
            (id.uuidString, Dictionary(uniqueKeysWithValues: byPurpose.map { ($0.key.rawValue, $0.value) }))
        })
        whmTokens = contents.whmTokens
    }

    var contents: ExportContents {
        var secretMap: [UUID: [SecretPurpose: String]] = [:]
        for (id, byPurpose) in secrets {
            guard let uuid = UUID(uuidString: id) else { continue }
            let typed = byPurpose.compactMap { key, value in SecretPurpose(rawValue: key).map { ($0, value) } }
            if !typed.isEmpty { secretMap[uuid] = Dictionary(uniqueKeysWithValues: typed) }
        }
        return ExportContents(
            connections: connections.map(\.connection),
            folders: folders.map { ClientFolder(id: $0.id, name: $0.name) },
            whmSources: whmSources.map {
                WHMSource(id: $0.id, label: $0.label, host: $0.host, apiPort: $0.apiPort, apiUser: $0.apiUser, apiTokenKeychainRef: $0.apiTokenKeychainRef,
                          accountLogin: $0.accountLogin.flatMap(WHMAccountLogin.init(rawValue:)) ?? .password)
            },
            settings: settings, secrets: secretMap, whmTokens: whmTokens, createdAt: createdAt)
    }
}
