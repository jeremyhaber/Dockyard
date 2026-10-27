import AppKit
import SwiftUI

/// Shows a SwiftUI view as a sheet on whichever Dockyard window is in front, so menu commands and the
/// Connections window can open the same dialogs.
@MainActor
enum SheetPresenter {
    private final class Handle {
        weak var parent: NSWindow?
        weak var sheet: NSWindow?

        func close() {
            guard let parent, let sheet else { return }
            parent.endSheet(sheet)
        }
    }

    /// `content` receives a closure that dismisses the sheet. Does nothing when the window already shows a sheet.
    static func present<Content: View>(@ViewBuilder _ content: (@escaping @MainActor () -> Void) -> Content) {
        guard let parent = frontWindow(), parent.attachedSheet == nil else { return }
        let handle = Handle()
        let root = content { handle.close() }.environment(AppModel.shared)
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: root))
        handle.parent = parent
        handle.sheet = sheet
        parent.beginSheet(sheet)
    }

    static func frontWindow() -> NSWindow? {
        let preferred = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        let candidates = preferred + NSApp.windows.filter { $0.isVisible }
        return candidates.first { $0.canBecomeMain && $0.sheetParent == nil }
    }
}
