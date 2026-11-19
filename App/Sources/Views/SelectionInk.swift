import AppKit

/// A label whose colour turns white on an emphasized (accent-blue) selected row.
/// AppKit only flips the cell's own `textField`; fixed or secondary colours elsewhere stay dark on blue.
/// Callers keep assigning `textColor` as usual; that is the colour used on every other background.
final class InkLabel: NSTextField {
    private var ink: NSColor = .labelColor
    var onEmphasized = false { didSet { if onEmphasized != oldValue { refresh() } } }

    override var textColor: NSColor! {
        get { ink }
        set { ink = newValue ?? .labelColor; refresh() }
    }

    private func refresh() {
        super.textColor = onEmphasized ? .alternateSelectedControlTextColor : ink
    }
}

/// An icon whose tint turns white on an emphasized selected row (blue and red tints vanish on accent blue).
final class InkImageView: NSImageView {
    private var ink: NSColor?
    var onEmphasized = false { didSet { if onEmphasized != oldValue { refresh() } } }

    override var contentTintColor: NSColor? {
        get { ink }
        set { ink = newValue; refresh() }
    }

    private func refresh() {
        super.contentTintColor = onEmphasized ? .alternateSelectedControlTextColor : ink
    }
}

extension NSView {
    /// Tells every `InkLabel`/`InkImageView` below this view whether the row behind it is emphasized.
    func applySelectionInk(emphasized: Bool) {
        if let label = self as? InkLabel { label.onEmphasized = emphasized }
        if let image = self as? InkImageView { image.onEmphasized = emphasized }
        for sub in subviews { sub.applySelectionInk(emphasized: emphasized) }
    }
}
