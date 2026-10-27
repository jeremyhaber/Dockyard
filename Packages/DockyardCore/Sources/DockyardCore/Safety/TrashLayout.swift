import Foundation
import ConnectionKit

public enum SafetyNetError: Error, Equatable, CustomStringConvertible {
    /// The user declined to continue without a backup.
    case declined(String)
    /// No place outside the web root could be found for the trash.
    case noSafeLocation(String)

    public var description: String {
        switch self {
        case .declined(let path): "Cancelled: no backup of \(path) could be made"
        case .noSafeLocation(let home): "No trash location outside the web root is available (home is \(home))"
        }
    }
}

/// Where trashed items live and how their names map back to the original paths.
///
/// Layout: `<root>/<YYYY-MM-DD>/<original path>`, with `<root>` = `~/.dockyard-trash`. A folder that was
/// trashed is marked by an empty sibling file `<name>.~dir~`, so a trashed folder can be told apart from
/// the plain parent folders that the layout creates. A name that was already taken that day gets
/// `.~N~` appended.
public enum TrashLayout {
    public static let folderName = ".dockyard-trash"
    public static let folderMarkerSuffix = ".~dir~"
    public static let webRootNames: Set<String> = ["public_html", "www", "htdocs", "httpdocs"]

    public struct Root: Sendable, Equatable {
        public var path: String
        /// Set when the home directory could not be used directly.
        public var warning: String?
    }

    /// The trash root for `home`, never inside a web root. When `home` is itself in or below a web root,
    /// the trash goes next to that web root, in its parent directory.
    public static func root(forHome home: String) throws -> Root {
        let parts = components(home)
        if parts.isEmpty {
            // A chrooted FTP account: its root is all there is. It may be served over HTTP, so say so.
            return Root(path: "/" + folderName, warning: "The account root is the only place for the trash; make sure it is not served over HTTP")
        }
        guard let webRoot = parts.firstIndex(where: { webRootNames.contains($0.lowercased()) }) else {
            return Root(path: "/" + (parts + [folderName]).joined(separator: "/"))
        }
        let parent = Array(parts[..<webRoot])
        guard !parent.isEmpty else { throw SafetyNetError.noSafeLocation(home) }
        let path = "/" + (parent + [folderName]).joined(separator: "/")
        return Root(path: path, warning: "The home directory is inside a web root; keeping the trash in \(path) instead")
    }

    public static func isInsideWebRoot(_ path: String) -> Bool {
        components(path).contains { webRootNames.contains($0.lowercased()) }
    }

    public static func isInsideTrash(_ path: String) -> Bool {
        components(path).contains(folderName)
    }

    public static func destination(root: String, day: String, original: String, version: Int = 1) -> String {
        var parts = components(original)
        if version > 1, let last = parts.last { parts[parts.count - 1] = "\(last).~\(version)~" }
        return "/" + ([root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))] + [day] + parts).joined(separator: "/")
    }

    /// Splits `name.~3~` into (`name`, 3).
    public static func parseVersion(_ name: String) -> (name: String, version: Int) {
        guard name.hasSuffix("~"), let open = name.range(of: ".~", options: .backwards) else { return (name, 1) }
        let digits = name[open.upperBound..<name.index(before: name.endIndex)]
        guard let version = Int(digits), version > 1 else { return (name, 1) }
        return (String(name[..<open.lowerBound]), version)
    }

    public static func isDayName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
            && parts.allSatisfy { $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// Absolute, without `.`/empty parts or a trailing slash. Relative paths are taken relative to `home`.
    public static func normalize(_ path: String, home: String) -> String {
        let base = path.hasPrefix("/") ? [] : components(home)
        var out: [String] = []
        for part in base + components(path) {
            if part == "." { continue }
            if part == ".." { _ = out.popLast(); continue }
            out.append(part)
        }
        return "/" + out.joined(separator: "/")
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
