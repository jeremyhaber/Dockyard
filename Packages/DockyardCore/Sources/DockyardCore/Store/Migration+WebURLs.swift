import GRDB

extension DatabaseMigrator {
    /// Folder-to-website mappings ("Copy Web URL") and a custom sidebar icon per connection.
    mutating func registerWebURLsMigration() {
        registerMigration("v_web_urls_icon") { db in
            try db.alter(table: "connection") { t in
                t.add(column: "webURLs", .text).notNull().defaults(to: "[]")
                t.add(column: "icon", .text)
            }
        }
    }

    /// Colour label shown on a connection's tab and panel.
    mutating func registerConnectionColorMigration() {
        registerMigration("v_connection_color") { db in
            try db.alter(table: "connection") { t in
                t.add(column: "color", .text)
            }
        }
    }

    /// A website chosen to take the connection's icon from.
    mutating func registerFaviconSiteMigration() {
        registerMigration("v_favicon_site") { db in
            try db.alter(table: "connection") { t in
                t.add(column: "faviconSite", .text)
            }
        }
    }

    /// Where the server folder tree starts (home folder or server root).
    mutating func registerTreeRootMigration() {
        registerMigration("v_tree_root") { db in
            try db.alter(table: "connection") { t in
                t.add(column: "treeRoot", .text).notNull().defaults(to: "home")
            }
        }
    }
}
