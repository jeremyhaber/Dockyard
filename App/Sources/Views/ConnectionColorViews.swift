import AppKit
import DockyardCore
import SwiftUI

extension ConnectionColor {
    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .teal: .systemTeal
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        case .brown: .systemBrown
        case .gray: .systemGray
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Header and tab fill: light enough to keep text readable in both appearances.
    func fill(active: Bool) -> Color { color.opacity(active ? 0.32 : 0.18) }

    /// A filled circle for menus (SF Symbols in menus are drawn as templates and lose their colour).
    var swatch: NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension AppModel {
    func setColor(_ color: ConnectionColor?, for connection: Connection) {
        Task { try? await connections.update(connection.id) { $0.color = color } }
    }
}

/// "Colour" submenu for tab, column and sidebar context menus.
struct ConnectionColorMenu: View {
    @Environment(AppModel.self) private var app
    let connection: Connection

    var body: some View {
        Menu("Colour") {
            Button {
                app.setColor(nil, for: connection)
            } label: {
                if connection.color == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
            }
            Divider()
            ForEach(ConnectionColor.allCases, id: \.self) { color in
                Button {
                    app.setColor(color, for: connection)
                } label: {
                    Label { Text(connection.color == color ? "\(color.title) \u{2713}" : color.title) } icon: { Image(nsImage: color.swatch) }
                }
            }
        }
    }
}

/// A thin bar in the connection's colour along the top of its panel, drawn over it so headers stay aligned.
struct ConnectionColorStripe: View {
    let color: ConnectionColor?

    var body: some View {
        if let color {
            color.color.frame(height: 3).accessibilityHidden(true)
        }
    }
}

/// Site editor: colour label swatches.
struct ConnectionColorPicker: View {
    @Binding var selection: ConnectionColor?

    var body: some View {
        LabeledContent("Colour label") {
            HStack(spacing: 6) {
                swatch(nil)
                ForEach(ConnectionColor.allCases, id: \.self) { swatch($0) }
            }
        }
    }

    private func swatch(_ color: ConnectionColor?) -> some View {
        let selected = selection == color
        return Button {
            selection = color
        } label: {
            ZStack {
                Circle().fill(color?.color ?? Color.clear)
                if color == nil {
                    Circle().stroke(Palette.border)
                    Image(systemName: "slash.circle").font(.system(size: 14)).foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(width: 18, height: 18)
            .padding(2)
            .overlay(Circle().stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(color?.title ?? "No colour")
        .accessibilityLabel(color?.title ?? "No colour")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
