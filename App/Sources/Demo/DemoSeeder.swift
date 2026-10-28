import ConnectionKit
import DockyardCore
import Foundation

/// Fills the in-memory database with sample data and opens the demo connection. Only runs in demo mode.
@MainActor
enum DemoSeeder {
    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n)) ?? UUID()
    }

    private static func ago(_ seconds: Double) -> Date { DemoMode.anchor.addingTimeInterval(-seconds) }
    private static let hour = 3_600.0
    private static let day = 86_400.0

    static let clients = [
        "Acme Corp", "Bluebird Bakery", "Cedar & Pine Law", "Delta Dental", "Evergreen Landscaping", "Fjord Marine",
        "Granite Fitness", "Harbor Books", "Ivy Interiors", "Juniper Cafe", "Keystone Realty", "Lumen Studio",
    ]

    static func run(_ app: AppModel) async {
        var folderIDs: [String: UUID] = [:]
        for name in clients {
            if let folder = try? await app.folders.create(name: name) { folderIDs[name] = folder.id }
        }

        let whm = WHMSource(id: id(900), label: "HostCo WHM", host: "whm.hostco.example", lastSyncAt: ago(3 * hour))
        try? await app.whmSources.save(whm)

        var list: [Connection] = []

        // Added by hand. The first three are open in the demo.
        list.append(Connection(
            id: id(1), name: "Acme Corp", clientFolderId: folderIDs["Acme Corp"], protocol: .ftp, host: "ftp.acmecorp.example",
            username: "acme", isProd: true, favorite: true, tags: ["wordpress", "prod"], notes: "Main marketing site.",
            mountInFinder: true, mountOnLaunch: true,
            lastConnectedAt: ago(0.5 * hour), createdAt: ago(200 * day), initialRemotePath: "/home/acme/public_html",
            localFolder: "/Users/demo/Sites/acme", keepVersionsOnOverwrite: true,
            pinnedFolders: [
                PinnedFolder(path: "/home/acme/public_html/wp-content/themes", label: "Themes"),
                PinnedFolder(path: "/home/acme/public_html/wp-content/uploads"),
                PinnedFolder(path: "/home/acme/logs"),
            ]))
        list.append(Connection(
            id: id(2), name: "Bluebird Bakery", clientFolderId: folderIDs["Bluebird Bakery"], protocol: .sftp,
            host: "bluebirdbakery.example", username: "bluebird", authMethods: .both, keyPath: "~/.ssh/id_ed25519",
            elevation: .sudo, elevateFileBrowsing: true, isProd: true, favorite: true, tags: ["shop"],
            lastConnectedAt: ago(2 * hour), createdAt: ago(180 * day), trashOnDelete: true, keepVersionsOnOverwrite: true,
            verifyChecksums: true, transferFilters: ["*.log", "/staging", "!error.log"], defaultConflictAction: .overwriteIfDifferent))
        list.append(Connection(
            id: id(3), name: "Fjord Marine (R2 assets)", clientFolderId: folderIDs["Fjord Marine"], protocol: .rclone,
            host: "https://0a1b2c.r2.cloudflarestorage.example", username: "AKIADEMO", favorite: true, tags: ["assets"],
            lastConnectedAt: ago(day), createdAt: ago(90 * day),
            cloud: CloudSpec(backend: "s3", options: ["provider": "Cloudflare"], root: "")))
        list.append(Connection(
            id: id(4), name: "Dev VPS", protocol: .sftp, host: "dev.example.net", username: "deploy", authMethods: .key,
            keyPath: "~/.ssh/id_ed25519", tags: ["internal"], lastConnectedAt: ago(3 * day), createdAt: ago(300 * day)))
        list.append(Connection(
            id: id(5), name: "Offsite backups (S3)", protocol: .rclone, host: "", username: "AKIABACKUP", tags: ["internal"],
            lastConnectedAt: ago(12 * day), createdAt: ago(250 * day),
            cloud: CloudSpec(backend: "s3", options: ["provider": "AWS", "region": "eu-west-1"], root: "dockyard-backups")))

        list.append(Connection(
            id: id(6), name: "Staging (via bastion)", protocol: .sftp, host: "10.0.4.12", username: "deploy", authMethods: .key,
            keyPath: "~/.ssh/id_ed25519", tags: ["internal"], createdAt: ago(60 * day), jumpHost: id(4)))

        // WHM accounts.
        let domains = [
            "cedarpinelaw", "deltadental", "evergreenlandscaping", "granitefitness", "harborbooks", "ivyinteriors",
            "junipercafe", "keystonerealty", "lumenstudio", "maplesmiles", "northwindtraders", "orchardfarms",
            "pineconepress", "quartzanalytics", "redwoodcabinets", "summitoutfitters", "tidewaterboats", "umbrellaroofing",
            "vistaphotography", "willowvet", "xenonfitness", "yellowkitedesign", "zenithaccounting", "alpinebikes",
        ]
        for (i, domain) in domains.enumerated() {
            var c = Connection(
                id: id(100 + i), name: "\(domain).example", protocol: .sftp, host: "\(domain).example",
                username: String(domain.prefix(8)), tags: i % 5 == 0 ? ["wordpress"] : [],
                source: .whm(whm.id), createdAt: ago(Double(40 + i) * day))
            if i % 3 == 0 { c.lastConnectedAt = ago(Double(4 + i) * day) }
            if i == 7 { c.removedFromSource = true }
            if i == 11 { c.tags.append("suspended") }
            if let match = clients.first(where: { $0.lowercased().hasPrefix(domain.prefix(5)) }) { c.clientFolderId = folderIDs[match] }
            list.append(c)
        }

        // FileZilla import.
        let legacy = (try? await app.folders.findOrCreate(name: "Legacy / Clients"))?.id
        let fz: [(String, String, ConnectionProtocol)] = [
            ("Old reseller box", "reseller.legacy.example", .sftp), ("Print shop FTP", "ftp.printshop.example", .ftp),
            ("Hotel site", "hotel.example", .ftps), ("Church site", "church.example", .ftp),
            ("School newsletter", "newsletter.school.example", .sftp), ("Garage", "garage.example", .ftp),
            ("Gym", "gym.example", .sftp), ("Conference", "conf.example", .ftps),
        ]
        for (i, entry) in fz.enumerated() {
            list.append(Connection(
                id: id(200 + i), name: entry.0, clientFolderId: legacy, protocol: entry.2, host: entry.1,
                username: "admin", source: .filezillaImport, createdAt: ago(Double(20 + i) * day)))
        }

        // Quick connects.
        list.append(Connection(
            id: id(300), name: "staging.acmecorp.example", protocol: .sftp, host: "staging.acmecorp.example", username: "acme",
            source: .quickConnect, lastConnectedAt: ago(5 * hour), createdAt: ago(5 * hour), isNew: true))
        list.append(Connection(
            id: id(301), name: "files.partner.example", protocol: .ftps, host: "files.partner.example", username: "guest",
            source: .quickConnect, lastConnectedAt: ago(26 * hour), createdAt: ago(26 * hour), isNew: true))
        list.append(Connection(
            id: id(302), name: "test.example.org", protocol: .sftp, host: "test.example.org", username: "root",
            source: .quickConnect, lastConnectedAt: ago(9 * day), createdAt: ago(9 * day)))

        // 1Password imports: a password kept in 1Password and an agent key, the first one matched by the import preview.
        list.append(Connection(
            id: id(400), name: "Harbor Books web01", protocol: .sftp, host: "harborbooks.example", username: "harbor",
            authMethods: [.agent, .password], tags: ["harbor"], notes: "Imported from 1Password (Infrastructure)",
            source: .onePasswordImport, createdAt: ago(12 * day), agentSocket: .onePassword,
            secretReferences: [.password: "op://Infrastructure/Harbor Books web01/password"], onePasswordItemId: "demo-harbor"))
        list.append(Connection(
            id: id(401), name: "Cedar & Pine staging", clientFolderId: folderIDs["Cedar & Pine Law"], protocol: .sftp,
            host: "staging.cedarpine.example", username: "cedar", authMethods: .agent, notes: "Imported from 1Password (Client Sites)",
            source: .onePasswordImport, createdAt: ago(12 * day), agentSocket: .onePassword, onePasswordItemId: "demo-cedar"))

        try? await app.connections.save(list)

        let snippets = [
            ("Tail the error log", "tail -f /var/log/nginx/error.log"), ("Disk usage here", "du -sh * | sort -h"),
            ("Restart PHP-FPM", "sudo systemctl restart php8.3-fpm"), ("Who is logged in", "w"),
        ]
        for (i, entry) in snippets.enumerated() {
            try? await app.snippets.save(Snippet(name: entry.0, command: entry.1, sortOrder: i))
        }

        // A saved session for the open connection: 3 server and 2 local folders, one of them gone.
        let www = "/home/acme/public_html"
        let state = SessionState(
            connectionId: id(1),
            localTabs: [TabState(path: "/Users/demo/Sites/acme"), TabState(path: "/Users/demo/Downloads")],
            remoteTabs: [
                TabState(path: www), TabState(path: "\(www)/wp-content/uploads/2026/10"),
                TabState(path: "/home/acme/logs"), TabState(path: "/home/acme/old-site"),
            ],
            activeLocalTab: 0, activeRemoteTab: 1,
            localTreeExpanded: ["/", "/Users", "/Users/demo", "/Users/demo/Sites"],
            remoteTreeExpanded: ["/", "/home", "/home/acme", www, "\(www)/wp-content", "\(www)/wp-content/uploads", "\(www)/wp-content/uploads/2026"],
            savedAt: DemoMode.anchor.addingTimeInterval(-day))
        try? await app.sessionRepository.save(state)

        guard let acme = list.first(where: { $0.id == id(1) }) else { return }
        app.open(list[1])
        app.open(list[2])
        app.open(acme)
        for session in app.sessions where session.connection.id == acme.id { app.activate(session) }

        for _ in 0..<50 where !app.sessions.allSatisfy({ $0.status.isConnected }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        if ["transfers", "transfersFailed"].contains(DemoMode.screen) {
            await app.queue.setMaxConcurrent(5)
            enqueueTransferScreen(app, failures: DemoMode.screen == "transfersFailed")
        } else {
            enqueueTransfers(app, relay: DemoMode.screen == "sideBySide")
        }
        await seedJournal(app, scope: acme.id)
        if let session = app.session(for: acme.id) {
            session.log.append(.command, "STOR archive-2026.zip")
            session.log.append(.error, "550 archive-2026.zip: Permission denied")
        }
        await applyScreen(app)
    }

    /// A few recent changes on Acme so the "Recent changes" list is not empty.
    private static func seedJournal(_ app: AppModel, scope: UUID) async {
        let www = "/home/acme/public_html"
        let now = Date()
        let entries = [
            ChangeEntry(scope: scope, kind: .upload, toPath: "\(www)/hero-banner.jpg", createdSize: 1_204_881, createdModified: now, time: now.addingTimeInterval(-2 * 3_600)),
            ChangeEntry(scope: scope, kind: .chmod, toPath: "\(www)/wp-config.php", previousMode: 0o644, newMode: 0o640, time: now.addingTimeInterval(-3_600)),
            ChangeEntry(scope: scope, kind: .newFolder, toPath: "\(www)/old-site", isDirectory: true, time: now.addingTimeInterval(-14 * 60)),
            ChangeEntry(scope: scope, kind: .rename, fromPath: "\(www)/style.css", toPath: "\(www)/style-old.css", time: now.addingTimeInterval(-11 * 60)),
            ChangeEntry(scope: scope, kind: .move, fromPath: "\(www)/images", toPath: "\(www)/old-site/images", isDirectory: true, time: now.addingTimeInterval(-3 * 60)),
        ]
        for entry in entries { _ = try? await app.journal.record(entry) }
        await app.refreshUndoState()
    }

    /// Where demo downloads really land: a temp folder. The Transfers tab shows it as ~/Downloads/acme-backups
    /// (`DemoMode.downloadsMarker`), so demo mode writes nothing outside the temp directory.
    private static var demoDownloads: String {
        FileManager.default.temporaryDirectory.appendingPathComponent(DemoMode.downloadsMarker).path
    }

    private static func enqueueTransfers(_ app: AppModel, relay: Bool) {
        let source = TransferEndpoint(fs: DemoFileSystem(kind: .server), label: "Acme Corp")
        let target = relay
            ? TransferEndpoint(fs: DemoFileSystem(kind: .server, flavor: .bluebird), label: "Bluebird Bakery")
            : TransferEndpoint.thisMac()
        let folder = relay ? "/home/bluebird/backups" : demoDownloads
        if !relay { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        let files: [(String, UInt64)] = [
            ("db-2026-10-26.sql.gz", 480_000_000), ("site-2026-10-01.tar.gz", 1_820_000_000), ("db-2026-10-19.sql.gz", 471_300_000),
        ]
        let queue = app.queue
        let requests = files.map { name, size in
            TransferRequest(
                source: source, sourcePath: "/home/acme/backups/\(name)", destination: target,
                destinationPath: "\(folder)/\(name)", size: size, modified: ago(day))
        }
        Task { _ = await queue.enqueue(requests) }
    }

    /// Several running, queued, finished and (for the Failed screen) failed transfers for the Transfers tab.
    private static func enqueueTransferScreen(_ app: AppModel, failures: Bool) {
        let folder = demoDownloads
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let queue = app.queue
        let local = TransferEndpoint.thisMac()
        let server = TransferEndpoint(fs: DemoFileSystem(kind: .server), label: "Acme Corp")
        let downloads: [(String, UInt64)] = [
            ("db-2026-10-26.sql.gz", 480_000_000), ("site-2026-10-01.tar.gz", 1_820_000_000), ("db-2026-10-19.sql.gz", 471_300_000),
            ("access.log", 18_204_113), ("uploads-2026-09.zip", 912_400_000), ("access-30-Sep.gz", 40_000),
            ("access-29-Sep.gz", 49_113), ("access-28-Sep.gz", 58_226), ("access-27-Sep.gz", 67_339), ("access-26-Sep.gz", 76_452),
        ]
        var requests = downloads.map { name, size in
            TransferRequest(
                source: server, sourcePath: "/home/acme/backups/\(name)", destination: local, destinationPath: "\(folder)/\(name)",
                size: size, modified: ago(day))
        }
        let finished: [(String, UInt64)] = [("header.php", 4_212), ("footer.php", 6_033), ("sidebar.php", 1_204)]
        let target = TransferEndpoint(fs: DemoFileSystem(kind: .server), label: "Acme Corp")
        let done = finished.map { name, size in
            TransferRequest(
                source: local, sourcePath: "\(folder)/\(name)", destination: target,
                destinationPath: "/home/acme/public_html/wp-content/themes/acme-child/\(name)", size: size, modified: ago(hour))
        }
        var failing: [TransferRequest] = []
        if failures {
            let reasons: [(String, String)] = [
                ("db-2026-09-28.sql.gz", "550 Permission denied"),
                ("site-2026-09-01.tar.gz", "552 Disk quota exceeded"),
                ("mail-export.mbox", "550 mail-export.mbox: No such file or directory"),
                ("wp-content-2026-08.zip", "553 Could not create file"),
                ("error.log", "550 Permission denied"),
                ("cache-dump.sql", "550 Permission denied"),
            ]
            let broken = TransferEndpoint(
                fs: DemoFileSystem(kind: .server, failures: Dictionary(uniqueKeysWithValues: reasons.map { ("/home/acme/backups/\($0.0)", $0.1) })),
                label: "Acme Corp")
            failing = reasons.map { name, _ in
                TransferRequest(
                    source: broken, sourcePath: "/home/acme/backups/\(name)", destination: local, destinationPath: "\(folder)/\(name)",
                    size: 2_000_000, modified: ago(day))
            }
        }
        if failures { requests = Array(requests.prefix(7)) }
        Task {
            _ = await queue.enqueue(done)
            _ = await queue.enqueue(failing)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            _ = await queue.enqueue(requests)
        }
    }

    /// Opens the screen named by `-DockyardDemoScreen`. `connectionManager` and `settings` are handled by the main window.
    static func applyScreen(_ app: AppModel) async {
        let acme = app.session(for: id(1))
        let bluebird = app.session(for: id(2))
        switch DemoMode.screen {
        case "logDrawer":
            app.drawerTab = .log
            app.drawerVisible = true
        case "jump":
            app.jumpVisible = true
        case "transfers", "transfersFailed":
            app.drawerHeight = 330
            // The first rows are finished and failed ones; give the active ones a moment to start.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if DemoMode.screen == "transfersFailed" {
                app.transferUI.tab = .failed
                app.showFailureToast(app.transfers.failedCount)
            } else {
                app.transferUI.tab = .active
            }
            app.drawerTab = .transfers
            app.drawerVisible = true
        case "versions":
            if let acme { app.showVersions(for: acme) }
        case "search":
            guard let acme else { return }
            let www = "/home/acme/public_html"
            acme.server?.navigate(to: www)
            let hits = [
                SearchHit(path: "\(www)/wp-config.php", isDirectory: false, size: 3_163, modified: ago(14 * day)),
                SearchHit(path: "\(www)/wp-config-sample.php", isDirectory: false, size: 2_994, modified: ago(60 * day)),
                SearchHit(path: "\(www)/staging/wp-config.php", isDirectory: false, size: 3_105, modified: ago(12 * day)),
                SearchHit(path: "\(www)/wp-content/themes/acme-child/wp-config-local.php", isDirectory: false, size: 1_411, modified: ago(20 * day)),
                SearchHit(path: "\(www)/old-site/wp-config.php.bak", isDirectory: false, size: 3_040, modified: ago(210 * day)),
            ]
            app.safety.search(for: acme).seedDemo(
                root: www, hits: hits, summary: SearchSummary(hits: hits.count, usedShell: false))
        case "watchFolders":
            let link = { (connection: Int, local: String, remote: String, mirror: Bool, paused: Bool) in
                WatchLink(connectionId: id(connection), localRoot: local, remoteRoot: remote, mirrorDeletes: mirror, paused: paused)
            }
            let theme = link(1, "/Users/demo/Sites/acme/wp-content/themes/acme-child", "/home/acme/public_html/wp-content/themes/acme-child", false, false)
            let menu = link(2, "/Users/demo/Sites/bluebird/menu", "/home/bluebird/public_html/menu", true, true)
            let api = link(4, "/Users/demo/Sites/api/dist", "/srv/api/current", false, false)
            app.watches.seedDemo(
                [theme, menu, api],
                status: [
                    theme.id: WatchStatus(uploaded: 14, skipped: 3, lastActivity: Date().addingTimeInterval(-140)),
                    menu.id: WatchStatus(uploaded: 6, deleted: 1),
                    api.id: WatchStatus(uploaded: 126, skipped: 41, lastActivity: Date().addingTimeInterval(-3_000)),
                ])
        case "siteEditorSafety":
            if let c = app.allConnections.first(where: { $0.id == id(2) }) { app.editConnection(c, origin: .main) }
        case "launchPrompt":
            Task { _ = await app.prompts.askLeftovers(queued: 340, failed: 12) }
        case "conflict":
            Task {
                _ = await app.prompts.askConflict(ConflictInfo(
                    jobId: UUID(), name: "wp-config.php", route: "This Mac \u{2192} Acme Corp",
                    sourcePath: "/Users/demo/Sites/acme/wp-config.php", destinationPath: "/home/acme/public_html/wp-config.php",
                    sourceSize: 3_412, sourceModified: DemoMode.anchor.addingTimeInterval(-3_600),
                    destinationSize: 3_163, destinationModified: DemoMode.anchor.addingTimeInterval(-14 * day), direction: .upload))
            }
        case "siteEditor":
            if let c = app.allConnections.first(where: { $0.id == id(2) }) { app.editConnection(c, origin: .main) }
        case "siteEditorJump":
            if let c = app.allConnections.first(where: { $0.id == id(6) }) { app.editConnection(c, origin: .main) }
        case "importPreview", "importUnsupported", "export", "importExport":
            await app.showImportDemo(DemoMode.screen)
        case "onePasswordImport":
            app.presentOnePasswordImport { _ in }
        case "siteEditor1Password":
            if let c = app.allConnections.first(where: { $0.id == id(400) }) { app.editConnection(c, origin: .main) }
        case "healthCheck":
            await app.seedHealthDemo()
        case "recentlyRemoved":
            await app.seedRemovedDemo()
        case "quickLook":
            await app.showQuickLookDemo()
        case "terminal":
            if let bluebird { app.activate(bluebird) }
            app.drawerTab = .terminal
            app.drawerVisible = true
        case "sideBySideColumns":
            // Three colour-labelled columns, wider than the window, with the last one active.
            guard let acme, let bluebird else { return }
            try? await app.connections.update(acme.connection.id) { $0.color = .red }
            try? await app.connections.update(bluebird.connection.id) { $0.color = .teal }
            app.groupSession(bluebird.id, with: acme.id)
            if let third = app.sessions.first(where: { $0.id != acme.id && $0.id != bluebird.id }) {
                app.groupSession(third.id, with: bluebird.id)
                app.activate(third)
            }
        case "tabGroups":
            // Two tabs grouped and shown side by side at uneven widths, the third ungrouped, and a closed group.
            guard let acme, let bluebird else { return }
            app.tabGroups = [TabGroup(id: UUID(), color: .orange, connectionIDs: [id(4), id(6)])]
            app.groupSession(bluebird.id, with: acme.id)
            if let client = app.group(id: app.sessionGroups[acme.id]) { app.setColor(.blue, for: client) }
            app.columnWeights = [acme.id: 1.4, bluebird.id: 0.6]
            app.activate(acme)
        case "sideBySide":
            guard let acme, let bluebird else { return }
            app.groupSession(bluebird.id, with: acme.id)
            app.activate(acme)
            if let pane = bluebird.server {
                app.dropHint = DropHint(paneID: pane.id, text: "Drop to copy 2 files here \u{00B7} Acme Corp \u{2192} Bluebird Bakery")
            }
        case "compare":
            acme?.server?.navigate(to: "/home/acme/public_html")
            try? await Task.sleep(nanoseconds: 800_000_000)
            app.compareVisible = true
        case "editing":
            app.edits.seedDemo()
            app.showToast("Uploaded wp-config.php to Acme Corp", symbol: "arrow.up.doc")
        case "recentChanges":
            guard let acme, let entry = try? await app.journal.entries(scope: acme.scope(.server)).first else { return }
            app.showToast(entry.summary, symbol: "arrow.uturn.backward.circle", undo: UndoTarget(entry: entry, sessionID: acme.id, side: .server))
            acme.server?.requestRecentChanges()
        default:
            break
        }
    }
}
