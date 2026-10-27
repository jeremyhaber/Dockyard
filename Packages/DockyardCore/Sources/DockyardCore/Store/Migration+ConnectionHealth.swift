import GRDB

extension DatabaseMigrator {
    /// Test-and-clean-up support: health results per connection and soft delete of connections.
    mutating func registerConnectionHealthMigration() {
        registerMigration("connection_health_v1") { db in
            try db.create(table: "connectionHealth") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("connectionId", .text).notNull().references("connection", onDelete: .cascade)
                t.column("status", .text).notNull()
                t.column("latencyMs", .integer)
                t.column("message", .text)
                t.column("testedAt", .datetime).notNull()
            }
            try db.create(index: "connectionHealth_on_connection", on: "connectionHealth", columns: ["connectionId", "id"])
            try db.alter(table: "connection") { t in
                t.add(column: "deletedAt", .datetime)
            }
            try db.create(index: "connection_on_deletedAt", on: "connection", columns: ["deletedAt"])
        }
    }
}
