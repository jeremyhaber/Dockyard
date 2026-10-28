import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ConnectionKit

public struct FileZillaSite: Sendable, Equatable {
    public var name: String
    /// Nested FileZilla folders from the outermost to the one containing the site.
    public var folderPath: [String]
    public var `protocol`: ConnectionProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var authMethods: AuthMethods
    public var keyPath: String?
    /// Only set when FileZilla stored it without a master password.
    public var password: String?
    /// The site asks for the password on connect (logon type "ask" / "interactive", nothing saved, or encrypted).
    public var needsPasswordPrompt: Bool
    /// A password was stored but encrypted with FileZilla's master password; it was not imported.
    public var passwordWasEncrypted: Bool
    public var notes: String

    /// Client folder name for this site: nested folders joined with " / ".
    public var clientFolderName: String? { folderPath.isEmpty ? nil : folderPath.joined(separator: " / ") }
}

public struct FileZillaParseResult: Sendable, Equatable {
    public var sites: [FileZillaSite] = []
    /// Human readable notes about skipped sites and passwords that could not be imported.
    public var warnings: [String] = []
    public var masterPasswordDetected: Bool { sites.contains { $0.passwordWasEncrypted } }
}

public enum FileZillaImportError: Error, Equatable {
    case notASiteManagerFile
    case malformedXML(String)
}

public enum FileZillaParser {
    /// `~/.config/filezilla/sitemanager.xml` on macOS and Linux.
    public static func defaultPath(home: String) -> String { RemotePath.join(home, ".config/filezilla/sitemanager.xml") }

    public static func parse(_ xml: String) throws -> FileZillaParseResult { try parse(Data(xml.utf8)) }

    public static func parse(_ data: Data) throws -> FileZillaParseResult {
        let delegate = SiteManagerDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw FileZillaImportError.malformedXML(parser.parserError?.localizedDescription ?? "unknown error")
        }
        guard delegate.sawRoot else { throw FileZillaImportError.notASiteManagerFile }
        return delegate.result
    }

    /// FileZilla protocol numbers. nil = not supported by Dockyard.
    static func mapProtocol(_ code: Int) -> ConnectionProtocol? {
        switch code {
        case 0, 6: .ftp       // FTP, insecure FTP
        case 1: .sftp
        case 3, 4: .ftps      // implicit and explicit TLS
        default: nil
        }
    }

    static func protocolName(_ code: Int) -> String {
        switch code {
        case 2: "HTTP"
        case 5: "HTTPS"
        case 7: "S3"
        case 8: "Storj"
        case 9: "WebDAV"
        default: "protocol \(code)"
        }
    }
}

private final class SiteManagerDelegate: NSObject, XMLParserDelegate {
    struct RawServer {
        var fields: [String: String] = [:]
        var passEncoding: String?
    }

    var result = FileZillaParseResult()
    var sawRoot = false

    private var stack: [String] = []
    private var folders: [String] = []          // names of the open Folder elements
    private var folderText: [String] = []       // text collected directly inside each open Folder
    private var folderNamed: [Bool] = []
    private var server: RawServer?
    private var field: String?
    private var buffer = ""
    private var bookmarkDepth = 0

    /// A folder's name is the text before its first child element.
    private func nameOpenFolderIfNeeded() {
        guard let last = folderNamed.last, !last else { return }
        folders[folders.count - 1] = folderText[folderText.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)
        folderNamed[folderNamed.count - 1] = true
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "FileZilla3" || name == "Servers" { sawRoot = true }
        if stack.last == "Folder" { nameOpenFolderIfNeeded() }
        stack.append(name)
        switch name {
        case "Folder":
            folders.append(""); folderText.append(""); folderNamed.append(false)
        case "Server":
            server = RawServer()
        case "Bookmark":
            bookmarkDepth += 1
        default:
            if server != nil, bookmarkDepth == 0, stack.count >= 2, stack[stack.count - 2] == "Server" {
                field = name
                buffer = ""
                if name == "Pass" { server?.passEncoding = attributes["encoding"] }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil { buffer += string; return }
        if server == nil, stack.last == "Folder", let i = folderText.indices.last { folderText[i] += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: s) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { stack.removeLast() }
        switch name {
        case "Folder":
            if folderNamed.last == false { nameOpenFolderIfNeeded() }
            _ = folders.popLast(); _ = folderText.popLast(); _ = folderNamed.popLast()
        case "Server":
            if let server { finish(server) }
            server = nil
        case "Bookmark":
            bookmarkDepth -= 1
        default:
            if let f = field, f == name {
                server?.fields[f] = buffer
                field = nil
            }
        }
    }

    private func finish(_ raw: RawServer) {
        let f = raw.fields
        func s(_ k: String) -> String { (f[k] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let host = s("Host")
        let name = s("Name").isEmpty ? host : s("Name")
        guard !host.isEmpty else {
            result.warnings.append("Skipped \"\(name)\": no host")
            return
        }
        let code = Int(s("Protocol")) ?? 0
        guard let proto = FileZillaParser.mapProtocol(code) else {
            result.warnings.append("Skipped \"\(name)\": \(FileZillaParser.protocolName(code)) is not supported")
            return
        }
        var port = Int(s("Port")) ?? 0
        if !(1...65535).contains(port) { port = proto.defaultPort }

        // Logon types: 0 anonymous, 1 normal, 2 ask, 3 interactive, 4 account, 5 key file.
        let logon = Int(s("Logontype")) ?? 1
        var user = s("User")
        var password: String?
        var encrypted = false
        var prompt = false

        if logon == 0 {
            if user.isEmpty { user = "anonymous" }
        } else if logon == 2 || logon == 3 {
            prompt = true
        } else if let stored = f["Pass"]?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            switch raw.passEncoding?.lowercased() {
            case nil:
                password = stored
            case "base64":
                if let data = Data(base64Encoded: stored), let text = String(data: data, encoding: .utf8) {
                    password = text
                } else {
                    result.warnings.append("\"\(name)\": saved password could not be decoded; you will be asked on first connect")
                    prompt = true
                }
            case "crypt":
                encrypted = true
                prompt = true
                result.warnings.append("\"\(name)\": password is protected by a FileZilla master password and was not imported")
            default:
                encrypted = true
                prompt = true
                result.warnings.append("\"\(name)\": password uses an unknown encoding and was not imported")
            }
        } else if logon != 5 {
            prompt = true  // nothing saved: ask when connecting
        }

        var auth: AuthMethods = .password
        var keyPath: String?
        if logon == 5 {
            let key = s("Keyfile")
            keyPath = key.isEmpty ? nil : key
            auth = password == nil ? .key : .both
        }

        result.sites.append(FileZillaSite(
            name: name, folderPath: folders.filter { !$0.isEmpty }, protocol: proto, host: host, port: port, username: user,
            authMethods: auth, keyPath: keyPath, password: password, needsPasswordPrompt: prompt,
            passwordWasEncrypted: encrypted, notes: s("Comments")))
    }
}

public struct FileZillaImportSummary: Sendable, Equatable {
    public var created = 0
    public var skippedDuplicates = 0
    public var foldersCreated = 0
    public var passwordsStored = 0
    /// Connections that will ask for a password on first connect.
    public var needingPassword = 0
    public var warnings: [String] = []
}

public struct FileZillaImporter: Sendable {
    private let repository: ConnectionRepository
    private let folders: ClientFolderRepository
    private let secrets: any SecretStore
    private let clock: any DockyardClock

    public init(repository: ConnectionRepository, folders: ClientFolderRepository, secrets: any SecretStore, clock: any DockyardClock = SystemClock()) {
        self.repository = repository
        self.folders = folders
        self.secrets = secrets
        self.clock = clock
    }

    /// Creates client folders and connections (source `filezillaImport`). Sites that already exist
    /// (same protocol, host, port and user) are left alone.
    public func apply(_ parsed: FileZillaParseResult) async throws -> FileZillaImportSummary {
        var summary = FileZillaImportSummary(warnings: parsed.warnings)
        let existingFolders = Set(try await folders.all().map { $0.name.lowercased() })
        var folderIds: [String: UUID] = [:]
        for site in parsed.sites {
            if try await repository.connection(protocol: site.protocol, host: site.host, port: site.port, username: site.username) != nil {
                summary.skippedDuplicates += 1
                continue
            }
            var folderId: UUID?
            if let fname = site.clientFolderName {
                if let id = folderIds[fname.lowercased()] { folderId = id } else {
                    let folder = try await folders.findOrCreate(name: fname)
                    folderIds[fname.lowercased()] = folder.id
                    folderId = folder.id
                    if !existingFolders.contains(fname.lowercased()) { summary.foldersCreated += 1 }
                }
            }
            let connection = Connection(
                name: site.name, clientFolderId: folderId, protocol: site.protocol, host: site.host, port: site.port,
                username: site.username, authMethods: site.authMethods, keyPath: site.keyPath, notes: site.notes,
                source: .filezillaImport, createdAt: clock.now())
            try await repository.save(connection)
            if let pw = site.password {
                try await secrets.setSecret(pw, for: connection.id, purpose: .password)
                summary.passwordsStored += 1
            }
            if site.needsPasswordPrompt { summary.needingPassword += 1 }
            summary.created += 1
        }
        return summary
    }
}
