import Foundation
import ConnectionKit

/// Pure rules for HANDOFF section 9 (mount as a drive). The File Provider extension and the app both call these.
public enum MountNaming {
    public static let readOnlySuffix = " (read-only)"
    public static let maxNameLength = 80
    static let identifierPrefix = "app.dockyard.mount."

    /// "Client – Prod (read-only)". The client folder comes first; read-only mounts say so in the Finder name.
    public static func displayName(connectionName: String, clientName: String?, readOnly: Bool) -> String {
        let name = clean(connectionName)
        let client = clientName.map(clean).flatMap { $0.isEmpty ? nil : $0 }
        var base = name.isEmpty ? "Connection" : name
        if let client, client.caseInsensitiveCompare(base) != .orderedSame { base = "\(client) – \(base)" }
        let suffix = readOnly ? readOnlySuffix : ""
        if base.count + suffix.count > maxNameLength { base = String(base.prefix(maxNameLength - suffix.count)).trimmingCharacters(in: .whitespaces) }
        return base + suffix
    }

    public static func displayName(for connection: Connection, clientName: String?) -> String {
        displayName(connectionName: connection.name, clientName: clientName, readOnly: connection.mountReadOnly)
    }

    /// Makes names unique among the locations already in Finder: "Prod", "Prod 2", "Prod 3".
    public static func uniqueDisplayName(_ name: String, among taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let (base, suffix) = name.hasSuffix(readOnlySuffix) ? (String(name.dropLast(readOnlySuffix.count)), readOnlySuffix) : (name, "")
        var n = 2
        while taken.contains("\(base) \(n)\(suffix)") { n += 1 }
        return "\(base) \(n)\(suffix)"
    }

    /// Slashes and colons are path separators in Finder; control characters and runs of spaces are dropped.
    static func clean(_ s: String) -> String {
        let mapped = s.unicodeScalars.map { u -> Character in
            if u == "/" || u == ":" || CharacterSet.controlCharacters.contains(u) { return " " }
            return Character(u)
        }
        return String(mapped).split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// Stable File Provider domain identifier for a connection.
    public static func domainIdentifier(for connectionId: UUID) -> String { identifierPrefix + connectionId.uuidString }

    public static func connectionId(fromDomainIdentifier id: String) -> UUID? {
        guard id.hasPrefix(identifierPrefix) else { return nil }
        return UUID(uuidString: String(id.dropFirst(identifierPrefix.count)))
    }
}

public struct MountDomainSpec: Sendable, Equatable {
    public var identifier: String
    public var connectionId: UUID
    public var displayName: String
    public var readOnly: Bool
}

public enum MountPolicy {
    /// PROD connections mount read-only unless the user turned that off.
    public static func defaultReadOnly(isProd: Bool) -> Bool { isProd }

    /// Mounts always use the normal user, never su or sudo.
    public static func config(for connection: Connection) -> ConnectionConfig {
        var c = connection.config
        c.elevation = .none
        return c
    }

    /// Protocols the File Provider extension can serve.
    public static func canMount(_ connection: Connection) -> Bool { !connection.removedFromSource }

    /// Domains that should exist, for every connection with "Mount in Finder" on.
    public static func desiredDomains(connections: [Connection], clientNames: [UUID: String] = [:]) -> [MountDomainSpec] {
        var taken = Set<String>()
        var out: [MountDomainSpec] = []
        for c in connections.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }) where c.mountInFinder && canMount(c) {
            let name = MountNaming.uniqueDisplayName(
                MountNaming.displayName(for: c, clientName: c.clientFolderId.flatMap { clientNames[$0] }), among: taken)
            taken.insert(name)
            out.append(MountDomainSpec(identifier: MountNaming.domainIdentifier(for: c.id), connectionId: c.id, displayName: name, readOnly: c.mountReadOnly))
        }
        return out
    }

    /// Connections to mount when Dockyard opens.
    public static func mountOnLaunch(_ connections: [Connection]) -> [Connection] {
        connections.filter { $0.mountInFinder && $0.mountOnLaunch && canMount($0) }
    }

    public struct DomainDiff: Sendable, Equatable {
        public var add: [MountDomainSpec] = []
        public var remove: [String] = []
        /// Existing domains whose Finder name or read-only state changed.
        public var update: [MountDomainSpec] = []
        public var isEmpty: Bool { add.isEmpty && remove.isEmpty && update.isEmpty }
    }

    /// What to do to bring the registered File Provider domains in line with the connections.
    /// A deleted connection (or one with mounting turned off) loses its domain.
    public static func reconcile(registered: [MountDomainSpec], connections: [Connection], clientNames: [UUID: String] = [:]) -> DomainDiff {
        let desired = desiredDomains(connections: connections, clientNames: clientNames)
        let have = Dictionary(registered.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        let want = Dictionary(desired.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        var diff = DomainDiff()
        diff.add = desired.filter { have[$0.identifier] == nil }
        diff.remove = registered.map(\.identifier).filter { want[$0] == nil }.sorted()
        diff.update = desired.filter { w in have[w.identifier].map { $0.displayName != w.displayName || $0.readOnly != w.readOnly } ?? false }
        return diff
    }
}

/// How often the extension re-lists the folders Finder is showing (SFTP/FTP have no change notifications).
public struct MountPollingSettings: Sendable, Equatable, Codable {
    public static let defaultInterval: TimeInterval = 30
    public static let range: ClosedRange<TimeInterval> = 5...3600
    public static let maxBackoff: TimeInterval = 600

    public var interval: TimeInterval

    public init(interval: TimeInterval = MountPollingSettings.defaultInterval) {
        self.interval = Self.clamp(interval)
    }

    static func clamp(_ v: TimeInterval) -> TimeInterval {
        v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : defaultInterval
    }

    /// Delay before the next poll. Doubles per consecutive failure, capped at ten minutes.
    public func delay(afterConsecutiveFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return interval }
        let factor = pow(2.0, Double(min(failures, 10)))
        return min(max(interval, Self.maxBackoff) , interval * factor)
    }
}

public struct RemoteVersion: Sendable, Equatable {
    public var modified: Date?
    public var size: UInt64?
    public init(modified: Date?, size: UInt64?) { self.modified = modified; self.size = size }
    public init(_ item: RemoteItem) { self.init(modified: item.modified, size: item.size) }
}

public enum MountConflict {
    public enum Decision: Sendable, Equatable {
        case upload
        /// Keep the server file and save the local edit as a conflict copy; log a warning.
        case keepBoth(conflictName: String)
    }

    /// Both sides changed since the file was downloaded.
    public static func isConflict(downloaded: RemoteVersion, currentRemote: RemoteVersion?, locallyEdited: Bool, tolerance: TimeInterval = 1) -> Bool {
        guard locallyEdited, let now = currentRemote else { return false }
        if let a = downloaded.modified, let b = now.modified, abs(a.timeIntervalSince(b)) > tolerance { return true }
        if let a = downloaded.size, let b = now.size, a != b { return true }
        return false
    }

    /// Decides what to do when Finder hands back an edited file.
    public static func decide(
        fileName: String, downloaded: RemoteVersion, currentRemote: RemoteVersion?, locallyEdited: Bool,
        siblings: Set<String>, now: Date, timeZone: TimeZone = .current
    ) -> Decision {
        guard isConflict(downloaded: downloaded, currentRemote: currentRemote, locallyEdited: locallyEdited) else { return .upload }
        return .keepBoth(conflictName: FileNaming.uniqueConflictCopy(fileName, date: now, existing: siblings, timeZone: timeZone))
    }

    public static func warning(for fileName: String, conflictName: String) -> String {
        "\(fileName) changed on the server and locally; kept both, local edit saved as \(conflictName)"
    }
}

public enum FinderLog {
    public static let sourcePrefix = "Finder: "
    /// Operations started from Finder appear in the connection's Log with this prefix.
    public static func message(_ operation: String) -> String { sourcePrefix + operation }
    public static func isFromFinder(_ line: LogLine) -> Bool { line.message.hasPrefix(sourcePrefix) }
}

/// What changed between two listings of a folder (drives the File Provider working set).
public struct DirectoryChange: Sendable, Equatable {
    public var added: [RemoteItem] = []
    public var modified: [RemoteItem] = []
    public var deleted: [RemoteItem] = []
    public var isEmpty: Bool { added.isEmpty && modified.isEmpty && deleted.isEmpty }
}

public enum DirectoryChangeDetector {
    public static func diff(old: [RemoteItem], new: [RemoteItem], timeTolerance: TimeInterval = 1) -> DirectoryChange {
        let oldBy = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let newBy = Dictionary(new.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var change = DirectoryChange()
        for item in new {
            guard let before = oldBy[item.name] else { change.added.append(item); continue }
            let timeChanged: Bool = {
                guard let a = before.modified, let b = item.modified else { return false }
                return abs(a.timeIntervalSince(b)) > timeTolerance
            }()
            if before.isDirectory != item.isDirectory || before.size != item.size || timeChanged { change.modified.append(item) }
        }
        change.deleted = old.filter { newBy[$0.name] == nil }
        return change
    }
}
