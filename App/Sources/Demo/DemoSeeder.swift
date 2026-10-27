import ConnectionKit
import DockyardCore
import Foundation

/// Fills the in-memory database with sample data and opens the demo connection. Only runs in demo mode.
@MainActor
enum DemoSeeder {
    private static func id(_ n: Int) -> UUID {
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
            lastConnectedAt: ago(0.5 * hour), createdAt: ago(200 * day), initialRemotePath: "/home/acme/public_html",
            localFolder: "/Users/demo/Sites/acme"))
        list.append(Connection(
            id: id(2), name: "Bluebird Bakery", clientFolderId: folderIDs["Bluebird Bakery"], protocol: .sftp,
            host: "bluebirdbakery.example", username: "bluebird", authMethods: .both, keyPath: "~/.ssh/id_ed25519",
            elevation: .sudo, elevateFileBrowsing: true, isProd: true, favorite: true, tags: ["shop"],
            lastConnectedAt: ago(2 * hour), createdAt: ago(180 * day)))
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

        try? await app.connections.save(list)

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

        try? await Task.sleep(nanoseconds: 900_000_000)
        enqueueTransfers(app)
        if let session = app.session(for: acme.id) {
            session.log.append(.command, "STOR archive-2026.zip")
            session.log.append(.error, "550 archive-2026.zip: Permission denied")
        }
        applyScreen(app)
    }

    private static func enqueueTransfers(_ app: AppModel) {
        let source = TransferEndpoint(fs: DemoFileSystem(kind: .server), label: "Acme Corp")
        let target = TransferEndpoint.thisMac()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dockyard-demo").path
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
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

    /// Opens the screen named by `-DockyardDemoScreen`. `connectionManager` is handled by the main window.
    static func applyScreen(_ app: AppModel) {
        switch DemoMode.screen {
        case "logDrawer":
            app.drawerTab = .log
            app.drawerVisible = true
        case "jump":
            app.jumpVisible = true
        case "siteEditor":
            if let c = app.allConnections.first(where: { $0.id == id(2) }) { app.editConnection(c, origin: .main) }
        default:
            break
        }
    }
}
