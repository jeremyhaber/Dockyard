import AppKit
import ConnectionKit
import SwiftUI

/// Named colours from the asset catalog (HANDOFF section 12), each with a dark variant.
enum Palette {
    static let ground = Color("Ground")
    static let chrome = Color("Chrome")
    static let chromeAlt = Color("ChromeAlt")
    static let border = Color("Border")
    static let textPrimary = Color("TextPrimary")
    static let textSecondary = Color("TextSecondary")
    static let selection = Color("Selection")
    static let statusGreen = Color("StatusGreen")
    static let statusAmber = Color("StatusAmber")
    static let statusGrey = Color("StatusGrey")
    static let prodBg = Color("ProdBadgeBg")
    static let prodFg = Color("ProdBadgeFg")
    static let cloudBg = Color("CloudBadgeBg")
    static let cloudFg = Color("CloudBadgeFg")
    static let drawer = Color("DrawerBg")
    static let rootFg = Color("RootBadgeFg")

    static func ns(_ name: String) -> NSColor { NSColor(named: name) ?? .labelColor }

    static func statusColor(_ status: SessionStatus?) -> Color {
        switch status {
        case .connected: statusGreen
        case .connecting, .reconnecting: statusAmber
        case .failed, .disconnected, nil: statusGrey
        }
    }

    static func logColor(_ kind: LogLine.Kind) -> NSColor {
        switch kind {
        case .status: ns("LogStatus")
        case .command: ns("LogCommand")
        case .response: ns("LogResponse")
        case .warning: ns("LogWarning")
        case .error: ns("LogError")
        }
    }
}

extension Font {
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
}

/// A small coloured tag such as PROD or CLOUD.
struct Badge: View {
    enum Style { case prod, cloud, new, root }
    let text: String
    let style: Style

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 3))
            .accessibilityLabel(text)
    }

    private var foreground: Color {
        switch style {
        case .prod: Palette.prodFg
        case .cloud: Palette.cloudFg
        case .new: Color.accentColor
        case .root: Palette.rootFg
        }
    }

    private var background: Color {
        switch style {
        case .prod: Palette.prodBg
        case .cloud: Palette.cloudBg
        case .new: Color.accentColor.opacity(0.15)
        case .root: Palette.statusAmber.opacity(0.25)
        }
    }
}

struct StatusDot: View {
    let status: SessionStatus?
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Palette.statusColor(status))
            .frame(width: size, height: size)
            .accessibilityLabel(status?.label ?? "Not connected")
    }
}
