import GRDB

extension DatabaseMigrator {
    /// Transfers that bypass pause and the connection limit (edit in place).
    mutating func registerImmediateTransfersMigration() {
        registerMigration("transfer_immediate_v1") { db in
            try db.alter(table: "transferJob") { t in
                t.add(column: "immediate", .boolean).notNull().defaults(to: false)
            }
        }
    }
}
