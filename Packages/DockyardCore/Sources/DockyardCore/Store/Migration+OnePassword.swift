import ConnectionKit
import GRDB

extension DatabaseMigrator {
    /// 1Password support: the agent socket choice, per-purpose secret references and the imported item's id.
    mutating func registerOnePasswordMigration() {
        registerMigration("onepassword_v1") { db in
            try db.alter(table: "connection") { t in
                t.add(column: "agentSocket", .text).notNull().defaults(to: AgentSocket.system.rawValue)
                t.add(column: "secretReferences", .text).notNull().defaults(to: "{}")
                t.add(column: "onePasswordItemId", .text)
            }
            try db.create(index: "connection_on_onePasswordItemId", on: "connection", columns: ["onePasswordItemId"])
        }
    }
}
