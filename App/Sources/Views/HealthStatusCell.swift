import AppKit

/// The manager's Status cell: a symbol, the status text and, when known, the latency.
final class StatusCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [icon, label, detail])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ display: HealthStatusDisplay) {
        icon.image = NSImage(systemSymbolName: display.symbol, accessibilityDescription: nil)
        icon.contentTintColor = Self.color(display.tone)
        label.stringValue = display.text
        label.textColor = display.tone == .neutral ? .secondaryLabelColor : .labelColor
        detail.stringValue = display.detail ?? ""
        detail.isHidden = display.detail == nil
        toolTip = display.tooltip
        setAccessibilityLabel(display.accessibilityText)
    }

    private static func color(_ tone: HealthStatusDisplay.Tone) -> NSColor {
        switch tone {
        case .good: Palette.ns("StatusGreen")
        case .warning: Palette.ns("StatusAmber")
        case .bad: .systemRed
        case .neutral: .tertiaryLabelColor
        case .active: .controlAccentColor
        }
    }
}
