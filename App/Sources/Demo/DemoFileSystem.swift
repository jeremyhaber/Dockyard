import ConnectionKit
import Foundation

/// An in-memory file system with a plausible tree. Used for both panes in demo mode; no network, no disk.
final class DemoFileSystem: RemoteFileSystem {
    enum Kind { case server, local }
    enum Flavor { case acme, bluebird }

    private struct State {
        var folders: [String: [RemoteItem]]
    }

    private let kind: Kind
    private let flavor: Flavor
    private let shell: Bool
    let browsesAsRoot: Bool
    private let hub = LogHub()
    private let state: LockedBox<State>

    var logStream: AsyncStream<LogLine> { hub.stream() }
    var supportsShell: Bool { shell }

    init(kind: Kind, flavor: Flavor = .acme, shell: Bool = false, browsesAsRoot: Bool = false) {
        self.kind = kind
        self.flavor = flavor
        self.shell = shell
        self.browsesAsRoot = browsesAsRoot
        let folders: [String: [RemoteItem]]
        switch (kind, flavor) {
        case (.local, _): folders = Self.localTree()
        case (.server, .acme): folders = Self.serverTree()
        case (.server, .bluebird): folders = Self.bluebirdTree()
        }
        state = LockedBox(State(folders: folders))
    }

    // MARK: RemoteFileSystem

    func connect() async throws {
        guard kind == .server else { return }
        if flavor == .bluebird {
            hub.emit(.status, "Connecting to bluebirdbakery.example:22...")
            hub.emit(.status, "Host key ssh-ed25519 trusted")
            hub.emit(.status, "Authenticated with publickey, then password")
            hub.emit(.status, browsesAsRoot ? "Browsing files as root" : "SFTP subsystem ready")
            return
        }
        hub.emit(.status, "Resolving ftp.acmecorp.example")
        hub.emit(.status, "Connecting to 203.0.113.24:21...")
        hub.emit(.response, "220 ProFTPD Server (acmecorp) ready.")
        hub.emit(.command, "AUTH TLS")
        hub.emit(.response, "234 AUTH TLS successful")
        hub.emit(.status, "TLS connection established, cipher TLS_AES_256_GCM_SHA384")
        hub.emit(.command, "USER acme")
        hub.emit(.response, "331 Password required for acme")
        hub.emit(.command, "PASS ****")
        hub.emit(.response, "230 User acme logged in")
        hub.emit(.command, "FEAT")
        hub.emit(.response, "211-Features: MLST type*;size*;modify*;perm*; MLSD EPSV UTF8 REST STREAM")
        hub.emit(.command, "PWD")
        hub.emit(.response, "257 \"/home/acme\" is the current directory")
        hub.emit(.status, "Connected")
    }

    func disconnect() async {}

    func homeDirectory() async throws -> String {
        switch (kind, flavor) {
        case (.local, _): "/Users/demo"
        case (.server, .acme): "/home/acme"
        case (.server, .bluebird): "/home/bluebird"
        }
    }

    func list(_ path: String) async throws -> [RemoteItem] {
        let normalized = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let items = state.withLock({ $0.folders[normalized] }) else { throw RemoteError.notFound(path) }
        if kind == .server, flavor == .bluebird {
            hub.emit(.status, "Listing directory \(normalized)")
        } else if kind == .server {
            hub.emit(.command, "PASV")
            hub.emit(.response, "227 Entering Passive Mode (203,0,113,24,195,80)")
            hub.emit(.command, "MLSD \(normalized)")
            hub.emit(.response, "150 Opening ASCII mode data connection for MLSD")
            hub.emit(.response, "226 Transfer complete, \(items.count) entries")
        }
        return items
    }

    func download(_ remote: String, to local: URL, progress: Progress, resume: Bool) async throws {
        let total = progress.totalUnitCount > 0 ? progress.totalUnitCount : 480_000_000
        progress.totalUnitCount = total
        // Jump to a fixed point and hold so screenshots always show the same state.
        progress.completedUnitCount = total * 62 / 100
        hub.emit(.command, "RETR \(remote)")
        hub.emit(.response, "150 Opening BINARY mode data connection for \(remote)")
        while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }

    func upload(_ local: URL, to remote: String, progress: Progress, resume: Bool) async throws {
        progress.completedUnitCount = progress.totalUnitCount
    }

    func mkdir(_ path: String) async throws {
        state.withLock { s in
            s.folders[path] = []
            let parent = RemotePath.parent(of: path)
            s.folders[parent, default: []].append(
                RemoteItem(name: RemotePath.lastComponent(of: path), path: path, isDirectory: true, modified: DemoMode.anchor, permissions: 0o755))
        }
    }

    func rename(_ from: String, _ to: String) async throws {}
    func delete(_ path: String, recursive: Bool) async throws {}
    func chmod(_ path: String, mode: UInt16) async throws {}

    // MARK: Trees

    private static func dir(_ base: String, _ name: String, ageDays: Double, perms: UInt16 = 0o755) -> RemoteItem {
        RemoteItem(name: name, path: RemotePath.join(base, name), isDirectory: true,
                   modified: DemoMode.anchor.addingTimeInterval(-ageDays * 86_400), permissions: perms)
    }

    private static func file(_ base: String, _ name: String, size: UInt64, ageDays: Double, perms: UInt16 = 0o644) -> RemoteItem {
        RemoteItem(name: name, path: RemotePath.join(base, name), isDirectory: false, size: size,
                   modified: DemoMode.anchor.addingTimeInterval(-ageDays * 86_400), permissions: perms)
    }

    private static func serverTree() -> [String: [RemoteItem]] {
        var t: [String: [RemoteItem]] = [:]
        let home = "/home/acme"
        let www = "\(home)/public_html"
        let content = "\(www)/wp-content"
        t["/"] = [dir("/", "home", ageDays: 400), dir("/", "etc", ageDays: 400), dir("/", "var", ageDays: 400), dir("/", "tmp", ageDays: 1, perms: 0o1777)]
        t["/home"] = [dir("/home", "acme", ageDays: 2)]
        t["/etc"] = []
        t["/var"] = []
        t["/tmp"] = []
        t[home] = [
            dir(home, "public_html", ageDays: 1), dir(home, "logs", ageDays: 0), dir(home, "backups", ageDays: 1),
            dir(home, "mail", ageDays: 3), dir(home, "ssl", ageDays: 90, perms: 0o700), dir(home, "tmp", ageDays: 5),
            file(home, ".bash_profile", size: 141, ageDays: 400), file(home, ".bashrc", size: 231, ageDays: 400),
            file(home, ".htpasswd", size: 98, ageDays: 120, perms: 0o600),
        ]
        t[www] = [
            dir(www, "wp-admin", ageDays: 30), dir(www, "wp-content", ageDays: 0), dir(www, "wp-includes", ageDays: 30),
            dir(www, "cgi-bin", ageDays: 200), dir(www, "staging", ageDays: 12),
            file(www, ".htaccess", size: 1_024, ageDays: 14), file(www, "index.php", size: 405, ageDays: 30),
            file(www, "license.txt", size: 19_915, ageDays: 30), file(www, "readme.html", size: 7_425, ageDays: 30),
            file(www, "robots.txt", size: 212, ageDays: 40), file(www, "wp-config.php", size: 3_163, ageDays: 14, perms: 0o640),
            file(www, "wp-cron.php", size: 5_543, ageDays: 30), file(www, "wp-login.php", size: 50_917, ageDays: 30),
            file(www, "xmlrpc.php", size: 3_236, ageDays: 30), file(www, "error_log", size: 2_318_407, ageDays: 0),
        ]
        t["\(www)/wp-admin"] = [dir("\(www)/wp-admin", "css", ageDays: 30), dir("\(www)/wp-admin", "js", ageDays: 30), file("\(www)/wp-admin", "index.php", size: 7_976, ageDays: 30)]
        t["\(www)/wp-includes"] = []
        t["\(www)/cgi-bin"] = []
        t["\(www)/staging"] = [file("\(www)/staging", "index.html", size: 512, ageDays: 12)]
        t[content] = [
            dir(content, "plugins", ageDays: 3), dir(content, "themes", ageDays: 20), dir(content, "uploads", ageDays: 0),
            dir(content, "cache", ageDays: 0), dir(content, "languages", ageDays: 60), file(content, "index.php", size: 28, ageDays: 400),
        ]
        let plugins = ["akismet", "contact-form-7", "elementor", "wordpress-seo", "woocommerce", "wp-super-cache", "updraftplus",
                       "redirection", "query-monitor", "classic-editor", "really-simple-ssl", "wordfence"]
        t["\(content)/plugins"] = plugins.enumerated().map { dir("\(content)/plugins", $1, ageDays: Double($0 * 3 + 2)) }
        for p in plugins { t["\(content)/plugins/\(p)"] = [file("\(content)/plugins/\(p)", "\(p).php", size: 14_320, ageDays: 20)] }
        t["\(content)/themes"] = [dir("\(content)/themes", "acme-child", ageDays: 20), dir("\(content)/themes", "twentytwentyfive", ageDays: 90)]
        t["\(content)/themes/acme-child"] = [file("\(content)/themes/acme-child", "style.css", size: 4_212, ageDays: 20), file("\(content)/themes/acme-child", "functions.php", size: 6_033, ageDays: 20)]
        t["\(content)/themes/twentytwentyfive"] = []
        t["\(content)/languages"] = []
        t["\(content)/cache"] = (1...36).map { file("\(content)/cache", String(format: "page-%04d.html.gz", $0 * 37), size: UInt64(2_000 + $0 * 311), ageDays: 0) }
        let uploads = "\(content)/uploads"
        t[uploads] = [dir(uploads, "2024", ageDays: 400), dir(uploads, "2025", ageDays: 200), dir(uploads, "2026", ageDays: 0)]
        t["\(uploads)/2024"] = []
        t["\(uploads)/2025"] = [dir("\(uploads)/2025", "11", ageDays: 330), dir("\(uploads)/2025", "12", ageDays: 300)]
        t["\(uploads)/2025/11"] = []
        t["\(uploads)/2025/12"] = []
        t["\(uploads)/2026"] = [dir("\(uploads)/2026", "09", ageDays: 40), dir("\(uploads)/2026", "10", ageDays: 0)]
        t["\(uploads)/2026/09"] = []
        let month = "\(uploads)/2026/10"
        var photos: [RemoteItem] = []
        for i in 1...320 {
            let base = String(format: "IMG_%04d", 4_000 + i * 3)
            photos.append(file(month, "\(base).jpg", size: UInt64(180_000 + (i * 7_919) % 2_400_000), ageDays: Double(i % 24) / 2))
        }
        t[month] = photos
        let logs = "\(home)/logs"
        var logFiles: [RemoteItem] = []
        for i in 0..<30 {
            let number = String(format: "%02d", 30 - i)
            logFiles.append(file(logs, "access-\(number)-Sep.gz", size: UInt64(40_000 + i * 9_113), ageDays: Double(i + 30)))
        }
        logFiles.append(file(logs, "access.log", size: 18_204_113, ageDays: 0))
        logFiles.append(file(logs, "error.log", size: 412_880, ageDays: 0))
        t[logs] = logFiles
        let backups = "\(home)/backups"
        t[backups] = [
            file(backups, "db-2026-10-26.sql.gz", size: 480_000_000, ageDays: 1, perms: 0o600),
            file(backups, "db-2026-10-19.sql.gz", size: 471_300_000, ageDays: 8, perms: 0o600),
            file(backups, "site-2026-10-01.tar.gz", size: 1_820_000_000, ageDays: 26, perms: 0o600),
        ]
        t["\(home)/mail"] = []
        t["\(home)/ssl"] = [file("\(home)/ssl", "acmecorp.example.crt", size: 3_412, ageDays: 60, perms: 0o600)]
        t["\(home)/tmp"] = []
        return t
    }

    private static func bluebirdTree() -> [String: [RemoteItem]] {
        var t: [String: [RemoteItem]] = [:]
        let home = "/home/bluebird"
        let www = "\(home)/public_html"
        t["/"] = [dir("/", "home", ageDays: 400), dir("/", "etc", ageDays: 400), dir("/", "var", ageDays: 400)]
        t["/home"] = [dir("/home", "bluebird", ageDays: 1)]
        t["/etc"] = []
        t["/var"] = []
        t[home] = [
            dir(home, "public_html", ageDays: 0), dir(home, "backups", ageDays: 2), dir(home, "logs", ageDays: 0),
            file(home, ".bashrc", size: 231, ageDays: 300),
        ]
        t[www] = [
            dir(www, "shop", ageDays: 1), dir(www, "wp-content", ageDays: 2), dir(www, "menu", ageDays: 9),
            file(www, "index.php", size: 405, ageDays: 40), file(www, "wp-config.php", size: 3_201, ageDays: 20, perms: 0o640),
            file(www, "order-export.csv", size: 82_144, ageDays: 1), file(www, "robots.txt", size: 180, ageDays: 90),
        ]
        t["\(www)/shop"] = [
            file("\(www)/shop", "cart.php", size: 12_880, ageDays: 1), file("\(www)/shop", "checkout.php", size: 9_412, ageDays: 3),
        ]
        t["\(www)/wp-content"] = [dir("\(www)/wp-content", "uploads", ageDays: 1), dir("\(www)/wp-content", "themes", ageDays: 30)]
        t["\(www)/wp-content/uploads"] = []
        t["\(www)/wp-content/themes"] = []
        t["\(www)/menu"] = [
            file("\(www)/menu", "spring.pdf", size: 412_300, ageDays: 9), file("\(www)/menu", "winter.pdf", size: 398_114, ageDays: 40),
        ]
        t["\(home)/backups"] = [file("\(home)/backups", "shop-2026-10-24.tar.gz", size: 212_000_000, ageDays: 2, perms: 0o600)]
        t["\(home)/logs"] = [
            file("\(home)/logs", "access.log", size: 5_204_113, ageDays: 0), file("\(home)/logs", "error.log", size: 31_880, ageDays: 0),
        ]
        return t
    }

    private static func localTree() -> [String: [RemoteItem]] {
        var t: [String: [RemoteItem]] = [:]
        let home = "/Users/demo"
        t["/"] = [dir("/", "Applications", ageDays: 100), dir("/", "Library", ageDays: 100), dir("/", "Users", ageDays: 100), dir("/", "Volumes", ageDays: 100)]
        t["/Applications"] = []
        t["/Library"] = []
        t["/Volumes"] = []
        t["/Users"] = [dir("/Users", "demo", ageDays: 0)]
        t[home] = [
            dir(home, "Desktop", ageDays: 2), dir(home, "Documents", ageDays: 5), dir(home, "Downloads", ageDays: 0),
            dir(home, "Sites", ageDays: 1), dir(home, "Pictures", ageDays: 30),
        ]
        t["\(home)/Desktop"] = []
        t["\(home)/Pictures"] = []
        t["\(home)/Documents"] = [dir("\(home)/Documents", "Invoices", ageDays: 9), file("\(home)/Documents", "hosting-notes.txt", size: 2_144, ageDays: 5)]
        t["\(home)/Documents/Invoices"] = []
        let sites = "\(home)/Sites"
        t[sites] = [dir(sites, "acme", ageDays: 1), dir(sites, "bluebird", ageDays: 6), dir(sites, "fjord-marine", ageDays: 11)]
        t["\(sites)/bluebird"] = []
        t["\(sites)/fjord-marine"] = []
        let acme = "\(sites)/acme"
        t[acme] = [
            dir(acme, "wp-content", ageDays: 1), file(acme, "index.php", size: 405, ageDays: 3), file(acme, "wp-config.php", size: 3_163, ageDays: 14, perms: 0o640),
            file(acme, "style-new.css", size: 18_442, ageDays: 0), file(acme, "hero-banner.jpg", size: 1_204_881, ageDays: 0),
            file(acme, "deploy-notes.md", size: 1_990, ageDays: 1),
        ]
        t["\(acme)/wp-content"] = [dir("\(acme)/wp-content", "themes", ageDays: 1)]
        t["\(acme)/wp-content/themes"] = []
        let downloads = "\(home)/Downloads"
        t[downloads] = [
            file(downloads, "acme-logo.svg", size: 8_120, ageDays: 0, perms: 0o644), file(downloads, "invoice-1042.pdf", size: 96_318, ageDays: 2),
            file(downloads, "plugin-update.zip", size: 4_812_330, ageDays: 1), file(downloads, "wordpress-6.8.zip", size: 26_018_113, ageDays: 6),
            dir(downloads, "exports", ageDays: 4),
        ]
        t["\(downloads)/exports"] = []
        return t
    }
}
