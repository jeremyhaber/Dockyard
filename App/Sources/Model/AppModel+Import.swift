import ConnectionKit
import DockyardCore
import Foundation

enum ImportKind: String, Identifiable {
    case transmit, cyberduck, sshConfig
    var id: String { rawValue }

    var title: String {
        switch self {
        case .transmit: "Transmit"
        case .cyberduck: "Cyberduck"
        case .sshConfig: "SSH config"
        }
    }

    var source: ConnectionSource {
        switch self {
        case .transmit: .transmitImport
        case .cyberduck: .cyberduckImport
        case .sshConfig: .sshConfigImport
        }
    }

    /// Whether the other app keeps passwords in the login Keychain.
    var readsKeychain: Bool { self != .sshConfig }
}

/// One line of the preview sheet.
struct ImportRow: Identifiable, Equatable {
    enum Outcome: Equatable { case new, update, duplicate }

    let id = UUID()
    var name: String
    var detail: String
    var folder: String?
    var outcome: Outcome
    /// How the login will work: Keychain password, asks on first connect, key file, jump host.
    var note: String?
}

/// What an import would do, computed before anything is written.
struct ImportPreview: Identifiable {
    enum Payload {
        case sites(ImportParseResult)
        case sshConfig(SSHConfigResult)
    }

    let id = UUID()
    var kind: ImportKind
    var rows: [ImportRow]
    var warnings: [String]
    var payload: Payload

    var newCount: Int { rows.filter { $0.outcome == .new }.count }
    var updateCount: Int { rows.filter { $0.outcome == .update }.count }
    var duplicateCount: Int { rows.filter { $0.outcome == .duplicate }.count }
    var changeCount: Int { newCount + updateCount }
}

struct ImportFailure: Error {
    var title: String
    var message: String
}

extension AppModel {
    private static let transmit5Explanation = "Transmit 5 keeps its servers in its own database and exports them as .exportedServers files, "
        + "a format Panic has not published, so Dockyard cannot read them. Dockyard reads favorites from the preferences file of "
        + "Transmit 3 and 4 (~/Library/Preferences/com.panic.Transmit.plist). To bring Transmit 5 sites over, import them "
        + "from ~/.ssh/config or Cyberduck, or add them by hand."

    /// Parses the other app's data and works out what an import would do. Nothing is written.
    func prepareImport(_ kind: ImportKind, from url: URL? = nil) async throws -> ImportPreview {
        let home = NSHomeDirectory()
        switch kind {
        case .transmit:
            guard let url else { throw ImportFailure(title: "Choose a Transmit file", message: Self.transmit5Explanation) }
            let parsed: ImportParseResult
            do {
                let data = try Data(contentsOf: url)
                parsed = try TransmitParser.parse(data)
            } catch is TransmitImportError {
                throw ImportFailure(title: "This Transmit file cannot be imported", message: Self.transmit5Explanation)
            } catch {
                throw ImportFailure(title: "Could not read the file", message: error.userMessage)
            }
            if parsed.sites.isEmpty {
                throw ImportFailure(
                    title: "No Transmit favorites found",
                    message: (parsed.warnings + [Self.transmit5Explanation]).joined(separator: "\n\n"))
            }
            return sitePreview(kind, parsed)
        case .cyberduck:
            let directories = url.map { [$0.path] } ?? CyberduckParser.bookmarkDirectories(home: home)
            let parsed = await Task.detached { CyberduckParser.parseDirectories(directories) }.value
            if parsed.sites.isEmpty {
                throw ImportFailure(
                    title: "No Cyberduck bookmarks found",
                    message: (parsed.warnings + ["Cyberduck keeps one .duckbookmark file per site in ~/Library/Application Support/duck/Bookmarks. Choose that folder if yours is elsewhere. Cloud bookmarks (S3, Azure, WebDAV) are skipped."])
                        .joined(separator: "\n\n"))
            }
            return sitePreview(kind, parsed)
        case .sshConfig:
            let parsed = await Task.detached { SSHConfigParser(home: home).parseDefault() }.value
            if parsed.entries.isEmpty {
                throw ImportFailure(
                    title: "No hosts found",
                    message: (parsed.warnings + ["~/.ssh/config has no Host entries without wildcards."]).joined(separator: "\n\n"))
            }
            return sshConfigPreview(parsed)
        }
    }

    func sitePreview(_ kind: ImportKind, _ parsed: ImportParseResult) -> ImportPreview {
        let existing = Set(allConnections.map(\.endpointKey))
        var seen = Set<String>()
        var rows: [ImportRow] = []
        for site in parsed.sites {
            let key = Connection.endpointKey(protocol: site.protocol, host: site.host, port: site.port, username: site.username)
            let isDuplicate = existing.contains(key) || !seen.insert(key).inserted
            var note: String?
            if site.authMethods.contains(.key), let path = site.keyPath {
                note = "Key \(path)"
            } else if site.username == "anonymous" {
                note = "Anonymous login"
            } else if site.keychain != nil {
                note = "Password from \(kind.title) Keychain if readable"
            }
            rows.append(ImportRow(
                name: site.name, detail: Self.endpoint(site.protocol, site.username, site.host, site.port),
                folder: site.clientFolderName, outcome: isDuplicate ? .duplicate : .new, note: note))
        }
        return ImportPreview(kind: kind, rows: rows, warnings: parsed.warnings, payload: .sites(parsed))
    }

    private func sshConfigPreview(_ parsed: SSHConfigResult) -> ImportPreview {
        var warnings = parsed.warnings
        var rows: [ImportRow] = []
        let importedByName = Dictionary(
            allConnections.filter { $0.source == .sshConfigImport }.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let existing = Set(allConnections.map(\.endpointKey))
        for entry in parsed.entries {
            let user = entry.user ?? NSUserName()
            let port = entry.port ?? 22
            let key = Connection.endpointKey(protocol: .sftp, host: entry.hostName, port: port, username: user)
            let outcome: ImportRow.Outcome = importedByName[entry.alias] != nil ? .update : existing.contains(key) ? .duplicate : .new
            var notes: [String] = []
            if let identity = entry.identityFiles.first { notes.append("Key \(identity)") }
            if !entry.proxyJump.isEmpty { notes.append("Through " + entry.proxyJump.map(\.host).joined(separator: ", ")) }
            if entry.hasProxyCommand {
                notes.append("ProxyCommand ignored")
                warnings.append("\(entry.alias): ProxyCommand is not supported; imported without it")
            }
            rows.append(ImportRow(
                name: entry.alias, detail: Self.endpoint(.sftp, user, entry.hostName, port), folder: nil, outcome: outcome,
                note: notes.isEmpty ? nil : notes.joined(separator: " \u{00B7} ")))
        }
        return ImportPreview(kind: .sshConfig, rows: rows, warnings: warnings, payload: .sshConfig(parsed))
    }

    private static func endpoint(_ proto: ConnectionProtocol, _ user: String, _ host: String, _ port: Int) -> String {
        let account = user.isEmpty ? host : "\(user)@\(host)"
        return "\(proto.rawValue)://\(account)" + (port == proto.defaultPort ? "" : ":\(port)")
    }

    /// Writes what the preview promised and returns the sentence for the Connections window's banner.
    func applyImport(_ preview: ImportPreview, readKeychain: Bool) async -> String {
        do {
            switch preview.payload {
            case .sites(let parsed):
                let importer = SiteImporter(repository: connections, folders: folders, source: preview.kind.source, secrets: secrets)
                let reader: (any ImportedPasswordReader)? = readKeychain ? KeychainPasswordReader() : nil
                let summary = try await importer.apply(parsed, passwordReader: reader)
                var text = "Imported \(summary.created) connection\(summary.created == 1 ? "" : "s") from \(preview.kind.title)"
                if summary.skippedDuplicates > 0 { text += ", skipped \(summary.skippedDuplicates) already saved" }
                if summary.passwordsStored > 0 { text += ", read \(summary.passwordsStored) password\(summary.passwordsStored == 1 ? "" : "s") from the Keychain" }
                if summary.needingPassword > 0 { text += ". \(summary.needingPassword) will ask for a password on first connect" }
                return text
            case .sshConfig(let parsed):
                let importer = SSHConfigImporter(repository: connections)
                let summary = try await importer.apply(parsed)
                var text = "Imported \(summary.created) new and updated \(summary.updated) from ~/.ssh/config"
                if summary.skippedExisting > 0 { text += ", skipped \(summary.skippedExisting) already saved" }
                return text
            }
        } catch {
            return "Import failed: \(error.userMessage)"
        }
    }
}
