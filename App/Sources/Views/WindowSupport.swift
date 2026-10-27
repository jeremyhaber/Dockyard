import AppKit
import SwiftUI

/// Hands the hosting `NSWindow` to SwiftUI code once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let callback = onWindow
        Task { @MainActor [weak view] in
            // The window is attached after the first layout pass.
            try? await Task.sleep(nanoseconds: 80_000_000)
            if let window = view?.window { callback(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Screenshot support: sizes the main window and tells the capture script which window to shoot.
@MainActor
enum DemoWindows {
    static func register(_ kind: String, _ window: NSWindow) {
        guard DemoMode.isEnabled else { return }
        let target = kind == DemoMode.targetWindow
        Task { @MainActor in
            // Sheets and popovers make AppKit fit the window to the screen again, so the size is re-applied until the shot.
            for _ in 0..<12 {
                if kind == "main", let size = DemoMode.windowSize {
                    let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                    let wanted = NSRect(x: visible.minX, y: visible.maxY - size.height, width: size.width, height: size.height)
                    if window.frame.size != wanted.size { window.setFrame(wanted, display: true) }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard target else { return }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            guard let path = DemoMode.windowIDFile else { return }
            try? String(window.windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

enum DockyardWindowDefaults {
    /// About 1440 x 900, fitted to the screen's visible frame.
    @MainActor
    static var initialSize: CGSize {
        if let forced = DemoMode.windowSize { return forced }
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: min(1440, visible.width), height: min(900, visible.height))
    }
}
