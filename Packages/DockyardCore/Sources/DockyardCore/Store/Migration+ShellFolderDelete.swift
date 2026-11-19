import GRDB

extension DatabaseMigrator {
    /// SFTP folder deletes through one `rm -rf` over SSH. On for existing connections too.
    mutating func registerShellFolderDeleteMigration() {
        registerMigration("v_shell_folder_delete") { db in
            try db.alter(table: "connection") { t in
                t.add(column: "shellFolderDelete", .boolean).notNull().defaults(to: true)
            }
        }
    }
}
