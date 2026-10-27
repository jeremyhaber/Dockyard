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
