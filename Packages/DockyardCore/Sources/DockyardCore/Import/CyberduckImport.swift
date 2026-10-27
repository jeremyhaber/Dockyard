import Foundation
import ConnectionKit

/// Reads Cyberduck bookmarks: one property list per bookmark, named `<uuid>.duckbookmark`.
///
/// Supported: SFTP, FTP and FTP over TLS. Cloud providers (S3, WebDAV, Azure, B2, Drive, ...) are skipped with a
/// warning, because they need credentials and settings that map to rclone remotes rather than a host/user pair.
/// Passwords are not in the bookmark; Cyberduck keeps them in the login Keychain as internet passwords, so each
/// site carries a `KeychainPasswordRequest`.
public enum CyberduckParser {
    /// Current (sandbox group container) and legacy bookmark folders, in the order to try.
    public static func bookmarkDirectories(home: String) -> [String] {
        [
            "\(home)/Library/Group Containers/G69SCX94XU.duck/Library/Application Support/duck/Bookmarks",
            "\(home)/Library/Application Support/Cyberduck/Bookmarks",
        ]
    }

    /// Parses every `*.duckbookmark` in the existing directories among `directories`.
    public static func parseDirectories(_ directories: [String], fileManager: FileManager = .default) -> ImportParseResult {
        var result = ImportParseResult()
        var seen = Set<String>()
        for directory in directories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for name in names.sorted() where name.hasSuffix(".duckbookmark") {
                guard let data = fileManager.contents(atPath: directory + "/" + name) else {
                    result.warnings.append("\(name): cannot read the file")
                    continue
                }
                let parsed = parseBookmark(data, fileName: name)
                // The same bookmark can exist in both folders after an app update.
                for site in parsed.sites where seen.insert(Connection.endpointKey(protocol: site.protocol, host: site.host, port: site.port, username: site.username)).inserted {
                    result.sites.append(site)
                }
                result.warnings += parsed.warnings
            }
        }
        return result
    }

    public static func parseBookmark(_ data: Data, fileName: String = "bookmark") -> ImportParseResult {
        var result = ImportParseResult()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            result.warnings.append("\(fileName): not a property list")
            return result
        }
        func string(_ key: String) -> String {
            switch plist[key] {
            case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
            case let n as NSNumber: return n.stringValue
            default: return ""
            }
        }

        let host = string("Hostname")
        let nickname = string("Nickname")
        let name = nickname.isEmpty ? host : nickname
        let scheme = string("Protocol").lowercased()
        guard !host.isEmpty else {
            result.warnings.append("\(fileName): skipped, no host")
            return result
        }
        guard let proto = mapProtocol(scheme) else {
            result.warnings.append("Skipped \"\(name)\": \(scheme.isEmpty ? "unknown protocol" : scheme) is not supported (add it as a cloud connection instead)")
            return result
        }

        var port = Int(string("Port")) ?? 0
        if !(1...65535).contains(port) { port = proto.defaultPort }
        if proto == .ftps && port == 990 {
            result.warnings.append("\"\(name)\": implicit FTPS (port 990) is not supported; it was imported as explicit FTPS and may need a port change")
        }

        var user = string("Username")
        if user.isEmpty, proto != .sftp { user = "anonymous" }
        var keyPath: String?
        let key = string("Private Key File")
        if !key.isEmpty {
            keyPath = (key as NSString).expandingTildeInPath
        } else if plist["Private Key File Dictionary"] != nil {
            result.warnings.append("\"\(name)\": its private key is stored as a sandbox bookmark; choose the key file again in the site editor")
        }

        let labels = (plist["Labels"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var path = string("Path")
        if path.isEmpty || path == "/" { path = "" }

        result.sites.append(ImportedSite(
            name: name, protocol: proto, host: host, port: port, username: user,
            authMethods: keyPath == nil ? .password : .key, keyPath: keyPath,
            remotePath: path.isEmpty ? nil : path, notes: string("Comment"), tags: labels,
            keychain: user == "anonymous" || keyPath != nil
                ? nil
                : KeychainPasswordRequest(application: .cyberduck, server: host, account: user, port: port, protocolName: scheme)))
        return result
    }

    static func mapProtocol(_ scheme: String) -> ConnectionProtocol? {
        switch scheme {
        case "sftp", "ssh": .sftp
        case "ftp": .ftp
        case "ftps", "ftp-tls", "ftpes", "ftp-ssl": .ftps
        default: nil
        }
    }
}
