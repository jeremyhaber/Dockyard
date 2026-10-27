import Foundation
import ConnectionKit

public struct JumpFolder: Sendable, Hashable {
    public var connectionId: UUID
    public var path: String
    public var visitedAt: Date
    public init(connectionId: UUID, path: String, visitedAt: Date) {
        self.connectionId = connectionId; self.path = path; self.visitedAt = visitedAt
    }
}

public struct JumpHit: Sendable, Equatable, Identifiable {
    public enum Target: Sendable, Equatable {
        case connection(Connection)
        case folder(JumpFolder, in: Connection)
    }
    public var target: Target
    public var score: Double

    public var id: String {
        switch target {
        case .connection(let c): "c:\(c.id)"
        case .folder(let f, _): "f:\(f.connectionId):\(f.path)"
        }
    }
}

/// ⌘K search over connections and recent folders.
public enum JumpSearch {
    public static func search(
        _ query: String,
        connections: [Connection],
        folders: [JumpFolder] = [],
        clientNames: [UUID: String] = [:],
        openNow: Set<UUID> = [],
        now: Date = Date(),
        limit: Int = 20
    ) -> [JumpHit] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let byId = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        var hits: [JumpHit] = []

        for c in connections {
            let boost = boost(for: c, open: openNow.contains(c.id), now: now)
            if tokens.isEmpty {
                // Empty query: show what you are most likely to want.
                if c.favorite || c.lastConnectedAt != nil || openNow.contains(c.id) {
                    hits.append(JumpHit(target: .connection(c), score: boost))
                }
                continue
            }
            let fields = connectionFields(c, client: c.clientFolderId.flatMap { clientNames[$0] })
            guard let base = score(tokens: tokens, fields: fields) else { continue }
            hits.append(JumpHit(target: .connection(c), score: base + boost))
        }

        if !tokens.isEmpty {
            for f in folders {
                guard let c = byId[f.connectionId] else { continue }
                var fields = connectionFields(c, client: c.clientFolderId.flatMap { clientNames[$0] }).map { ($0.0, $0.1 * 0.5) }
                fields.append((f.path.lowercased(), 0.6))
                fields.append((RemotePath.lastComponent(of: f.path).lowercased(), 1.0))
                guard let base = score(tokens: tokens, fields: fields) else { continue }
                // Folders sit below an equally good connection, newer visits slightly higher.
                let age = max(0, now.timeIntervalSince(f.visitedAt)) / 86_400
                hits.append(JumpHit(target: .folder(f, in: c), score: base - 5 + max(0, 5 - age * 0.5)))
            }
        }

        return Array(hits.sorted(by: order).prefix(limit))
    }

    private static func order(_ a: JumpHit, _ b: JumpHit) -> Bool {
        if a.score != b.score { return a.score > b.score }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    private static func connectionFields(_ c: Connection, client: String?) -> [(String, Double)] {
        var f: [(String, Double)] = [(c.name.lowercased(), 1.0), (c.host.lowercased(), 0.8), (c.username.lowercased(), 0.4)]
        if let client { f.append((client.lowercased(), 0.7)) }
        for t in c.tags { f.append((t.lowercased(), 0.5)) }
        return f
    }

    private static func boost(for c: Connection, open: Bool, now: Date) -> Double {
        var b = 0.0
        if c.favorite { b += 8 }
        if open { b += 10 }
        if let last = c.lastConnectedAt {
            let days = max(0, now.timeIntervalSince(last)) / 86_400
            b += max(0, 10 - days / 3)
        }
        if c.removedFromSource { b -= 20 }
        return b
    }

    /// Every token must match some field; the score is the mean of each token's best field score.
    static func score(tokens: [String], fields: [(String, Double)]) -> Double? {
        var total = 0.0
        for t in tokens {
            var best = 0.0
            for (text, weight) in fields {
                let s = matchScore(t, in: text) * weight
                best = max(best, s)
            }
            if best == 0 { return nil }
            total += best
        }
        return total / Double(tokens.count)
    }

    /// 100 exact, 80 prefix, 60 word prefix, 40 substring, 15 subsequence, 0 none.
    static func matchScore(_ token: String, in text: String) -> Double {
        guard !token.isEmpty, !text.isEmpty else { return 0 }
        if text == token { return 100 }
        if text.hasPrefix(token) { return 80 }
        if let r = text.range(of: token) {
            let before = text[..<r.lowerBound].last
            if let before, !before.isLetter && !before.isNumber { return 60 }
            return 40
        }
        if token.count >= 3 && isSubsequence(token, of: text) { return 15 }
        return 0
    }

    private static func isSubsequence(_ token: String, of text: String) -> Bool {
        var it = text.makeIterator()
        for ch in token {
            var found = false
            while let n = it.next() { if n == ch { found = true; break } }
            if !found { return false }
        }
        return true
    }
}

extension JumpHit {
    public var title: String {
        switch target {
        case .connection(let c): c.name
        case .folder(let f, _): f.path
        }
    }
}
