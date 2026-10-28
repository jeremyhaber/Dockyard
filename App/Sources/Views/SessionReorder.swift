import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A connection tab or side-by-side column header dragged to a new place, declared in Info.plist.
    /// Only this process can read it, so dropping one on Finder or a file list does nothing.
    static let dockyardSession = UTType(exportedAs: "app.dockyard.session", conformingTo: .data)
}

extension View {
    /// Lets a connection tab or column header be dragged onto another: onto its left or right quarter to move it there
    /// (the columns follow the tabs), onto its middle to group the two.
    func reordersSession(_ id: UUID) -> some View { modifier(SessionReorder(id: id)) }
}

/// Where a dragged tab lands on another.
private enum SessionDropZone {
    case before, after, group
}

private struct SessionReorder: ViewModifier {
    @Environment(AppModel.self) private var app
    let id: UUID
    @State private var zone: SessionDropZone?
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, new in width = new }
                }
            }
            .onDrag {
                app.draggedSessionID = id
                return NSItemProvider.dockyardSession(id)
            }
            .onDrop(of: [.dockyardSession], delegate: SessionDropDelegate(target: id, width: width, app: app, zone: $zone))
            .overlay(alignment: zone == .before ? .leading : .trailing) {
                switch zone {
                case .before, .after:
                    Rectangle().fill(Color.accentColor).frame(width: 2).allowsHitTesting(false)
                case .group:
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .allowsHitTesting(false)
                case nil:
                    EmptyView()
                }
            }
    }
}

extension NSItemProvider {
    static func dockyardSession(_ id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.dockyardSession.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }
}

/// Shows where the dragged tab will land and moves or groups it on drop.
private struct SessionDropDelegate: DropDelegate {
    let target: UUID
    let width: CGFloat
    let app: AppModel
    @Binding var zone: SessionDropZone?

    func validateDrop(info: DropInfo) -> Bool { app.draggedSessionID.map { $0 != target } ?? false }

    func dropEntered(info: DropInfo) { zone = zone(at: info.location.x) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = zone(at: info.location.x)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let landing = zone(at: info.location.x)
        zone = nil
        guard let id = app.draggedSessionID else { return false }
        app.draggedSessionID = nil
        withAnimation(.snappy(duration: 0.2)) {
            switch landing {
            case .before: app.moveSession(id, beside: target, after: false)
            case .after: app.moveSession(id, beside: target, after: true)
            case .group: app.groupSession(id, with: target)
            }
            // Like Chrome, the dragged tab becomes the active one, so side by side shows where it went.
            app.activeSessionID = id
        }
        return true
    }

    /// The outer quarters move the tab beside the target; the middle groups them.
    private func zone(at x: CGFloat) -> SessionDropZone {
        guard width > 0 else { return .after }
        let fraction = x / width
        return fraction < 0.25 ? .before : fraction > 0.75 ? .after : .group
    }
}

/// A group's chip takes a dropped tab as the group's first tab.
struct GroupChipDropDelegate: DropDelegate {
    let groupID: UUID
    let app: AppModel
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool { app.draggedSessionID != nil }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { targeted = false }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard let id = app.draggedSessionID else { return false }
        app.draggedSessionID = nil
        withAnimation(.snappy(duration: 0.2)) {
            app.moveSession(id, toStartOf: groupID)
            app.activeSessionID = id
        }
        return true
    }
}
