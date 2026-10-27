import Foundation
import ConnectionKit

public enum TransmitImportError: Error, Equatable, CustomStringConvertible {
    case unsupportedFormat(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let reason): reason
        }
    }
}

/// Reads Transmit favorites from a property list: `~/Library/Preferences/com.panic.Transmit.plist` (Transmit 3 and
/// 4 keep their favorites in the `FavoriteCollections` key, nested collections becoming client folders) or any plist
/// with the same shape.
///
/// What is NOT supported, because Panic does not publish the format and it is not a property list:
/// Transmit 5's `.exportedServers` export, its internal Servers database and the older `.exportedFavorites`
/// files. For those, `parse` throws `.unsupportedFormat`; the importer UI should tell the user to re-create or
/// import the sites through another route (for example `~/.ssh/config` or Cyberduck).
///
/// The key names below are matched loosely (case, punctuation and common synonyms are ignored) because the exact
/// schema has changed between Transmit versions. Passwords live in the login Keychain, not in the plist.
public enum TransmitParser {
    public static func defaultPaths(home: String) -> [String] {
        ["\(home)/Library/Preferences/com.panic.Transmit.plist"]
    }

    public static func parse(_ data: Data) throws -> ImportParseResult {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            throw TransmitImportError.unsupportedFormat(
                "This is not a property list. Transmit 5's Servers export (.exportedServers) is proprietary and cannot be read; import from Transmit 4's preferences, Cyberduck or ~/.ssh/config instead.")
        }
        var walker = Walker()
        if let archive = root as? [String: Any], archive["$archiver"] != nil {
            if let resolved = KeyedArchive.resolve(archive) { walker.walk(resolved, folder: []) }
        } else {
            walker.walk(root, folder: [])
        }
        if walker.result.sites.isEmpty && walker.result.warnings.isEmpty {
            walker.result.warnings.append("No Transmit favorites were found in this file")
        }
        return walker.result
    }

    // MARK: Walking

    private struct Walker {
        var result = ImportParseResult()

        mutating func walk(_ value: Any, folder: [String]) {
            switch value {
            case let data as Data:
                guard let nested = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return }
                if let archive = nested as? [String: Any], archive["$archiver"] != nil, let resolved = KeyedArchive.resolve(archive) {
                    walk(resolved, folder: folder)
                } else {
                    walk(nested, folder: folder)
                }
            case let array as [Any]:
                for element in array { walk(element, folder: folder) }
            case let dict as [String: Any]:
                if let favorite = Favorite(dict) {
                    add(favorite, folder: folder)
                    return
                }
                var inner = folder
                if let name = Favorite.folderName(dict) { inner.append(name) }
                for key in dict.keys.sorted() { walk(dict[key]!, folder: inner) }
            default:
                break
            }
        }

        mutating func add(_ favorite: Favorite, folder: [String]) {
            let name = favorite.name.isEmpty ? favorite.host : favorite.name
            guard let proto = favorite.mappedProtocol else {
                result.warnings.append("Skipped \"\(name)\": \(favorite.protocolText.isEmpty ? "unknown protocol" : favorite.protocolText) is not supported")
                return
            }
            var port = favorite.port ?? 0
            if !(1...65535).contains(port) { port = proto.defaultPort }
            var user = favorite.user
            if user.isEmpty, proto != .sftp { user = "anonymous" }
            let keyPath = favorite.keyPath.isEmpty ? nil : (favorite.keyPath as NSString).expandingTildeInPath
            result.sites.append(ImportedSite(
                name: name, folderPath: folder, protocol: proto, host: favorite.host, port: port, username: user,
                authMethods: keyPath == nil ? .password : .key, keyPath: keyPath,
                remotePath: favorite.path.isEmpty || favorite.path == "/" ? nil : favorite.path, notes: favorite.notes,
                keychain: user == "anonymous" || keyPath != nil
                    ? nil
                    : KeychainPasswordRequest(application: .transmit, server: favorite.host, account: user, port: port,
                                              protocolName: favorite.protocolText.lowercased())))
        }
    }

    private struct Favorite {
        var name = "", host = "", user = "", protocolText = "", path = "", keyPath = "", notes = ""
        var port: Int?

        init?(_ dict: [String: Any]) {
            var fields: [String: Any] = [:]
            for (key, value) in dict { fields[Self.normalize(key)] = value }
            func text(_ names: [String]) -> String {
                for name in names {
                    switch fields[name] {
                    case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
                    case let n as NSNumber: return n.stringValue
                    default: continue
                    }
                }
                return ""
            }
            host = text(["server", "host", "hostname", "address"])
            protocolText = text(["protocol", "type", "service"])
            guard !host.isEmpty, !protocolText.isEmpty else { return nil }
            name = text(["nickname", "name", "title"])
            user = text(["username", "user", "login"])
            port = Int(text(["port"]))
            path = text(["path", "remotepath", "initialpath", "remotedirectory"])
            keyPath = text(["keypath", "privatekey", "keyfile", "identityfile"])
            notes = text(["notes", "comment", "comments"])
        }

        static func folderName(_ dict: [String: Any]) -> String? {
            let normalized = Dictionary(dict.map { (normalize($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
            let containers: Set<String> = ["favorites", "children", "items", "contents", "servers"]
            guard !containers.isDisjoint(with: normalized.keys) else { return nil }
            for key in ["name", "title", "collectionname", "nickname"] {
                if let s = (normalized[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
            }
            return nil
        }

        static func normalize(_ key: String) -> String {
            String(key.lowercased().filter { $0.isLetter })
        }

        /// Transmit's protocol names: FTP, SFTP, FTP with TLS/SSL, plus the cloud ones that are not imported.
        var mappedProtocol: ConnectionProtocol? {
            let p = Self.normalize(protocolText)
            if p == "sftp" || p == "ssh" { return .sftp }
            if ["ftptls", "ftpssl", "ftps", "ftpes", "ftpwithtls", "ftpwithssl", "ftptlsexplicit"].contains(p) { return .ftps }
            if p == "ftp" { return .ftp }
            return nil
        }
    }
}

/// Minimal `NSKeyedArchiver` reader for plists in XML form (`CF$UID` references appear as dictionaries).
/// Binary archives written by Foundation on macOS expose their references as opaque objects and are not handled.
enum KeyedArchive {
    static func resolve(_ archive: [String: Any]) -> Any? {
        guard let objects = archive["$objects"] as? [Any],
              let top = archive["$top"] as? [String: Any], let rootRef = top["root"] ?? top.values.first else { return nil }
        return resolve(rootRef, objects: objects, depth: 0)
    }

    /// Foundation parses `CF$UID` into an opaque object on Apple platforms and on Linux, so the number is read
    /// by reflection or from its description (`...{value = 3}`).
    private static func uid(_ value: Any) -> Int? {
        if let dict = value as? [String: Any] {
            guard dict.count == 1, let n = dict["CF$UID"] as? NSNumber else { return nil }
            return n.intValue
        }
        let type = String(describing: Swift.type(of: value))
        guard type.contains("KeyedArchiverUID") else { return nil }
        if let child = Mirror(reflecting: value).children.first(where: { $0.label == "value" })?.value {
            if let n = child as? Int { return n }
            if let n = child as? UInt { return Int(n) }
            if let n = child as? UInt32 { return Int(n) }
        }
        let description = String(describing: value)
        guard let range = description.range(of: #"value = (\d+)"#, options: .regularExpression) else { return nil }
        return Int(description[range].filter(\.isNumber))
    }

    private static func resolve(_ value: Any, objects: [Any], depth: Int) -> Any? {
        guard depth < 64 else { return nil }
        if let index = uid(value) {
            guard objects.indices.contains(index) else { return nil }
            if let s = objects[index] as? String, s == "$null" { return nil }
            return resolve(objects[index], objects: objects, depth: depth + 1)
        }
        if let dict = value as? [String: Any] {
            if let keys = dict["NS.keys"] as? [Any], let values = dict["NS.objects"] as? [Any] {
                var out: [String: Any] = [:]
                for (k, v) in zip(keys, values) {
                    if let key = resolve(k, objects: objects, depth: depth + 1) as? String, let value = resolve(v, objects: objects, depth: depth + 1) {
                        out[key] = value
                    }
                }
                return out
            }
            if let items = dict["NS.objects"] as? [Any] {
                return items.compactMap { resolve($0, objects: objects, depth: depth + 1) }
            }
            if dict["$class"] != nil {
                var out: [String: Any] = [:]
                for (k, v) in dict where k != "$class" {
                    if let value = resolve(v, objects: objects, depth: depth + 1) { out[k] = value }
                }
                return out
            }
            return dict.compactMapValues { resolve($0, objects: objects, depth: depth + 1) }
        }
        if let array = value as? [Any] { return array.compactMap { resolve($0, objects: objects, depth: depth + 1) } }
        return value
    }
}
