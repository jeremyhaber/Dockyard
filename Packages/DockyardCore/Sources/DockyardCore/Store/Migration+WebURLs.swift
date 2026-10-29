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

    /// How a WHM server's accounts log in (password, one key, an agent, or through root), and the login user
    /// that reaching an account through root needs.
    mutating func registerWHMAccountLoginMigration() {
        registerMigration("v_whm_account_login") { db in
            try db.alter(table: "whmSource") { t in
                t.add(column: "accountLogin", .text).notNull().defaults(to: "password")
            }
            try db.alter(table: "connection") { t in
                t.add(column: "loginUser", .text)
            }
        }
    }

    /// Where the local pane starts. Connections that already had a local folder keep starting there.
    mutating func registerLocalStartMigration() {
        registerMigration("v_local_start") { db in
            try db.alter(table: "connection") { t in
                t.add(column: "localStart", .text).notNull().defaults(to: "default")
                t.add(column: "localStartOverridesRestore", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: "UPDATE connection SET localStart = 'folder' WHERE localFolder IS NOT NULL AND localFolder != ''")
        }
    }

    /// Databases that ran an early `v_whm_account_login`, before it added `loginUser`, lack the column.
    mutating func registerLoginUserRepairMigration() {
        registerMigration("v_connection_login_user") { db in
            guard try !db.columns(in: "connection").contains(where: { $0.name == "loginUser" }) else { return }
            try db.alter(table: "connection") { t in
                t.add(column: "loginUser", .text)
            }
        }
    }
}
