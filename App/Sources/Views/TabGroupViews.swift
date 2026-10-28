import DockyardCore
import SwiftUI

/// An expanded group's tabs in the tab bar, inside a rounded outline in the group's colour. The outline is
/// stronger while the group is on screen side by side.
struct TabGroupOutline<Content: View>: View {
    @Environment(AppModel.self) private var app
    let group: TabGroup
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shown = app.activeGroupID == group.id
        HStack(spacing: 2) { content() }
            .padding(2)
            .background(group.color.color.opacity(shown ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(group.color.color.opacity(shown ? 1 : 0.55), lineWidth: shown ? 2 : 1.5)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tab group: \(app.summary(of: group))")
    }
}

/// A collapsed or closed group in the tab bar: an outlined pill with how many tabs it holds (dashed when closed).
/// A collapsed group's pill expands it and takes dropped tabs; a closed group's pill reopens it side by side.
struct TabGroupChip: View {
    @Environment(AppModel.self) private var app
    let group: TabGroup
    let isOpen: Bool
    @State private var targeted = false

    var body: some View {
        let count = isOpen ? app.members(of: group.id).count : group.connectionIDs.count
        let summary = app.summary(of: group)
        HStack(spacing: 4) {
            Image(systemName: "square.stack").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
            Text("\(count)").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(group.color.color)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background {
            if isOpen { RoundedRectangle(cornerRadius: 8).fill(group.color.color.opacity(targeted ? 0.2 : 0.06)) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(group.color.color, style: StrokeStyle(lineWidth: 1.5, dash: isOpen ? [] : [3, 2]))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { isOpen ? app.showGroup(group) : app.openGroup(group) }
        .onDrop(of: isOpen ? [.dockyardSession] : [], delegate: GroupChipDropDelegate(groupID: group.id, app: app, targeted: $targeted))
        .contextMenu { TabGroupActions(group: group, isOpen: isOpen) }
        .help(isOpen ? "\(summary)\nClick to expand; drop a tab here to add it." : "\(summary)\nClick to reopen side by side.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOpen ? "Collapsed tab group: \(summary)" : "Closed tab group: \(summary)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Whole-group commands: a collapsed or closed group's pill menu, and the "Tab Group" submenu on a grouped tab.
private struct TabGroupActions: View {
    @Environment(AppModel.self) private var app
    let group: TabGroup
    let isOpen: Bool

    var body: some View {
        if isOpen {
            Button(group.collapsed ? "Expand Group" : "Collapse Group") { app.toggleCollapsed(group) }
        } else {
            Button("Reopen Group") { app.openGroup(group) }
        }
        TabGroupColorMenu(group: group)
        Divider()
        if isOpen {
            Button("Ungroup") { app.ungroup(group) }
            Button("Close Group") { app.closeGroup(group) }
        }
        Button("Delete Group\u{2026}") { app.deleteGroup(group) }
    }
}

/// "Colour" submenu for a tab group.
private struct TabGroupColorMenu: View {
    @Environment(AppModel.self) private var app
    let group: TabGroup

    var body: some View {
        Menu("Colour") {
            ForEach(ConnectionColor.allCases, id: \.self) { color in
                Button {
                    app.setColor(color, for: group)
                } label: {
                    Label { Text(group.color == color ? "\(color.title) \u{2713}" : color.title) } icon: { Image(nsImage: color.swatch) }
                }
            }
        }
    }
}

/// Group items for a tab's or column header's context menu.
struct TabGroupMenuItems: View {
    @Environment(AppModel.self) private var app
    let session: ConnectionSession

    var body: some View {
        let current = app.sessionGroups[session.id]
        let others = app.openGroups.filter { $0.id != current }
        let loose = app.sessions.filter { $0.id != session.id && app.sessionGroups[$0.id] == nil }
        if !loose.isEmpty {
            // A group needs two tabs, so a new one starts with another ungrouped tab.
            Menu("Group With") {
                ForEach(loose) { other in
                    Button(other.connection.name) { app.groupSession(session.id, with: other.id) }
                }
            }
        }
        if !others.isEmpty {
            Menu("Add to Group") {
                ForEach(others) { group in
                    Button {
                        app.setGroup(session, to: group.id)
                    } label: {
                        Label { Text(app.summary(of: group)) } icon: { Image(nsImage: group.color.swatch) }
                    }
                }
            }
        }
        if let group = app.group(id: current) {
            Button("Remove from Group") { app.setGroup(session, to: nil) }
            Menu("Tab Group") { TabGroupActions(group: group, isOpen: true) }
        }
    }
}
