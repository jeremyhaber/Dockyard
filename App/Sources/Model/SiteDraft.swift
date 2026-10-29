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

/// Where the SSH agent method looks for the agent.
enum AgentChoice: String, CaseIterable, Identifiable {
    case system, onePassword, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System (SSH_AUTH_SOCK)"
        case .onePassword: "1Password"
        case .custom: "Custom path"
        }
    }
}

enum SiteDraftError: Error, Equatable, CustomStringConvertible {
    case missingHost
    case invalidPort(String)
    case missingKeyPath
    case noAuthMethod
    case jump(String)
    case invalidReference(String)
    case missingAgentPath

    var description: String {
        switch self {
        case .missingHost: "Enter a host."
        case .invalidPort(let text): "\"\(text)\" is not a valid port."
        case .missingKeyPath: "Choose the private key file, or turn off SSH key."
        case .noAuthMethod: "Turn on at least one authentication method."
        case .jump(let message): message
        case .invalidReference(let what): "The 1Password reference for the \(what) must look like op://Vault/Item/field."
        case .missingAgentPath: "Enter the path of the agent socket, or choose another agent."
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
    var agentChoice = AgentChoice.system
    var agentPath = ""
    /// Secrets that come from 1Password instead of the Keychain, and their `op://` references.
    var onePasswordPurposes: Set<SecretPurpose> = []
    var references: [SecretPurpose: String] = [:]

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
    var keepVersionsOnOverwrite = false
    var trashOnDelete = false
    var verifyChecksums = false
    var transferFilters = ""
    var defaultConflict = ConflictPolicy.ask
    var maxConnections = Connection.defaultMaxConnections
    var connectDelayMs = 0
    var localFolder = ""
    var localStart = LocalStart.defaultFolder
    var localStartOverridesRestore = false
    var restoreSession = true
    var treeRoot = FolderTreeRoot.home
    var jumpHost: UUID?
    var webURLs: [WebURLMapping] = []
    var icon: ConnectionIcon?
    var color: ConnectionColor?
    var faviconSite = ""

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
        switch c.agentSocket {
        case .system: agentChoice = .system
        case .onePassword: agentChoice = .onePassword
        case .custom(let path):
            agentChoice = .custom
            agentPath = path
        }
        references = c.secretReferences
        onePasswordPurposes = Set(c.secretReferences.keys)
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
        keepVersionsOnOverwrite = c.keepVersionsOnOverwrite
        trashOnDelete = c.trashOnDelete
        verifyChecksums = c.verifyChecksums
        transferFilters = c.transferFilters.joined(separator: "\n")
        defaultConflict = c.defaultConflictAction ?? .ask
        maxConnections = c.maxConnections
        connectDelayMs = c.connectDelayMs
        localFolder = c.localFolder ?? ""
        localStart = c.localStart
        localStartOverridesRestore = c.localStartOverridesRestore
        restoreSession = c.restoreSession
        treeRoot = c.treeRoot
        jumpHost = c.jumpHost
        webURLs = c.webURLs
        icon = c.icon
        color = c.color
        faviconSite = c.faviconSite ?? ""
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

        if proto == .sftp, useAgent, agentChoice == .custom, agentPath.trimmingCharacters(in: .whitespaces).isEmpty {
            throw SiteDraftError.missingAgentPath
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
        c.keepVersionsOnOverwrite = keepVersionsOnOverwrite
        c.trashOnDelete = trashOnDelete
        c.verifyChecksums = proto == .sftp && verifyChecksums
        c.transferFilters = transferFilters.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        c.defaultConflictAction = defaultConflict == .ask ? nil : defaultConflict
        c.maxConnections = min(max(maxConnections, Connection.maxConnectionsRange.lowerBound), Connection.maxConnectionsRange.upperBound)
        c.connectDelayMs = max(0, connectDelayMs)
        c.localFolder = localFolder.trimmingCharacters(in: .whitespaces).isEmpty ? nil : localFolder
        c.localStart = localStart == .folder && c.localFolder == nil ? .defaultFolder : localStart
        c.localStartOverridesRestore = localStartOverridesRestore
        c.restoreSession = restoreSession
        c.treeRoot = treeRoot
        c.jumpHost = proto == .sftp ? jumpHost : nil
        c.webURLs = webURLs
        c.icon = icon
        c.color = color
        let site = faviconSite.trimmingCharacters(in: .whitespaces)
        c.faviconSite = site.isEmpty ? nil : site
        c.cloud = isCloud ? cloudPreset.spec(root: cloudRoot, region: cloudRegion) : nil
        c.agentSocket = agentSocket(for: proto)
        c.secretReferences = try secretReferences()
        return c
    }

    private func agentSocket(for proto: ConnectionProtocol) -> AgentSocket {
        guard proto == .sftp, useAgent else { return .system }
        switch agentChoice {
        case .system: return .system
        case .onePassword: return .onePassword
        case .custom: return .custom(agentPath.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Whether the editor shows a source choice for `purpose` with the current protocol and options.
    func offers(_ purpose: SecretPurpose) -> Bool {
        switch (protocolChoice, purpose) {
        case (.sftp, .password): usePassword
        case (.sftp, .keyPassphrase): useKey
        case (.sftp, .elevationPassword): elevation != .none
        case (.ftp, .password), (.ftps, .password): true
        default: false
        }
    }

    private func secretReferences() throws -> [SecretPurpose: String] {
        var out: [SecretPurpose: String] = [:]
        for purpose in [SecretPurpose.password, .keyPassphrase, .elevationPassword] where onePasswordPurposes.contains(purpose) && offers(purpose) {
            let text = (references[purpose] ?? "").trimmingCharacters(in: .whitespaces)
            guard OnePasswordCLI.isValidReference(text) else { throw SiteDraftError.invalidReference(Self.name(of: purpose)) }
            out[purpose] = text
        }
        return out
    }

    static func name(of purpose: SecretPurpose) -> String {
        switch purpose {
        case .password: "password"
        case .keyPassphrase: "key passphrase"
        case .elevationPassword: "elevation password"
        case .cloudToken: "cloud secret"
        }
    }

    /// Secrets that were typed in; empty fields leave the stored value alone.
    var secretsToStore: [(SecretPurpose, String)] {
        var out: [(SecretPurpose, String)] = []
        if protocolChoice == .cloud {
            if !cloudSecret.isEmpty { out.append((.cloudToken, cloudSecret)) }
            return out
        }
        if !password.isEmpty, !onePasswordPurposes.contains(.password) { out.append((.password, password)) }
        if !keyPassphrase.isEmpty, !onePasswordPurposes.contains(.keyPassphrase) { out.append((.keyPassphrase, keyPassphrase)) }
        if !elevationPassword.isEmpty, !onePasswordPurposes.contains(.elevationPassword) { out.append((.elevationPassword, elevationPassword)) }
        return out
    }
}
