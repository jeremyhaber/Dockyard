import AppKit
import ConnectionKit
import DockyardCore

extension NSPasteboard.PasteboardType {
    static let dockyardItems = NSPasteboard.PasteboardType("app.dockyard.items")
}

/// What is being dragged between panes. Set when a drag starts in one of our tables.
@MainActor
enum DragState {
    static var origin: (session: UUID, side: PaneSide)?
    static var items: [RemoteItem] = []

    static func clear() {
        origin = nil
        items = []
        AppModel.shared.dropHint = nil
    }
}

/// Shared drop logic for the file list and the folder tree.
@MainActor
enum DropHandler {
    struct Resolved {
        var items: [RemoteItem]
        var originSide: PaneSide
        var sameFileSystem: Bool
        /// The session the drag started in, when that is not the target's session and its server files are dragged.
        var originSession: ConnectionSession?

        /// Server to server between two connections, relayed through this Mac.
        func isRelay(to side: PaneSide) -> Bool { originSession != nil && side == .server }
    }

    static func resolve(_ info: NSDraggingInfo, pane: PaneModel, session: ConnectionSession) -> Resolved? {
        if let origin = DragState.origin, !DragState.items.isEmpty {
            if origin.session == session.id {
                return Resolved(items: DragState.items, originSide: origin.side, sameFileSystem: origin.side == pane.side)
            }
            // This Mac is the same disk whichever connection's local pane the drag started in, so the rail of a group
            // uploads to any of its columns.
            if origin.side == .local {
                return Resolved(items: DragState.items, originSide: .local, sameFileSystem: pane.side == .local)
            }
            // Another connection's server files: relayed through this Mac to a server, or downloaded to it.
            guard let other = AppModel.shared.sessions.first(where: { $0.id == origin.session }) else { return nil }
            return Resolved(items: DragState.items, originSide: .server, sameFileSystem: false, originSession: other)
        }
        // Files dragged from Finder.
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        let local = LocalFileSystem()
        let items = urls.compactMap { local.stat(path: $0.path) }
        guard !items.isEmpty else { return nil }
        return Resolved(items: items, originSide: .local, sameFileSystem: false)
    }

    static func operation(
        _ info: NSDraggingInfo, pane: PaneModel, session: ConnectionSession, directory: String
    ) -> NSDragOperation {
        guard let resolved = resolve(info, pane: pane, session: session) else {
            AppModel.shared.dropHint = nil
            return []
        }
        let option = NSEvent.modifierFlags.contains(.option)
        let plan = DropPlanner.plan(
            items: resolved.items, destinationDirectory: directory,
            sameFileSystem: resolved.sameFileSystem, optionKey: option)
        let isRelay = resolved.isRelay(to: pane.side)
        switch plan {
        case .move:
            AppModel.shared.dropHint = hint(resolved, pane: pane, session: session, verb: "move")
            return .move
        case .copy:
            AppModel.shared.dropHint = hint(resolved, pane: pane, session: session, verb: isRelay && option ? "move" : "copy")
            return isRelay && option ? .move : .copy
        case .reject:
            AppModel.shared.dropHint = nil
            return []
        }
    }

    /// "Drop to copy 2 files here \u{00B7} Prod \u{2192} Staging".
    static func hint(_ resolved: Resolved, pane: PaneModel, session: ConnectionSession, verb: String) -> DropHint {
        let source = resolved.originSession ?? session
        let from = resolved.originSide == .local ? "This Mac" : source.connection.name
        let to = pane.side == .local ? "This Mac" : session.connection.name
        let files = resolved.items.filter { !$0.isDirectory }.count
        let folders = resolved.items.count - files
        var what: [String] = []
        if files > 0 { what.append("\(files) file\(files == 1 ? "" : "s")") }
        if folders > 0 { what.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        let route = resolved.sameFileSystem ? "" : " \u{00B7} \(from) \u{2192} \(to)"
        return DropHint(paneID: pane.id, text: "Drop to \(verb) \(what.joined(separator: " and ")) here\(route)")
    }

    static func perform(
        _ info: NSDraggingInfo, app: AppModel, pane: PaneModel, session: ConnectionSession, directory: String
    ) -> Bool {
        guard let resolved = resolve(info, pane: pane, session: session) else { return false }
        let option = NSEvent.modifierFlags.contains(.option)
        let plan = DropPlanner.plan(
            items: resolved.items, destinationDirectory: directory,
            sameFileSystem: resolved.sameFileSystem, optionKey: option)
        switch plan {
        case .reject:
            return false
        case .move:
            let items = resolved.items
            Task { await session.move(items, to: directory, in: pane.side) }
        case .copy:
            let source = resolved.originSession ?? session
            var rule: ConflictPolicy?
            let isRelay = resolved.isRelay(to: pane.side)
            if option, !isRelay {
                // Option on a transfer between this Mac and a server asks which rule to use for existing files.
                guard let chosen = ConflictRuleMenu.choose(for: info) else {
                    DragState.clear()
                    return false
                }
                rule = chosen == .ask ? nil : chosen
            }
            app.transfer(
                resolved.items, from: source, resolved.originSide, to: session, pane.side, directory: directory,
                move: isRelay && option, conflict: rule)
        }
        DragState.clear()
        return true
    }
}

/// A small menu of the rules for existing files, shown where the user dropped while holding Option.
@MainActor
enum ConflictRuleMenu {
    /// The chosen rule (`.ask` for "use the default"), or nil when the menu was dismissed.
    static func choose(for info: NSDraggingInfo) -> ConflictPolicy? {
        let menu = NSMenu(title: "Existing files")
        let header = NSMenuItem(title: "If a file already exists", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        var chosen: ConflictPolicy?
        let handler = RuleHandler { chosen = $0 }
        for policy in ConflictPolicy.allCases {
            let item = NSMenuItem(title: policy == .ask ? "Use the default" : policy.title, action: #selector(RuleHandler.pick(_:)), keyEquivalent: "")
            item.target = handler
            item.representedObject = policy.rawValue
            menu.addItem(item)
            if policy == .ask { menu.addItem(.separator()) }
        }
        let view = info.draggingDestinationWindow?.contentView
        let location = view.map { $0.convert(info.draggingLocation, from: nil) } ?? .zero
        menu.popUp(positioning: nil, at: location, in: view)
        return chosen
    }

    private final class RuleHandler: NSObject {
        let onPick: (ConflictPolicy) -> Void
        init(onPick: @escaping (ConflictPolicy) -> Void) { self.onPick = onPick }
        @objc func pick(_ sender: NSMenuItem) {
            if let raw = sender.representedObject as? String, let policy = ConflictPolicy(rawValue: raw) { onPick(policy) }
        }
    }
}
