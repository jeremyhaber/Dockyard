import Foundation

public struct RemoteItem: Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: UInt64?
    public var modified: Date?
    /// Unix permission bits (e.g. `0o644`), when the server reports them.
    public var permissions: UInt16?
    public var symlinkTarget: String?

    public var id: String { path }
    public var isSymlink: Bool { symlinkTarget != nil }

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        size: UInt64? = nil,
        modified: Date? = nil,
        permissions: UInt16? = nil,
        symlinkTarget: String? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.symlinkTarget = symlinkTarget
    }
}

public enum RemotePath {
    public static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        let parent = String(path[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    public static func lastComponent(of path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }
}
