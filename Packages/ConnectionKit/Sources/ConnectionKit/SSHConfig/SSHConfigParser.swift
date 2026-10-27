import Foundation

/// A jump host as written in `ProxyJump`: `[user@]host[:port]`.
public struct SSHJumpSpec: Sendable, Equatable, Hashable {
    public var user: String?
    public var host: String
    public var port: Int?

    public init(user: String? = nil, host: String, port: Int? = nil) {
        self.user = user; self.host = host; self.port = port
    }

    /// Parses `user@host:port`, `host`, `[::1]:2222` and `ssh://user@host:port`.
    public static func parse(_ text: String) -> SSHJumpSpec? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.hasPrefix("ssh://") { rest = rest.dropFirst(6) }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        var port: Int?
        var host = String(rest)
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") {
                guard let p = Int(after.dropFirst()), (1...65535).contains(p) else { return nil }
                port = p
            }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.lastIndex(of: ":") {
            guard let p = Int(rest[rest.index(after: colon)...]), (1...65535).contains(p) else { return nil }
            port = p
            host = String(rest[..<colon])
        }
        guard !host.isEmpty else { return nil }
        return SSHJumpSpec(user: user?.isEmpty == true ? nil : user, host: host, port: port)
    }
}

/// One concrete `Host` alias with every matching block applied (first value wins, as in OpenSSH).
public struct SSHConfigEntry: Sendable, Equatable {
    public var alias: String
    public var hostName: String
    public var user: String?
    public var port: Int?
    public var identityFiles: [String]
    public var proxyJump: [SSHJumpSpec]
    /// A `ProxyCommand` is set (and no ProxyJump); Dockyard cannot honour it.
    public var hasProxyCommand: Bool

    public init(alias: String, hostName: String, user: String? = nil, port: Int? = nil,
                identityFiles: [String] = [], proxyJump: [SSHJumpSpec] = [], hasProxyCommand: Bool = false) {
        self.alias = alias; self.hostName = hostName; self.user = user; self.port = port
        self.identityFiles = identityFiles; self.proxyJump = proxyJump; self.hasProxyCommand = hasProxyCommand
    }
}

public struct SSHConfigResult: Sendable, Equatable {
    public var entries: [SSHConfigEntry] = []
    public var warnings: [String] = []
}

/// Where the parser reads config files from. Tests use an in-memory implementation.
public protocol SSHConfigFiles: Sendable {
    func contents(of path: String) -> String?
    /// Existing files matching `pattern` (which may contain wildcards), sorted.
    func expand(_ pattern: String) -> [String]
}

public struct LocalSSHConfigFiles: SSHConfigFiles {
    public init() {}

    public func contents(of path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func expand(_ pattern: String) -> [String] {
        var candidates = [pattern.hasPrefix("/") ? "/" : ""]
        for component in pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            var next: [String] = []
            for base in candidates {
                if Glob.hasWildcards(component) {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: base.isEmpty ? "." : base)) ?? []
                    next += names.filter { !$0.hasPrefix(".") && Glob.matches(component, $0) }.sorted().map { join(base, $0) }
                } else {
                    next.append(join(base, component))
                }
            }
            candidates = next
        }
        var isDirectory: ObjCBool = false
        return candidates.filter { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && !isDirectory.boolValue }
    }

    private func join(_ base: String, _ name: String) -> String {
        base.isEmpty ? name : base == "/" ? "/" + name : base + "/" + name
    }
}

/// Parses `~/.ssh/config`: Host patterns, HostName, User, Port, IdentityFile, ProxyJump and Include.
/// `Match` blocks are skipped with a warning.
public struct SSHConfigParser: Sendable {
    public var home: String
    public var files: any SSHConfigFiles
    public var maxIncludeDepth = 8

    public init(home: String, files: any SSHConfigFiles = LocalSSHConfigFiles()) {
        self.home = home
        self.files = files
    }

    public var defaultConfigPath: String { home + "/.ssh/config" }

    public func parseDefault() -> SSHConfigResult { parse(path: defaultConfigPath) }

    public func parse(path: String) -> SSHConfigResult {
        var state = State()
        guard let text = files.contents(of: path) else {
            state.result.warnings.append("Cannot read \(path)")
            return state.result
        }
        state.blocks.append(Block(patterns: nil))
        read(text, file: path, current: 0, depth: 0, state: &state)
        state.result.entries = resolveAll(state.blocks)
        return state.result
    }

    // MARK: Parsing

    private struct Block {
        /// nil for the global section before the first Host.
        var patterns: [String]?
        var options: [(key: String, values: [String])] = []
    }

    private struct State {
        var blocks: [Block] = []
        var result = SSHConfigResult()
    }

    /// `current == nil` means "inside a Match block": options are ignored until the next Host.
    private func read(_ text: String, file: String, current startBlock: Int?, depth: Int, state: inout State) {
        var current = startBlock
        let name = (file as NSString).lastPathComponent
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            guard let (key, values) = Self.tokenize(String(rawLine)) else { continue }
            switch key.lowercased() {
            case "host":
                state.blocks.append(Block(patterns: values))
                current = state.blocks.count - 1
            case "match":
                state.result.warnings.append("\(name):\(index + 1): Match blocks are not supported and were skipped")
                current = nil
            case "include":
                guard depth < maxIncludeDepth else {
                    state.result.warnings.append("\(name):\(index + 1): Include nesting too deep")
                    continue
                }
                for pattern in values {
                    for included in files.expand(absolute(pattern)) {
                        guard let sub = files.contents(of: included) else { continue }
                        read(sub, file: included, current: current, depth: depth + 1, state: &state)
                    }
                }
            case let lower:
                guard let block = current else { continue }
                state.blocks[block].options.append((lower, values))
            }
        }
    }

    private func absolute(_ path: String) -> String {
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        if path.hasPrefix("/") { return path }
        return home + "/.ssh/" + path
    }

    /// Splits a line into keyword and values. Handles `Key value`, `Key=value`, quotes and `#` comments.
    static func tokenize(_ line: String) -> (String, [String])? {
        var tokens: [String] = []
        var token = ""
        var inQuote = false
        var hasToken = false
        var sawEquals = false
        for ch in line {
            if inQuote {
                if ch == "\"" { inQuote = false } else { token.append(ch) }
                continue
            }
            switch ch {
            case "\"":
                inQuote = true; hasToken = true
            case "#" where !hasToken:
                return finish(tokens)
            case " ", "\t":
                if hasToken { tokens.append(token); token = ""; hasToken = false }
            case "=" where !sawEquals && tokens.count <= 1 && (tokens.count == 1 ? !hasToken : hasToken):
                if hasToken { tokens.append(token); token = ""; hasToken = false }
                sawEquals = true
            default:
                token.append(ch); hasToken = true
            }
        }
        if hasToken { tokens.append(token) }
        return finish(tokens)
    }

    private static func finish(_ tokens: [String]) -> (String, [String])? {
        guard let first = tokens.first else { return nil }
        return (first, Array(tokens.dropFirst()))
    }

    // MARK: Resolving

    private func resolveAll(_ blocks: [Block]) -> [SSHConfigEntry] {
        var aliases: [String] = []
        var seen = Set<String>()
        for block in blocks {
            for pattern in block.patterns ?? [] where !pattern.hasPrefix("!") && !Glob.hasWildcards(pattern) {
                if seen.insert(pattern).inserted { aliases.append(pattern) }
            }
        }
        return aliases.map { resolve(alias: $0, blocks: blocks) }
    }

    private func resolve(alias: String, blocks: [Block]) -> SSHConfigEntry {
        var hostName: String?, user: String?, port: Int?
        var proxyJump: [SSHJumpSpec]?
        var identityFiles: [String] = []
        var proxyCommand = false

        for block in blocks where applies(block, to: alias) {
            for (key, values) in block.options {
                let first = values.first
                switch key {
                case "hostname": if hostName == nil { hostName = first }
                case "user": if user == nil { user = first }
                case "port": if port == nil, let first, let p = Int(first), (1...65535).contains(p) { port = p }
                case "identityfile": if let first { identityFiles.append(expandIdentity(first, host: hostName ?? alias)) }
                case "proxyjump":
                    if proxyJump == nil, let first {
                        proxyJump = first.lowercased() == "none" ? [] : values.joined(separator: ",").split(separator: ",").compactMap { SSHJumpSpec.parse(String($0)) }
                    }
                case "proxycommand": if first?.lowercased() != "none" { proxyCommand = true }
                default: break
                }
            }
        }
        var unique: [String] = []
        for file in identityFiles where !unique.contains(file) { unique.append(file) }
        return SSHConfigEntry(
            alias: alias, hostName: (hostName ?? alias).replacingOccurrences(of: "%h", with: alias),
            user: user, port: port, identityFiles: unique,
            proxyJump: proxyJump ?? [], hasProxyCommand: proxyCommand && (proxyJump ?? []).isEmpty
        )
    }

    private func applies(_ block: Block, to alias: String) -> Bool {
        guard let patterns = block.patterns else { return true }
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if Glob.matches(String(pattern.dropFirst()), alias, caseInsensitive: true) { return false }
            } else if Glob.matches(pattern, alias, caseInsensitive: true) {
                matched = true
            }
        }
        return matched
    }

    private func expandIdentity(_ path: String, host: String) -> String {
        let p = path.replacingOccurrences(of: "%d", with: home).replacingOccurrences(of: "%h", with: host)
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + String(p.dropFirst(1)) }
        return p
    }
}
