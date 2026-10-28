import DockyardCore
import Foundation

/// A coloured set of tabs, like an unnamed Chrome tab group (HANDOFF 8). Its tabs sit together in the tab bar and side by
/// side shows them as the columns. Groups are saved with their connections, so a closed group can be reopened.
struct TabGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var color: ConnectionColor
    var collapsed = false
    /// The group's connections in tab order; kept while the group is closed.
    var connectionIDs: [UUID]

    private static let defaultsKey = "tabGroups"

    static func loadSaved() -> [TabGroup] {
        guard !DemoMode.isEnabled, let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([TabGroup].self, from: data)) ?? []
    }

    static func save(_ groups: [TabGroup]) {
        guard !DemoMode.isEnabled, let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// What the connection tab bar draws, in order.
enum TabBarItem: Identifiable {
    /// An expanded group's tabs, drawn inside its outline.
    case group(TabGroup, [ConnectionSession])
    /// A collapsed group, drawn as a pill.
    case collapsed(TabGroup)
    case tab(ConnectionSession)

    var id: UUID {
        switch self {
        case .group(let group, _), .collapsed(let group): group.id
        case .tab(let session): session.id
        }
    }
}

extension AppModel {
    var activeGroupID: UUID? { activeSessionID.flatMap { sessionGroups[$0] } }

    func group(id: UUID?) -> TabGroup? { id.flatMap { id in tabGroups.first { $0.id == id } } }

    func members(of groupID: UUID) -> [ConnectionSession] { sessions.filter { sessionGroups[$0.id] == groupID } }

    func isOpen(_ group: TabGroup) -> Bool { sessionGroups.values.contains(group.id) }

    var openGroups: [TabGroup] { tabGroups.filter { isOpen($0) } }

    var closedGroups: [TabGroup] { tabGroups.filter { !isOpen($0) } }

    /// Groups have no names; they are told apart by colour and by their connections.
    func summary(of group: TabGroup) -> String {
        let names = group.connectionIDs.compactMap { id in allConnections.first { $0.id == id }?.name }
        return names.isEmpty ? "Empty group" : ListFormatter.localizedString(byJoining: names)
    }

    var tabBarItems: [TabBarItem] {
        var items: [TabBarItem] = []
        for session in sessions {
            guard let group = group(id: sessionGroups[session.id]) else {
                items.append(.tab(session))
                continue
            }
            // A group's tabs are next to each other, so each one either continues the last item or starts a new one.
            switch items.last {
            case .group(let current, let members) where current.id == group.id:
                items[items.count - 1] = .group(current, members + [session])
            case .collapsed(let current) where current.id == group.id:
                continue
            default:
                items.append(group.collapsed ? .collapsed(group) : .group(group, [session]))
            }
        }
        return items
    }

    // MARK: Membership

    /// A new, empty group in the first colour no other group uses.
    private func makeGroup() -> TabGroup {
        let used = Set(tabGroups.map(\.color))
        let group = TabGroup(id: UUID(), color: ConnectionColor.allCases.first { !used.contains($0) } ?? .blue, connectionIDs: [])
        tabGroups.append(group)
        return group
    }

    /// Puts a tab in a group, or takes it out with nil. It moves to the end of the group it joins, or to just after
    /// the group it leaves, so each group's tabs stay together. A group left with one tab is dissolved.
    func setGroup(_ session: ConnectionSession, to groupID: UUID?) {
        guard let old = assign(session, to: groupID) else { return }
        settle([old])
    }

    /// Moves a tab into a group (or out with nil) without settling the groups. Returns its old group, or nil when
    /// nothing changed.
    private func assign(_ session: ConnectionSession, to groupID: UUID?) -> UUID?? {
        let old = sessionGroups[session.id]
        guard old != groupID, let from = sessions.firstIndex(where: { $0.id == session.id }) else { return nil }
        sessionGroups[session.id] = groupID
        // Next to the group it joins, or (joining a new group) just after the one it leaves.
        let anchors = [groupID, old].compactMap { $0 }
        if let last = anchors.lazy.compactMap({ anchor in
            self.sessions.lastIndex { $0.id != session.id && self.sessionGroups[$0.id] == anchor }
        }).first {
            placeSession(session.id, at: from < last ? last : last + 1)
        }
        return .some(old)
    }

    /// Drops tab `id` on the edge of tab `target`: it moves just before or after it. It joins the target's group
    /// when it lands inside the group's run of tabs and leaves its own group when it lands outside it, so each group's
    /// tabs stay together. Side by side columns follow the tab order.
    func moveSession(_ id: UUID, beside target: UUID, after: Bool) {
        guard id != target, sessions.contains(where: { $0.id == id }) else { return }
        let others = sessions.filter { $0.id != id }
        guard let index = others.firstIndex(where: { $0.id == target }) else { return }
        let slot = after ? index + 1 : index
        let targetGroup = sessionGroups[target]
        let neighbourIndex = after ? index + 1 : index - 1
        let neighbour = others.indices.contains(neighbourIndex) ? others[neighbourIndex] : nil
        let joins = targetGroup != nil
            && (sessionGroups[id] == targetGroup || neighbour.map { sessionGroups[$0.id] == targetGroup } == true)
        regroup(id, to: joins ? targetGroup : nil, at: slot)
    }

    /// Drops tab `id` on the middle of tab `target`: it joins the target's group, or starts a new group with it.
    func groupSession(_ id: UUID, with target: UUID) {
        guard id != target, sessions.contains(where: { $0.id == id }) else { return }
        let groupID = sessionGroups[target] ?? {
            let group = makeGroup()
            sessionGroups[target] = group.id
            return group.id
        }()
        let others = sessions.filter { $0.id != id }
        guard let index = others.firstIndex(where: { $0.id == target }) else { return }
        regroup(id, to: groupID, at: index + 1)
    }

    /// Moves a tab to `slot` in the tab order without it and sets its group, then settles the group it left.
    private func regroup(_ id: UUID, to groupID: UUID?, at slot: Int) {
        let old = sessionGroups[id]
        sessionGroups[id] = groupID
        placeSession(id, at: slot)
        settle([old])
    }

    /// A group always holds at least two open tabs: one left with a single tab is dissolved and one left empty is
    /// deleted. Then saves each open group's
    /// connections. Only `touched` groups are checked, so closed groups are kept.
    private func settle(_ touched: [UUID?]) {
        for groupID in Set(touched.compactMap { $0 }) {
            let members = members(of: groupID)
            guard members.count < 2 else { continue }
            if let lone = members.first { sessionGroups[lone.id] = nil }
            tabGroups.removeAll { $0.id == groupID }
        }
        syncGroupConnections()
    }

    /// Drops a tab onto a group's chip: it joins the group as its first tab.
    func moveSession(_ id: UUID, toStartOf groupID: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        setGroup(session, to: groupID)
        if let first = sessions.firstIndex(where: { sessionGroups[$0.id] == groupID }) { placeSession(id, at: first) }
        syncGroupConnections()
    }

    /// Before a tab closes: drops its connection from its group, dissolving the group if one tab is left.
    /// (Close Group detaches every tab first, so the group stays saved.) Returns another tab in the group to activate.
    func leaveGroupOnClose(_ session: ConnectionSession) -> UUID? {
        guard let groupID = sessionGroups.removeValue(forKey: session.id) else { return nil }
        let others = members(of: groupID)
        if !others.isEmpty { settle([groupID]) }
        return (others.first { $0.id == groupLastActive[groupID] } ?? others.first)?.id
    }

    /// Saves each open group's connections in tab order.
    private func syncGroupConnections() {
        var groups = tabGroups
        for index in groups.indices where isOpen(groups[index]) {
            var seen = Set<UUID>()
            let ids = members(of: groups[index].id).map(\.connection.id).filter { seen.insert($0).inserted }
            groups[index].connectionIDs = ids
        }
        if groups != tabGroups { tabGroups = groups }
    }

    func noteGroupActivation(_ groupID: UUID, session: UUID) {
        groupLastActive[groupID] = session
        if let index = tabGroups.firstIndex(where: { $0.id == groupID }), tabGroups[index].collapsed {
            tabGroups[index].collapsed = false
        }
    }

    // MARK: Whole groups

    /// Clicking a group's chip: shows its tabs (as the columns in side by side), back on the tab last used there.
    func showGroup(_ group: TabGroup) {
        let members = members(of: group.id)
        guard !members.isEmpty else { return openGroup(group) }
        if let active = activeSessionID, members.contains(where: { $0.id == active }) {
            noteGroupActivation(group.id, session: active)
            return
        }
        activeSessionID = (members.first { $0.id == groupLastActive[group.id] } ?? members[0]).id
    }

    /// Reopens a closed group's connections side by side, reusing ungrouped tabs that are already open.
    func openGroup(_ group: TabGroup) {
        let connections = group.connectionIDs.compactMap { id in allConnections.first { $0.id == id } }
        guard !connections.isEmpty else {
            alertMessage = "The connections in this group no longer exist."
            return
        }
        var first: UUID?
        var touched: [UUID?] = [group.id]
        for connection in connections {
            let session: ConnectionSession
            if let loose = sessions.first(where: { $0.connection.id == connection.id && sessionGroups[$0.id] == nil }) {
                session = loose
            } else {
                open(connection, newTab: true)
                guard let opened = activeSession, opened.connection.id == connection.id else { continue }
                session = opened
            }
            // New tabs can join the group on screen first; settle once all are in, so a half-open group isn't dissolved.
            if let old = assign(session, to: group.id) { touched.append(old) }
            first = first ?? session.id
        }
        settle(touched)
        if let index = tabGroups.firstIndex(where: { $0.id == group.id }) { tabGroups[index].collapsed = false }
        if let first { activeSessionID = first }
    }

    func setColor(_ color: ConnectionColor, for group: TabGroup) {
        if let index = tabGroups.firstIndex(where: { $0.id == group.id }) { tabGroups[index].color = color }
    }

    /// Collapsing hides the group's tabs behind its chip; the active tab moves to the nearest tab outside it.
    func toggleCollapsed(_ group: TabGroup) {
        guard let index = tabGroups.firstIndex(where: { $0.id == group.id }) else { return }
        if !tabGroups[index].collapsed, activeGroupID == group.id {
            guard let outside = sessions.last(where: { sessionGroups[$0.id] != group.id }) else { return }
            tabGroups[index].collapsed = true
            activeSessionID = outside.id
        } else {
            tabGroups[index].collapsed.toggle()
        }
    }

    /// Keeps the tabs open and forgets the group.
    func ungroup(_ group: TabGroup) {
        for session in members(of: group.id) { sessionGroups[session.id] = nil }
        tabGroups.removeAll { $0.id == group.id }
    }

    /// Closes the group's tabs and keeps the group saved, so its chip can reopen them.
    func closeGroup(_ group: TabGroup) {
        let members = members(of: group.id)
        let ids = Set(members.map(\.id))
        for session in members { sessionGroups[session.id] = nil }
        if let active = activeSessionID, ids.contains(active) {
            activeSessionID = sessions.last { !ids.contains($0.id) }?.id
        }
        for session in members { close(session) }
    }

    func deleteGroup(_ group: TabGroup) {
        guard Dialogs.confirm(
            title: "Delete this tab group?",
            message: isOpen(group) ? "Its tabs will close." : "The connections stay saved.",
            confirm: "Delete Group"
        ) else { return }
        closeGroup(group)
        tabGroups.removeAll { $0.id == group.id }
    }
}
