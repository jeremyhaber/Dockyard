import GRDB

extension DatabaseMigrator {
    /// Per-site default for existing files at the destination (nil: use the global default).
    mutating func registerConflictDefaultMigration() {
        registerMigration("v_conflict_default_action") { db in
            try db.alter(table: "connection") { t in
                t.add(column: "defaultConflictAction", .text)
            }
        }
    }
}
