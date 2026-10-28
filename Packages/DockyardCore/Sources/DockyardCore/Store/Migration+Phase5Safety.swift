import GRDB

extension DatabaseMigrator {
    /// Phase 5 (safety and productivity): per-connection safety switches, jump host, pinned folders and transfer filters.
    mutating func registerPhase5SafetyMigration() {
        registerMigration("v_phase5_safety") { db in
            try db.alter(table: "connection") { t in
                t.add(column: "trashOnDelete", .boolean).notNull().defaults(to: false)
                t.add(column: "keepVersionsOnOverwrite", .boolean).notNull().defaults(to: false)
                t.add(column: "readOnly", .boolean).notNull().defaults(to: false)
                t.add(column: "verifyChecksums", .boolean).notNull().defaults(to: false)
                t.add(column: "jumpHost", .text).references("connection", onDelete: .setNull)
                t.add(column: "pinnedFolders", .text).notNull().defaults(to: "[]")
                t.add(column: "transferFilters", .text).notNull().defaults(to: "[]")
            }
        }
    }
}
