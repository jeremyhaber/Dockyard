import AppKit
import SwiftUI

/// Sizes of the folder tree above the file list. The list gives way first: the tree keeps its height until
/// the pane is too short to leave `minListHeight` for the list.
enum TreeLayout {
    static let defaultHeight = 200.0
    static let minHeight = 120.0
    static let maxHeight = 520.0
    static let minListHeight = 80.0
    /// Path bar, folder tabs, footer and dividers.
    static let chromeHeight = 90.0

    static func key(for side: PaneSide) -> String { "treeHeight.\(side.rawValue)" }

    static func clamp(_ height: Double, available: Double) -> Double {
        let ceiling = max(minHeight, min(maxHeight, available - chromeHeight - minListHeight))
        return min(max(height, minHeight), ceiling)
    }
}

/// The draggable divider under the folder tree.
struct TreeResizeHandle: View {
    let height: Double
    let onChange: (Double) -> Void
    @State private var dragStart: Double?

    var body: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(height: 1)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = dragStart ?? height
                                dragStart = start
                                onChange(bounded(start + value.translation.height))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
            .accessibilityElement()
            .accessibilityLabel("Resize folder tree")
            .accessibilityValue("\(Int(height)) points")
            .accessibilityAdjustableAction { direction in
                onChange(bounded(height + (direction == .increment ? 20 : -20)))
            }
    }

    private func bounded(_ value: Double) -> Double {
        min(max(value, TreeLayout.minHeight), TreeLayout.maxHeight)
    }
}

/// The expanded local pane in side by side.
enum LocalPaneLayout {
    static let defaultWidth = 320.0
    static let minWidth = 240.0
    static let maxWidth = 640.0

    static func clamp(_ width: Double) -> Double { min(max(width, minWidth), maxWidth) }
}

/// The draggable divider between side-by-side panes. Drag reports the distance from where the drag began;
/// double-click evens the panes out.
struct ColumnResizeHandle: View {
    let label: String
    let onBegin: () -> Void
    let onDrag: (Double) -> Void
    let onReset: () -> Void
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .onTapGesture(count: 2, perform: onReset)
                    .gesture(
                        // Global, because the handle moves with the drag.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if !dragging {
                                    dragging = true
                                    onBegin()
                                }
                                onDrag(value.translation.width)
                            }
                            .onEnded { _ in dragging = false }
                    )
            }
            .zIndex(1)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAdjustableAction { direction in
                onBegin()
                onDrag(direction == .increment ? 20 : -20)
            }
    }
}
