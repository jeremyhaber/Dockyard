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
    }
}

/// Shared drop logic for the file list and the folder tree.
@MainActor
enum DropHandler {
    struct Resolved {
        var items: [RemoteItem]
        var originSide: PaneSide
        var sameFileSystem: Bool
    }

    static func resolve(_ info: NSDraggingInfo, pane: PaneModel, session: ConnectionSession) -> Resolved? {
        if let origin = DragState.origin, origin.session == session.id, !DragState.items.isEmpty {
            return Resolved(items: DragState.items, originSide: origin.side, sameFileSystem: origin.side == pane.side)
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
        guard let resolved = resolve(info, pane: pane, session: session) else { return [] }
        let option = NSEvent.modifierFlags.contains(.option)
        let plan = DropPlanner.plan(
            items: resolved.items, destinationDirectory: directory,
            sameFileSystem: resolved.sameFileSystem, optionKey: option)
        switch plan {
        case .move: return .move
        case .copy: return .copy
        case .reject: return []
        }
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
            session.queueTransfer(
                resolved.items, from: resolved.originSide, to: pane.side, directory: directory,
                move: false, queue: app.queue)
        }
        DragState.clear()
        return true
    }
}
