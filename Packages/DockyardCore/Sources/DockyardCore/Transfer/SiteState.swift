import Foundation
import ConnectionKit

struct FIFO<Element> {
    private var items: [Element] = []
    private var head = 0

    var count: Int { items.count - head }
    var isEmpty: Bool { count == 0 }
    var first: Element? { head < items.count ? items[head] : nil }

    mutating func append(_ e: Element) { items.append(e) }

    mutating func popFirst() -> Element? {
        guard head < items.count else { return nil }
        let e = items[head]
        head += 1
        if head > 512 && head * 2 > items.count { items.removeFirst(head); head = 0 }
        return e
    }

    mutating func removeAll() { items.removeAll(); head = 0 }

    mutating func remove(where predicate: (Element) -> Bool) -> Element? {
        guard let i = items[head...].firstIndex(where: predicate) else { return nil }
        return items.remove(at: i)
    }
}

/// A window onto the queued rows of one site and kind. Rows with `id <= cursor` are either in the
/// window or no longer queued; later rows are loaded from SQLite as the window drains.
struct Lane {
    var window = FIFO<JobRecord>()
    var cursor: Int64 = 0
    /// Everything queued with `id > cursor` is known to be absent from SQLite, so new rows can be appended directly.
    var tailKnownEmpty = false
    var skippedAdds = false
    var refilling = false
    var generation = 0

    static let windowSize = 512

    mutating func reset() {
        window.removeAll()
        cursor = 0
        tailKnownEmpty = false
        skippedAdds = true
        generation += 1
    }

    mutating func add(_ record: JobRecord) {
        if tailKnownEmpty && window.count < Self.windowSize * 2 && record.id > cursor {
            window.append(record)
            cursor = record.id
        } else {
            skippedAdds = true
            tailKnownEmpty = false
        }
    }
}

enum SessionLease: @unchecked Sendable {
    case idle(any RemoteFileSystem)
    case connect
    case shared(any RemoteFileSystem)
    case local
}

/// Per-site queues plus the connection pool bookkeeping. Only touched from `TransferQueue`.
final class SiteState {
    let key: String
    var label: String
    var profile: TransferSite?
    /// Caller-owned session used when no `TransferSite` is registered (never closed, no limits).
    var shared: (any RemoteFileSystem)?

    var files = Lane()
    var dirs = Lane()
    var retry: [(due: Date, record: JobRecord)] = []
    var isPaused = false

    var maxLimit: Int
    var liveLimit: Int
    var connectDelay: TimeInterval
    var inUse = 0
    var idle: [(fs: any RemoteFileSystem, since: Date)] = []
    var nextConnectAt = Date.distantPast
    var successStreak = 0

    var isLocal: Bool { key == JobRecord.localKey }
    var isPooled: Bool { profile != nil }
    /// False for a restored site whose connection details have not been looked up yet.
    var isResolved: Bool { isLocal || isPooled || shared != nil }

    /// `empty` is true for a site created now: SQLite holds no queued rows for it yet.
    init(key: String, label: String, profile: TransferSite? = nil, empty: Bool = false) {
        self.key = key
        self.label = label
        self.profile = profile
        files.tailKnownEmpty = empty
        dirs.tailKnownEmpty = empty
        let max = profile?.maxConnections ?? Int.max
        maxLimit = max
        liveLimit = max
        connectDelay = TimeInterval(profile?.connectDelayMs ?? 0) / 1000
    }

    func apply(_ profile: TransferSite) {
        self.profile = profile
        label = profile.label
        connectDelay = TimeInterval(profile.connectDelayMs) / 1000
        let wasAtMax = liveLimit >= maxLimit
        maxLimit = profile.maxConnections
        liveLimit = wasAtMax ? maxLimit : min(liveLimit, maxLimit)
    }

    var live: Int { inUse + idle.count }
    var hasReadyWork: Bool { !files.window.isEmpty || !dirs.window.isEmpty || !retry.isEmpty }

    /// Earliest time a new connection may be opened, or nil when one can be opened now.
    func canStart(now: Date) -> Bool {
        guard isResolved else { return false }
        guard isPooled else { return true }
        guard inUse < liveLimit else { return false }
        return !idle.isEmpty || now >= nextConnectAt
    }

    func reserve(now: Date) -> SessionLease {
        if isLocal { return .local }
        guard isPooled else { return .shared(shared!) }
        inUse += 1
        if let session = idle.popLast() { return .idle(session.fs) }
        nextConnectAt = now.addingTimeInterval(connectDelay)
        return .connect
    }

    /// Sessions beyond the live limit that should be closed right now.
    func excessIdle() -> [any RemoteFileSystem] {
        var out: [any RemoteFileSystem] = []
        while live > liveLimit, let s = idle.popLast() { out.append(s.fs) }
        return out
    }

    func expiredIdle(now: Date, timeout: TimeInterval) -> [any RemoteFileSystem] {
        var out: [any RemoteFileSystem] = []
        idle.removeAll { entry in
            guard now.timeIntervalSince(entry.since) >= timeout else { return false }
            out.append(entry.fs)
            return true
        }
        return out
    }

    /// Lowers the limit by one, or to one below the connections that were open when the server said no,
    /// whichever is lower (never under 1). `openConnections` includes the refused attempt.
    func noteRefusal(openConnections: Int) {
        successStreak = 0
        liveLimit = max(1, min(liveLimit - 1, openConnections - 1))
    }

    /// Returns true when the limit was raised.
    func noteSuccess(recoverAfter: Int) -> Bool {
        guard isPooled, liveLimit < maxLimit else { return false }
        successStreak += 1
        guard successStreak >= recoverAfter else { return false }
        successStreak = 0
        liveLimit += 1
        return true
    }
}
