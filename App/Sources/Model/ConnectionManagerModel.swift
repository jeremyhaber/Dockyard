import ConnectionKit
import DockyardCore
import Foundation
import Observation

enum LastUsedChoice: String, CaseIterable, Identifiable {
    case last7 = "Last 7 days", last30 = "Last 30 days", never = "Never connected"
    var id: String { rawValue }

    var filter: ConnectionFilter.LastUsed {
        switch self {
        case .last7: .within(days: 7)
        case .last30: .within(days: 30)
        case .never: .never
        }
    }
}

enum ManagerScope: Hashable {
    case all, favorites, openNow, recentlyAdded
    case whm(UUID)
    case filezilla, manual, quickConnect
}

struct ManagerFilterKey: Hashable {
    var scope: ManagerScope
    var search: String
    var protocols: [String]
    var whmServer: UUID?
    var tag: String?
    var lastUsed: LastUsedChoice?
    var revision: Int
    var openCount: Int
}

@MainActor @Observable
final class ConnectionManagerModel {
    var scope = ManagerScope.all
    var search = ""
    var protocols: Set<ConnectionProtocol> = []
    var whmServer: UUID?
    var tag: String?
    var lastUsed: LastUsedChoice?
    var selection: Set<UUID> = []
    var notice: String?

    private(set) var results: [Connection] = []
    private(set) var whmSources: [WHMSource] = []
    private(set) var counts: [String: Int] = [:]
    private(set) var tags: [String] = []

    func key(app: AppModel) -> ManagerFilterKey {
        ManagerFilterKey(
            scope: scope, search: search, protocols: protocols.map(\.rawValue).sorted(), whmServer: whmServer,
            tag: tag, lastUsed: lastUsed, revision: app.connectionsRevision, openCount: app.sessions.count)
    }

    func filter(app: AppModel) -> ConnectionFilter {
        let scopeFilter: ConnectionFilter.Scope
        switch scope {
        case .all: scopeFilter = .all
        case .favorites: scopeFilter = .favorites
        case .openNow: scopeFilter = .ids(Array(Set(app.sessions.map(\.connection.id))))
        case .recentlyAdded: scopeFilter = .recentlyAdded(limit: 50)
        case .whm(let id): scopeFilter = .source(.whm(id))
        case .filezilla: scopeFilter = .source(.filezillaImport)
        case .manual: scopeFilter = .source(.manual)
        case .quickConnect: scopeFilter = .source(.quickConnect)
        }
        return ConnectionFilter(
            scope: scopeFilter, search: search, protocols: protocols, whmServer: whmServer,
            tag: tag, lastUsed: lastUsed?.filter)
    }

    func reload(app: AppModel) async {
        let filter = filter(app: app)
        let repo = app.connections
        if let rows = try? await repo.fetch(filter) { results = rows }
        if let sources = try? await app.whmSources.all() { whmSources = sources }
        if let c = try? await repo.sourceCounts() { counts = c }
        if let t = try? await repo.allTags() { tags = t }
        let visible = Set(results.map(\.id))
        selection = selection.intersection(visible)
    }

    func count(for source: ConnectionSource) -> Int { counts[source.rawValue] ?? 0 }

    var hasActiveFilters: Bool { !protocols.isEmpty || whmServer != nil || tag != nil || lastUsed != nil }

    func clearFilters() {
        protocols = []
        whmServer = nil
        tag = nil
        lastUsed = nil
    }

    func selectedConnections() -> [Connection] { results.filter { selection.contains($0.id) } }
}
