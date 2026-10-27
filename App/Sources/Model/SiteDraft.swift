import ConnectionKit
import DockyardCore
import Foundation

enum DraftProtocol: String, CaseIterable, Identifiable {
    case sftp = "SFTP", ftp = "FTP", ftps = "FTPS", cloud = "Cloud"
    var id: String { rawValue }

    var connectionProtocol: ConnectionProtocol {
        switch self {
        case .sftp: .sftp
        case .ftp: .ftp
        case .ftps: .ftps
        case .cloud: .rclone
        }
    }
}

enum SiteDraftError: Error, Equatable, CustomStringConvertible {
    case missingHost
    case invalidPort(String)
    case missingKeyPath
    case noAuthMethod

    var description: String {
        switch self {
        case .missingHost: "Enter a host."
        case .invalidPort(let text): "\"\(text)\" is not a valid port."
        case .missingKeyPath: "Choose the private key file, or turn off SSH key."
        case .noAuthMethod: "Turn on at least one authentication method."
        }
    }
}

/// Everything the site editor edits, as plain text fields. Secrets are kept apart and only written when non-empty.
struct SiteDraft {
    var original: Connection?
    var id = UUID()
    var name = ""
    var clientFolderId: UUID?
    var protocolChoice = DraftProtocol.sftp
    var host = ""
    var port = ""
    var username = ""

    var useKey = false
    var keyPath = ""
    var usePassword = true
    var useAgent = false
    var password = ""
    var keyPassphrase = ""

    var elevation = Elevation.none
    var elevationPassword = ""
    var elevateFileBrowsing = false
    var askBeforeElevatingOnProd = true

    var isProd = false
    var favorite = false
    var tags = ""
    var notes = ""
    var mountInFinder = false
    var mountOnLaunch = false
    var mountReadOnly = false
    var readOnly = false
    var localFolder = ""
    var restoreSession = true

    var cloudPresetID = "s3"
    var cloudRoot = ""
    var cloudRegion = ""
    var cloudSecret = ""

    var isNew: Bool { original == nil }

    init() {}

    init(connection c: Connection) {
        original = c
        id = c.id
        name = c.name
        clientFolderId = c.clientFolderId
        switch c.protocol {
        case .sftp: protocolChoice = .sftp
        case .ftp: protocolChoice = .ftp
        case .ftps: protocolChoice = .ftps
        case .rclone: protocolChoice = .cloud
        }
        host = c.host
        port = c.protocol == .rclone || c.port == c.protocol.defaultPort ? "" : String(c.port)
        username = c.username
        useKey = c.authMethods.contains(.key)
        keyPath = c.keyPath ?? ""
        usePassword = c.authMethods.contains(.password)
        useAgent = c.authMethods.contains(.agent)
        elevation = c.elevation
        elevateFileBrowsing = c.elevateFileBrowsing
        askBeforeElevatingOnProd = c.askBeforeElevatingOnProd
        isProd = c.isProd
        favorite = c.favorite
        tags = c.tags.joined(separator: ", ")
        notes = c.notes
        mountInFinder = c.mountInFinder
        mountOnLaunch = c.mountOnLaunch
        mountReadOnly = c.mountReadOnly
        readOnly = c.readOnly
        localFolder = c.localFolder ?? ""
        restoreSession = c.restoreSession
        if let cloud = c.cloud {
            cloudPresetID = CloudPreset.preset(for: cloud)?.id ?? "s3"
            cloudRoot = cloud.root
            cloudRegion = cloud.options["region"] ?? ""
        }
    }

    var cloudPreset: CloudPreset { CloudPreset.preset(id: cloudPresetID) ?? CloudPreset.all[0] }

    var parsedTags: [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Validates and builds the `Connection`, keeping fields the editor does not show from the original.
    func connection() throws -> Connection {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let proto = protocolChoice.connectionProtocol
        let isCloud = proto == .rclone
        let needsHost = !isCloud || cloudPreset.hostLabel != nil
        if needsHost, trimmedHost.isEmpty { throw SiteDraftError.missingHost }
        var portNumber = proto.defaultPort
        let trimmedPort = port.trimmingCharacters(in: .whitespaces)
        if !trimmedPort.isEmpty {
            guard let p = Int(trimmedPort), (1...65535).contains(p) else { throw SiteDraftError.invalidPort(trimmedPort) }
            portNumber = p
        }

        var auth: AuthMethods = []
        if proto == .sftp {
            if useKey { auth.insert(.key) }
            if usePassword { auth.insert(.password) }
            if useAgent { auth.insert(.agent) }
            if auth.isEmpty { throw SiteDraftError.noAuthMethod }
            if useKey, keyPath.trimmingCharacters(in: .whitespaces).isEmpty { throw SiteDraftError.missingKeyPath }
        } else {
            auth = .password
        }

        var c = original ?? Connection(name: "", host: trimmedHost, username: "")
        c.id = id
        c.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? (trimmedHost.isEmpty ? cloudPreset.title : trimmedHost) : name
        c.clientFolderId = clientFolderId
        c.protocol = proto
        c.host = trimmedHost
        c.port = isCloud ? 0 : portNumber
        c.username = username.trimmingCharacters(in: .whitespaces)
        c.authMethods = auth
        c.keyPath = proto == .sftp && useKey ? keyPath.trimmingCharacters(in: .whitespaces) : nil
        c.elevation = proto == .sftp ? elevation : .none
        c.elevateFileBrowsing = proto == .sftp && elevation != .none && elevateFileBrowsing
        c.askBeforeElevatingOnProd = askBeforeElevatingOnProd
        c.isProd = isProd
        c.favorite = favorite
        c.tags = parsedTags
        c.notes = notes
        c.mountInFinder = mountInFinder
        c.mountOnLaunch = mountOnLaunch
        c.mountReadOnly = mountReadOnly
        c.readOnly = readOnly
        c.localFolder = localFolder.trimmingCharacters(in: .whitespaces).isEmpty ? nil : localFolder
        c.restoreSession = restoreSession
        c.cloud = isCloud ? cloudPreset.spec(root: cloudRoot, region: cloudRegion) : nil
        return c
    }

    /// Secrets that were typed in; empty fields leave the stored value alone.
    var secretsToStore: [(SecretPurpose, String)] {
        var out: [(SecretPurpose, String)] = []
        if protocolChoice == .cloud {
            if !cloudSecret.isEmpty { out.append((.cloudToken, cloudSecret)) }
            return out
        }
        if !password.isEmpty { out.append((.password, password)) }
        if !keyPassphrase.isEmpty { out.append((.keyPassphrase, keyPassphrase)) }
        if !elevationPassword.isEmpty { out.append((.elevationPassword, elevationPassword)) }
        return out
    }
}
