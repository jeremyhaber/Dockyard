import Foundation

/// A remote folder that a website serves from, e.g. `/home/acme/public_html` at `https://acme.example`.
public struct WebURLMapping: Sendable, Hashable, Codable, Identifiable {
    public var path: String
    public var baseURL: String

    public var id: String { path }

    public init(path: String, baseURL: String) {
        self.path = WebURLResolver.normalizePath(path)
        self.baseURL = baseURL
    }
}

/// Turns remote paths into web addresses with a connection's folder mappings.
public enum WebURLResolver {
    /// The mapping whose folder is the deepest one containing `path`.
    public static func mapping(for path: String, in mappings: [WebURLMapping]) -> WebURLMapping? {
        let target = normalizePath(path)
        return mappings
            .filter { contains($0.path, target) }
            .max { $0.path.count < $1.path.count }
    }

    /// The web address of `path`, or nil when no mapping covers it. Each path component is percent-encoded.
    public static func url(for path: String, in mappings: [WebURLMapping]) -> URL? {
        guard let mapping = mapping(for: path, in: mappings), let base = normalizeBase(mapping.baseURL) else { return nil }
        let target = normalizePath(path)
        let relative = target == mapping.path ? "" : String(target.dropFirst(mapping.path == "/" ? 1 : mapping.path.count + 1))
        let encoded = relative.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: encoded.isEmpty ? base : base + "/" + encoded)
    }

    /// `acme.example/` becomes `https://acme.example`. Returns nil for text that is not an http(s) address with a host.
    public static func normalizeBase(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let components = URLComponents(string: s), let host = components.host, !host.isEmpty,
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else { return nil }
        return s
    }

    /// Trailing slashes dropped, root kept as `/`.
    public static func normalizePath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func contains(_ folder: String, _ path: String) -> Bool {
        folder == "/" || path == folder || path.hasPrefix(folder + "/")
    }

    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#;")
        return set
    }()
}
