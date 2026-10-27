import ConnectionKit
import DockyardCore
import Foundation
import RcloneKit

enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Dockyard", isDirectory: true)
    }

    static var databaseURL: URL { supportDirectory.appendingPathComponent("dockyard.sqlite") }

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
        #if canImport(Security)
        KeychainSecretStore(useDataProtectionKeychain: false)
        #else
        InMemorySecretStore()
        #endif
    }

    static func make(
        for connection: Connection, secrets: any SecretStore, hostKeyValidator: SSHHostKeyValidator
    ) throws -> any RemoteFileSystem {
        switch connection.protocol {
        case .sftp:
            return SFTPFileSystem(config: connection.config, secrets: secrets, hostKeyValidator: hostKeyValidator)
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
