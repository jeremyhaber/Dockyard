import ConnectionKit
import DockyardCore
import Foundation
import RcloneKit

enum AppPaths {
    /// The App Group container when the build is signed (the Finder extension reads the database there), else Application Support.
    static var supportDirectory: URL { AppGroup.supportDirectory }

    static var databaseURL: URL { AppGroup.databaseURL }

    /// One-time move of the database from Application Support into the App Group container.
    static func migrateDatabaseIfNeeded() {
        let target = AppGroup.databaseURL
        let source = AppGroup.legacySupportDirectory.appendingPathComponent("dockyard.sqlite")
        let fm = FileManager.default
        guard source != target, fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { return }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let from = URL(fileURLWithPath: source.path + suffix)
                let to = URL(fileURLWithPath: target.path + suffix)
                if fm.fileExists(atPath: from.path) { try fm.moveItem(at: from, to: to) }
            }
        } catch {
            NSLog("Dockyard: could not move the database to the App Group container: \(error.localizedDescription)")
        }
    }

    static var logsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Dockyard", isDirectory: true)
    }
}

enum AppError: Error, LocalizedError {
    case rcloneNotBundled
    case cancelled
    case message(String)

    var errorDescription: String? {
        switch self {
        case .rcloneNotBundled:
            "The rclone library is not bundled with this build of Dockyard, so cloud connections are unavailable. Build it with scripts/build-librclone.sh and rebuild the app."
        case .cancelled: "Cancelled"
        case .message(let text): text
        }
    }
}

extension Error {
    /// Text for alerts and the status line.
    var userMessage: String {
        if let app = self as? AppError { return app.errorDescription ?? "\(self)" }
        if let remote = self as? RemoteError { return remote.description }
        if let rpc = self as? RcloneRPCError { return rpc.message }
        return (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}

enum FileSystemFactory {
    static func secretStore() -> any SecretStore {
        if DemoMode.isEnabled { return InMemorySecretStore() }
        #if canImport(Security)
        // Signed builds share items with the Finder extension through the data-protection keychain.
        if let group = AppGroup.keychainAccessGroup {
            return KeychainSecretStore(accessGroup: group, useDataProtectionKeychain: true)
        }
        return KeychainSecretStore(useDataProtectionKeychain: false)
        #else
        return InMemorySecretStore()
        #endif
    }

    /// The store used before a build gained the keychain group; its items are copied over once.
    static func legacySecretStore() -> any SecretStore {
        #if canImport(Security)
        return KeychainSecretStore(useDataProtectionKeychain: false)
        #else
        return InMemorySecretStore()
        #endif
    }

    static func make(
        for connection: Connection, secrets: any SecretStore, hostKeyValidator: SSHHostKeyValidator, browseAsRoot: Bool = false
    ) throws -> any RemoteFileSystem {
        if DemoMode.isEnabled {
            return DemoFileSystem(
                kind: .server, flavor: connection.host.hasPrefix("bluebird") ? .bluebird : .acme,
                shell: connection.protocol == .sftp, browsesAsRoot: browseAsRoot)
        }
        switch connection.protocol {
        case .sftp:
            return SFTPFileSystem(
                config: connection.config, secrets: secrets, hostKeyValidator: hostKeyValidator,
                options: SFTPFileSystem.Options(browseAsRoot: browseAsRoot && connection.elevation != .none))
        case .ftp, .ftps:
            return FTPFileSystem(config: connection.config, secrets: secrets)
        case .rclone:
            guard let cloud = connection.cloud, let backend = RcloneBackend(rawValue: cloud.backend) else {
                throw AppError.message("This cloud connection has no storage provider configured. Open it in the site editor.")
            }
            let spec = RcloneRemoteSpec(backend: backend, options: cloud.options, root: cloud.root)
            return try RcloneFileSystem(config: connection.config, spec: spec, secrets: secrets, library: try loadRclone())
        }
    }

    static func loadRclone() throws -> RcloneLibrary {
        do {
            return try RcloneLibrary.load()
        } catch RcloneLibraryError.notFound {
            throw AppError.rcloneNotBundled
        }
    }

    static func rules(for connection: Connection) -> PathRules {
        connection.cloud?.listsBuckets == true ? .cloudBucket : .filesystem
    }
}
