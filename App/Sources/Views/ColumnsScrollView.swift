import AppKit
import SwiftUI

/// Side-by-side columns in an AppKit scroll view: a classic, always-visible scroller you can drag whenever the
/// columns are wider than the window, sideways swipes anywhere over the columns, and the active column scrolled into view.
struct HorizontalColumns<Content: View>: NSViewRepresentable {
    let minimumWidth: CGFloat
    /// Each column's share of the width, left to right.
    let columnFractions: [CGFloat]
    let activeIndex: Int?
    let app: AppModel
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> ColumnsScrollView {
        let scroll = ColumnsScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.drawsBackground = false
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        scroll.documentView = hosting
        return scroll
    }

    func updateNSView(_ scroll: ColumnsScrollView, context: Context) {
        (scroll.documentView as? NSHostingView<AnyView>)?.rootView = root
        scroll.minimumContentWidth = minimumWidth
        scroll.columnFractions = columnFractions
        scroll.reveal(activeIndex)
    }

    private var root: AnyView {
        AnyView(content().frame(maxWidth: .infinity, maxHeight: .infinity).environment(app))
    }
}

final class ColumnsScrollView: NSScrollView {
    var minimumContentWidth: CGFloat = 0 {
        didSet { if oldValue != minimumContentWidth { tile() } }
    }
    var columnFractions: [CGFloat] = []
    private var revealedIndex: Int?
    private var monitor: Any?
    /// Whether the current trackpad gesture scrolls the columns (decided on its first movement).
    private var gestureRoutesHere: Bool?

    /// Overlay scrollers only appear while scrolling; the columns keep a scroller you can always see and drag.
    override var scrollerStyle: NSScroller.Style {
        get { .legacy }
        set { super.scrollerStyle = .legacy }
    }

    private var overflows: Bool { minimumContentWidth > bounds.width + 0.5 }

    override func tile() {
        super.tile()
        guard let document = documentView else { return }
        let scrollerHeight = overflows ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let frame = NSRect(x: 0, y: 0, width: max(bounds.width, minimumContentWidth), height: max(0, bounds.height - scrollerHeight))
        if document.frame != frame { document.frame = frame }
    }

    /// Scrolls just enough to show column `index` when the active column changes.
    func reveal(_ index: Int?) {
        guard index != revealedIndex else { return }
        revealedIndex = index
        guard let index, columnFractions.indices.contains(index) else { return }
        // Let SwiftUI add a new column and the document resize first.
        DispatchQueue.main.async { [weak self] in
            guard let self, let document = documentView else { return }
            tile()
            guard columnFractions.indices.contains(index) else { return }
            let usable = document.frame.width - CGFloat(columnFractions.count - 1)
            let minX = columnFractions.prefix(index).reduce(0, +) * usable + CGFloat(index)
            let column = NSRect(x: minX, y: 0, width: columnFractions[index] * usable, height: 1)
            let visible = contentView.bounds
            var x = visible.minX
            if column.minX < visible.minX {
                x = column.minX
            } else if column.maxX > visible.maxX {
                x = min(column.minX, column.maxX - visible.width)
            } else {
                return
            }
            x = max(0, min(x, document.frame.width - visible.width))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                contentView.animator().setBoundsOrigin(NSPoint(x: x, y: visible.minY))
            } completionHandler: { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated { self.reflectScrolledClipView(self.contentView) }
            }
        }
    }

    // MARK: Sideways scrolling over the file lists

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let unsafeEvent = event
            let consumed = MainActor.assumeIsolated { self?.route(unsafeEvent) ?? false }
            return consumed ? nil : event
        }
    }

    /// The tables and outlines inside the columns are scroll views of their own and would swallow sideways swipes.
    /// Sends those to the columns unless the view under the pointer can scroll sideways itself.
    /// Returns true when the columns took the event.
    private func route(_ event: NSEvent) -> Bool {
        guard event.window === window, overflows else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), !isOverScroller(point) else { return false }

        let routes: Bool
        if !event.momentumPhase.isEmpty {
            routes = gestureRoutesHere ?? false
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled { gestureRoutesHere = nil }
        } else if !event.phase.isEmpty {
            if event.phase == .began || event.phase == .mayBegin { gestureRoutesHere = nil }
            if gestureRoutesHere == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
                gestureRoutesHere = isSideways(event) && !innerScrollsSideways(at: event)
            }
            routes = gestureRoutesHere ?? false
        } else {
            // A mouse wheel (Shift turns it sideways): decide per event.
            routes = isSideways(event) && !innerScrollsSideways(at: event)
        }
        guard routes else { return false }
        scrollWheel(with: event)
        return true
    }

    private func isSideways(_ event: NSEvent) -> Bool {
        abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
    }

    private func isOverScroller(_ point: NSPoint) -> Bool {
        guard let scroller = horizontalScroller, !scroller.isHidden else { return false }
        return scroller.frame.contains(point)
    }

    private func innerScrollsSideways(at event: NSEvent) -> Bool {
        guard let root = window?.contentView, let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)) else { return false }
        var view: NSView? = hit
        while let current = view, current !== self {
            if let scroll = current as? NSScrollView, let document = scroll.documentView,
               document.frame.width > scroll.contentSize.width + 1 {
                return true
            }
            view = current.superview
        }
        return false
    }
}
