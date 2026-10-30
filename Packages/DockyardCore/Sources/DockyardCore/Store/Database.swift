import Foundation
import GRDB

/// Owns the SQLite database (a file in the app group container, or in memory for tests).
/// Secrets are never written here; `Connection` has no password fields.
public final class DockyardDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        writer = pool
        try Self.migrator.migrate(pool)
    }

    /// In-memory database for tests and previews.
    public init() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        writer = queue
        try Self.migrator.migrate(queue)
    }

    /// Read-only access for the File Provider extension (it reads the app's database).
    public static func openReadOnly(path: String) throws -> DockyardDatabase {
        try DockyardDatabase(readOnlyPath: path)
    }

    private init(readOnlyPath path: String) throws {
        var config = Configuration()
        config.readonly = true
        writer = try DatabaseQueue(path: path, configuration: config)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "clientFolder") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
            }
            try db.create(table: "whmSource") { t in
                t.primaryKey("id", .text)
                t.column("label", .text).notNull()
                t.column("host", .text).notNull()
                t.column("apiPort", .integer).notNull().defaults(to: 2087)
                t.column("apiUser", .text).notNull().defaults(to: "root")
                t.column("apiTokenKeychainRef", .text).notNull()
                t.column("lastSyncAt", .datetime)
                t.column("lastSyncError", .text)
            }
            try db.create(table: "connection") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("clientFolderId", .text).references("clientFolder", onDelete: .setNull)
                t.column("protocol", .text).notNull()
                t.column("host", .text).notNull()
                t.column("port", .integer).notNull()
                t.column("username", .text).notNull()
                t.column("authMethods", .integer).notNull()
                t.column("keyPath", .text)
                t.column("elevation", .text).notNull().defaults(to: "none")
                t.column("elevateFileBrowsing", .boolean).notNull().defaults(to: false)
                t.column("askBeforeElevatingOnProd", .boolean).notNull().defaults(to: true)
                t.column("isProd", .boolean).notNull().defaults(to: false)
                t.column("favorite", .boolean).notNull().defaults(to: false)
                t.column("tags", .text).notNull().defaults(to: "[]")
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("source", .text).notNull().defaults(to: "manual")
                t.column("restoreSession", .boolean).notNull().defaults(to: true)
                t.column("mountInFinder", .boolean).notNull().defaults(to: false)
                t.column("mountOnLaunch", .boolean).notNull().defaults(to: false)
                t.column("mountReadOnly", .boolean).notNull().defaults(to: false)
                t.column("lastConnectedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("removedFromSource", .boolean).notNull().defaults(to: false)
                t.column("isNew", .boolean).notNull().defaults(to: false)
                t.column("userEditedFields", .text).notNull().defaults(to: "[]")
                t.column("initialRemotePath", .text)
            }
            try db.create(index: "connection_on_host", on: "connection", columns: ["host"])
            try db.create(index: "connection_on_source", on: "connection", columns: ["source"])
            try db.create(index: "connection_on_lastConnectedAt", on: "connection", columns: ["lastConnectedAt"])
            try db.create(index: "connection_on_createdAt", on: "connection", columns: ["createdAt"])
            try db.create(index: "connection_on_endpoint", on: "connection", columns: ["protocol", "host", "port", "username"])

            try db.create(table: "sessionState") { t in
                t.primaryKey("connectionId", .text).references("connection", onDelete: .cascade)
                t.column("localTabs", .text).notNull()
                t.column("remoteTabs", .text).notNull()
                t.column("activeLocalTab", .integer).notNull()
                t.column("activeRemoteTab", .integer).notNull()
                t.column("localTreeExpanded", .text).notNull()
                t.column("remoteTreeExpanded", .text).notNull()
                t.column("savedAt", .datetime).notNull()
            }
            try db.create(table: "folderHistory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("connectionId", .text).notNull().references("connection", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("visitedAt", .datetime).notNull()
            }
            try db.create(index: "folderHistory_on_connection", on: "folderHistory", columns: ["connectionId", "id"])
            try db.create(table: "snippet") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("command", .text).notNull()
                t.column("connectionId", .text).references("connection", onDelete: .cascade)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v2") { db in
            try db.alter(table: "connection") { t in
                t.add(column: "localFolder", .text)
                t.add(column: "cloudBackend", .text)
                t.add(column: "cloudOptions", .text)
                t.add(column: "cloudRoot", .text)
            }
            try db.create(table: "knownHost") { t in
                t.column("host", .text).notNull()
                t.column("port", .integer).notNull()
                t.column("keyType", .text).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("firstSeenAt", .datetime).notNull()
                t.primaryKey(["host", "port", "keyType"])
            }
        }
        migrator.registerPhase5SafetyMigration()
        migrator.registerMigration("v3-transfer-queue") { db in
            try db.alter(table: "connection") { t in
                t.add(column: "maxConnections", .integer).notNull().defaults(to: Connection.defaultMaxConnections)
                t.add(column: "connectDelayMs", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "transferJob") { t in
                t.primaryKey("id", .integer)
                t.column("parentId", .integer)
                t.column("rootId", .integer).notNull()
                t.column("siteKey", .text).notNull()
                t.column("srcSite", .text)
                t.column("dstSite", .text)
                t.column("srcLabel", .text).notNull()
                t.column("dstLabel", .text).notNull()
                t.column("sourcePath", .text).notNull()
                t.column("destPath", .text).notNull()
                t.column("isDirectory", .boolean).notNull()
                t.column("size", .integer)
                t.column("modified", .double)
                t.column("createParents", .boolean).notNull()
                t.column("recursive", .boolean).notNull()
                t.column("deleteSource", .boolean).notNull()
                t.column("conflict", .integer)
                t.column("state", .integer).notNull()
                t.column("bytesDone", .integer).notNull().defaults(to: 0)
                t.column("bytesTotal", .integer).notNull().defaults(to: 0)
                t.column("error", .text)
                t.column("expanded", .boolean).notNull().defaults(to: false)
                t.column("childCount", .integer).notNull().defaults(to: 0)
                t.column("childrenDone", .integer).notNull().defaults(to: 0)
                t.column("resume", .boolean).notNull().defaults(to: false)
                t.column("attempts", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "transferJob_on_lane", on: "transferJob", columns: ["siteKey", "isDirectory", "state", "id"])
            try db.create(index: "transferJob_on_state", on: "transferJob", columns: ["state", "id"])
            try db.create(index: "transferJob_on_parent", on: "transferJob", columns: ["parentId", "id"])
            try db.create(index: "transferJob_on_root", on: "transferJob", columns: ["rootId"])
        }
        registerJournalMigration(&migrator)
        migrator.registerOnePasswordMigration()
        migrator.registerConnectionHealthMigration()
        migrator.registerConflictDefaultMigration()
        migrator.registerWebURLsMigration()
        migrator.registerConnectionColorMigration()
        migrator.registerFaviconSiteMigration()
        migrator.registerTreeRootMigration()
        migrator.registerWHMAccountLoginMigration()
        migrator.registerLoginUserRepairMigration()
        migrator.registerLocalStartMigration()
        migrator.registerImmediateTransfersMigration()
        return migrator
    }
}
