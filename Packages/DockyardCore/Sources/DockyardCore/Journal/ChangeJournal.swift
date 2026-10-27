import Foundation
import GRDB
import ConnectionKit

/// What a journal entry did. See HANDOFF section 11, "Undo and recent changes".
public enum ChangeKind: String, Sendable, Codable, CaseIterable {
    case move, rename, newFolder, chmod
    /// An upload or copy that created a new file.
    case upload
    /// An overwrite where a version was kept: `fromPath` is the kept copy, `toPath` the file.
    case overwrite
}

/// One reversible operation on one connection (or on the local pane).
public struct ChangeEntry: Sendable, Equatable, Identifiable {
    public var id: Int64?
    /// The connection id, or `ChangeEntry.localScope` for the local pane.
    public var scope: UUID
    public var kind: ChangeKind
    /// Where the item was before (move, rename), or the kept version (overwrite).
    public var fromPath: String?
    /// Where the item is now: the new path, the created file or folder, or the changed item.
    public var toPath: String
    public var isDirectory: Bool
    public var previousMode: UInt16?
    public var newMode: UInt16?
    /// Size and time of a created or overwritten file, to tell whether it changed since.
    public var createdSize: UInt64?
    public var createdModified: Date?
    public var time: Date
    public var undone: Bool

    public static let localScope = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    public init(
        id: Int64? = nil, scope: UUID, kind: ChangeKind, fromPath: String? = nil, toPath: String, isDirectory: Bool = false,
        previousMode: UInt16? = nil, newMode: UInt16? = nil, createdSize: UInt64? = nil, createdModified: Date? = nil,
        time: Date = Date(), undone: Bool = false
    ) {
        self.id = id; self.scope = scope; self.kind = kind; self.fromPath = fromPath; self.toPath = toPath
        self.isDirectory = isDirectory; self.previousMode = previousMode; self.newMode = newMode
        self.createdSize = createdSize; self.createdModified = createdModified; self.time = time; self.undone = undone
    }

    public var itemName: String { RemotePath.lastComponent(of: toPath) }

    /// "Move "images"", used in the Edit menu and the list.
    public var title: String {
        switch kind {
        case .move: "Move \u{201C}\(itemName)\u{201D}"
        case .rename: "Rename \u{201C}\(RemotePath.lastComponent(of: fromPath ?? toPath))\u{201D}"
        case .newFolder: "New folder \u{201C}\(itemName)\u{201D}"
        case .chmod: "Permissions of \u{201C}\(itemName)\u{201D}"
        case .upload: "Upload \u{201C}\(itemName)\u{201D}"
        case .overwrite: "Overwrite \u{201C}\(itemName)\u{201D}"
        }
    }

    /// "Moved `images` into `old-site`", for the toast right after the operation.
    public var summary: String {
        switch kind {
        case .move: "Moved \u{201C}\(itemName)\u{201D} into \u{201C}\(RemotePath.lastComponent(of: RemotePath.parent(of: toPath)))\u{201D}"
        case .rename: "Renamed \u{201C}\(RemotePath.lastComponent(of: fromPath ?? toPath))\u{201D} to \u{201C}\(itemName)\u{201D}"
        case .newFolder: "Created folder \u{201C}\(itemName)\u{201D}"
        case .chmod: "Changed permissions of \u{201C}\(itemName)\u{201D} to \(FileDisplay.octal(newMode))"
        case .upload: "Copied \u{201C}\(itemName)\u{201D}"
        case .overwrite: "Replaced \u{201C}\(itemName)\u{201D}"
        }
    }
}

extension ChangeEntry: FetchableRecord, MutablePersistableRecord, TableRecord {
    public static let databaseTableName = "changeJournal"

    public init(row: Row) throws {
        let scope: String = row["scope"]
        let kind: String = row["kind"]
        let mode: Int? = row["previousMode"]
        let new: Int? = row["newMode"]
        let size: Int64? = row["createdSize"]
        self.init(
            id: row["id"], scope: UUID(uuidString: scope) ?? ChangeEntry.localScope, kind: ChangeKind(rawValue: kind) ?? .move,
            fromPath: row["fromPath"], toPath: row["toPath"], isDirectory: row["isDirectory"],
            previousMode: mode.map { UInt16(truncatingIfNeeded: $0) }, newMode: new.map { UInt16(truncatingIfNeeded: $0) },
            createdSize: size.map { UInt64(truncatingIfNeeded: $0) }, createdModified: row["createdModified"],
            time: row["time"], undone: row["undone"])
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["scope"] = scope.uuidString
        container["kind"] = kind.rawValue
        container["fromPath"] = fromPath
        container["toPath"] = toPath
        container["isDirectory"] = isDirectory
        container["previousMode"] = previousMode.map { Int($0) }
        container["newMode"] = newMode.map { Int($0) }
        container["createdSize"] = createdSize.map { Int64(truncatingIfNeeded: $0) }
        container["createdModified"] = createdModified
        container["time"] = time
        container["undone"] = undone
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension DockyardDatabase {
    /// The change journal table. Registered from `migrator` in its own function so it stays independent of other migrations.
    static func registerJournalMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("journal_v1") { db in
            try db.create(table: "changeJournal") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("scope", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("fromPath", .text)
                t.column("toPath", .text).notNull()
                t.column("isDirectory", .boolean).notNull().defaults(to: false)
                t.column("previousMode", .integer)
                t.column("newMode", .integer)
                t.column("createdSize", .integer)
                t.column("createdModified", .datetime)
                t.column("time", .datetime).notNull()
                t.column("undone", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "changeJournal_on_scope", on: "changeJournal", columns: ["scope", "id"])
        }
    }
}

/// The per-connection change journal: the last `limit` entries per scope survive a restart.
public final class ChangeJournal: Sendable {
    public static let defaultLimit = 100
    private let db: DockyardDatabase
    private let limit: Int

    public init(database: DockyardDatabase, limit: Int = ChangeJournal.defaultLimit) {
        db = database
        self.limit = max(1, limit)
    }

    /// Adds an entry and drops the oldest ones beyond the limit. A new change clears the redo chain (entries marked undone).
    @discardableResult
    public func record(_ entry: ChangeEntry) async throws -> ChangeEntry {
        let limit = self.limit
        return try await db.writer.write { db in
            var saved = entry
            try db.execute(sql: "DELETE FROM changeJournal WHERE scope = ? AND undone = 1", arguments: [entry.scope.uuidString])
            try saved.insert(db)
            try db.execute(sql: """
                DELETE FROM changeJournal WHERE scope = ? AND id NOT IN \
                (SELECT id FROM changeJournal WHERE scope = ? ORDER BY id DESC LIMIT ?)
                """, arguments: [entry.scope.uuidString, entry.scope.uuidString, limit])
            return saved
        }
    }

    /// Newest first.
    public func entries(scope: UUID) async throws -> [ChangeEntry] {
        try await db.writer.read { db in
            try ChangeEntry.fetchAll(db, sql: "SELECT * FROM changeJournal WHERE scope = ? ORDER BY id DESC", arguments: [scope.uuidString])
        }
    }

    /// The change ⌘Z would undo: the newest entry that is not undone yet.
    public func nextUndo(scope: UUID) async throws -> ChangeEntry? {
        try await db.writer.read { db in
            try ChangeEntry.fetchOne(
                db, sql: "SELECT * FROM changeJournal WHERE scope = ? AND undone = 0 ORDER BY id DESC LIMIT 1",
                arguments: [scope.uuidString])
        }
    }

    /// The change ⇧⌘Z would redo: the most recently undone entry.
    public func nextRedo(scope: UUID) async throws -> ChangeEntry? {
        try await db.writer.read { db in
            try ChangeEntry.fetchOne(
                db, sql: "SELECT * FROM changeJournal WHERE scope = ? AND undone = 1 ORDER BY id ASC LIMIT 1",
                arguments: [scope.uuidString])
        }
    }

    public func setUndone(_ id: Int64, _ undone: Bool) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE changeJournal SET undone = ? WHERE id = ?", arguments: [undone, id])
        }
    }

    public func clear(scope: UUID) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM changeJournal WHERE scope = ?", arguments: [scope.uuidString])
        }
    }
}

// MARK: - Undo

/// Why an undo or redo cannot go ahead as recorded.
public enum UndoBlock: Sendable, Equatable {
    /// The item is no longer where the journal left it.
    case itemMissing(String)
    /// Something else now sits at the path the item would return to.
    case pathOccupied(String)
    /// The created file changed (size or modification time) since it was created.
    case changedSince(String)
    case folderNotEmpty(String)
    case notRedoable(String)

    public var message: String {
        switch self {
        case .itemMissing(let p): "\u{201C}\(RemotePath.lastComponent(of: p))\u{201D} is no longer at \(p)."
        case .pathOccupied(let p): "Something else is now at \(p)."
        case .changedSince(let p): "\u{201C}\(RemotePath.lastComponent(of: p))\u{201D} has changed since it was created."
        case .folderNotEmpty(let p): "The folder \u{201C}\(RemotePath.lastComponent(of: p))\u{201D} is not empty."
        case .notRedoable(let m): m
        }
    }

    /// Blocks the user can resolve with the usual conflict choices.
    public var isConflict: Bool {
        switch self {
        case .pathOccupied: true
        default: false
        }
    }
}

public enum UndoResolution: Sendable, Equatable {
    /// Replace whatever occupies the path.
    case overwrite
    /// Put the item back under a conflict-copy name next to it.
    case keepBoth
}

/// Checks the current state against a journal entry and reverses (or repeats) it on a file system.
public struct ChangeUndoer: Sendable {
    private let fs: any RemoteFileSystem
    public var timeTolerance: TimeInterval = 2

    public init(fs: any RemoteFileSystem) { self.fs = fs }

    public func check(_ entry: ChangeEntry, redo: Bool = false) async -> UndoBlock? {
        do { return try await validate(entry, redo: redo) } catch { return .itemMissing(entry.toPath) }
    }

    /// Reverses the entry. Throws `UndoBlockedError` when the state does not match and no resolution was chosen.
    public func undo(_ entry: ChangeEntry, resolution: UndoResolution? = nil) async throws {
        try await perform(entry, redo: false, resolution: resolution)
    }

    public func redo(_ entry: ChangeEntry, resolution: UndoResolution? = nil) async throws {
        try await perform(entry, redo: true, resolution: resolution)
    }

    // MARK: Internals

    private func validate(_ e: ChangeEntry, redo: Bool) async throws -> UndoBlock? {
        switch e.kind {
        case .move, .rename:
            let (source, target) = redo ? (e.fromPath ?? e.toPath, e.toPath) : (e.toPath, e.fromPath ?? e.toPath)
            guard try await fs.stat(source) != nil else { return .itemMissing(source) }
            if try await fs.stat(target) != nil { return .pathOccupied(target) }
            return nil
        case .newFolder:
            if redo { return try await fs.stat(e.toPath) == nil ? nil : .pathOccupied(e.toPath) }
            guard let item = try await fs.stat(e.toPath) else { return .itemMissing(e.toPath) }
            guard item.isDirectory else { return .changedSince(e.toPath) }
            return try await fs.list(e.toPath).isEmpty ? nil : .folderNotEmpty(e.toPath)
        case .chmod:
            guard try await fs.stat(e.toPath) != nil else { return .itemMissing(e.toPath) }
            return nil
        case .upload:
            if redo { return .notRedoable("Copy the file again from the transfer queue.") }
            guard let item = try await fs.stat(e.toPath) else { return .itemMissing(e.toPath) }
            return unchanged(item, e) ? nil : .changedSince(e.toPath)
        case .overwrite:
            if redo { return .notRedoable("Overwrite the file again to redo this.") }
            guard let version = e.fromPath, try await fs.stat(version) != nil else { return .itemMissing(e.fromPath ?? e.toPath) }
            guard let item = try await fs.stat(e.toPath) else { return .itemMissing(e.toPath) }
            return unchanged(item, e) ? nil : .changedSince(e.toPath)
        }
    }

    private func unchanged(_ item: RemoteItem, _ e: ChangeEntry) -> Bool {
        if let size = e.createdSize, item.size != size { return false }
        if let when = e.createdModified, let now = item.modified, abs(now.timeIntervalSince(when)) > timeTolerance { return false }
        return true
    }

    private func perform(_ e: ChangeEntry, redo: Bool, resolution: UndoResolution?) async throws {
        if let block = try await validate(e, redo: redo) {
            guard block.isConflict, let resolution else { throw UndoBlockedError(block: block) }
            try await resolve(e, redo: redo, resolution: resolution)
            return
        }
        switch e.kind {
        case .move, .rename:
            let (source, target) = redo ? (e.fromPath ?? e.toPath, e.toPath) : (e.toPath, e.fromPath ?? e.toPath)
            try await fs.rename(source, target)
        case .newFolder:
            if redo { try await fs.mkdir(e.toPath) } else { try await fs.delete(e.toPath, recursive: false) }
        case .chmod:
            if let mode = redo ? e.newMode : e.previousMode { try await fs.chmod(e.toPath, mode: mode) }
        case .upload:
            try await fs.delete(e.toPath, recursive: false)
        case .overwrite:
            try await fs.delete(e.toPath, recursive: false)
            if let version = e.fromPath { try await fs.rename(version, e.toPath) }
        }
    }

    private func resolve(_ e: ChangeEntry, redo: Bool, resolution: UndoResolution) async throws {
        let (source, target) = redo ? (e.fromPath ?? e.toPath, e.toPath) : (e.toPath, e.fromPath ?? e.toPath)
        switch resolution {
        case .overwrite:
            try await fs.delete(target, recursive: true)
            try await fs.rename(source, target)
        case .keepBoth:
            let parent = RemotePath.parent(of: target)
            let existing = Set(try await fs.list(parent).map(\.name))
            let name = FileNaming.uniqueConflictCopy(RemotePath.lastComponent(of: target), date: Date(), existing: existing)
            try await fs.rename(source, RemotePath.join(parent, name))
        }
    }
}

public struct UndoBlockedError: Error, Sendable, Equatable, CustomStringConvertible {
    public var block: UndoBlock
    public var description: String { block.message }
}
